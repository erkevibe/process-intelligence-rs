param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# New runtime restoration only. Verification copies and historical databases stay offline.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'list_config_before_import'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha))){if((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $pin[0])).Hash -cne $pin[1].ToUpperInvariant()){throw 'list_module_before_import'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's13-project-list-rbac-restored-runtime' -or $c.database -cne 'process_intelligence' -or $c.target_database -cnotmatch '^pi_restore_s13_list_[a-z0-9_]{1,20}$' -or $c.app_port -ne 3097 -or $c.pg_port -ne 5465 -or $c.version -cne '0.7.3'){throw 'list_finite_scope'}
$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($deadline -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or [DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'list_admission'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$out=$c.output_directory;Assert-OwnedPrivateDirectory $out
Assert-OwnedHash $c.fixture_review $c.fixture_review_sha
$review=Get-Content -LiteralPath $c.fixture_review -Raw|ConvertFrom-Json
if($review.status -cne 'S13_MAINTAINED_SMALL_S_INPUT_REVIEWED' -or $review.archive_sha -cne $c.small_archive_sha -or $review.manifest_sha -cne $c.small_manifest_sha){throw 'list_accepted_fixture_required'}
Assert-OwnedHash $c.small_archive $c.small_archive_sha;Assert-OwnedHash ($c.small_archive+'.manifest.json') $c.small_manifest_sha
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$manifest=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($manifest.source_commit -cne $c.source_commit -or $manifest.version -cne '0.7.3'){throw 'list_candidate_binding'}
$app=Join-Path $pkg 'process-intelligence-rs.exe';Assert-OwnedHash $app $c.app_sha
$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
$service=$null;$runtime=$null;$secret=$null;$admin=$null;$complete=$false
function Budget {
 if([DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 4GB){throw 'list_floor_freeze'}
 $total=[long](Get-ChildItem -LiteralPath (Join-Path $c.workspace '.local/sprint13') -File -Recurse -Force|Measure-Object Length -Sum).Sum
 if($total -gt 16GB -or [long](Get-ChildItem -LiteralPath $out -File -Recurse -Force|Measure-Object Length -Sum).Sum -gt 512MB){throw 'list_logical_evidence_cap'}
}
function Sql([string]$Label,[string]$Text){
 Budget
 return Invoke-OwnedPhaseCommand $psql $c.psql_sha @('-X','-qAt','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5465','-U','pi_admin','-w','-d',$c.target_database,'-c',$Text) $pkg $out $Label $admin 60 8MB
}
$captureSql=@'
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT jsonb_build_object('kv',(SELECT jsonb_agg(to_jsonb(t) ORDER BY key) FROM public.pi_kv t),'projects',(SELECT jsonb_agg(to_jsonb(t) ORDER BY project_id) FROM public.pi_projects t),'records',(SELECT jsonb_agg(to_jsonb(t) ORDER BY project_id,kind,resource_id) FROM public.pi_records t),'markers',(SELECT jsonb_agg(to_jsonb(t) ORDER BY project_id) FROM public.pi_migration_v2 t),'ledger',(SELECT jsonb_agg(to_jsonb(t) ORDER BY version) FROM public.pi_schema_migrations t),'sequence',(SELECT jsonb_build_array(q.last_value::text,q.log_cnt::text,q.is_called,s.seqtypid::text,s.seqstart::text,s.seqincrement::text,s.seqmax::text,s.seqmin::text,s.seqcache::text,s.seqcycle) FROM public.pi_resource_sequence q CROSS JOIN pg_sequence s WHERE s.seqrelid='public.pi_resource_sequence'::regclass));
COMMIT;
'@
try{
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @('--check',$c.probe) $c.workspace $out 'probe-syntax' @{} 30 1MB)
 $service=Start-OwnedStockService $c $pkg 'list-stock';[void](Wait-OwnedStockService $service)
 $old=@($service.Processes|Where-Object Name -ceq 'app');if($old.Count -ne 1 -or !$service.Job.Member($old[0].Handle)){throw 'list_initial_app_identity'}
 $old[0].Process.Kill();if(!$old[0].Process.WaitForExit(10000)){throw 'list_initial_app_stop'}
 Write-OwnedJson (Join-Path $out 'bootstrap-app-forced-stop.json') @{pid=$old[0].Process.Id;creation_utc=$old[0].Creation;native_exit=$old[0].Process.ExitCode;no_clean_app_exit_claim=$true}
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json
 $admin=@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c default_transaction_read_only=on -c TimeZone=UTC -c DateStyle=ISO,YMD'}
 $archive=Join-Path $pkg '.local/list-input.dump';[IO.File]::Copy($c.small_archive,$archive,$false);[IO.File]::Copy(($c.small_archive+'.manifest.json'),($archive+'.manifest.json'),$false)
 $originalManifest=Get-Content ($archive+'.manifest.json') -Raw|ConvertFrom-Json
 [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out 'restore-stdio.json'),'-ArgumentsJson',(@{Mode='Restore';Database=$originalManifest.database;BackupFile=$archive;TargetDatabase=$c.target_database}|ConvertTo-Json -Compress)) $pkg $out 'restore-list-runtime' @{} 120 4MB)
 [void](Sql 'runtime-restored-pre' $captureSql)
 $pre=Get-Content (Join-Path $out 'runtime-restored-pre.stdout') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 $seed=Get-Content $c.seed_capture -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 foreach($key in @('kv','projects','records','markers','ledger')){if(($pre[$key]|ConvertTo-Json -Depth 100 -Compress) -cne ($seed[$key]|ConvertTo-Json -Depth 100 -Compress)){throw 'list_restored_small_fixture_changed'}}
 $d=$seed.sequence.definition
 if($d.data_type -cne 'bigint'){throw 'list_expected_sequence_type'}
 $expectedSequence=@($seed.sequence.last_value,$seed.sequence.log_cnt,$seed.sequence.is_called,'20',$d.start_value,$d.increment_by,$d.max_value,$d.min_value,$d.cache_size,$d.cycle)
 if(($pre.sequence|ConvertTo-Json -Compress) -cne ($expectedSequence|ConvertTo-Json -Compress)){throw 'list_restored_sequence_changed'}
 [void](Sql 'runtime-identity' "SELECT jsonb_build_object('database',current_database(),'database_oid',(SELECT oid::text FROM pg_database WHERE datname=current_database()),'system_identifier',(pg_control_system()).system_identifier::text);")
 $url="host=127.0.0.1 port=5465 user=pi_app password=$($secret.app_password) dbname=$($c.target_database) connect_timeout=5 application_name=s13_project_list_http"
 $runtime=Start-OwnedCapturedProcess -Program $app -ProgramSha256 $c.app_sha -Arguments @() -WorkingDirectory $pkg -OutputDirectory $out -Label 'list-runtime' -MaxOutputBytes 8MB -Environment @{PI_DATABASE_URL=$url;PORT='3097';RUST_LOG='info'}
 $creation=$runtime.Process.StartTime.ToUniversalTime().ToString('o')
 $readyEnd=[DateTime]::UtcNow.AddSeconds(30)
 do{if($runtime.Process.HasExited -or [DateTime]::UtcNow -ge $readyEnd){throw 'list_runtime_not_ready'};$listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object LocalPort -eq 3097);if($listeners.Count){if(@($listeners|Where-Object {$_.OwningProcess -ne $runtime.Process.Id -or $_.LocalAddress -notin @('127.0.0.1','::1')}).Count){throw 'list_runtime_listener_identity'};break};Start-Sleep -Milliseconds 100}while($true)
 $runtimeCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id)
 if(!$runtimeCim -or $runtimeCim.ExecutablePath -cne $app -or $runtime.Process.HasExited -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation){throw 'list_ready_identity'}
 $cimCreation=$runtimeCim.CreationDate.ToUniversalTime().ToString('o')
 # Outer readiness uses its own CIM sample; native identity remains separately
 # bound to the retained handle instead of cross-API timestamp equality.
 Wait-OwnedReadyJob @(@{name='app';pid=$runtime.Process.Id;creation_utc=$cimCreation}) $out
 [void](Sql 'runtime-before-login' $captureSql)
 if((Get-OwnedHash (Join-Path $out 'runtime-before-login.stdout')) -cne (Get-OwnedHash (Join-Path $out 'runtime-restored-pre.stdout'))){throw 'list_startup_changed_managed_state'}
 $admission=Join-Path $out 'runtime-admission.json'
 Write-OwnedJson $admission @{scope='S13_NEW_RESTORED_PROJECT_LIST_RUNTIME_REVIEWED';database=$c.target_database;app_port=3097;pg_port=5465;version='0.7.3';app_sha256=$c.app_sha;app_pid=$runtime.Process.Id;creation_utc=$creation;cim_creation_utc=$cimCreation;outer_ready_response_sha256=Get-OwnedHash (Join-Path $out 'ready-response.json');database_identity_sha256=Get-OwnedHash (Join-Path $out 'runtime-identity.stdout');fixture_review_sha256=$c.fixture_review_sha;scope_limit='Launcher native+restore admission only, not result acceptance'}
 $probe=@{scope='s13-new-restored-project-list-rbac';version='0.7.3';database=$c.target_database;app_port=3097;pg_port=5465;output_directory=$out;credentials_private=$c.credentials_private;actor_ids=$c.actor_ids;projects=$c.projects;app_sha256=$c.app_sha;http_client_sha=$c.http_client_sha;runtime_admission=@{path=$admission;sha256=Get-OwnedHash $admission};source_pins=$c.probe_source_pins;deadline_utc=$c.deadline_utc}
 $probeConfig=Join-Path $out 'http-probe-config.json';Write-OwnedJson $probeConfig $probe
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.probe,$probeConfig) $c.workspace $out 'project-list-http' @{PI_PROJECT_LIST_PROBE_CONFIG_SHA=(Get-OwnedHash $probeConfig).ToLowerInvariant()} 660 1MB)
 [void](Sql 'runtime-after-http' $captureSql)
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256};Budget
 Write-OwnedJson (Join-Path $out 'project-list-phase-result.json') @{status='FINITE_RESTORED_RUNTIME_HTTP_EVIDENCE_PENDING_INDEPENDENT_WHOLE_AUTH_DELTA_REVIEW';source_commit=$c.source_commit;runtime_admission_sha256=Get-OwnedHash $admission;restored_pre_sha256=Get-OwnedHash (Join-Path $out 'runtime-restored-pre.stdout');before_login_sha256=Get-OwnedHash (Join-Path $out 'runtime-before-login.stdout');after_http_sha256=Get-OwnedHash (Join-Path $out 'runtime-after-http.stdout');limits=@('Synthetic maintained SmallS runtime only','Whole SQL/Auth/membership/session/sequence delta oracle mandatory separately','No browser/Datastar/fullC18/history/persistence-fault acceptance')}
 $complete=$true
}catch{
 $failure=@{status='FAILED_RETAINED';automatic_retry=$false;managed_state='NOT_AVAILABLE';no_success_claim=$true}
 if($secret -and $admin -and (Test-Path (Join-Path $out 'runtime-identity.stdout'))){try{[void](Sql 'runtime-failure-state' $captureSql);$failure.managed_state_sha256=Get-OwnedHash (Join-Path $out 'runtime-failure-state.stdout');$failure.managed_state='FULL_CAPTURED'}catch{$failure.managed_state='CAPTURE_UNAVAILABLE_RETAINED'}}
 Write-OwnedJson (Join-Path $out 'project-list-failed.json') $failure
 throw
}finally{
 try{
  if($runtime){
   if(!$runtime.Process.HasExited){$again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id);if(!$again -or $again.ExecutablePath -cne $app -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation){throw 'list_final_runtime_identity'};$runtime.Process.Kill()}
   if(!$runtime.Process.WaitForExit(10000)){throw 'list_final_runtime_stop'}
   $ended=Complete-OwnedCapturedProcess $runtime
   Write-OwnedJson (Join-Path $out 'list-runtime-forced-stop.json') @{native=$ended;controlled_forced_stop=$true;no_clean_exit_claim=$true}
   if(!$ended.stdout_complete -or !$ended.stderr_complete -or $ended.capture_fault -or $ended.output_limit -or $ended.drain_timeout){throw 'list_runtime_capture_incomplete'}
  }
 }finally{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'};$secret=$null;$admin=$null}
}
if(!$complete){throw 'list_phase_incomplete'}
