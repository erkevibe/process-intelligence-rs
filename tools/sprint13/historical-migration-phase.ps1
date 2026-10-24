param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'historical_config_before_import'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha))){if($pin[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $pin[0])).Hash -cne $pin[1].ToUpperInvariant()){throw 'historical_module_before_import'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($deadline -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or [DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'historical_capacity_freeze'}
function CheckHistoricalBudget([long]$Reserve=0) {
 if([DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 4GB){throw 'historical_capacity_floor_freeze'}
 $logical=[long](Get-ChildItem -LiteralPath (Join-Path $c.workspace '.local/sprint13') -Recurse -File -Force|Measure-Object Length -Sum).Sum
 if($logical+$Reserve -gt 16GB){throw 'historical_logical_cap'}
}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
if($c.scope -cne 'full-genuine03-offline-migration-and-native-interruption' -or $c.pg_port -ne 5465){throw 'historical_scope'}
$names=@($c.original_db,$c.forward_db,$c.interrupted_db)
if(@($names|Sort-Object -Unique).Count -ne 3 -or @($names|Where-Object{$_ -cnotmatch '^pi_restore_s13_[a-z0-9_]{1,35}$'}).Count){throw 'new_historical_database_scope'}
$out=$c.output_directory;Assert-OwnedPrivateDirectory $out
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$manifest=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($manifest.source_commit -cne $c.source_commit -or $manifest.build_proof.executable_sha256 -cne $c.app_sha){throw 'candidate_binding'}
$bin=Join-Path $pkg 'runtime/postgresql/pgsql/bin'
$psql=Join-Path $bin 'psql.exe';$app=Join-Path $pkg 'process-intelligence-rs.exe'
$secret=$null;$pg=$null;$clean=$false
try{
 [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$c.stdio_wrapper,'-Script',(Join-Path $pkg 'tools/setup-postgres.ps1'),'-ScriptSha',(Get-OwnedHash (Join-Path $pkg 'tools/setup-postgres.ps1')),'-Proof',(Join-Path $out 'bootstrap-stdio.json'),'-ArgumentsJson',(@{Port=$c.pg_port}|ConvertTo-Json -Compress)) $pkg $out 'bootstrap' @{} 120)
 $listeners=@(Get-NetTCPConnection -LocalPort $c.pg_port -State Listen -ErrorAction Stop)
 $ids=@($listeners.OwningProcess|Select-Object -Unique)
 if($ids.Count -ne 1 -or @($listeners|Where-Object LocalAddress -notin @('127.0.0.1','::1')).Count){throw 'new_pg_listener'}
 $pg=[Diagnostics.Process]::GetProcessById($ids[0]);$handle=$pg.Handle
 $cp=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg.Id)
 $image=Join-Path $bin 'postgres.exe';$data=Join-Path $pkg '.local/pgdata'
 if($cp.ExecutablePath -cne $image -or $pg.HasExited){throw 'new_pg_identity'}
 Assert-OwnedHash $image $c.postgres_sha
 Write-OwnedJson (Join-Path $out 'postgres-argv.json') @{pid=$pg.Id;creation_utc=$cp.CreationDate.ToUniversalTime().ToString('o');command_line=$cp.CommandLine;image=$image;sha256=$c.postgres_sha}
 [void](Get-OwnedDatadirArgument $cp.CommandLine $data)
 Wait-OwnedReadyJob @(@{name='postgres';pid=$pg.Id;creation_utc=$cp.CreationDate.ToUniversalTime().ToString('o')}) $out
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json
 $admin=@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c TimeZone=UTC -c DateStyle=ISO,YMD'}
 $connection=@('-h','127.0.0.1','-p',[string]$c.pg_port,'-U','pi_admin','-w')
 function Sql([string]$Database,[string]$Label,[string[]]$Arguments,[long]$Cap=16MB){
  if($Database -cne 'postgres' -and $Database -cnotin $names){throw 'historical_sql_scope'}
  return Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connection+@('-d',$Database,'-qAt','-v','ON_ERROR_STOP=1')+$Arguments) $pkg $out $Label $admin 120 $Cap
 }
 function State([string]$Database,[string]$Label){CheckHistoricalBudget 1GB;$r=Sql $Database $Label @('-f',$c.capture_sql) 1GB;CheckHistoricalBudget;return $r}
 function Oracle([string]$Label,[string[]]$Arguments){return Invoke-OwnedPhaseCommand $c.node $c.node_sha (@($c.oracle)+$Arguments) $c.workspace $out $Label @{} 180 1MB}
 function Migrate([string]$Database,[string]$Label,[bool]$Interrupt=$false){
  if($Database -cnotin $names){throw 'historical_native_scope'}
  $application='s13historical_'+$Label
  if($application -cnotmatch '^s13historical_[a-z-]+$'){throw 'historical_backend_label'}
  $url="host=127.0.0.1 port=$($c.pg_port) user=pi_app password=$($secret.app_password) dbname=$Database connect_timeout=5 application_name=$application"
  $p=Start-OwnedCapturedProcess -Program $app -ProgramSha256 $c.app_sha -Arguments @('--migrate-storage') -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes 4MB -Environment @{PI_DATABASE_URL=$url}
  $end=[DateTime]::UtcNow.AddSeconds(300);$killed=$false;$progress=$false;$stop=$false;$backend=$null
  if($Interrupt){
   $identifyEnd=[DateTime]::UtcNow.AddSeconds(5);$poll=0
   do{
    $poll++;$witnessLabel=$Label+'-backend-identify-'+$poll
    [void](Sql 'postgres' $witnessLabel @('-c',("SET statement_timeout='2s'; SELECT coalesce(jsonb_agg(jsonb_build_object('pid',pid,'database',datname,'username',usename,'application_name',application_name,'backend_start',backend_start,'state',state,'xact_start',xact_start)), '[]'::jsonb) FROM pg_stat_activity WHERE datname='"+$Database+"' AND usename='pi_app' AND application_name='"+$application+"';")) 1MB)
    $found=@(Get-Content (Join-Path $out ($witnessLabel+'.stdout')) -Raw|ConvertFrom-Json -DateKind String)
    if($found.Count -gt 1){throw 'historical_backend_not_unique'}
    if($found.Count -eq 1){$backend=$found[0];break}
    if($p.Process.HasExited -or [DateTime]::UtcNow -ge $identifyEnd){throw 'historical_backend_not_observed'}
   }while($true)
   Write-OwnedJson (Join-Path $out ($Label+'-backend-bound.json')) @{native_pid=$p.Process.Id;backend=$backend;scope='Actual unique pi_app backend in this new database and unique application_name; no PID inferred from client PID'}
  }
  while(-not $p.Process.WaitForExit(50)){
   if($Interrupt -and (Test-Path (Join-Path $out ($Label+'.stderr')))){
    $prefix=Get-OwnedLivePrefix (Join-Path $out ($Label+'.stderr')) 1MB
    if($prefix.Contains('migration_v2_record_verified')){$progress=$true;$p.Process.Kill($true);$killed=$true;break}
   }
   if([DateTime]::UtcNow -ge $end -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$stop=$true;$p.Process.Kill($true);break}
  }
  if(-not $p.Process.WaitForExit(10000)){throw 'historical_native_stop_timeout'}
  $r=Complete-OwnedCapturedProcess $p
  Write-OwnedJson (Join-Path $out ($Label+'-interruption.json')) @{native=$r;killed=$killed;committed_record_log_observed=$progress;budget_or_capture_stop=$stop;scope='Post-commit production progress log triggers native interruption; complete persisted state is checked separately. No exact last SQL instruction claim.'}
  if($stop -or -not $r.stdout_complete -or -not $r.stderr_complete -or $r.output_limit -or $r.capture_fault){throw 'historical_native_capture_failed'}
  if($Interrupt){if(-not $killed -or -not $progress -or $r.native_exit -eq 0){throw 'historical_interruption_boundary_not_observed'}}elseif($r.native_exit -ne 0){throw 'historical_migration_failed_no_retry'}
  if($Interrupt){
   $goneEnd=[DateTime]::UtcNow.AddSeconds(5);$poll=0
   do{
    $poll++;$witnessLabel=$Label+'-backend-quiescence-'+$poll
    [void](Sql 'postgres' $witnessLabel @('-c',("SET statement_timeout='2s'; SELECT jsonb_build_object('pid_still_present',EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid="+[string]$backend.pid+"),'matching_backends',(SELECT count(*) FROM pg_stat_activity WHERE datname='"+$Database+"' AND usename='pi_app' AND application_name='"+$application+"'));")) 1MB)
    $gone=Get-Content (Join-Path $out ($witnessLabel+'.stdout')) -Raw|ConvertFrom-Json
    if(!$gone.pid_still_present -and $gone.matching_backends -eq 0){break}
    if([DateTime]::UtcNow -ge $goneEnd){throw 'historical_backend_not_quiescent'}
   }while($true)
   Write-OwnedJson (Join-Path $out ($Label+'-backend-quiescent.json')) @{backend_pid=$backend.pid;actual_native=$r;final_observation=$gone;no_resume_before_persisted_partial_inspection=$true}
  }
  CheckHistoricalBudget
  return $r
 }
 # Explicit adapter: the genuine original dump has no stock manifest.
 # Restore untouched bytes with the stock ownership policy, never fabricate one.
 [void](Sql 'postgres' 'create-original' @('-c',('CREATE DATABASE "'+$c.original_db+'" OWNER pi_app;')))
 [void](Invoke-OwnedPhaseCommand (Join-Path $bin 'pg_restore.exe') $c.pg_restore_sha ($connection+@('-d',$c.original_db,'--exit-on-error','--single-transaction','--no-owner','--no-privileges','--role=pi_app',$c.original_archive)) $pkg $out 'original-raw-restore' $admin 180 16MB)
 $original=State $c.original_db 'original-full'
 [void](Oracle 'original-independent-oracle' @('--mode','original','--legacy-values',$c.original_values,'--capture',(Join-Path $out 'original-full.stdout'),'--sequence',$c.original_sequence))
 $backup=Join-Path $pkg 'tools/database-backup.ps1';$archive=Join-Path $pkg '.local/historical-stock.dump'
 [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Backup','-Database',$c.original_db,'-BackupFile',$archive) $pkg $out 'original-stock-backup' @{} 180)
 foreach($pair in @(@($c.forward_db,'forward'),@($c.interrupted_db,'interrupted'))){
  [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Restore','-Database',$c.original_db,'-BackupFile',$archive,'-TargetDatabase',$pair[0]) $pkg $out ('restore-'+$pair[1]) @{} 180)
  $r=State $pair[0] ($pair[1]+'-pre')
  if($r.stdout_sha256 -cne $original.stdout_sha256 -or $r.stdout_bytes_persisted -ne $original.stdout_bytes_persisted){throw 'full_original_restore_changed'}
 }
 $start=[DateTime]::UtcNow.ToString('o')
 $forward=Migrate $c.forward_db 'forward'
 $forwardEnd=[DateTime]::UtcNow.ToString('o');$post=State $c.forward_db 'forward-post'
 $oracleArgs=@('--mode','forward','--legacy-values',$c.original_values,'--sequence',$c.original_sequence,'--source-hashes',$c.source_hashes,'--source-hashes-sha',$c.source_hashes_sha,'--checksum',$c.normalized_checksum)
 [void](Oracle 'forward-independent-oracle' ($oracleArgs+@('--capture',(Join-Path $out 'forward-post.stdout'),'--not-before',$start,'--not-after',$forwardEnd)))
 $noop=Migrate $c.forward_db 'forward-noop';$noopPost=State $c.forward_db 'forward-noop-post'
 if($noopPost.stdout_sha256 -cne $post.stdout_sha256){throw 'historical_noop_changed'}
 $faultStart=[DateTime]::UtcNow.ToString('o');$interruption=Migrate $c.interrupted_db 'interrupted' $true
 $partial=State $c.interrupted_db 'partial-persisted'
 [void](Oracle 'partial-independent-oracle' @('--mode','partial','--legacy-values',$c.original_values,'--sequence',$c.original_sequence,'--source-hashes',$c.source_hashes,'--source-hashes-sha',$c.source_hashes_sha,'--checksum',$c.normalized_checksum,'--capture',(Join-Path $out 'partial-persisted.stdout')))
 $partialSummary=Sql $c.interrupted_db 'partial-summary' @('-c',"SELECT jsonb_build_object('ledger2',(SELECT count(*) FROM public.pi_schema_migrations WHERE version=2),'projects',(SELECT count(*) FROM public.pi_projects),'records',(SELECT count(*) FROM public.pi_records),'markers',(SELECT count(*) FROM public.pi_migration_v2));")
 $summary=Get-Content (Join-Path $out 'partial-summary.stdout') -Raw|ConvertFrom-Json
 if($summary.ledger2 -ne 0 -or $summary.projects -lt 1 -or $summary.records -lt 1 -or $summary.markers -lt 1){throw 'historical_partial_progress_not_proven'}
 $resumed=Migrate $c.interrupted_db 'resumed';$resumeEnd=[DateTime]::UtcNow.ToString('o');$resumedPost=State $c.interrupted_db 'resumed-post'
 [void](Oracle 'resumed-independent-oracle' ($oracleArgs+@('--capture',(Join-Path $out 'resumed-post.stdout'),'--not-before',$faultStart,'--not-after',$resumeEnd)))
 $originalAfter=State $c.original_db 'original-untouched-final'
 if($originalAfter.stdout_sha256 -cne $original.stdout_sha256){throw 'original_verification_copy_changed'}
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
 CheckHistoricalBudget
 Write-OwnedJson (Join-Path $out 'historical-result.json') @{status='FULL_HISTORICAL_OFFLINE_FORWARD_NATIVE_PARTIAL_INTERRUPTION_RESUME_AND_NOOP_READY_FOR_INDEPENDENT_REVIEW';original=$original;forward=$forward;post=$post;noop=$noop;interruption=$interruption;partial=$partial;partial_summary=$summary;resumed=$resumed;resumed_post=$resumedPost;verification_final=$originalAfter;automatic_retry=$false;limits=@('Separate explicit new-operation resume after inspection, not blind retry','No HTTP/RBAC/downgrade/future-schema/source-mutation/cleanup credit from this phase','Original raw dump adapter provenance differs from newly generated stock backup manifest')}
}finally{
 if($pg -and -not $pg.HasExited){
  [void](Invoke-OwnedPhaseCommand (Join-Path $bin 'pg_ctl.exe') $c.pg_ctl_sha @('-D',(Join-Path $pkg '.local/pgdata'),'-w','-t','15','stop','-m','fast') $pkg $out 'pg-fast-stop' @{} 30)
  if(-not $pg.WaitForExit(10000) -or $pg.ExitCode -ne 0){throw 'historical_postmaster_not_clean'}
  Write-OwnedJson (Join-Path $out 'postgres-clean-exit.json') @{pid=$pg.Id;native_exit=$pg.ExitCode;clean_before_outer_job_close=$true}
 }
 if($pg){$pg.Dispose()};$secret=$null;$admin=$null
}
