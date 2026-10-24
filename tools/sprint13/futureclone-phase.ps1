param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY C05 draft. Only a NEW SmallS cluster may be cold-copied; no old data.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'clone_config_before_import'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha),@('evidence-storage.psm1',$c.storage_sha))){if($p[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1].ToUpperInvariant()){throw 'clone_preimport_source_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's13-new-small-cold-physical-clone-C05' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5465 -or $c.clone_port -ne 5466 -or $c.app_port -ne 3097 -or $c.database -cne 'process_intelligence' -or $c.target_database -cnotmatch '^pi_restore_s13_clone_[a-z0-9_]{1,20}$'){throw 'clone_new_finite_scope'}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$root=Join-Path $workspace '.local/sprint13'
$out=Get-OwnedCanonicalPath $c.output_directory;$install=Get-OwnedCanonicalPath $c.install_parent;Assert-OwnedPrivateDirectory $out
foreach($p in @($out,$install)){if(!$p.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'clone_exact_S13_new_scope'}}
Assert-OwnedNoReparse $out
if(Test-Path -LiteralPath $install){throw 'clone_install_must_be_new_absent'}
Assert-OwnedNoReparse (Split-Path -Parent $install);Assert-OwnedPrivateDirectory (Split-Path -Parent $install)
if($out -ceq $install -or $out.StartsWith($install.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $install.StartsWith($out.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'clone_disjoint_output_install'}
$clone=Get-OwnedCanonicalPath $c.clone_datadir
if($clone -cne (Get-OwnedCanonicalPath (Join-Path $install 'cold-clone-pgdata')) -or (Test-Path -LiteralPath $clone)){throw 'clone_literal_NEVER_existing_copy_target'}
function Proof($Pin){Assert-OwnedNoReparse $Pin.path;Assert-OwnedHash $Pin.path $Pin.sha256;Assert-OwnedPrivateDirectory (Split-Path -Parent $Pin.path);if((Get-Item $Pin.path).Length -gt 4MB){throw 'clone_proof_size'};return Get-Content $Pin.path -Raw|ConvertFrom-Json -AsHashtable -DateKind String}
$fixture=Proof $c.fixture_review
if($fixture.status -cne 'S13_MAINTAINED_SMALL_S_INPUT_REVIEWED' -or $fixture.archive_sha -cne $c.small_archive_sha -or $fixture.manifest_sha -cne $c.small_manifest_sha -or $fixture.candidates.Count -ne 2 -or !$fixture.all_record_kinds -or !$fixture.normal_auth -or !$fixture.project_list_exercised){throw 'clone_actual_small_seed02_required'}
Assert-OwnedHash $c.small_archive $c.small_archive_sha;Assert-OwnedHash ($c.small_archive+'.manifest.json') $c.small_manifest_sha
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
foreach($p in @(@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.capture_sql,$c.capture_sql_sha),@($c.catalog_sql,$c.catalog_sql_sha))){Assert-OwnedHash $p[0] $p[1]}
if((Get-OwnedCanonicalPath $c.capture_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'managed-state.sql')) -or (Get-OwnedCanonicalPath $c.catalog_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'logical-catalog.sql'))){throw 'clone_current_complete_capture_sources'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($deadline -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or $started -ge $deadline -or $c.capture_reservation_bytes -ne 512MB -or $c.clone_data_reservation_bytes -lt 1GB -or $c.phase_budget.db_wal_temp_extract_archive_bytes -lt 3GB -or $c.phase_reservation_bytes -gt 6GB){throw 'clone_whole_uncompressed_two_cluster_peak'}
$resourceBudget=New-S13PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S13PhaseBudget -Proof $resourceBudget -Next $Next}
if(@(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object LocalPort -in @(5465,5466,3097)).Count){throw 'clone_new_ports_absent'}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $install $c.manifest_sha
$manifest=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($manifest.version -cne '0.7.3' -or $manifest.source_commit -cne $c.source_commit){throw 'clone_current_package'}
$app=Join-Path $pkg 'process-intelligence-rs.exe';$bin=Join-Path $pkg 'runtime/postgresql/pgsql/bin';$psql=Join-Path $bin 'psql.exe';$pg=Join-Path $bin 'postgres.exe';$ctl=Join-Path $bin 'pg_ctl.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1';$data=Join-Path $pkg '.local/pgdata'
foreach($p in @(@($app,$c.app_sha),@($psql,$c.psql_sha),@($pg,$c.postgres_sha),@($ctl,$c.pg_ctl_sha),@($backup,$c.backup_sha))){Assert-OwnedHash $p[0] $p[1]}
$service=$null;$secret=$null;$postmasters=[Collections.Generic.List[object]]::new();$success=$false
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int]$Seconds=120,[long]$Cap=8MB,[int]$ExpectedExit=0){
 Budget $Cap;$p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $end=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $end -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 4GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'clone_owned_child_stop'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;automatic_retry=$false}
 if($forced -or $r.native_exit -ne $ExpectedExit -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw ('clone_native_failed_'+$Label)};Budget;return $r
}
function Sql([int]$Port,[string]$Db,[string]$Label,[string[]]$Arguments,[long]$Cap=8MB){
 if($Port -notin @(5465,5466) -or $Db -cnotin @('postgres',$c.target_database)){throw 'clone_SQL_exact_new_pair'}
 [string[]]$argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p',[string]$Port,'-U','pi_admin','-w','-d',$Db)+$Arguments
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments $argv -Environment @{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c default_transaction_read_only=on -c TimeZone=UTC -c DateStyle=ISO,YMD'} -Cap $Cap
}
function State([int]$Port,[string]$Label,[bool]$Catalog=$false){Budget 8MB;$sql=if($Catalog){$c.catalog_sql}else{$c.capture_sql};$r=Sql $Port $c.target_database $Label @('-f',$sql);return @{path=Join-Path $out ($Label+'.stdout');sha256=$r.stdout_sha256;bytes=$r.stdout_bytes_persisted}}
function EqualState($a,$b){if($a.sha256 -cne $b.sha256 -or $a.bytes -ne $b.bytes){throw 'clone_whole_state_changed'}}
function ColdTick{if([DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 4GB){throw 'clone_cold_deadline_floor'}}
function AssertCold{
 if(!(Test-Path -LiteralPath (Join-Path $service.Directory 'postmaster-clean-exit.json'))){throw 'clone_actual_cold_stop_proof_missing'}
 $stop=Get-Content (Join-Path $service.Directory 'postmaster-clean-exit.json') -Raw|ConvertFrom-Json -DateKind String
 if($stop.native_exit -ne 0 -or !$stop.listener_absent -or !$stop.job_stop_not_yet_issued -or (Test-Path -LiteralPath (Join-Path $data 'postmaster.pid')) -or @(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object LocalPort -in @(5465,5466)).Count){throw 'clone_source_not_cold'}
 $live=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$stop.pid)
 if($live -and $live.CreationDate.ToUniversalTime().ToString('o') -eq $stop.creation_utc){throw 'clone_retained_postmaster_still_live'}
 if(@(Get-CimInstance Win32_Process -Filter "Name='postgres.exe'" -ErrorAction Stop|Where-Object {$_.ExecutablePath -ceq $pg}).Count){throw 'clone_no_other_postgres_from_NEW_package'}
}
function ColdInventory([string]$Dir){
 $map=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal);$dirs=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal);$stack=[Collections.Generic.Stack[string]]::new();$stack.Push($Dir);$total=0L
 while($stack.Count){$d=$stack.Pop();Assert-OwnedNoReparse $d;foreach($f in Get-ChildItem -LiteralPath $d -Force -ErrorAction Stop){
  ColdTick;Assert-OwnedNoReparse $f.FullName;if($f.PSIsContainer){if($dirs.Count -ge 10000){throw 'clone_cold_directory_count'};[void]$dirs.Add([IO.Path]::GetRelativePath($Dir,$f.FullName));$stack.Push($f.FullName);continue};if($map.Count -ge 10000){throw 'clone_cold_file_count'}
  $s=$null;$hash=$null;try{$s=[IO.FileStream]::new($f.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None,65536,[IO.FileOptions]::SequentialScan);$before=[PiS13EvidenceStorageV1]::Inspect($s)
   if($before.Links -ne 1 -or $before.FileSystem -cne 'NTFS' -or ($before.Attributes -band 0x445650)){throw 'clone_cold_native_file_guard'}
   $hash=[Security.Cryptography.SHA256]::Create();$digest=[Convert]::ToHexString($hash.ComputeHash($s));$after=[PiS13EvidenceStorageV1]::Inspect($s)
   if(($before|ConvertTo-Json -Depth 10 -Compress) -cne ($after|ConvertTo-Json -Depth 10 -Compress)){throw 'clone_cold_native_identity_changed'}
   $rel=[IO.Path]::GetRelativePath($Dir,$f.FullName);$map.Add($rel,@{relative=$rel;bytes=$before.EndOfFile;sha256=$digest;native=$before});$total+=$before.EndOfFile;if($total -gt $c.clone_data_reservation_bytes){throw 'clone_actual_cold_tree_exceeds_reserved_peak'}
  }finally{if($hash){$hash.Dispose()};if($s){$s.Dispose()}}
 }};return @{files=$map;directories=$dirs;logical_bytes=$total}
}
function InventoryDigest($Inventory,[bool]$WithIdentity){
 $h=[Security.Cryptography.SHA256]::Create();try{foreach($d in $Inventory.directories){$b=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject @('directory',$d) -Compress)+"`n");[void]$h.TransformBlock($b,0,$b.Length,$b,0)};foreach($r in $Inventory.files.Values){$row=@($r.relative,[string]$r.bytes,$r.sha256);if($WithIdentity){$row+=($r.native|ConvertTo-Json -Depth 10 -Compress)};$b=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $row -Depth 12 -Compress)+"`n");[void]$h.TransformBlock($b,0,$b.Length,$b,0)};[void]$h.TransformFinalBlock([byte[]]::new(0),0,0);return [Convert]::ToHexString($h.Hash)}finally{$h.Dispose()}
}
try{
 $service=Start-OwnedStockService $c $pkg 'clone-stock';[void](Wait-OwnedStockService $service)
 $boot=@($service.Processes|Where-Object Name -ceq 'app');if($boot.Count -ne 1 -or !$service.Job.Member($boot[0].Handle)){throw 'clone_bootstrap_app_identity'};$boot[0].Process.Kill();if(!$boot[0].Process.WaitForExit(10000)){throw 'clone_bootstrap_app_stop'}
 Write-OwnedJson (Join-Path $out 'bootstrap-app-forced-stop.json') @{pid=$boot[0].Process.Id;creation=$boot[0].Creation;native_exit=$boot[0].Process.ExitCode;controlled_forced_stop=$true;no_clean_app_exit_claim=$true}
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5465){throw 'clone_private_NEW_port'}
 [void](Sql 5465 'postgres' 'new-db-absent' @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$c.target_database+"');")));if((Get-Content (Join-Path $out 'new-db-absent.stdout') -Raw).Trim() -cne 'f'){throw 'clone_database_not_NEW'}
 $seed=Join-Path $pkg '.local/new-small-input.dump';[IO.File]::Copy($c.small_archive,$seed,$false);[IO.File]::Copy(($c.small_archive+'.manifest.json'),($seed+'.manifest.json'),$false);$sm=Get-Content ($seed+'.manifest.json') -Raw|ConvertFrom-Json
 [string[]]$restore=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out 'small-restore-stdio.json'),'-ArgumentsJson',(@{Mode='Restore';Database=$sm.database;TargetDatabase=$c.target_database;BackupFile=$seed}|ConvertTo-Json -Compress))
 [void](Native 'restore-new-small' $c.pwsh $c.pwsh_sha $restore @{} 180)
 $baseline=State 5465 'small-before-cold';$catalog=State 5465 'catalog-before-cold' $true
 $archive=Join-Path $pkg '.local/new-source-backup.dump';[string[]]$save=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out 'source-backup-stdio.json'),'-ArgumentsJson',(@{Mode='Backup';Database=$c.target_database;BackupFile=$archive}|ConvertTo-Json -Compress))
 [void](Native 'backup-new-source' $c.pwsh $c.pwsh_sha $save @{} 180)
 Stop-OwnedStockService $service 'fixture-finalization';AssertCold
 # Source is only this phase's freshly restored, actual clean-stop0 datadir.
 $cold=ColdInventory $data;AssertCold;[void](New-OwnedPrivateDirectory $clone)
 Budget $cold.logical_bytes
 foreach($relativeDir in $cold.directories){ColdTick;$newDir=Get-OwnedCanonicalPath (Join-Path $clone $relativeDir);if(!$newDir.StartsWith($clone.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'clone_directory_escape'};[void][IO.Directory]::CreateDirectory($newDir);Assert-OwnedNoReparse $newDir}
 foreach($r in $cold.files.Values){ColdTick;$from=Join-Path $data $r.relative;$to=Get-OwnedCanonicalPath (Join-Path $clone $r.relative);if(!$to.StartsWith($clone.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'clone_copy_path_escape'}
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $to));Assert-OwnedNoReparse (Split-Path -Parent $to);$i=$null;$o=$null
  try{$i=[IO.FileStream]::new($from,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$o=[IO.File]::Open($to,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$i.CopyTo($o);$o.Flush($true)}finally{if($o){$o.Dispose()};if($i){$i.Dispose()}}
 }
 $again=ColdInventory $data;$copied=ColdInventory $clone;AssertCold
 if((InventoryDigest $cold $true) -cne (InventoryDigest $again $true) -or (InventoryDigest $cold $false) -cne (InventoryDigest $copied $false)){throw 'clone_full_cold_byte_identity_copy_mismatch'}
 Write-OwnedJson (Join-Path $out 'actual-cold-copy.json') @{source=$data;target=$clone;file_count=$cold.files.Count;logical_bytes=$cold.logical_bytes;source_native_full_digest=InventoryDigest $cold $true;source_after_native_full_digest=InventoryDigest $again $true;source_allbytes_digest=InventoryDigest $cold $false;clone_allbytes_digest=InventoryDigest $copied $false;files=@($cold.files.Values);no_reparse=$true;new_source_only=$true}
 foreach($entry in @(@{name='source';port=5465;data=$data},@{name='clone';port=5466;data=$clone})){
  [string[]]$argv=@('-D',$entry.data,'-p',[string]$entry.port,'-h','127.0.0.1')
  $p=Start-OwnedCapturedProcess -Program $pg -ProgramSha256 $c.postgres_sha -Arguments $argv -WorkingDirectory $pkg -OutputDirectory $out -Label ('postgres-'+$entry.name) -MaxOutputBytes 8MB -Environment @{}
  $postmasters.Add(@{entry=$entry;child=$p;native_creation=$p.Record.native_creation_utc;ready=$null})
 }
 $readyEnd=[DateTime]::UtcNow.AddSeconds(30);$readyRows=@()
 foreach($held in $postmasters){do{Budget;if($held.child.Process.HasExited -or [DateTime]::UtcNow -ge $readyEnd){throw 'clone_restarted_postmaster_not_ready'};$ls=@(Get-NetTCPConnection -State Listen -LocalPort $held.entry.port -ErrorAction SilentlyContinue);if($ls.Count){if(@($ls|Where-Object {$_.OwningProcess -ne $held.child.Process.Id -or $_.LocalAddress -notin @('127.0.0.1','::1')}).Count){throw 'clone_actual_listener'};break};Start-Sleep -Milliseconds 100}while($true)
  $cim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$held.child.Process.Id);if(!$cim -or $cim.ExecutablePath -cne $pg -or $held.child.Process.HasExited -or $held.child.Process.StartTime.ToUniversalTime().ToString('o') -cne $held.native_creation){throw 'clone_actual_postmaster_PID_creation_image'}
  $canonical=Get-OwnedDatadirArgument $cim.CommandLine $held.entry.data;$held.ready=@{name=$held.entry.name;pid=$held.child.Process.Id;creation_utc=$cim.CreationDate.ToUniversalTime().ToString('o');native_creation=$held.native_creation;image=$cim.ExecutablePath;datadir=$canonical;port=$held.entry.port};$readyRows+=$held.ready
 }
 # Both are NEW children of the outer Job, never attached to the closed inner service Job.
 Write-OwnedJson (Join-Path $out 'restarted-postmasters-identity.json') @{processes=$readyRows;scope='Retained native creation+actualCIM image/datadir and actual loopback listener before outer Job witness'}
 $membership=@();foreach($r in $readyRows){$membership+=@{name=$r.name;pid=$r.pid;creation_utc=$r.creation_utc}}
 Wait-OwnedReadyJob $membership $out
 $identities=@();foreach($port in @(5465,5466)){
  [void](Sql $port $c.target_database ('identity-'+$port) @('-c',"SELECT jsonb_build_object('database',current_database(),'database_oid',(SELECT oid::text FROM pg_database WHERE datname=current_database()),'system_identifier',(pg_control_system()).system_identifier::text,'server_version_num',current_setting('server_version_num'),'encoding',current_setting('server_encoding'),'recovery',pg_is_in_recovery());"));$v=Get-Content (Join-Path $out ('identity-'+$port+'.stdout')) -Raw|ConvertFrom-Json
  if($v.database -cne $c.target_database -or $v.server_version_num -cne '180006' -or $v.encoding -cne 'UTF8' -or $v.recovery -or $v.database_oid -cnotmatch '^[0-9]+$' -or $v.system_identifier -cnotmatch '^[0-9]+$'){throw 'clone_actual_SQL_identity'};$identities+=$v
 }
 if($identities[0].database_oid -cne $identities[1].database_oid -or $identities[0].system_identifier -cne $identities[1].system_identifier){throw 'clone_actual_physical_pair_not_same'}
 $sourcePre=State 5465 'source-before-verify';$clonePre=State 5466 'clone-before-verify';EqualState $baseline $sourcePre;EqualState $baseline $clonePre
 $sourceCatalog=State 5465 'source-catalog-before' $true;$cloneCatalog=State 5466 'clone-catalog-before' $true;EqualState $catalog $sourceCatalog;EqualState $catalog $cloneCatalog
 $plan=Join-Path $pkg '.local/never-created-clone.plan.json';$receipt=Join-Path $pkg '.local/never-created-clone.receipt.json';if((Test-Path $plan) -or (Test-Path $receipt)){throw 'clone_plan_receipt_must_be_absent'}
 $env=@{PI_DATABASE_URL="host=127.0.0.1 port=5465 user=pi_admin password=$($secret.admin_password) dbname=$($c.target_database) connect_timeout=5";PI_CLEANUP_RESTORE_URL="host=127.0.0.1 port=5466 user=pi_admin password=$($secret.admin_password) dbname=$($c.target_database) connect_timeout=5";PI_CLEANUP_ARCHIVE=$archive;PI_CLEANUP_PLAN=$plan;PI_CLEANUP_RECEIPT=$receipt}
 [void](Native -Label 'actual-current-same-physical-verify' -Program $app -Sha $c.app_sha -Arguments @('--cleanup-storage-verify') -Environment $env -Seconds 300 -ExpectedExit 1)
 $result=Get-Content (Join-Path $out 'actual-current-same-physical-verify.stdout') -Raw|ConvertFrom-Json
 if($result.outcome -cne 'cleanup_refused' -or $result.code -cne 'cleanup_identity' -or (Test-Path $plan) -or (Test-Path $receipt)){throw 'clone_exact_current_identity_refusal_required'}
 $sourceAfter=State 5465 'source-after-refusal';$cloneAfter=State 5466 'clone-after-refusal';EqualState $sourcePre $sourceAfter;EqualState $clonePre $cloneAfter;EqualState $sourceCatalog (State 5465 'source-catalog-after' $true);EqualState $cloneCatalog (State 5466 'clone-catalog-after' $true)
 Write-OwnedJson (Join-Path $out 'C05-physical-clone-result.json') @{status='CURRENT_SMALLS_C05_ACTUAL_PHYSICAL_IDENTITY_REFUSAL_PENDING_QA_TD';identities=$identities;source_pre=$sourcePre;clone_pre=$clonePre;source_post=$sourceAfter;clone_post=$cloneAfter;whole_catalog_unchanged=$true;cli=$result;apply_executed=$false;automatic_retry=$false;limits=@('New cold SmallS constructor only, no historical clone credit','Actual same systemid+dbOID prerequisite; no guessed identity','Full all-file native source conservation/copy checked before restart','Physical PG files may change normally after restart; managed logical state/catalog refusal oracle only','No R3/release self-acceptance')}
 $success=$true
}finally{
 try{foreach($held in $postmasters){$p=$held.child;$clean=$false;$failure=$null
  try{if(!$p.Process.HasExited){$live=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.Process.Id);if(!$live -or $live.ExecutablePath -cne $pg -or $p.Process.StartTime.ToUniversalTime().ToString('o') -cne $held.native_creation){throw 'clone_stop_retained_identity'};[void](Native ('fast-stop-'+$held.entry.name) $ctl $c.pg_ctl_sha @('-D',$held.entry.data,'-w','-t','15','stop','-m','fast') @{} 30)};if(!$p.Process.WaitForExit(10000) -or $p.Process.ExitCode -ne 0 -or @(Get-NetTCPConnection -State Listen -LocalPort $held.entry.port -ErrorAction SilentlyContinue).Count){throw 'clone_postmaster_clean_exit0_required'};$clean=$true}catch{$failure=$_.Exception.Message;if(!$p.Process.HasExited){$p.Process.Kill($true)};if(!$p.Process.WaitForExit(10000)){throw 'clone_final_owned_stop_deadline'}}
  $native=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ('postgres-'+$held.entry.name+'-completion.json')) @{native=$native;clean_exit0=$clean;forced=(!$clean);failure=$failure};if(!$clean -or !$native.stdout_complete -or !$native.stderr_complete -or $native.capture_fault -or $native.output_limit -or $native.drain_timeout){$success=$false}
 }}finally{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'};$secret=$null}
}
if(!$success){throw 'clone_failed_or_unclean_retained'}
<# SOURCE-ONLY draft, never executed in preparation. Future exact config/source/
package/SmallS seed02 and Root/QA/TD resource+copy review required before launch.
Dynamic resource module pin must bind actual adopted decision, never future caps
by assertion. Full clone lies under NEW install_parent/cold-clone-pgdata so global
and ownphase reservation includes BOTH physical clusters, allWAL/temp/archive/extract.
512MiB captures+>=3GiB otherfullpeak, >=1GiB cold-copy data reservation; actual cold
bytes exceeding reserve refuse. Fixed freeze19:44:42/initial8/floor4/whole1800 unchanged.
Config uses current stock pins, scope/newports/newdatabase above; package/source/app/
PG/pwsh/stdio pins; small_archive/hash/manifest and fixture_review{path,sha256};
capture_sql/catalog_sql pinned current sources; storage_sha; phase_budget dynamic.
NO old datadir/database/process used. Source actualcleanstop0 precedes exclusive
all-file SHA/nativeidentity enumeration; NEWcopy CreateNew, same whole source/native
inventory afterward, whole clone bytes equal, all noReparse/hardlinks1. Copy hash
comparison is ordinary file-copy verification, not atomic snapshot claim; external
quiet admission/closed-source evidence remains mandatory. Restart only two NEW owned
postmasters explicit ports/datadirs, one outerReadyJob AFTER BOTH exist. CurrentSQL
same systemid+OID must precede Verify1 cleanup_identity, absentplan/receipt and full
SmallS allmanagedvalues/catalog conservation. No Apply, faultflags, timeout changes,
login/reset/oldSQL, automatic retry, evidence deletion or self-granted PASS.
All conditional code remains unparsed/unexecuted pending independent review.
#>
