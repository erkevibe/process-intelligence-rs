param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# Twelve new synthetic databases; current immutable binary refuses one hostile Auth mutation per database.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item $PhaseConfig).Length -gt 1MB -or (Get-FileHash $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'catalog_invalid_config_pin'}
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if((Get-FileHash (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1]){throw 'catalog_invalid_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
if($c.scope -cne 's15-current-catalog-invalid' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5475 -or $c.app_port -ne 3098 -or $c.database -cne 'process_intelligence'){throw 'catalog_invalid_finite_scope'}
if($c.package_sha -cne 'E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C' -or $c.app_sha -cne '23563DFF8FE93F339AD7F12FD0783AC3E2C53B8D9368C00D772A8FBABBE5F292'){throw 'catalog_invalid_current_candidate'}
$archiveExpected=Join-Path $workspace '.local/sprint14/root/catalog-integration-install01/process-intelligence-rs-0.7.3-windows-x86_64/.local/catalog-integrated.dump'
if((Get-OwnedCanonicalPath $c.catalog_archive) -cne (Get-OwnedCanonicalPath $archiveExpected) -or $c.catalog_archive_sha -cne '52790569003C1DCCCE0F0770CD9AD1DB060FC8388162E0E45DF76C6686B791E0' -or $c.catalog_manifest_sha -cne '6B21A3CADAEB41FA6C9299FA71D7149A43D4263DEA09C4549E65A5AE74CF4EDA'){throw 'catalog_invalid_exact_catalog_input'}
$names=@($c.case_databases);if($names.Count -ne 12 -or @($names|Select-Object -Unique).Count -ne 12){throw 'invalid_case_database_count'};foreach($db in $names){if($db -cnotmatch '^pi_restore_s15_neg_[a-z0-9_]{1,30}$'){throw 'invalid_new_db'}}
foreach($pin in $c.pins){Assert-OwnedNoReparse $pin.path;Assert-OwnedHash $pin.path $pin.sha256}
foreach($p in @(@($c.catalog_archive,$c.catalog_archive_sha),@(($c.catalog_archive+'.manifest.json'),$c.catalog_manifest_sha),@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.capture_sql,$c.capture_sql_sha),@($c.catalog_sql,$c.catalog_sql_sha),@($c.acl_sql,$c.acl_sql_sha))){Assert-OwnedHash $p[0] $p[1]}
if((Get-OwnedCanonicalPath $c.capture_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'managed-state.sql')) -or (Get-OwnedCanonicalPath $c.catalog_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'logical-catalog.sql')) -or (Get-OwnedCanonicalPath $c.acl_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'identity-denied-acl.sql'))){throw 'catalog_invalid_capture_paths'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($c.required_free_bytes -ne 8GB -or $c.runtime_floor_bytes -ne 8GB -or $deadline -gt [DateTimeOffset]::Parse('2026-10-20T16:44:24Z').UtcDateTime -or $started -ge $deadline -or $c.capture_reservation_bytes -ne 256MB -or $c.phase_reservation_bytes -gt 4GB){throw 'catalog_invalid_resource_freeze'}
$resource=New-S14PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S14PhaseBudget -Proof $resource -Next $Next}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$m=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($m.source_commit -cne $c.source_commit -or $m.version -cne '0.7.3'){throw 'catalog_invalid_current_manifest'}
$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
Assert-OwnedHash $psql $c.psql_sha;Assert-OwnedHash $backup $c.backup_sha
$service=$null;$secret=$null;$success=$false
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int[]]$Exits=@(0),[int]$Seconds=120,[long]$Cap=8MB){
 Budget $Cap;$p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'catalog_invalid_child_stop'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;single_invocation=$true}
 if($forced -or $r.native_exit -notin $Exits -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw ('catalog_invalid_native_'+$Label)};Budget;return $r
}
function Sql([string]$Db,[string]$Label,[string[]]$Arguments,[long]$Cap=8MB){
 if($Db -cnotin ($names+@('postgres'))){throw 'catalog_invalid_sql_scope'}
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments (@('-X','-qAt','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5475','-U','pi_admin','-w','-d',$Db)+$Arguments) -Environment @{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c default_transaction_read_only=on -c TimeZone=UTC -c DateStyle=ISO,YMD'} -Cap $Cap
}
function State([string]$Db,[string]$Label,[string]$Kind='managed'){$sql=switch($Kind){'managed'{$c.capture_sql};'catalog'{$c.catalog_sql};'acl'{$c.acl_sql};default{throw 'catalog_invalid_capture_kind'}};$r=Sql $Db $Label @('-f',$sql);return @{path=Join-Path $out ($Label+'.stdout');bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256}}
function EqualState($a,$b){if($a.bytes -ne $b.bytes -or $a.sha256.ToUpperInvariant() -cne $b.sha256.ToUpperInvariant()){throw 'catalog_invalid_full_state_changed'}}
function Stock([string]$Label,[hashtable]$Fields){[void](Native -Label $Label -Program $c.pwsh -Sha $c.pwsh_sha -Arguments @('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Fields|ConvertTo-Json -Compress)) -Seconds 180)}
try{
 $service=Start-OwnedStockService $c $pkg 'downgrade-stock';[void](Wait-OwnedStockService $service)
 $boot=@($service.Processes|Where-Object Name -ceq 'app');$pg=@($service.Processes|Where-Object Name -ceq 'postgres');if($boot.Count -ne 1 -or $pg.Count -ne 1 -or !$service.Job.Member($boot[0].Handle)){throw 'catalog_invalid_bootstrap_identity'}
 $boot[0].Process.Kill();if(!$boot[0].Process.WaitForExit(10000)){throw 'catalog_invalid_bootstrap_stop'};Write-OwnedJson (Join-Path $out 'bootstrap-app-forced-stop.json') @{native_exit=$boot[0].Process.ExitCode;controlled_forced_stop=$true;no_clean_app_exit_claim=$true}
 if(@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'catalog_invalid_bootstrap_listener'}
 $ci=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id);if(!$ci -or $ci.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe') -or $pg[0].Process.StartTime.ToUniversalTime().ToString('o') -cne $pg[0].Creation){throw 'catalog_invalid_pg_identity'}
 Wait-OwnedReadyJob @(@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$ci.CreationDate.ToUniversalTime().ToString('o')}) $out
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5475){throw 'catalog_invalid_private_port'}
 $seed=Join-Path $pkg '.local/catalog-integrated.dump';[IO.File]::Copy($c.catalog_archive,$seed,$false);[IO.File]::Copy(($c.catalog_archive+'.manifest.json'),($seed+'.manifest.json'),$false);$sm=Get-Content ($seed+'.manifest.json') -Raw|ConvertFrom-Json
 $cases=@('catalog-unknown','folder-unknown','parent-missing','parent-cycle','assignment-folder-missing','assignment-project-missing','owner-missing','owner-not-project-owner','audit-rule','audit-policy-unknown','audit-outcome','audit-hash')
 $results=@();$index=0
 foreach($case in $cases){
  $db=$names[$index];$label='n'+($index+1).ToString('00');$index++
  [void](Sql 'postgres' ($label+'-absent') @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$db+"');")))
  if((Get-Content (Join-Path $out ($label+'-absent.stdout')) -Raw).Trim() -cne 'f'){throw 'invalid_target_exists'}
  Stock ($label+'-restore') @{Mode='Restore';Database=$sm.database;TargetDatabase=$db;BackupFile=$seed}
  $initial=State $db ($label+'-initial')
  $auth=$null;foreach($line in [IO.File]::ReadLines($initial.path)){$r=ConvertFrom-Json -InputObject $line -NoEnumerate -Depth 100;if($r[0] -ceq 'kv' -and $r[1] -ceq 'auth'){$auth=$r[3]}}
  if(!$auth -or !$auth.project_list -or $auth.project_list.revision -le 0){throw 'invalid_catalog_seed'}
  $folders=@($auth.project_list.folders.PSObject.Properties)
  if(!$folders.Count){throw 'invalid_seed_folder_required'}
  $fid=$folders[0].Name;$placedFolder=$fid;$placedOwner=[string]$folders[0].Value.owner_id
  $owned=@($auth.projects.PSObject.Properties|Where-Object {$member=$_.Value.members.PSObject.Properties[$placedOwner];$member -and $member.Value -ceq 'owner'})
  $foreign=@($auth.projects.PSObject.Properties|Where-Object {$member=$_.Value.members.PSObject.Properties[$placedOwner];!$member -or $member.Value -cne 'owner'})
  if(!$owned.Count -or !$foreign.Count){throw 'invalid_seed_owner_and_foreign_projects_required'}
  $placedProject=$owned[0].Name;$foreignProject=$foreign[0].Name
  $ap=$null;$ai=-1
  foreach($trail in $auth.audit.PSObject.Properties){for($j=0;$j -lt $trail.Value.entries.Count;$j++){if($trail.Value.entries[$j].action -clike 'project_list_folder_*' -and $trail.Value.entries[$j].policy){$ap=$trail.Name;$ai=$j;break}};if($ap){break}}
  if(!$ap -or $ai -lt 0 -or !$placedOwner){throw 'invalid_seed_audit_owner_required'}
  foreach($id in @($fid,$placedProject,$placedFolder,$ap,$placedOwner,$foreignProject)){if($id -cnotmatch '^[A-Za-z0-9_-]{1,128}$'){throw 'invalid_seed_id_sql_domain'}}
  $missing='00000000-0000-4000-8000-000000000099';$path=@();$value='null';$expected='Доступ запрещён.'
  switch($case){
   'catalog-unknown'{$path=@('project_list','extra');$value='true'}
   'folder-unknown'{$path=@('project_list','folders',$fid,'extra');$value='true'}
   'parent-missing'{$path=@('project_list','folders',$fid,'parent_id');$value='"'+$missing+'"';$expected='Некорректная папка или расположение проекта.'}
   'parent-cycle'{$path=@('project_list','folders',$fid,'parent_id');$value='"'+$fid+'"';$expected='Некорректная папка или расположение проекта.'}
   'assignment-folder-missing'{$path=@('project_list','project_folders',$placedProject);$value='"'+$missing+'"';$expected='Некорректная папка или расположение проекта.'}
   'assignment-project-missing'{$path=@('project_list','project_folders',$missing);$value='"'+$placedFolder+'"';$expected='Некорректная папка или расположение проекта.'}
   'owner-missing'{$path=@('project_list','folders',$fid,'owner_id');$value='"synthetic-missing-user"';$expected='Некорректная папка или расположение проекта.'}
   'owner-not-project-owner'{$path=@('project_list','project_folders',$foreignProject);$value='"'+$placedFolder+'"'}
   'audit-rule'{$path=@('audit',$ap,'entries',[string]$ai,'policy','rule');$value='"owner_archive_session_cas_v1"';$expected='История действий повреждена или не поддерживается.'}
   'audit-policy-unknown'{$path=@('audit',$ap,'entries',[string]$ai,'policy','password');$value='"synthetic-no-secret"'}
   'audit-outcome'{$path=@('audit',$ap,'entries',[string]$ai,'outcome');$value='"uncommitted"'}
   'audit-hash'{$path=@('audit',$ap,'entries',[string]$ai,'policy','parameters_sha256');$value='"INVALID"';$expected='История действий повреждена или не поддерживается.'}
  }
  $sql="BEGIN; UPDATE public.pi_kv SET document=jsonb_set(document,ARRAY['"+($path -join "','")+"'],'"+$value+"'::jsonb,true) WHERE key='auth' RETURNING key; COMMIT;"
  $sqlPath=Join-Path $out ($label+'-mutation.sql');[IO.File]::WriteAllText($sqlPath,$sql,[Text.UTF8Encoding]::new($false))
  [void](Native -Label ($label+'-mutate') -Program $psql -Sha $c.psql_sha -Arguments @('-X','-qAt','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5475','-U','pi_admin','-w','-d',$db,'-f',$sqlPath) -Environment @{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c TimeZone=UTC'} -Cap 1MB)
  if((Get-Content (Join-Path $out ($label+'-mutate.stdout')) -Raw).Trim() -cne 'auth'){throw 'invalid_exact_one_auth_update'}
  $before=@{};foreach($kind in @('managed','catalog','acl')){$before[$kind]=State $db ($label+'-'+$kind+'-before') $kind}
  if($initial.sha256 -ceq $before.managed.sha256){throw 'invalid_mutation_must_change_auth'}
  $url="host=127.0.0.1 port=5475 user=pi_app password=$($secret.app_password) dbname=$db connect_timeout=5 application_name=s15_catalog_invalid"
  $app=Native -Label ($label+'-startup-refusal') -Program (Join-Path $pkg 'process-intelligence-rs.exe') -Sha $c.app_sha -Arguments @() -Environment @{PI_DATABASE_URL=$url;PORT='3098';RUST_LOG='info'} -Exits @(1) -Seconds 30 -Cap 1MB;$url=$null
  $err=Get-Content (Join-Path $out ($label+'-startup-refusal.stderr')) -Raw;$stdout=Get-Content (Join-Path $out ($label+'-startup-refusal.stdout')) -Raw
  if(!$err.Contains($expected) -or ($err+$stdout) -match 'app_started' -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw ('invalid_specific_refusal_'+$case)}
  [void](Sql 'postgres' ($label+'-backends-gone') @('-c',("SELECT count(*) FROM pg_stat_activity WHERE datname='"+$db+"' AND backend_type='client backend';")))
  if((Get-Content (Join-Path $out ($label+'-backends-gone.stdout')) -Raw).Trim() -cne '0'){throw 'invalid_backend_remains'}
  $after=@{};foreach($kind in @('managed','catalog','acl')){$after[$kind]=State $db ($label+'-'+$kind+'-after') $kind;EqualState $before[$kind] $after[$kind]}
  $results+=@{case=$case;database=$db;single_json_path=$path;synthetic_value=$value;expected_message=$expected;native_exit=$app.native_exit;initial=$initial;before=$before;after=$after;mutation_sql_sha256=(Get-FileHash $sqlPath).Hash;no_listener=$true}
 }
 Write-OwnedJson (Join-Path $out 'catalog-invalid-result.json') @{status='ACTUAL_CURRENT_CATALOG_HOSTILE_REFUSALS_PENDING_QA_TD';cases=$results;no_cleanup_verify_claim=$true;limits=@('Twelve named synthetic single-path Auth mutations only; no arbitrary hostile universe coverage','Audit hash test rejects malformed digest syntax, not recomputation of unavailable policy parameters','Existing normal catalog startup/restart supplied by separately accepted exact integration proof')};$success=$true
}finally{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'};$secret=$null}
if(!$success){throw 'catalog_invalid_incomplete_retained'}
Write-OwnedJson (Join-Path $out 'closed-phase-budget.json') (Get-S14ClosedPhaseBudgetTotals $resource)
