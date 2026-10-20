param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# New synthetic resources only. An actual immutable older binary must refuse the new Auth format.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item $PhaseConfig).Length -gt 1MB -or (Get-FileHash $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'downgrade_config_pin'}
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if((Get-FileHash (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1]){throw 'downgrade_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
if($c.scope -cne 's14-actual-old-binary-catalog-downgrade' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5475 -or $c.app_port -ne 3098 -or $c.database -cne 'process_intelligence'){throw 'downgrade_finite_scope'}
if($c.package_sha -cne 'E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C' -or $c.app_sha -cne '23563DFF8FE93F339AD7F12FD0783AC3E2C53B8D9368C00D772A8FBABBE5F292'){throw 'downgrade_current_candidate'}
if($c.old_package_sha -cne '8442298B31F0E4AD749EDB9D981109AEB360A0989038D46E92E35719BE2025DB' -or $c.old_app_sha -cne 'D0EDFFD23AAA33EB5D31EB0A4B7917D33519AD36E6F32E949B5F551C170F20F5' -or $c.old_manifest_sha -cne 'E3E50B0D38657A3FF9EB7307C604F91BD5842C02BB7F270B9BD5FCCF9A2B91BA'){throw 'downgrade_exact_old_candidate'}
$archiveExpected=Join-Path $workspace '.local/sprint14/root/catalog-integration-install01/process-intelligence-rs-0.7.3-windows-x86_64/.local/catalog-integrated.dump'
if((Get-OwnedCanonicalPath $c.catalog_archive) -cne (Get-OwnedCanonicalPath $archiveExpected) -or $c.catalog_archive_sha -cne '52790569003C1DCCCE0F0770CD9AD1DB060FC8388162E0E45DF76C6686B791E0' -or $c.catalog_manifest_sha -cne '6B21A3CADAEB41FA6C9299FA71D7149A43D4263DEA09C4549E65A5AE74CF4EDA'){throw 'downgrade_exact_catalog_input'}
$names=@($c.source_db,$c.restore_db);foreach($db in $names){if($db -cnotmatch '^pi_restore_s14_[a-z0-9_]{1,35}$'){throw 'downgrade_new_db'}};if(@($names|Select-Object -Unique).Count -ne 2){throw 'downgrade_distinct_db'}
foreach($pin in $c.pins){Assert-OwnedNoReparse $pin.path;Assert-OwnedHash $pin.path $pin.sha256}
foreach($p in @(@($c.catalog_archive,$c.catalog_archive_sha),@(($c.catalog_archive+'.manifest.json'),$c.catalog_manifest_sha),@($c.old_package,$c.old_package_sha),@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.capture_sql,$c.capture_sql_sha),@($c.catalog_sql,$c.catalog_sql_sha),@($c.acl_sql,$c.acl_sql_sha))){Assert-OwnedHash $p[0] $p[1]}
if((Get-OwnedCanonicalPath $c.capture_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'managed-state.sql')) -or (Get-OwnedCanonicalPath $c.catalog_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'logical-catalog.sql')) -or (Get-OwnedCanonicalPath $c.acl_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'identity-denied-acl.sql'))){throw 'downgrade_capture_paths'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($c.required_free_bytes -ne 8GB -or $c.runtime_floor_bytes -ne 8GB -or $deadline -gt [DateTimeOffset]::Parse('2026-10-20T09:54:16Z').UtcDateTime -or $started -ge $deadline -or $c.capture_reservation_bytes -ne 128MB -or $c.phase_reservation_bytes -gt 2GB){throw 'downgrade_resource_freeze'}
$resource=New-S14PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S14PhaseBudget -Proof $resource -Next $Next}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$m=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($m.source_commit -cne $c.source_commit -or $m.version -cne '0.7.3'){throw 'downgrade_current_manifest'}
$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
Assert-OwnedHash $psql $c.psql_sha;Assert-OwnedHash $backup $c.backup_sha
# Only two verified old package entries are copied into this NEW private installation.
# No old installation/setup/runtime is opened for writing or started.
Budget 16MB;$oldDir=Join-Path $pkg '.local/old-0.6.1';if(Test-Path $oldDir){throw 'downgrade_old_output_exists'};[void][IO.Directory]::CreateDirectory($oldDir)
$zip=[IO.Compression.ZipFile]::OpenRead($c.old_package)
try{
 foreach($item in @(@('build-manifest.json','E3E50B0D38657A3FF9EB7307C604F91BD5842C02BB7F270B9BD5FCCF9A2B91BA',2MB),@('process-intelligence-rs.exe',$c.old_app_sha,16MB))){
  $entry=@($zip.Entries|Where-Object FullName -ceq ('process-intelligence-rs-0.6.1-windows-x86_64/'+$item[0]));if($entry.Count -ne 1 -or $entry[0].Length -le 0 -or $entry[0].Length -gt $item[2]){throw 'downgrade_old_entry'}
  $target=Join-Path $oldDir $item[0];$input=$entry[0].Open();$output=[IO.File]::Open($target,'CreateNew','Write','None');try{$input.CopyTo($output)}finally{$input.Dispose();$output.Dispose()};Assert-OwnedHash $target $item[1]
 }
}finally{$zip.Dispose()}
$oldApp=Join-Path $oldDir 'process-intelligence-rs.exe';$om=Get-Content (Join-Path $oldDir 'build-manifest.json') -Raw|ConvertFrom-Json
if($om.version -cne '0.6.1' -or $om.source_commit -cne '3ba4cbbd6ffdc00c1185eb726dd01445eba86a9e' -or $om.build_proof.executable_sha256 -cne $c.old_app_sha){throw 'downgrade_old_manifest_binding'}
$service=$null;$secret=$null;$success=$false
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int[]]$Exits=@(0),[int]$Seconds=120,[long]$Cap=8MB){
 Budget $Cap;$p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'downgrade_child_stop'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;single_invocation=$true}
 if($forced -or $r.native_exit -notin $Exits -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw ('downgrade_native_'+$Label)};Budget;return $r
}
function Sql([string]$Db,[string]$Label,[string[]]$Arguments,[long]$Cap=8MB){
 if($Db -cnotin ($names+@('postgres'))){throw 'downgrade_sql_scope'}
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments (@('-X','-qAt','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5475','-U','pi_admin','-w','-d',$Db)+$Arguments) -Environment @{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c default_transaction_read_only=on -c TimeZone=UTC -c DateStyle=ISO,YMD'} -Cap $Cap
}
function State([string]$Db,[string]$Label,[string]$Kind='managed'){$sql=switch($Kind){'managed'{$c.capture_sql};'catalog'{$c.catalog_sql};'acl'{$c.acl_sql};default{throw 'downgrade_capture_kind'}};$r=Sql $Db $Label @('-f',$sql);return @{path=Join-Path $out ($Label+'.stdout');bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256}}
function EqualState($a,$b){if($a.bytes -ne $b.bytes -or $a.sha256.ToUpperInvariant() -cne $b.sha256.ToUpperInvariant()){throw 'downgrade_full_state_changed'}}
function Stock([string]$Label,[hashtable]$Fields){[void](Native -Label $Label -Program $c.pwsh -Sha $c.pwsh_sha -Arguments @('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Fields|ConvertTo-Json -Compress)) -Seconds 180)}
try{
 $service=Start-OwnedStockService $c $pkg 'downgrade-stock';[void](Wait-OwnedStockService $service)
 $boot=@($service.Processes|Where-Object Name -ceq 'app');$pg=@($service.Processes|Where-Object Name -ceq 'postgres');if($boot.Count -ne 1 -or $pg.Count -ne 1 -or !$service.Job.Member($boot[0].Handle)){throw 'downgrade_bootstrap_identity'}
 $boot[0].Process.Kill();if(!$boot[0].Process.WaitForExit(10000)){throw 'downgrade_bootstrap_stop'};Write-OwnedJson (Join-Path $out 'bootstrap-app-forced-stop.json') @{native_exit=$boot[0].Process.ExitCode;controlled_forced_stop=$true;no_clean_app_exit_claim=$true}
 if(@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'downgrade_bootstrap_listener'}
 $ci=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id);if(!$ci -or $ci.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe') -or $pg[0].Process.StartTime.ToUniversalTime().ToString('o') -cne $pg[0].Creation){throw 'downgrade_pg_identity'}
 Wait-OwnedReadyJob @(@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$ci.CreationDate.ToUniversalTime().ToString('o')}) $out
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5475){throw 'downgrade_private_port'}
 foreach($pair in @(@('source',$c.source_db),@('restore',$c.restore_db))){[void](Sql 'postgres' ('absent-'+$pair[0]) @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$pair[1]+"');")));if((Get-Content (Join-Path $out ('absent-'+$pair[0]+'.stdout')) -Raw).Trim() -cne 'f'){throw 'downgrade_target_exists'}}
 $seed=Join-Path $pkg '.local/catalog-integrated.dump';[IO.File]::Copy($c.catalog_archive,$seed,$false);[IO.File]::Copy(($c.catalog_archive+'.manifest.json'),($seed+'.manifest.json'),$false);$sm=Get-Content ($seed+'.manifest.json') -Raw|ConvertFrom-Json
 Stock 'restore-source' @{Mode='Restore';Database=$sm.database;TargetDatabase=$c.source_db;BackupFile=$seed}
 Stock 'restore-verification' @{Mode='Restore';Database=$sm.database;TargetDatabase=$c.restore_db;BackupFile=$seed}
 $before=@{};foreach($pair in @(@('source',$c.source_db),@('restore',$c.restore_db))){foreach($kind in @('managed','catalog','acl')){$before[$pair[0]+'-'+$kind]=State $pair[1] ($pair[0]+'-'+$kind+'-before') $kind}}
 EqualState $before['source-managed'] $before['restore-managed'];EqualState $before['source-catalog'] $before['restore-catalog']
 # Assert the real new format is present; refusal cannot receive credit on an empty/old Auth.
 $auth=$null;$authCount=0;foreach($line in [IO.File]::ReadLines($before['source-managed'].path)){$a=ConvertFrom-Json -InputObject $line -NoEnumerate -Depth 100;if($a[0] -ceq 'kv' -and $a[1] -ceq 'auth'){$auth=$a[3];$authCount++}}
 if($authCount -ne 1 -or !$auth.project_list -or $auth.project_list.revision -le 0 -or @($auth.project_list.folders.PSObject.Properties).Count -eq 0){throw 'downgrade_nonempty_new_catalog_required'}
 $url="host=127.0.0.1 port=5475 user=pi_app password=$($secret.app_password) dbname=$($c.source_db) connect_timeout=5 application_name=s14_actual_old_downgrade"
 $old=Native -Label 'old-061-startup-refusal' -Program $oldApp -Sha $c.old_app_sha -Arguments @() -Environment @{PI_DATABASE_URL=$url;PORT='3098';RUST_LOG='info'} -Exits @(1) -Seconds 30 -Cap 1MB;$url=$null
 $err=Get-Content (Join-Path $out 'old-061-startup-refusal.stderr') -Raw;$stdout=Get-Content (Join-Path $out 'old-061-startup-refusal.stdout') -Raw
 if($err -cnotmatch 'Доступ запрещён\.' -or $stdout -match 'app_started' -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'downgrade_specific_old_auth_decoder_refusal_required'}
 [void](Sql 'postgres' 'old-app-backends-gone' @('-c',("SELECT count(*) FROM pg_stat_activity WHERE datname='"+$c.source_db+"' AND backend_type='client backend';")))
 if((Get-Content (Join-Path $out 'old-app-backends-gone.stdout') -Raw).Trim() -cne '0'){throw 'downgrade_old_backend_remains'}
 $after=@{};foreach($pair in @(@('source',$c.source_db),@('restore',$c.restore_db))){foreach($kind in @('managed','catalog','acl')){$key=$pair[0]+'-'+$kind;$after[$key]=State $pair[1] ($key+'-after') $kind;EqualState $before[$key] $after[$key]}}
 Write-OwnedJson (Join-Path $out 'catalog-downgrade-result.json') @{status='ACTUAL_OLD_0_6_1_NEW_CATALOG_REFUSAL_PENDING_QA_TD';old_version='0.6.1';old_source_commit=$om.source_commit;old_package_sha256=$c.old_package_sha;old_app_sha256=$c.old_app_sha;old_native_exit=$old.native_exit;exact_message='Доступ запрещён.';source_path='3ba4: AuthData deny_unknown_fields -> validate_stored -> denied -> AppState::open -> main startup error';before=$before;after=$after;no_listener=$true;no_migration_or_fixture_mutation=$true;limits=@('Strict older Auth decoder incompatibility refusal, not schema_unsupported or old0.3 allversion support','Synthetic actual new catalog archive, no user installation downgrade','Future/checksum schema refusals remain separately required')};$success=$true
}finally{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'};$secret=$null}
if(!$success){throw 'downgrade_incomplete_retained'}
Write-OwnedJson (Join-Path $out 'closed-phase-budget.json') (Get-S14ClosedPhaseBudgetTotals $resource)
