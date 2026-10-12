param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
if($c.scope -cne 'stock-specific-schema-refusals-small-causal-migration' -or $c.app_port -ne 3095 -or $c.pg_port -ne 5462 -or $c.database -cne 'process_intelligence'){throw 'migration_scope'}
$names=@($c.future_db,$c.checksum_db,$c.noop_db,$c.downgrade_db,$c.fault_db)
if(@($names|Sort-Object -Unique).Count -ne 5 -or @($names|Where-Object {$_ -cnotmatch '^pi_restore_s11_[a-z0-9_]{1,35}$'}).Count){throw 'new_migration_database_scope'}
if([DateTime]::UtcNow -ge [DateTime]'2026-10-12T16:45:00Z' -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 6GB){throw 'migration_resource_admission'}
Import-Module $c.service_module -Force -DisableNameChecking
$out=$c.output_directory;Assert-OwnedPrivateDirectory $out
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$service=$null;$stopped=$false
try{
 $service=Start-OwnedStockService $c $pkg 'startup01';[void](Wait-OwnedStockService $service)
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json
 $psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$app=Join-Path $pkg 'process-intelligence-rs.exe'
 $connection=@('-h','127.0.0.1','-p',[string]$c.pg_port,'-U','pi_admin','-w')
 $admin=@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c TimeZone=UTC -c DateStyle=ISO,YMD'}
 function Sql([string]$Database,[string]$Label,[string[]]$Arguments){
  if($Database -cne 'postgres' -and $Database -cne $c.database -and $Database -cnotin $names){throw 'migration_sql_scope'}
  return Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connection+@('-d',$Database,'-At','-v','ON_ERROR_STOP=1')+$Arguments) $pkg $out $Label $admin 60 16MB
 }
 function State([string]$Database,[string]$Label,[string]$File){
  $r=Sql $Database $Label @('-f',$File)
  return @{sha256=$r.stdout_sha256;bytes=$r.stdout_bytes_persisted;native_exit=$r.native_exit;database=$Database}
 }
 function Native([string]$Database,[string]$Label,[string[]]$Arguments,[string]$Program=$app,[string]$ProgramSha=$c.app_sha){
  if($Database -cnotin $names){throw 'migration_native_scope'}
  $url="host=127.0.0.1 port=$($c.pg_port) user=pi_admin password=$($secret.admin_password) dbname=$Database connect_timeout=5"
  $p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $ProgramSha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes 1MB -Environment @{PI_DATABASE_URL=$url;PORT=[string]$c.app_port}
  $end=[DateTime]::UtcNow.AddSeconds(60);$forced=$false
  while(-not $p.Process.WaitForExit(100)){
   if([DateTime]::UtcNow -ge $end -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(-not $p.Process.WaitForExit(10000)){throw 'migration_native_stop_timeout'};break}
  }
  $native=Complete-OwnedCapturedProcess $p
  return @{native=$native;forced=$forced}
 }
 function CompleteNative($p){$n=$p.native;return (-not $p.forced -and $n.stdout_complete -and $n.stderr_complete -and -not $n.output_limit -and -not $n.capture_fault -and -not $n.drain_timeout)}
 function Contract([string]$Database,[string]$Label,[string[]]$Arguments,[int]$ExpectedExit,[string]$ExpectedMessage,[string]$Program=$app,[string]$ProgramSha=$c.app_sha){
  $pre=State $Database ($Label+'-pre') $c.migration_capture
  $catalogPre=State $Database ($Label+'-catalog-pre') $c.migration_catalog
  $run=Native $Database $Label $Arguments $Program $ProgramSha
  $post=State $Database ($Label+'-post') $c.migration_capture
  $catalogPost=State $Database ($Label+'-catalog-post') $c.migration_catalog
  $stderr=Get-Content (Join-Path $out ($Label+'.stderr')) -Raw
  $passed=(CompleteNative $run) -and $run.native.native_exit -eq $ExpectedExit -and ($ExpectedMessage -ceq '' -or $stderr.Contains($ExpectedMessage)) -and $pre.sha256 -ceq $post.sha256 -and $catalogPre.sha256 -ceq $catalogPost.sha256
  $proof=@{status=$(if($passed){'FINITE_CONTRACT_EVIDENCE_READY_FOR_REVIEW'}else{'FAILED_RETAINED'});database=$Database;run=$run;expected_exit=$ExpectedExit;expected_message=$ExpectedMessage;actual_specific_message=$stderr.Contains($ExpectedMessage);pre=$pre;post=$post;catalog_pre=$catalogPre;catalog_post=$catalogPost;automatic_retry=$false}
  Write-OwnedJson (Join-Path $out ($Label+'-result.json')) $proof
  if(-not $passed){throw ('migration_contract_failed_'+$Label)}
  return $proof
 }
 # New stock account/import fixture supplies actual current schema and Auth.
 [void](Invoke-OwnedPhaseCommand $c.node $c.node_sha @($c.http_probe,$PhaseConfig,'seed') $c.workspace $out 'http-seed' @{} 180 1MB)
 $backup=Join-Path $pkg 'tools/database-backup.ps1';$archive=Join-Path $pkg '.local/migration-stock.dump'
 [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Backup','-Database',$c.database,'-BackupFile',$archive) $pkg $out 'stock-backup' @{} 120)
 foreach($pair in @(@($c.future_db,'future'),@($c.checksum_db,'checksum'),@($c.noop_db,'noop'),@($c.downgrade_db,'downgrade'))){
  [void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$backup,'-Mode','Restore','-BackupFile',$archive,'-TargetDatabase',$pair[0]) $pkg $out ('restore-'+$pair[1]) @{} 120)
 }
 [void](Sql $c.future_db 'fixture-future' @('-c','UPDATE public.pi_schema_migrations SET version=3 WHERE version=2;'))
 [void](Sql $c.checksum_db 'fixture-checksum' @('-c',"UPDATE public.pi_schema_migrations SET checksum=repeat('0',64) WHERE version=2;"))
 $schemaMessage='Схема базы не поддерживается или повреждена. База не изменена; используйте совместимую версию и резервную копию.'
 $normalizedMessage='Схема или сохранённые данные не поддерживаются. Исходные записи не изменены; проверьте состояние миграции.'
 $future=Contract $c.future_db 'future-normal' @() 1 $schemaMessage
 $futureOffline=Contract $c.future_db 'future-offline' @('--migrate-storage') 1 $schemaMessage
 $checksum=Contract $c.checksum_db 'checksum-normal' @() 1 $normalizedMessage
 $checksumOffline=Contract $c.checksum_db 'checksum-offline' @('--migrate-storage') 1 $normalizedMessage
 $noop=Contract $c.noop_db 'ready-noop' @('--migrate-storage') 0 ''
 $downgrade=Contract $c.downgrade_db 'old03-schema-refusal' @() 1 $schemaMessage $c.old_exe $c.old_exe_sha
 # Separate tiny causal v1 fixture. No claim of full historical/Auth migration.
 [void](Sql 'postgres' 'create-fault-database' @('-c',('CREATE DATABASE "'+$c.fault_db+'"')))
 $migrationSource=Get-Content $c.migrations_source -Raw
 $match=[regex]::Match($migrationSource,'const MIGRATION: &str = "([^"\r\n]+)";')
 if(-not $match.Success){throw 'baseline_checksum_literal_binding'}
 $baselineChecksum=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($match.Groups[1].Value))).ToLowerInvariant()
 [void](Sql $c.fault_db 'fixture-v1' @('-v',('baseline_checksum='+$baselineChecksum),'-f',$c.v1_fixture))
 $legacyPre=State $c.fault_db 'v1-pre-fault' $c.migration_capture
 [void](Sql $c.fault_db 'install-ddl-fault' @('-f',$c.fault_fixture))
 $rollback=Contract $c.fault_db 'ddl-rollback' @('--migrate-storage') 1 'База недоступна; изменение не подтверждено.'
 $pgLog=Join-Path $pkg '.local/logs/postgres-server.log'
 if((Get-Item $pgLog).Length -gt 1MB){throw 'migration_pg_fault_log_bound'}
 $faultLines=@((Get-OwnedLivePrefix $pgLog 1MB) -split "`n"|Where-Object {$_ -match '\[\d+\].*ERROR:\s+sprint11 owned migration DDL fault'})
 if($faultLines.Count -ne 1){throw 'actual_owned_ddl_fault_reason_required'}
 Write-OwnedJson (Join-Path $out 'ddl-fault-server-proof.json') @{actual_pg_error_reason='sprint11 owned migration DDL fault';matches=1;scope='New owned PostgreSQL server error, independently preserved raw log; not a CLI generic-error substitution'}
 [void](Sql $c.fault_db 'remove-ddl-fault' @('-f',$c.fault_remove))
 $afterFaultRemoval=State $c.fault_db 'v1-after-fault-removal' $c.migration_capture
 if($legacyPre.sha256 -cne $afterFaultRemoval.sha256){throw 'legacy_rows_changed_after_fault_removal'}
 $resume=Native $c.fault_db 'ddl-resume' @('--migrate-storage')
 $resumed=State $c.fault_db 'v2-resumed' $c.migration_capture
 if(-not (CompleteNative $resume) -or $resume.native.native_exit -ne 0){throw 'migration_resume_failed_retained'}
 $legacyRows=@(Get-Content (Join-Path $out 'v1-pre-fault.stdout')|Where-Object {$_ -match '^\['}|ForEach-Object {$row=$_|ConvertFrom-Json -NoEnumerate;if($row[0] -cin @('pi_kv','pi_resource_sequence','sequence_definition') -or ($row[0] -ceq 'pi_schema_migrations' -and $row[1].version -eq 1)){$_}})
 $resumedRows=@(Get-Content (Join-Path $out 'v2-resumed.stdout')|Where-Object {$_ -match '^\['}|ForEach-Object {$row=$_|ConvertFrom-Json -NoEnumerate;if($row[0] -cin @('pi_kv','pi_resource_sequence','sequence_definition') -or ($row[0] -ceq 'pi_schema_migrations' -and $row[1].version -eq 1)){$_}})
 if($legacyRows.Count -ne 4 -or ($legacyRows -join "`n") -cne ($resumedRows -join "`n")){throw 'resume_rewrote_original_rows_or_sequence_or_ledger1'}
 $repeat=Contract $c.fault_db 'v2-repeat-noop' @('--migrate-storage') 0 ''
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 Test-OwnedPackageTree $pkg $c.manifest_sha $true
 Write-OwnedJson (Join-Path $out 'migration-result.json') @{status='FINITE_SPECIFIC_REFUSAL_AND_SMALL_CAUSAL_MIGRATION_EVIDENCE_READY_FOR_REVIEW';future=$future;future_offline=$futureOffline;checksum=$checksum;checksum_offline=$checksumOffline;ready_noop=$noop;old03_refusal=$downgrade;ddl_rollback=$rollback;resume=$resume;resumed=$resumed;repeat_noop=$repeat;limits=@('Small causal v1 fixture is not full original historical migration acceptance','Raw complete managed rows and explicit structural/ACL/event-trigger projection, not whole physical cluster','No post-login Auth transformation, migrated RBAC, browser/Datastar or full R3 acceptance')}
}finally{
 $secret=$null;$admin=$null
 if($service -and -not $stopped -and -not $service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}
}
