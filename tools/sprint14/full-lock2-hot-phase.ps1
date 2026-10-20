param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# Separate lock2 diagnostic: preserve original protocol, bound only metering overhead.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'boundary_config_before_import'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($c.boundary_mode -cne 'lock2' -or $c.hot_capture_reservation_bytes -ne 32MB){throw 'boundary_hot_exact_lock2_only'}
foreach($pin in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if($pin[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $pin[0])).Hash -cne $pin[1].ToUpperInvariant()){throw 'boundary_preimport_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's14-current-full-c2-timeouts' -or $c.boundary_mode -cnotin @('observe-delete','lock2','sql5-observe','sql5-hold') -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5475 -or $c.app_port -ne 3098 -or $c.proxy_port -ne 5477 -or $c.database -cne 'process_intelligence' -or $c.source_commit -cnotmatch '^[a-f0-9]{40}$'){throw 'boundary_finite_scope'}
if($c.app_sha -cne '23563DFF8FE93F339AD7F12FD0783AC3E2C53B8D9368C00D772A8FBABBE5F292' -or $c.package_sha -cne 'E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C'){throw 'boundary_exact_existing_candidate'}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$privateRoot=Join-Path $workspace '.local/sprint14'
$names=@($c.source_db,$c.restore_db);if($names[0] -ceq $names[1] -or @($names|Where-Object {$_ -cnotmatch '^pi_restore_s14_[a-z0-9_]{1,35}$'}).Count){throw 'boundary_new_distinct_pair'}
$inputSha='3A0E6E244384D141A326345E0161AEC0AFA7EC9AF2563E9C03CBDD1B04770274';$preSha='9959D3E9E746460C0C52853D139DCBCCFF37EE230907537AB437FCFE33933DA1';$postSha='4F3055304BF6B6B3CAFFD7C5D9EE8D7E3C021AE031B03D36B5A3981EB77DE256'
$oldObserverSha='6F0E22585B497BB2EBE73456DC2291D712BDB7AE75364D9DFC78A454EDF38899';$registrySha='D587F10D1144B91BD9BE1C09F3238DEA24C241DE75658ED065B0F35476226C36'
$sql5=$c.boundary_mode -cin @('sql5-observe','sql5-hold')
$observerName=if($sql5){'sql5-stream-observer.cjs'}else{'cleanup-boundary-observer.cjs'}
$observerSha=if($sql5){'B44179BA8A7FF272CCCB768068CF3C19BF3B5CC03B78214E457A9CAD3F168B6F'}else{'9CD97EC5FC9D7B02FBE2B6147DE2AD1BD3CAE0B19495308C6196C91B3902F05E'}
$original=Join-Path $workspace '.local/sprint09/qa/package-c2/process-intelligence-rs-0.7.1-windows-x86_64/.local/c2-c02-normalized01.dump'
foreach($pair in @(@($c.original_archive,$original),@($c.capture_sql,(Join-Path $workspace '.local/sprint11/root/sql5-inputs01/capture.sql')),@($c.catalog_sql,(Join-Path $PSScriptRoot 'logical-catalog.sql')),@($c.boundary_observer,(Join-Path $PSScriptRoot $observerName)),@($c.boundary_registry,(Join-Path $workspace '.local/sprint13/td/boundary-registry13-01.json')),@($c.post_oracle,(Join-Path $PSScriptRoot '../cleanup-post-oracle.cjs')),@($c.receipt_oracle,(Join-Path $PSScriptRoot '../sprint13/receipt-oracle.cjs')))){
 if((Get-OwnedCanonicalPath $pair[0]) -cne (Get-OwnedCanonicalPath $pair[1])){throw 'boundary_literal_inputs'};Assert-OwnedNoReparse $pair[0]
}
foreach($pair in @(@($original,$inputSha),@(($original+'.manifest.json'),'BD4BC1F45EA1AEB3A8D2668C6D0E7EFF39413A98CD27FD65C4B272ED10C735D7'),@($c.capture_sql,'054242566AC35D3AFAC986298BB030D8536A72710FA40F30ECA3193D8361A45B'),@($c.catalog_sql,$c.catalog_sql_sha),@($c.boundary_observer,$observerSha),@($c.boundary_registry,$registrySha),@($c.post_oracle,$c.post_oracle_sha),@($c.receipt_oracle,$c.receipt_oracle_sha),@((Join-Path $PSScriptRoot '../sprint13/historical-state-oracle.cjs'),$c.decimal_parser_sha),@($c.node,$c.node_sha),@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha))){Assert-OwnedHash $pair[0] $pair[1]}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$oldManifest=Get-Content -LiteralPath ($original+'.manifest.json') -Raw|ConvertFrom-Json
if($oldManifest.database -cne 'pi_restore_s9_c2_c18app01' -or $oldManifest.size -ne 7943113 -or $oldManifest.sha256.ToUpperInvariant() -cne $inputSha -or !$oldManifest.includes_auth){throw 'boundary_real_input_manifest'}
$registry=Get-Content -LiteralPath $c.boundary_registry -Raw|ConvertFrom-Json
if(@($registry.allowed_parse_sha).Count -ne 36 -or @($registry.allowed_simple).Count -ne 9 -or $registry.observer_sha256 -cne $oldObserverSha.ToLowerInvariant() -or $registry.startup.application_name -cne 'pi_cleanup_offline'){throw 'boundary_exact_registry_shape'}
# The retained registry was extracted while cleanup.rs had an intermediate
# cfg(test) calibration. Bind current production bytes to the package's exact
# core source; retain the old registry hash as provenance, never rewrite it.
Assert-OwnedHash $c.production_binding.path $c.production_binding.sha256
Assert-OwnedPrivateDirectory (Split-Path -Parent $c.production_binding.path)
$binding=Get-Content $c.production_binding.path -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($binding.scope -cne 'S14_EXACT_CLEANUP_PRODUCTION_PREFIX_CORE3F0_CURRENT' -or $binding.registry_sha256 -cne $registrySha -or $binding.current_sha256 -cne 'B7D4F6AF22F1A808CB794E8E545FF2641711838D2A71A750D5C2E77D06E8B51F' -or $binding.core_sha256 -cne '2941BEEE76B62E529448C701C9C44638E8EE64E615C9C299A9F074A9BDCB786B' -or $binding.prefix_bytes -ne 39070 -or $binding.prefix_sha256 -cne '8E1B4357330DBBF5AE606A14075D987DFF428A12133D3041D6A0EB0DE3476213'){throw 'boundary_production_binding_schema'}
$core=Get-OwnedCanonicalPath (Join-Path $workspace '.local/sprint14/root/full-timeout-drafts01/cleanup-core3f0.rs')
if((Get-OwnedCanonicalPath $binding.core_path) -cne $core){throw 'boundary_core_literal_path'}
Assert-OwnedHash $core $binding.core_sha256
$registrySource=Get-OwnedCanonicalPath (Join-Path $workspace '.local/sprint14/root/full-timeout-drafts01/cleanup-registry-ad921.rs')
if((Get-OwnedCanonicalPath $binding.registry_cleanup_path) -cne $registrySource){throw 'boundary_registry_source_literal_path'}
Assert-OwnedHash $registrySource 'AD9210B540B6717D7D8C9C4192CC1BCEAB363645F78DECA79DC3CF6C8DA094C0'
$cleanup=Join-Path $workspace 'src/cleanup.rs';Assert-OwnedHash $cleanup $binding.current_sha256
foreach($file in @($core,$cleanup,$registrySource)){
 $bytes=[IO.File]::ReadAllBytes($file);$text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
 if($text.IndexOf('#[cfg(test)]',[StringComparison]::Ordinal) -lt 0 -or [Text.Encoding]::UTF8.GetByteCount($text.Substring(0,$text.IndexOf('#[cfg(test)]',[StringComparison]::Ordinal))) -ne 39070){throw 'boundary_production_prefix_boundary'}
 $hash=[Security.Cryptography.SHA256]::Create();try{$digest=[Convert]::ToHexString($hash.ComputeHash($bytes,0,39070))}finally{$hash.Dispose()}
 if($digest -cne $binding.prefix_sha256){throw 'boundary_production_prefix_changed'}
}
$cleanupEntries=0
foreach($source in $registry.sources){
 if($source.path -ceq 'src/cleanup.rs'){
  if($source.sha256 -cne 'ad9210b540b6717d7d8c9c4192cc1bceab363645f78deca79dc3cf6c8da094c0'){throw 'boundary_retained_cleanup_provenance'};$cleanupEntries++
 }else{Assert-OwnedHash (Join-Path $workspace $source.path) $source.sha256}
}
if($cleanupEntries -ne 1){throw 'boundary_exact_cleanup_registry_entry'}
$oldScript=Join-Path $workspace ('tools/sprint13/'+$observerName)
$oldScriptSha=if($sql5){'16FDF895889C37D1A7204753E811FC619426AA6E9A74686642721E7F0D5967A1'}else{$oldObserverSha}
Assert-OwnedHash $oldScript $oldScriptSha;Assert-OwnedHash $c.observer_adapter.path $c.observer_adapter.sha256
$adapter=Get-Content $c.observer_adapter.path -Raw|ConvertFrom-Json
if($adapter.author_role -cne 'Developer' -or $adapter.registry_sha256 -cne $registrySha -or $adapter.original_sha256 -cne $oldScriptSha -or $adapter.adapted_sha256 -cne $observerSha -or $adapter.change -cne 'COMMENT_AND_LITERAL_BACKEND_PORT_5465_TO_5475_ONLY'){throw 'boundary_explicit_source_adapter'}
$expectedScript=[IO.File]::ReadAllText($oldScript).Replace('Sprint13 test','Sprint14 source-adapted test').Replace('cfg.backend_port !== 5465','cfg.backend_port !== 5475')
if([IO.File]::ReadAllText($c.boundary_observer) -cne $expectedScript){throw 'boundary_protocol_source_changed'}
$optionsSha=$registry.startup.options_sha
if($optionsSha -cne '3bfb6a81e5fe839828ae73660c0d14aa7d83ac7833a5109ff466920eed46cf92'){throw 'boundary_unchanged_production_options'}
if($c.boundary_mode -cin @('lock2','sql5-hold')){
 foreach($review in @(@{role='QA';pin=$c.observe_qa_review},@{role='TD';pin=$c.observe_td_review})){
  Assert-OwnedHash $review.pin.path $review.pin.sha256;$r=Get-Content -LiteralPath $review.pin.path -Raw|ConvertFrom-Json
  if($r.author_role -cne $review.role -or $r.scope -cne 's14-current-full-c2-timeouts' -or $r.observe_mode -cne $(if($sql5){'sql5-observe'}else{'observe-delete'}) -or $r.verdict -cne 'CURRENT_FULL_C2_BOUNDARY_OBSERVE_NATIVE0_RECEIPT_POST_VERIFIED' -or $r.package_sha256.ToUpperInvariant() -cne $c.package_sha.ToUpperInvariant() -or $r.observer_sha256.ToUpperInvariant() -cne $observerSha -or $r.registry_sha256.ToUpperInvariant() -cne $registrySha -or $r.archive_sha256.ToUpperInvariant() -cne $inputSha){throw 'boundary_actual_observe_first_required'}
  Assert-OwnedPrivateDirectory (Split-Path -Parent $r.actual_result.path);Assert-OwnedHash $r.actual_result.path $r.actual_result.sha256
  $observed=Get-Content $r.actual_result.path -Raw|ConvertFrom-Json
  if($observed.status -cne 'CURRENT_FULL_C2_BOUNDARY_EVIDENCE_PENDING_QA_TD' -or $observed.scope -cne $c.scope -or $observed.mode -cne $r.observe_mode -or $observed.native.native_exit -ne 0 -or $observed.observer_native.native_exit -ne 0 -or $observed.source_classification -cne 'EXPECTED_POST'){throw 'boundary_actual_NEW_observe_result_required'}
 }
}
$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out;$install=Get-OwnedCanonicalPath $c.install_parent
if($out -ceq $install -or $out.StartsWith($install.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $install.StartsWith($out.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'boundary_separate_install_output'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($deadline -gt [DateTimeOffset]::Parse('2026-10-20T09:54:16Z').UtcDateTime -or $started -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'boundary_capacity_freeze'}
if($c.required_free_bytes -ne 8GB -or $c.runtime_floor_bytes -ne 8GB -or $c.capture_reservation_bytes -ne 4000000000L -or $c.phase_reservation_bytes -gt 6GB){throw 'boundary_capture_reservation_unchanged'}
# This phase never adopts caps by configuration: the pinned helper must validate
# the actual Council decision and independently reviewed FULL uncompressed peak.
# A future helper/decision needs new exact source/config review before admission.
$resourceBudget=New-S14PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
$script:hotActive=$false;$script:hotCharged=0L;$script:hotBaseline=$null;$script:hotEnd=[DateTime]::MinValue
function GetHotFiles{
 $files=[Collections.Generic.List[IO.FileInfo]]::new()
 foreach($entry in [IO.DirectoryInfo]::new($out).EnumerateFileSystemInfos()){
  if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'boundary_hot_reparse'}
  if($entry -is [IO.DirectoryInfo]){
   if($entry.Name -cne 'boundary-stock'){throw 'boundary_hot_unknown_subdirectory'}
   foreach($file in $entry.EnumerateFileSystemInfos()){if($file -isnot [IO.FileInfo] -or $file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'boundary_hot_nested_kind'};$files.Add($file)}
  }else{$files.Add($entry)}
 }
 if($files.Count -gt 256){throw 'boundary_hot_bounded_file_count'};return $files.ToArray()
}
function AssertHot([long]$Next=0){
 if(!$script:hotActive -or !$script:hotBaseline -or $Next -lt 0 -or $Next -gt 1MB -or [DateTime]::UtcNow -ge $script:hotEnd -or [DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'boundary_hot_cap_or_deadline'}
 $script:hotCharged+=$Next;if($script:hotCharged -gt 32MB){throw 'boundary_hot_reservation_exhausted'}
 [long]$growth=0;$files=@(GetHotFiles)
 foreach($file in $files){$key=[IO.Path]::GetRelativePath($out,$file.FullName);$prior=if($script:hotBaseline.ContainsKey($key)){$script:hotBaseline[$key]}else{0L};if($file.Length -lt $prior){throw 'boundary_hot_preserved_output_shrank'};$growth+=$file.Length-$prior}
 if($growth -gt 32MB){throw 'boundary_hot_actual_growth_cap'}
 foreach($child in @($command,$observer,$holder,$service.Coordinator)){if($child -and ($child.Process.HasExited -or $child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached -or $child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted)){throw 'boundary_hot_parent_exit_or_capture_fault'}}
}
function Budget([long]$Next=0){if($script:hotActive){AssertHot $Next}else{Assert-S14PhaseBudget -Proof $resourceBudget -Next $Next}}
Budget
if(@(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object LocalPort -in @(5475,5477,3098)).Count){throw 'boundary_new_ports_must_be_absent'}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $install $c.manifest_sha
$manifest=Get-Content -LiteralPath (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($manifest.version -cne '0.7.3' -or $manifest.source_commit -cne $c.source_commit){throw 'boundary_current_candidate'}
$exe=Join-Path $pkg 'process-intelligence-rs.exe';$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
Assert-OwnedHash $exe $c.app_sha;Assert-OwnedHash $psql $c.psql_sha;Assert-OwnedHash $backup $c.backup_sha
$service=$null;$observer=$null;$command=$null;$observerCompleted=$false;$commandCompleted=$false;$secret=$null;$admin=$null;$envApply=$null;$holder=$null;$holderClosed=$false;$holderWitness=$null;$holderPort=0;$holderNonce=$null
function CompleteNative($n){return ($n.stdout_complete -and $n.stderr_complete -and !$n.output_limit -and !$n.capture_fault -and !$n.drain_timeout)}
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int]$Seconds=120,[long]$Cap=4MB){
 Budget $Cap;$p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if(($script:hotActive -and [DateTime]::UtcNow -ge $script:hotEnd) -or [DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'boundary_owned_native_stop'};break};if($script:hotActive){try{AssertHot}catch{$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'boundary_hot_owned_native_stop'};break}}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;automatic_retry=$false}
 if($forced -or $r.native_exit -ne 0 -or !(CompleteNative $r)){throw ('boundary_native_failed_'+$Label)};Budget;return $r
}
function Sql([string]$Database,[string]$Label,[string[]]$Arguments,[long]$Cap=16MB,[int]$SqlMs=60000){
 if($Database -cnotin ($names+@('postgres'))){throw 'boundary_sql_new_scope'}
 [string[]]$argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5475','-U','pi_admin','-w','-d',$Database)+$Arguments
 # Fixed UTC+05 belongs only to the independent immutable C2 snapshot domain.
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments $argv -Environment @{PGPASSWORD=$secret.admin_password;PGOPTIONS="-c statement_timeout=$SqlMs -c default_transaction_read_only=on -c TimeZone=Etc/GMT-5 -c DateStyle=ISO,YMD"} -Seconds 120 -Cap $Cap
}
function State([string]$Database,[string]$Label,[bool]$Catalog=$false){$sql=if($Catalog){$c.catalog_sql}else{$c.capture_sql};$cap=if($Catalog){16MB}else{1GB};Budget $cap;$r=Sql -Database $Database -Label $Label -Arguments @('-f',$sql) -Cap $cap;return @{database=$Database;path=(Join-Path $out ($Label+'.stdout'));sha256=$r.stdout_sha256;bytes=$r.stdout_bytes_persisted;native_exit=$r.native_exit}}
function EqualState($a,$b){if($a.bytes -ne $b.bytes -or $a.sha256.ToUpperInvariant() -cne $b.sha256.ToUpperInvariant()){throw 'boundary_full_state_mismatch'}}
function Stock([string]$Label,[hashtable]$Arguments){[string[]]$argv=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Arguments|ConvertTo-Json -Compress));return Native -Label $Label -Program $c.pwsh -Sha $c.pwsh_sha -Arguments $argv -Seconds 180}
function Identity([string]$Database,[string]$Label){
 [void](Sql -Database $Database -Label $Label -Arguments @('-c',"SELECT jsonb_build_object('database',current_database(),'database_oid',(SELECT oid::text FROM pg_database WHERE datname=current_database()),'system_identifier',(SELECT system_identifier::text FROM pg_control_system()),'server_version_num',current_setting('server_version_num'),'encoding',current_setting('server_encoding'),'recovery',pg_is_in_recovery());"))
 $v=Get-Content -LiteralPath (Join-Path $out ($Label+'.stdout')) -Raw|ConvertFrom-Json;if($v.database -cne $Database -or $v.server_version_num -cne '180006' -or $v.encoding -cne 'UTF8' -or $v.recovery){throw 'boundary_pg_actual_identity'}
 $identity=@{database=$v.database;database_oid=$v.database_oid;system_identifier=$v.system_identifier};Write-OwnedJson (Join-Path $out ($Label+'-receipt.json')) $identity;return $identity
}
$events=Join-Path $out 'boundary-events.jsonl'
function Trace {
 if(!(Test-Path -LiteralPath $events)){return @()}
 $s=[IO.File]::Open($events,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 try{if($s.Length -gt 2MB){throw 'boundary_trace_bound'};$buffer=[byte[]]::new([int]$s.Length);$read=0;while($read -lt $buffer.Length){$n=$s.Read($buffer,$read,$buffer.Length-$read);if(!$n){throw 'boundary_trace_short_read'};$read+=$n}}finally{$s.Dispose()}
 $text=[Text.UTF8Encoding]::new($false,$true).GetString($buffer);$end=$text.LastIndexOf("`n");if($end -lt 0){return @()}
 return @($text.Substring(0,$end).Split("`n")|Where-Object {$_}|ForEach-Object {$_|ConvertFrom-Json -AsHashtable -DateKind String})
}
function BeginLockHolder($Frame){
 # Separate fixture connection, never query injection into the cleanup stream.
 $script:holderNonce='s14-lock2-'+[Guid]::NewGuid().ToString('N');$file=Join-Path $out 'lock2-holder.sql'
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes("BEGIN;`nLOCK TABLE public.pi_kv IN ACCESS EXCLUSIVE MODE;`nSELECT pg_sleep(25);`n")
 $f=[IO.File]::Open($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$f.Write($bytes);$f.Flush($true)}finally{$f.Dispose()}
 Budget 1MB;$script:holder=Start-OwnedCapturedProcess -Program $psql -ProgramSha256 $c.psql_sha -Arguments @('-X','-qAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-h','127.0.0.1','-p','5475','-U','pi_admin','-w','-d',$c.source_db,'-f',$file) -WorkingDirectory $pkg -OutputDirectory $out -Label 'lock2-holder' -MaxOutputBytes 1MB -Environment @{PGPASSWORD=$secret.admin_password;PGAPPNAME=$holderNonce;PGOPTIONS='-c statement_timeout=60000'}
 $until=[DateTime]::UtcNow.AddSeconds(3)
 do{AssertHot;$connections=@(Get-NetTCPConnection -State Established -OwningProcess $holder.Process.Id -ErrorAction SilentlyContinue|Where-Object {$_.RemotePort -eq 5475 -and $_.RemoteAddress -eq '127.0.0.1'});AssertHot;if($connections.Count -eq 1){break};if($holder.Process.HasExited -or [DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $script:hotEnd){throw 'boundary_holder_socket_not_proven'};Start-Sleep -Milliseconds 25}while($true)
 $native=Get-CimInstance Win32_Process -Filter ('ProcessId='+$holder.Process.Id)
 if(!$native -or $native.ExecutablePath -cne $psql -or $holder.Process.StartTime.ToUniversalTime().ToString('o') -cne $holder.Record.native_creation_utc){throw 'boundary_holder_native_binding'}
 $script:holderPort=[int]$connections[0].LocalPort
 $query="SELECT jsonb_build_object('pid',a.pid,'backend_start',a.backend_start,'datname',a.datname,'usename',a.usename,'application_name',a.application_name,'client_port',a.client_port,'state',a.state,'wait_event',a.wait_event,'query',a.query,'granted_access_exclusive',(SELECT count(*) FROM pg_locks l WHERE l.pid=a.pid AND l.locktype='relation' AND l.relation='public.pi_kv'::regclass AND l.mode='AccessExclusiveLock' AND l.granted)) FROM pg_stat_activity a WHERE a.datname=current_database() AND a.application_name='"+$holderNonce+"' AND a.client_port="+$holderPort+';'
 [void](Sql -Database $c.source_db -Label 'lock2-holder-witness' -Arguments @('-c',$query) -Cap 1MB -SqlMs 2000)
 $script:holderWitness=Get-Content (Join-Path $out 'lock2-holder-witness.stdout') -Raw|ConvertFrom-Json -DateKind String
 if(!$holderWitness -or $holderWitness.pid -le 0 -or !$holderWitness.backend_start -or $holderWitness.datname -cne $c.source_db -or $holderWitness.usename -cne 'pi_admin' -or $holderWitness.application_name -cne $holderNonce -or $holderWitness.client_port -ne $holderPort -or $holderWitness.wait_event -cne 'PgSleep' -or $holderWitness.state -cne 'active' -or $holderWitness.query.Trim() -cne 'SELECT pg_sleep(25);' -or $holderWitness.granted_access_exclusive -ne 1){throw 'boundary_actual_holder_lock_not_proven'}
 # Also prove the held production backend is still in its exact open transaction.
 [void](Sql -Database $c.source_db -Label 'lock2-cleanup-held-witness' -Arguments @('-c',("SELECT jsonb_build_object('pid',pid,'backend_start',backend_start,'state',state,'xact_start',xact_start,'application_name',application_name) FROM pg_stat_activity WHERE pid="+[string][int]$Frame.backend_pid+" AND datname=current_database();")) -Cap 1MB -SqlMs 2000)
 $cw=Get-Content (Join-Path $out 'lock2-cleanup-held-witness.stdout') -Raw|ConvertFrom-Json -DateKind String
 if(!$cw -or $cw.pid -ne $Frame.backend_pid -or !$cw.backend_start -or !$cw.xact_start -or $cw.state -cne 'idle in transaction' -or $cw.application_name -cne 'pi_cleanup_offline'){throw 'boundary_cleanup_held_tx_not_proven'}
 Write-OwnedJson (Join-Path $out 'lock2-external-holder-binding.json') @{held_original=$Frame;cleanup_backend=$cw;holder_backend=$holderWitness;native_pid=$holder.Process.Id;native_creation=$holder.Record.native_creation_utc;cim_creation=$native.CreationDate.ToUniversalTime().ToString('o');image=$native.ExecutablePath;local_port=$holderPort;remote_port=5475;holder_sql_sha256=Get-OwnedHash $file;job_basis='Source-reviewed no-breakaway inheritance from admitted outer waiting worker; no direct unnamed outer Job.Member claim';admin_witness_closed_before_forward=$true}
}
function CloseLockHolder{
 if(!$holder -or !$holderWitness -or $holderClosed){throw 'boundary_missing_holder_close_binding'}
 $native=Get-CimInstance Win32_Process -Filter ('ProcessId='+$holder.Process.Id)
 if($holder.Process.HasExited -or !$native -or $native.ExecutablePath -cne $psql -or $holder.Process.StartTime.ToUniversalTime().ToString('o') -cne $holder.Record.native_creation_utc -or @(Get-NetTCPConnection -State Established -OwningProcess $holder.Process.Id -ErrorAction Stop|Where-Object {$_.LocalPort -eq $holderPort -and $_.RemotePort -eq 5475 -and $_.RemoteAddress -eq '127.0.0.1'}).Count -ne 1){throw 'boundary_holder_cancel_native_binding'}
 $where="pid="+[string][int]$holderWitness.pid+" AND datname='"+$c.source_db+"' AND usename='pi_admin' AND application_name='"+$holderNonce+"' AND client_port="+$holderPort+" AND backend_start='"+$holderWitness.backend_start+"'::timestamptz"
 [void](Sql -Database $c.source_db -Label 'lock2-holder-cancel-witness' -Arguments @('-c',("SELECT jsonb_build_object('pid',a.pid,'backend_start',a.backend_start,'wait_event',a.wait_event,'granted',(SELECT count(*) FROM pg_locks l WHERE l.pid=a.pid AND l.relation='public.pi_kv'::regclass AND l.mode='AccessExclusiveLock' AND l.granted)) FROM pg_stat_activity a WHERE "+$where+';')) -Cap 1MB -SqlMs 2000)
 $w=Get-Content (Join-Path $out 'lock2-holder-cancel-witness.stdout') -Raw|ConvertFrom-Json -DateKind String
 if(!$w -or $w.pid -ne $holderWitness.pid -or $w.backend_start -cne $holderWitness.backend_start -or $w.wait_event -cne 'PgSleep' -or $w.granted -ne 1){throw 'boundary_holder_cancel_backend_binding'}
 [void](Sql -Database $c.source_db -Label 'lock2-holder-targeted-cancel' -Arguments @('-c',("SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE "+$where+';')) -Cap 1MB -SqlMs 2000)
 if((Get-Content (Join-Path $out 'lock2-holder-targeted-cancel.stdout') -Raw).Trim() -cne 't' -or !$holder.Process.WaitForExit(10000)){throw 'boundary_holder_targeted_cancel_failed'}
 $r=Complete-OwnedCapturedProcess $holder;$script:holderClosed=$true
 Write-OwnedJson (Join-Path $out 'lock2-holder-native.json') @{native=$r;controlled_cancel=$true;backend_pid=$holderWitness.pid;backend_start=$holderWitness.backend_start;no_clean_native0_claim=$true}
 if($r.native_exit -notin @(1,3) -or !(CompleteNative $r) -or (Get-Content (Join-Path $out 'lock2-holder.stderr') -Raw) -cnotmatch '57014:.*canceling statement due to user request'){throw 'boundary_holder_actual_57014_user_cancel_required'}
 [void](Sql -Database 'postgres' -Label 'lock2-holder-backend-gone' -Arguments @('-c',('SELECT count(*) FROM pg_stat_activity WHERE pid='+[string][int]$holderWitness.pid+';')) -Cap 1MB -SqlMs 2000)
 if((Get-Content (Join-Path $out 'lock2-holder-backend-gone.stdout') -Raw).Trim() -cne '0'){throw 'boundary_holder_backend_remains'}
}
try{
 $service=Start-OwnedStockService $c $pkg 'boundary-stock';[void](Wait-OwnedStockService $service)
 $apps=@($service.Processes|Where-Object Name -ceq 'app');if($apps.Count -ne 1 -or !$service.Job.Member($apps[0].Handle)){throw 'boundary_owned_app_identity'}
 $held=$apps[0];$actual=Get-CimInstance Win32_Process -Filter ('ProcessId='+$held.Process.Id)
 if(!$actual -or $held.Process.HasExited -or $actual.ExecutablePath -cne $exe -or $held.Process.StartTime.ToUniversalTime().ToString('o') -cne $held.Creation){throw 'boundary_owned_app_stale'}
 $held.Process.Kill();if(!$held.Process.WaitForExit(10000) -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'boundary_app_not_offline'}
 Write-OwnedJson (Join-Path $out 'app-offline.json') @{pid=$held.Process.Id;creation=$held.Creation;native_exit=$held.Process.ExitCode;controlled_forced_stop=$true;no_clean_app_exit_claim=$true}
 $secret=Get-Content -LiteralPath (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5475){throw 'boundary_private_port'}
 foreach($n in $names){$label='absent-'+$n.Substring(15).Replace('_','-');[void](Sql -Database 'postgres' -Label $label -Arguments @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$n+"');")));if((Get-Content -LiteralPath (Join-Path $out ($label+'.stdout')) -Raw).Trim() -cne 'f'){throw 'boundary_database_not_new'}}
 $input=Join-Path $pkg '.local/full-original.dump';[IO.File]::Copy($original,$input,$false);[IO.File]::Copy(($original+'.manifest.json'),($input+'.manifest.json'),$false)
 [void](Stock -Label 'restore-source' -Arguments @{Mode='Restore';Database=$oldManifest.database;TargetDatabase=$c.source_db;BackupFile=$input})
 $archive=Join-Path $pkg '.local/full-current-source.dump';[void](Stock -Label 'backup-new-source' -Arguments @{Mode='Backup';Database=$c.source_db;BackupFile=$archive})
 $am=Get-Content -LiteralPath ($archive+'.manifest.json') -Raw|ConvertFrom-Json;if($am.database -cne $c.source_db -or !$am.includes_auth -or $am.sha256.ToUpperInvariant() -cne (Get-OwnedHash $archive) -or $am.size -ne (Get-Item -LiteralPath $archive).Length){throw 'boundary_truthful_current_archive'}
 [void](Stock -Label 'restore-verification' -Arguments @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.restore_db;BackupFile=$archive})
 $sid=Identity $c.source_db 'source-identity';$rid=Identity $c.restore_db 'restore-identity';if($sid.system_identifier -cne $rid.system_identifier -or $sid.database_oid -ceq $rid.database_oid){throw 'boundary_actual_distinct_pair'}
 $sourcePre=State $c.source_db 'source-pre';$restorePre=State $c.restore_db 'restore-pre';EqualState $sourcePre @{sha256=$preSha;bytes=614304123};EqualState $sourcePre $restorePre
 $catalogPre=State $c.source_db 'source-catalog-pre' $true;$restoreCatalogPre=State $c.restore_db 'restore-catalog-pre' $true;EqualState $catalogPre $restoreCatalogPre
 $plan=Join-Path $pkg '.local/boundary.plan.json';$receipt=Join-Path $pkg '.local/boundary.receipt.json'
 $direct="host=127.0.0.1 port=5475 user=pi_admin password=$($secret.admin_password) dbname=$($c.source_db) connect_timeout=5"
 $restoreUrl="host=127.0.0.1 port=5475 user=pi_admin password=$($secret.admin_password) dbname=$($c.restore_db) connect_timeout=5"
 $verifyEnv=@{PI_DATABASE_URL=$direct;PI_CLEANUP_RESTORE_URL=$restoreUrl;PI_CLEANUP_ARCHIVE=$archive;PI_CLEANUP_PLAN=$plan}
 [void](Native -Label 'current-verify' -Program $exe -Sha $c.app_sha -Arguments @('--cleanup-storage-verify') -Environment $verifyEnv -Seconds 300)
 $v=Get-Content -LiteralPath (Join-Path $out 'current-verify.stdout') -Raw|ConvertFrom-Json;if($v.outcome -cne 'cleanup_verified' -or $v.candidate_rows -ne 10 -or $v.plan_sha256.ToUpperInvariant() -cne (Get-OwnedHash $plan)){throw 'boundary_current_verify_ten'}
 $expectedPath=Join-Path $out 'expected-post.stdout';[string[]]$oracleArgs=@($c.post_oracle,$sourcePre.path,$plan,$expectedPath)
 [void](Native -Label 'derive-full-post' -Program $c.node -Sha $c.node_sha -Arguments $oracleArgs -Seconds 180 -Cap 1MB)
 $expected=Get-Content -LiteralPath (Join-Path $out 'derive-full-post.stdout') -Raw|ConvertFrom-Json;if($expected.status -cne 'FULL_POST_ORACLE_DERIVED' -or $expected.pre_sha256.ToUpperInvariant() -cne $preSha -or $expected.post_sha256.ToUpperInvariant() -cne $postSha -or $expected.post_bytes -ne 307159782 -or $expected.removed_exact_rows -ne 10){throw 'boundary_independent_post_oracle'}
 Assert-OwnedHash $expectedPath $postSha
 $planData=Get-Content -LiteralPath $plan -Raw|ConvertFrom-Json;if(@($planData.candidates).Count -ne 10 -or $c.target_key_sha -cnotmatch '^[a-f0-9]{64}$'){throw 'boundary_target_plan'}
 $targetMatches=0;$expectedPairs=@{};foreach($candidate in $planData.candidates){$b=[Text.Encoding]::UTF8.GetBytes($candidate.key);$h=[Security.Cryptography.SHA256]::Create();try{$keySha=[Convert]::ToHexString($h.ComputeHash($b)).ToLowerInvariant()}finally{$h.Dispose()};if($expectedPairs.ContainsKey($keySha)){throw 'boundary_duplicate_plan_key_hash'};$expectedPairs[$keySha]=[string]$candidate.source_version;if($keySha -ceq $c.target_key_sha){$targetMatches++}}
 if($targetMatches -ne 1){throw 'boundary_ambiguous_target_key'}
 $nonce=[Guid]::NewGuid().ToString('N');$control=Join-Path $out 'boundary-control.json';$observerConfig=Join-Path $out 'boundary-observer-config.json'
 Write-OwnedJson $observerConfig @{mode=$(if($c.boundary_mode -ceq 'sql5-observe'){'observe'}elseif($c.boundary_mode -ceq 'sql5-hold'){'hold'}else{$c.boundary_mode});backend_port=5475;listen_port=5477;database=$c.source_db;options_sha=$optionsSha;plan_sha=(Get-OwnedHash $plan).ToLowerInvariant();plan_path=$plan;target_key_sha=$c.target_key_sha;evidence_path=$events;allowed_parse_sha=@($registry.allowed_parse_sha);allowed_simple=@($registry.allowed_simple);control_path=$control;control_nonce=$nonce}
 [string[]]$observerArgs=@($c.boundary_observer)
 $observer=Start-OwnedCapturedProcess -Program $c.node -ProgramSha256 $c.node_sha -Arguments $observerArgs -WorkingDirectory $pkg -OutputDirectory $out -Label 'boundary-observer' -MaxOutputBytes 1MB -Environment @{PI_FULL_OBSERVER_CONFIG=$observerConfig}
 $readyEnd=[DateTime]::UtcNow.AddSeconds(10)
 do{$trace=@(Trace);if(@($trace|Where-Object kind -ceq 'listener_ready').Count -eq 1){break};if($observer.Process.HasExited -or [DateTime]::UtcNow -ge $readyEnd){throw 'boundary_proxy_not_ready'};Start-Sleep -Milliseconds 50}while($true)
 $listeners=@(Get-NetTCPConnection -LocalPort 5477 -State Listen -ErrorAction Stop)
 if(@($listeners.OwningProcess|Select-Object -Unique).Count -ne 1 -or $listeners[0].OwningProcess -ne $observer.Process.Id -or @($listeners|Where-Object LocalAddress -notin @('127.0.0.1','::1')).Count){throw 'boundary_proxy_actual_listener'}
 $nodeCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$observer.Process.Id);$pg=@($service.Processes|Where-Object Name -ceq 'postgres');if($pg.Count -ne 1){throw 'boundary_stock_pg_retained'}
 $pgCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id)
 if(!$nodeCim -or $nodeCim.ExecutablePath -cne $c.node -or $observer.Process.HasExited -or $observer.Process.StartTime.ToUniversalTime().ToString('o') -cne $observer.Record.native_creation_utc -or !$pgCim -or $pg[0].Process.HasExited -or $pgCim.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe')){throw 'boundary_actual_node_pg_identity'}
 Write-OwnedJson (Join-Path $out 'boundary-proxy-identity.json') @{node_pid=$observer.Process.Id;node_native_creation_utc=$observer.Record.native_creation_utc;node_cim_creation_utc=$nodeCim.CreationDate.ToUniversalTime().ToString('o');node_image=$nodeCim.ExecutablePath;node_sha256=$c.node_sha;port=5477;listener_addresses=@($listeners.LocalAddress);postgres_pid=$pg[0].Process.Id;postgres_cim_creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o');postgres_image=$pgCim.ExecutablePath;scope='Fresh actual retained PID/nativecreation plus CIMimage/creation and exactloopback5477 before outerJob membership request'}
 # Exactly ONE outer membership request, only now both retained processes exist.
 Wait-OwnedReadyJob @(@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o')},@{name='observer';pid=$observer.Process.Id;creation_utc=$nodeCim.CreationDate.ToUniversalTime().ToString('o')}) $out
 # Charge the complete existing phase plus a finite hot capture reservation before
 # Apply opens any transaction. During the held-frame setup only this flat output
 # delta (only root plus fixed flat boundary-stock) and all retained stream pumps
 # are inspected; no PostgreSQL install-tree walk occurs.
 Budget 32MB;$script:hotBaseline=@{};foreach($file in @(GetHotFiles)){$script:hotBaseline[[IO.Path]::GetRelativePath($out,$file.FullName)]=$file.Length}
 $envApply=@{PI_DATABASE_URL="host=127.0.0.1 port=5477 user=pi_admin password=$($secret.admin_password) dbname=$($c.source_db) connect_timeout=5";PI_CLEANUP_RESTORE_URL=$restoreUrl;PI_CLEANUP_ARCHIVE=$archive;PI_CLEANUP_PLAN=$plan;PI_CLEANUP_CONFIRM_SHA=(Get-OwnedHash $plan);PI_CLEANUP_RECEIPT=$receipt}
 $command=Start-OwnedCapturedProcess -Program $exe -ProgramSha256 $c.app_sha -Arguments @('--cleanup-storage-apply') -WorkingDirectory $pkg -OutputDirectory $out -Label 'boundary-apply' -MaxOutputBytes 1MB -Environment $envApply
 $until=[DateTime]::UtcNow.AddSeconds(300);$forced=$false;$controlSent=$false
 while(!$command.Process.WaitForExit(50)){
  if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB -or $command.OutCapture.LimitReached -or $command.ErrCapture.LimitReached -or $command.OutCapture.Pump.IsFaulted -or $command.ErrCapture.Pump.IsFaulted){$forced=$true;$command.Process.Kill($true);if(!$command.Process.WaitForExit(10000)){throw 'boundary_apply_owned_stop'};break}
  if($c.boundary_mode -ceq 'lock2' -and !$controlSent){
   $heldFrames=@(Trace|Where-Object {$_.kind -ceq 'original_frame_held_before_backend_forward' -and $_.held_kind -ceq 'share_row_exclusive_lock'})
   if($heldFrames.Count -gt 1){throw 'boundary_multiple_lock_holds'}
   if($heldFrames.Count -eq 1){$f=$heldFrames[0];if($f.actual_ready_status -cne 'T' -or $f.backend_pid -le 0 -or $f.frame_sha -cnotmatch '^[a-f0-9]{64}$' -or $f.backend_bytes_forwarded -ne 0){throw 'boundary_held_LOCK_binding'}
    # Six seconds starts at the observer's actual original-frame timestamp, not
    # after slow preparation. It never extends PostgreSQL's unchanged 5/2/10.
    $script:hotEnd=[DateTimeOffset]::Parse($f.utc).UtcDateTime.AddSeconds(6);$script:hotCharged=0L;$script:hotActive=$true;AssertHot
    BeginLockHolder $f;AssertHot
    Write-OwnedJson $control @{command='forward';nonce=$nonce;backend_pid=$f.backend_pid;frame_sha=$f.frame_sha};$controlSent=$true
    AssertHot;$script:hotActive=$false;Budget
    Write-OwnedJson (Join-Path $out 'lock2-hot-window.json') @{original_held_utc=$f.utc;hard_end_utc=$script:hotEnd.ToString('o');reservation_bytes=32MB;reserved_native_bytes=$script:hotCharged;full_meter_after_forward=$true;all_original_witnesses_retained=$true;no_timeout_or_SQL_change=$true}
   }
  }
 }
 $native=Complete-OwnedCapturedProcess $command;$commandCompleted=$true
 $observerForced=!$observer.Process.WaitForExit(10000);if($observerForced){$observer.Process.Kill($true);if(!$observer.Process.WaitForExit(10000)){throw 'boundary_observer_owned_stop'}}
 $observerNative=Complete-OwnedCapturedProcess $observer;$observerCompleted=$true;$trace=@(Trace)
 Write-OwnedJson (Join-Path $out 'boundary-native-completion.json') @{apply=$native;observer=$observerNative;apply_forced=$forced;observer_forced=$observerForced}
 if($c.boundary_mode -ceq 'lock2'){CloseLockHolder}
 $backends=@($trace|Where-Object kind -ceq 'actual_backend_pid');if($backends.Count -ne 1 -or $backends[0].backend_pid -le 0){throw 'boundary_unique_backend_pid'}
 $gone=$false;for($attempt=1;$attempt -le 10;$attempt++){[void](Sql -Database 'postgres' -Label ('backend-gone-'+$attempt) -Arguments @('-c',('SELECT count(*) FROM pg_stat_activity WHERE pid='+[string][int]$backends[0].backend_pid+';')) -Cap 1MB -SqlMs 2000);if((Get-Content -LiteralPath (Join-Path $out ('backend-gone-'+$attempt+'.stdout')) -Raw).Trim() -ceq '0'){$gone=$true;break};Start-Sleep -Milliseconds 100}
 if(!$gone){throw 'boundary_backend_not_gone_no_state_credit'}
 $sourceAfter=State $c.source_db 'source-after-boundary';$restoreAfter=State $c.restore_db 'restore-after-boundary';$catalogAfter=State $c.source_db 'source-catalog-after' $true;$restoreCatalogAfter=State $c.restore_db 'restore-catalog-after' $true
 EqualState $restorePre $restoreAfter;EqualState $catalogPre $catalogAfter;EqualState $restoreCatalogPre $restoreCatalogAfter
 $classification=if($sourceAfter.sha256 -ceq $preSha -and $sourceAfter.bytes -eq 614304123){'COMPLETE_PRE'}elseif($sourceAfter.sha256 -ceq $postSha -and $sourceAfter.bytes -eq 307159782){'EXPECTED_POST'}else{'UNEXPECTED_STOP'}
 $outcome=Get-Content -LiteralPath (Join-Path $out 'boundary-apply.stdout') -Raw|ConvertFrom-Json
 $stops=@($trace|Where-Object kind -ceq 'stop');$deleted=@($trace|Where-Object kind -ceq 'actual_delete_command_complete');$pairs=@($trace|Where-Object kind -ceq 'actual_delete_returned_pair')
 $common=!$forced -and !$observerForced -and (CompleteNative $native) -and (CompleteNative $observerNative) -and $observerNative.native_exit -eq 0 -and $stops.Count -eq 1
 $deleteProof=$deleted.Count -eq 1 -and $deleted[0].actual_tag -ceq 'DELETE 10' -and $pairs.Count -eq 10 -and @($pairs.key_sha|Select-Object -Unique).Count -eq 10
 foreach($pair in $pairs){if($pair.backend_pid -ne $backends[0].backend_pid -or !$expectedPairs.ContainsKey($pair.key_sha) -or $pair.version -cne $expectedPairs[$pair.key_sha]){throw 'boundary_returning_exact_plan_and_backend_binding'}}
 $passed=$false
 if($c.boundary_mode -cin @('observe-delete','sql5-observe')){
  $passed=$native.native_exit -eq 0 -and $outcome.outcome -ceq 'cleanup_committed' -and $outcome.deleted_rows -eq 10 -and $classification -ceq 'EXPECTED_POST'
  if($sql5){$passed=$passed -and @($trace|Where-Object {$_.kind -ceq 'actual_target_command_complete' -and $_.actual_tag -ceq 'SELECT 1' -and $_.target_rows -eq 1}).Count -eq 1 -and @($trace|Where-Object {$_.kind -ceq 'actual_target_datarow_shape' -and $_.columns -eq 3 -and $_.fields -eq 3}).Count -eq 1 -and $stops[0].target_completed}
  else{$passed=$passed -and $deleteProof -and @($trace|Where-Object kind -ceq 'actual_final_commit_complete').Count -eq 1}
  if($passed){[string[]]$receiptArgs=@($c.receipt_oracle,$plan,$receipt,(Join-Path $out 'boundary-apply.stdout'),(Join-Path $out 'source-identity-receipt.json'),(Join-Path $out 'restore-identity-receipt.json'),$archive);[void](Native -Label 'receipt-full-contract' -Program $c.node -Sha $c.node_sha -Arguments $receiptArgs -Seconds 60 -Cap 1MB);$rp=Get-Content (Join-Path $out 'receipt-full-contract.stdout') -Raw|ConvertFrom-Json;$passed=$rp.status -ceq 'COMMITTED_RECEIPT_FULL_CONTRACT_BOUND'}
 }else{
  $passed=$native.native_exit -eq 1 -and $outcome.outcome -ceq 'cleanup_refused' -and $outcome.code -ceq 'cleanup_storage_unavailable' -and $classification -ceq 'COMPLETE_PRE' -and $deleted.Count -eq 0 -and $pairs.Count -eq 0 -and !(Test-Path $receipt)
  if($sql5){$err=@($trace|Where-Object {$_.kind -ceq 'actual_server_error' -and $_.sqlstate -ceq '57014' -and $_.target_execution -and $_.statement_timeout_reason_verified -and $_.before_pair_release});$passed=$passed -and $err.Count -eq 1 -and @($trace|Where-Object kind -ceq 'actual_target_bind_complete').Count -eq 1 -and @($trace|Where-Object {$_.kind -ceq 'hold_armed' -and $_.deadline_ms_from_bind_write -eq 6500}).Count -eq 1 -and $stops[0].actual_target57014 -and $stops[0].actual_bind_complete -and $stops[0].held_execute -and $stops[0].held_sync -and !$stops[0].original_pair_released}
  else{$err=@($trace|Where-Object {$_.kind -ceq 'boundary_server_error_no_fault_credit' -and $_.sqlstate -ceq '55P03' -and $_.actual_lock_timeout});$passed=$passed -and $controlSent -and $holderClosed -and $err.Count -eq 1 -and $stops[0].reason -ceq 'actual_server_lock_timeout' -and @($trace|Where-Object kind -ceq 'original_lock_forward_after_external_witness').Count -eq 1}
 }
 $passed=$common -and $passed
 Write-OwnedJson (Join-Path $out 'full-boundary-result.json') @{status=$(if($passed){'CURRENT_FULL_C2_BOUNDARY_EVIDENCE_PENDING_QA_TD'}else{'FAILED_RETAINED'});scope=$c.scope;mode=$c.boundary_mode;native=$native;observer_native=$observerNative;source_classification=$classification;source_after=$sourceAfter;restore_after=$restoreAfter;catalog_pre=$catalogPre;catalog_after=$catalogAfter;restore_catalog_pre=$restoreCatalogPre;restore_catalog_after=$restoreCatalogAfter;outcome=$outcome;source_backend_gone=$gone;control_sent=$controlSent;single_apply_invocation=$true;no_compression_assumed=$true;limits=@('NEW current0.7.3 execution only; old registry/source/fixture readonly provenance, not runtime credit','SQL5 exact target57014 before original E/Sync release, not CPU execution-duration proof','lock2 exact55P03 requires captured original LOCK and independently witnessed owned holder before forward','Complete raw state and catalog, not CLI exit inference','No full R3/release/browser/C18 acceptance')}
 if(!$passed){throw 'boundary_failed_retained_no_retry'}
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256};Assert-OwnedHash $c.boundary_registry $registrySha;Assert-OwnedHash $c.boundary_observer $observerSha;Test-OwnedPackageTree $pkg $c.manifest_sha $true;Budget
}finally{
 $script:hotActive=$false
 try{
 foreach($item in @(@{name='holder';child=$holder;completed=$holderClosed},@{name='apply';child=$command;completed=$commandCompleted},@{name='observer';child=$observer;completed=$observerCompleted})){
  if($item.child -and !$item.completed){$p=$item.child.Process;$wasAlive=!$p.HasExited;if($wasAlive){$p.Kill($true)};if(!$p.WaitForExit(10000)){throw 'boundary_final_owned_child_stop'};$n=Complete-OwnedCapturedProcess $item.child;Write-OwnedJson (Join-Path $out ($item.name+'-finally-stop.json')) @{native=$n;forced=$wasAlive;successful_boundary_claim=$false}}
 }
 }finally{
 $secret=$null;$admin=$null;$envApply=$null
 if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'}
 }
}


Write-OwnedJson (Join-Path $out 'closed-phase-budget.json') (Get-S14ClosedPhaseBudgetTotals $resourceBudget)
# SOURCE ONLY: no observed timeout, native0, cleanPG or actual fresh-meter feasibility claimed until reviewed execution.
