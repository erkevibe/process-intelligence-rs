param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# New synthetic maintained SMALL S only. No historical source/recovery acceptance.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'small_seed_config_before_import'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in @(@((Join-Path $PSScriptRoot 'owned-runtime.psm1'),$c.module_sha),@((Join-Path $PSScriptRoot 'owned-phase-support.psm1'),$c.phase_support_sha),@((Join-Path $PSScriptRoot 'owned-stock-service.psm1'),$c.service_sha))){if($pin[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $pin[0]).Hash -cne $pin[1].ToUpperInvariant()){throw 'small_seed_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's13-maintained-small-seed' -or $c.pg_port -ne 5465 -or $c.app_port -ne 3097 -or $c.database -cne 'process_intelligence' -or $c.seed_database -cne 'pi_restore_s13_small_seed01' -or $c.version -cne '0.7.3' -or $c.source_commit -cnotmatch '^[a-f0-9]{40}$'){throw 'finite_small_seed_scope'}
if((Get-OwnedCanonicalPath $c.http_probe) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'small-seed-probe.cjs')) -or (Get-OwnedCanonicalPath $c.baseline_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../migration-fixture-v1.sql')) -or (Get-OwnedCanonicalPath $c.migrations_source) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../../src/migrations.rs'))){throw 'literal_maintained_seed_sources'}
$out=$c.output_directory;Assert-OwnedPrivateDirectory $out
if((Get-OwnedCanonicalPath $c.install_parent).StartsWith((Get-OwnedCanonicalPath $out).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Get-OwnedCanonicalPath $c.install_parent) -ceq (Get-OwnedCanonicalPath $out)){throw 'separate_seed_install_and_evidence'}
$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($deadline -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or [DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'small_seed_admission'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
foreach($pair in @(@($c.pwsh,$c.pwsh_sha),@($c.node,$c.node_sha),@($c.http_probe,$c.http_probe_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.baseline_sql,$c.baseline_sql_sha),@($c.migrations_source,$c.migrations_source_sha),@($c.manual_xes,$c.manual_xes_sha),@($c.model_bpmn,$c.model_bpmn_sha),@((Join-Path $PSScriptRoot '../owned-http-client.cjs'),$c.http_client_sha))){Assert-OwnedHash $pair[0] $pair[1]}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$manifest=Get-Content -LiteralPath (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json -DateKind String
if($manifest.source_commit -cne $c.source_commit -or $manifest.version -cne '0.7.3'){throw 'small_seed_candidate_manifest'}
$app=Join-Path $pkg 'process-intelligence-rs.exe';Assert-OwnedHash $app $c.app_sha
$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1';Assert-OwnedHash $backup $c.backup_sha
$service=$null;$secret=$null;$admin=$null
$sequenceSql="(SELECT jsonb_build_object('last_value',q.last_value::text,'is_called',q.is_called,'log_cnt',q.log_cnt::text,'definition',jsonb_build_object('data_type',s.seqtypid::regtype::text,'start_value',s.seqstart::text,'increment_by',s.seqincrement::text,'max_value',s.seqmax::text,'min_value',s.seqmin::text,'cache_size',s.seqcache::text,'cycle',s.seqcycle)) FROM pg_sequence s CROSS JOIN public.pi_resource_sequence q WHERE s.seqrelid='public.pi_resource_sequence'::regclass)"
function CheckBudget {
 if([DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 4GB){throw 'small_seed_floor_or_freeze'}
 $sum=(Get-ChildItem -LiteralPath $out -Recurse -File|Measure-Object Length -Sum).Sum
 if($sum -gt 512MB){throw 'small_seed_evidence_budget'}
}
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int]$Seconds=120,[long]$Cap=8MB){
 CheckBudget
 $p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $end=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $end -or [DateTime]::UtcNow -ge $deadline -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'small_seed_owned_child_stop'};break}}
 $r=Complete-OwnedCapturedProcess $p
 if($forced -or $r.native_exit -ne 0 -or !$r.stdout_complete -or !$r.stderr_complete -or $r.capture_fault -or $r.output_limit -or $r.drain_timeout){throw ('small_seed_native_failed_'+$Label)}
 return $r
}
function Sql([string]$Database,[string]$Label,[string[]]$Arguments,[bool]$AsApp=$false){
 if($Database -cnotin @('postgres','process_intelligence','pi_restore_s13_small_seed01')){throw 'small_seed_sql_scope'}
 $user=if($AsApp){'pi_app'}else{'pi_admin'};$environment=if($AsApp){@{PGPASSWORD=$secret.app_password;PGOPTIONS=$admin.PGOPTIONS}}else{$admin}
 return Native $Label $psql $c.psql_sha (@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5465','-U',$user,'-w','-d',$Database)+$Arguments) $environment 60 8MB
}
function Capture([string]$Database,[string]$Label,[bool]$V1=$false,[bool]$Normal=$false){
 $extra=if($V1){''}else{" ,'projects',(SELECT jsonb_agg(to_jsonb(t) ORDER BY project_id) FROM public.pi_projects t),'records',(SELECT jsonb_agg(to_jsonb(t) ORDER BY project_id,kind,resource_id) FROM public.pi_records t),'markers',(SELECT jsonb_agg(to_jsonb(t) ORDER BY project_id) FROM public.pi_migration_v2 t)"}
 if($Normal){$extra+=" ,'auth',(SELECT document FROM public.pi_kv WHERE key='auth'),'auth_version',(SELECT version::text FROM public.pi_kv WHERE key='auth')"}
 $sql="SELECT jsonb_build_object('kv',(SELECT jsonb_agg(to_jsonb(t) ORDER BY key) FROM public.pi_kv t),'ledger',(SELECT jsonb_agg(to_jsonb(t) ORDER BY version) FROM public.pi_schema_migrations t),'sequence',$sequenceSql$extra);"
 return Sql $Database $Label @('-c',$sql)
}
try{
 [void](Native 'probe-syntax-check' $c.node $c.node_sha @('--check',$c.http_probe) @{} 30 1MB)
 $service=Start-OwnedStockService $c $pkg 'small-stock';[void](Wait-OwnedStockService $service)
 $secret=Get-Content -LiteralPath (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json
 if($secret.port -ne 5465){throw 'small_seed_private_port'}
 $admin=@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c TimeZone=UTC -c DateStyle=ISO,YMD'}
 [void](Native 'maintained-http' $c.node $c.node_sha @($c.http_probe,$PhaseConfig,'http') @{PI_SMALL_SEED_CONFIG_SHA=$PhaseConfigSha.ToLowerInvariant()} 300 1MB)
 # Stop only the retained, verified app; keep its newly owned PostgreSQL alive for offline capture.
 $apps=@($service.Processes|Where-Object Name -ceq 'app');if($apps.Count -ne 1 -or !$service.Job.Member($apps[0].Handle)){throw 'small_seed_owned_app_identity'}
 $held=$apps[0];$again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$held.Process.Id)
 if($held.Process.HasExited -or !$again -or $again.ExecutablePath -cne $app -or $held.Process.StartTime.ToUniversalTime().ToString('o') -cne $held.Creation){throw 'small_seed_app_stale_identity'}
 $held.Process.Kill();if(!$held.Process.WaitForExit(10000)){throw 'small_seed_app_stop_deadline'}
 if(@(Get-NetTCPConnection -State Listen -LocalPort 3097 -ErrorAction SilentlyContinue).Count){throw 'small_seed_app_listener_remains'}
 Write-OwnedJson (Join-Path $out 'app-offline-stop.json') @{pid=$held.Process.Id;creation_utc=$held.Creation;native_exit=$held.Process.ExitCode;controlled_forced_stop=$true;no_clean_exit_claim=$true;postgres_retained=$true}
 $normal=Capture 'process_intelligence' 'normal-offline' $false $true
 [void](Native 'assemble-private-input' $c.node $c.node_sha @($c.http_probe,$PhaseConfig,'assemble') @{PI_SMALL_SEED_CONFIG_SHA=$PhaseConfigSha.ToLowerInvariant()} 30 1MB)
 $checksum=(Get-Content (Join-Path $out 'baseline-checksum.txt') -Raw).Trim();if($checksum -cnotmatch '^[a-f0-9]{64}$'){throw 'actual_baseline_checksum'}
 [void](Sql 'postgres' 'new-v1-absence' @('-c',"SELECT jsonb_build_object('exists',EXISTS(SELECT 1 FROM pg_database WHERE datname='pi_restore_s13_small_seed01'));"))
 $exists=Get-Content (Join-Path $out 'new-v1-absence.stdout') -Raw|ConvertFrom-Json
 if($exists.exists){throw 'new_small_seed_database_required'}
 [void](Sql 'postgres' 'create-v1' @('-c','CREATE DATABASE pi_restore_s13_small_seed01 OWNER pi_app;'))
 [void](Sql 'pi_restore_s13_small_seed01' 'maintained-baseline-v1' @('-v',('baseline_checksum='+$checksum),'-f',$c.baseline_sql) $true)
 [void](Sql 'pi_restore_s13_small_seed01' 'assemble-small-v1' @('-f',(Join-Path $out 'assemble-v1-private.sql')) $true)
 $pre=Capture 'pi_restore_s13_small_seed01' 'assembled-v1-pre' $true
 $preservedSql="SELECT jsonb_build_object('kv',(SELECT jsonb_agg(to_jsonb(t) ORDER BY key) FROM public.pi_kv t),'sequence',$sequenceSql,'baseline',(SELECT to_jsonb(t) FROM public.pi_schema_migrations t WHERE version=1));"
 $beforePreserved=Sql 'pi_restore_s13_small_seed01' 'preserved-v1-pre' @('-c',$preservedSql)
 $url="host=127.0.0.1 port=5465 user=pi_app password=$($secret.app_password) dbname=pi_restore_s13_small_seed01 connect_timeout=5"
 $migration=Native 'maintained-migrate-small' $app $c.app_sha @('--migrate-storage') @{PI_DATABASE_URL=$url} 300 1MB
 $post=Capture 'pi_restore_s13_small_seed01' 'migrated-small-post'
 $afterPreserved=Sql 'pi_restore_s13_small_seed01' 'preserved-v1-post' @('-c',$preservedSql)
 if($beforePreserved.stdout_sha256 -cne $afterPreserved.stdout_sha256 -or $beforePreserved.stdout_bytes_persisted -ne $afterPreserved.stdout_bytes_persisted){throw 'full_raw_kv_baseline_sequence_not_preserved'}
 [void](Native 'verify-small-transform' $c.node $c.node_sha @($c.http_probe,$PhaseConfig,'verify') @{PI_SMALL_SEED_CONFIG_SHA=$PhaseConfigSha.ToLowerInvariant()} 30 1MB)
 $archive=Join-Path $pkg '.local/small-s-seed.dump'
 [void](Native 'small-stock-backup' $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out 'backup-stdio.json'),'-ArgumentsJson',(@{Mode='Backup';Database='pi_restore_s13_small_seed01';BackupFile=$archive}|ConvertTo-Json -Compress)) @{} 120 4MB)
 $normalAfter=Capture 'process_intelligence' 'normal-offline-final' $false $true
 if($normal.stdout_sha256 -cne $normalAfter.stdout_sha256 -or $normal.stdout_bytes_persisted -ne $normalAfter.stdout_bytes_persisted){throw 'normal_constructor_source_changed_offline'}
 Test-OwnedPackageTree $pkg $c.manifest_sha $true
 $construction=Get-Content (Join-Path $out 'small-fixture-construction.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 $construction.archive_path=$archive;$construction.archive_sha=Get-OwnedHash $archive;$construction.manifest_sha=Get-OwnedHash ($archive+'.manifest.json');$construction.native_migration=$migration;$construction.full_pre=$pre;$construction.full_post=$post;$construction.raw_preservation_before=$beforePreserved;$construction.raw_preservation_after=$afterPreserved;$construction.synthetic_only=$true;$construction.independent_input_review_required=$true
 Write-OwnedJson (Join-Path $out 'small-seed-result.json') $construction
}finally{
 $secret=$null;$admin=$null;$url=$null
 if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'}
}

<#
SOURCE-ONLY DRAFT; NOT EXECUTED. Root/QA/TD must pin/review both new files, actual
package0.7.3 manifest/source/EXE, helper/runtime/worker/stdio/PS7/Node/PG pins and
the finite private config before the S13 outer waiting-worker Job launches this.
Config scope=s13-maintained-small-seed, version0.7.3, pg_port5465/app_port3097,
database process_intelligence, seed_database pi_restore_s13_small_seed01; exact
package/source_commit/install_parent/output/private inputs, deadline<=19:44:42Z.
Service config uses existing module_sha/worker_sha/pwsh_sha/stdio_sha/app_sha/
postgres_sha/pg_ctl_sha. Other fields: phase_support_sha/service_sha/node/node_sha,
http_probe/http_probe_sha/http_client_sha, migrations_source/migrations_source_sha,
baseline_sql/baseline_sql_sha, manual_xes/manual_xes_sha, model_bpmn/model_bpmn_sha,
backup_sha and pins[]. Outer phase<=1800sec,totalS13<=16GiB;initialfree8GiB/floor4,
evidence512MiB/pernative8MiB. No modified productSQL5/lock2/tx10/no oldresources.

Actual normalsetup creates4users (owner/editor/viewer/foreign),2targets with4
traces/10events manual XES preview+consent import, valid linear BPMN via import,
actual memberships/login/currentproject, positiveproject-list catalog assignment.
GET/backup raw payloadtoken bytes must exactly hash to actual Rust digest in the
bundle. No JS/PS reserialization for transfer. App is stopped via retained exact
owned innerJob handle/creation/image before full private offlineAuth capture.
PG remains alive under retainedserviceJob; finalizer cleanly stops only this PG.

Pin baseline SQL and src/migrations.rs; probe extracts only checked literal,
verifies maintained fixture DDL equals actual baseline after IFNOTEXISTS removal,
and derives real checksum. NEWpi_app-owned v1DB only (rejectexists), executes
maintained tools/migration-fixture-v1.sql then removes ONLY its known sentinel,
inserts exact raw normalAuth document+version/two payloads at7/11/Gversion3 using
standard_conforming_strings=on and singlequoted doubled private SQL FILE. No Auth
or payload in argv/output; nativeprivate captures may contain Auth perNTFS guard.
Maintainedsetval explicitly starts synthetic fixture log_cnt0; copies logical
last/is_called/definition and records actual normalSource log_cnt->0 change.
No nextval replay/no claim raw originalDB copy. Assembledv1 is the new exactPRE;
migration must preserve its fullrawKV/baselineledger/sequence incl0 byte-for-byte.

Actual --migrate-storage runs as pi_app; expected2headers/10records/2markers/all
5kinds/auth/catalog/G/retainedsource7/11+Rusthash+checksum checked. JS transform
checks supplement fullraw preservedKV/sequence; independent QA exactnumeric/all
header/record oracle required before issuing S13_MAINTAINED_SMALL_S_INPUT_REVIEWED.
Construction status stays SMALL_S_CONSTRUCTION_EVIDENCE_PENDING_QA_TD, never self
grants independent approval. Stock backup+actualmanifest produced only after
migration checks; normalHTTP source untouched after offline capture. No full
historical0.3/C2/R3/recovery claim; no resetting/reusingexisting fixtures, noDROP.
#>
