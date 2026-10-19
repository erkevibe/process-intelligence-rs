param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY full C2 boundary draft; current0.7.3, no old script/EXE execution.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'boundary_config_before_import'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if($pin[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $pin[0])).Hash -cne $pin[1].ToUpperInvariant()){throw 'boundary_preimport_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's13-current-full-c2-boundaries' -or $c.boundary_mode -cnotin @('observe-delete','f01','f02','f03','tx10') -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5465 -or $c.app_port -ne 3097 -or $c.proxy_port -ne 5467 -or $c.database -cne 'process_intelligence' -or $c.source_commit -cnotmatch '^[a-f0-9]{40}$'){throw 'boundary_finite_scope'}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$privateRoot=Join-Path $workspace '.local/sprint13'
$names=@($c.source_db,$c.restore_db);if($names[0] -ceq $names[1] -or @($names|Where-Object {$_ -cnotmatch '^pi_restore_s13_[a-z0-9_]{1,35}$'}).Count){throw 'boundary_new_distinct_pair'}
$inputSha='3A0E6E244384D141A326345E0161AEC0AFA7EC9AF2563E9C03CBDD1B04770274';$preSha='9959D3E9E746460C0C52853D139DCBCCFF37EE230907537AB437FCFE33933DA1';$postSha='4F3055304BF6B6B3CAFFD7C5D9EE8D7E3C021AE031B03D36B5A3981EB77DE256'
$observerSha='6F0E22585B497BB2EBE73456DC2291D712BDB7AE75364D9DFC78A454EDF38899';$registrySha='D587F10D1144B91BD9BE1C09F3238DEA24C241DE75658ED065B0F35476226C36'
$original=Join-Path $workspace '.local/sprint09/qa/package-c2/process-intelligence-rs-0.7.1-windows-x86_64/.local/c2-c02-normalized01.dump'
foreach($pair in @(@($c.original_archive,$original),@($c.capture_sql,(Join-Path $workspace '.local/sprint11/root/sql5-inputs01/capture.sql')),@($c.catalog_sql,(Join-Path $PSScriptRoot 'logical-catalog.sql')),@($c.boundary_observer,(Join-Path $PSScriptRoot 'cleanup-boundary-observer.cjs')),@($c.boundary_registry,(Join-Path $workspace '.local/sprint13/td/boundary-registry13-01.json')),@($c.post_oracle,(Join-Path $PSScriptRoot '../cleanup-post-oracle.cjs')),@($c.receipt_oracle,(Join-Path $PSScriptRoot 'receipt-oracle.cjs')))){
 if((Get-OwnedCanonicalPath $pair[0]) -cne (Get-OwnedCanonicalPath $pair[1])){throw 'boundary_literal_inputs'};Assert-OwnedNoReparse $pair[0]
}
foreach($pair in @(@($original,$inputSha),@(($original+'.manifest.json'),'BD4BC1F45EA1AEB3A8D2668C6D0E7EFF39413A98CD27FD65C4B272ED10C735D7'),@($c.capture_sql,'054242566AC35D3AFAC986298BB030D8536A72710FA40F30ECA3193D8361A45B'),@($c.catalog_sql,$c.catalog_sql_sha),@($c.boundary_observer,$observerSha),@($c.boundary_registry,$registrySha),@($c.post_oracle,$c.post_oracle_sha),@($c.receipt_oracle,$c.receipt_oracle_sha),@((Join-Path $PSScriptRoot 'historical-state-oracle.cjs'),$c.decimal_parser_sha),@($c.node,$c.node_sha),@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha))){Assert-OwnedHash $pair[0] $pair[1]}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$oldManifest=Get-Content -LiteralPath ($original+'.manifest.json') -Raw|ConvertFrom-Json
if($oldManifest.database -cne 'pi_restore_s9_c2_c18app01' -or $oldManifest.size -ne 7943113 -or $oldManifest.sha256.ToUpperInvariant() -cne $inputSha -or !$oldManifest.includes_auth){throw 'boundary_real_input_manifest'}
$registry=Get-Content -LiteralPath $c.boundary_registry -Raw|ConvertFrom-Json
if(@($registry.allowed_parse_sha).Count -ne 36 -or @($registry.allowed_simple).Count -ne 9 -or $registry.observer_sha256 -cne $observerSha.ToLowerInvariant() -or $registry.startup.application_name -cne 'pi_cleanup_offline'){throw 'boundary_exact_registry_shape'}
foreach($source in $registry.sources){Assert-OwnedHash (Join-Path $workspace $source.path) $source.sha256}
$optionsSha=$registry.startup.options_sha
if($optionsSha -cne '3bfb6a81e5fe839828ae73660c0d14aa7d83ac7833a5109ff466920eed46cf92'){throw 'boundary_unchanged_production_options'}
if($c.boundary_mode -cne 'observe-delete'){
 foreach($review in @(@{role='QA';pin=$c.observe_qa_review},@{role='TD';pin=$c.observe_td_review})){
  Assert-OwnedHash $review.pin.path $review.pin.sha256;$r=Get-Content -LiteralPath $review.pin.path -Raw|ConvertFrom-Json
  if($r.author_role -cne $review.role -or $r.verdict -cne 'CURRENT_FULL_C2_BOUNDARY_OBSERVE_NATIVE0_RECEIPT_POST_VERIFIED' -or $r.package_sha256.ToUpperInvariant() -cne $c.package_sha.ToUpperInvariant() -or $r.observer_sha256.ToUpperInvariant() -cne $observerSha -or $r.registry_sha256.ToUpperInvariant() -cne $registrySha -or $r.archive_sha256.ToUpperInvariant() -cne $inputSha){throw 'boundary_actual_observe_first_required'}
 }
}
$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out;$install=Get-OwnedCanonicalPath $c.install_parent
if($out -ceq $install -or $out.StartsWith($install.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $install.StartsWith($out.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'boundary_separate_install_output'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($deadline -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or $started -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'boundary_capacity_freeze'}
if($c.capture_reservation_bytes -ne 4000000000L -or $c.phase_reservation_bytes -gt 6GB){throw 'boundary_capture_reservation_unchanged'}
# This phase never adopts caps by configuration: the pinned helper must validate
# the actual Council decision and independently reviewed FULL uncompressed peak.
# A future helper/decision needs new exact source/config review before admission.
$resourceBudget=New-S13PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S13PhaseBudget -Proof $resourceBudget -Next $Next}
Budget
if(@(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object LocalPort -in @(5465,5467,3097)).Count){throw 'boundary_new_ports_must_be_absent'}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $install $c.manifest_sha
$manifest=Get-Content -LiteralPath (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($manifest.version -cne '0.7.3' -or $manifest.source_commit -cne $c.source_commit){throw 'boundary_current_candidate'}
$exe=Join-Path $pkg 'process-intelligence-rs.exe';$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
Assert-OwnedHash $exe $c.app_sha;Assert-OwnedHash $psql $c.psql_sha;Assert-OwnedHash $backup $c.backup_sha
$service=$null;$observer=$null;$command=$null;$observerCompleted=$false;$commandCompleted=$false;$secret=$null;$admin=$null;$envApply=$null
function CompleteNative($n){return ($n.stdout_complete -and $n.stderr_complete -and !$n.output_limit -and !$n.capture_fault -and !$n.drain_timeout)}
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int]$Seconds=120,[long]$Cap=4MB){
 Budget;$p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'boundary_owned_native_stop'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;automatic_retry=$false}
 if($forced -or $r.native_exit -ne 0 -or !(CompleteNative $r)){throw ('boundary_native_failed_'+$Label)};Budget;return $r
}
function Sql([string]$Database,[string]$Label,[string[]]$Arguments,[long]$Cap=16MB,[int]$SqlMs=60000){
 if($Database -cnotin ($names+@('postgres'))){throw 'boundary_sql_new_scope'}
 [string[]]$argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5465','-U','pi_admin','-w','-d',$Database)+$Arguments
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
try{
 $service=Start-OwnedStockService $c $pkg 'boundary-stock';[void](Wait-OwnedStockService $service)
 $apps=@($service.Processes|Where-Object Name -ceq 'app');if($apps.Count -ne 1 -or !$service.Job.Member($apps[0].Handle)){throw 'boundary_owned_app_identity'}
 $held=$apps[0];$actual=Get-CimInstance Win32_Process -Filter ('ProcessId='+$held.Process.Id)
 if(!$actual -or $held.Process.HasExited -or $actual.ExecutablePath -cne $exe -or $held.Process.StartTime.ToUniversalTime().ToString('o') -cne $held.Creation){throw 'boundary_owned_app_stale'}
 $held.Process.Kill();if(!$held.Process.WaitForExit(10000) -or @(Get-NetTCPConnection -State Listen -LocalPort 3097 -ErrorAction SilentlyContinue).Count){throw 'boundary_app_not_offline'}
 Write-OwnedJson (Join-Path $out 'app-offline.json') @{pid=$held.Process.Id;creation=$held.Creation;native_exit=$held.Process.ExitCode;controlled_forced_stop=$true;no_clean_app_exit_claim=$true}
 $secret=Get-Content -LiteralPath (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5465){throw 'boundary_private_port'}
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
 $direct="host=127.0.0.1 port=5465 user=pi_admin password=$($secret.admin_password) dbname=$($c.source_db) connect_timeout=5"
 $restoreUrl="host=127.0.0.1 port=5465 user=pi_admin password=$($secret.admin_password) dbname=$($c.restore_db) connect_timeout=5"
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
 Write-OwnedJson $observerConfig @{mode=$c.boundary_mode;backend_port=5465;listen_port=5467;database=$c.source_db;options_sha=$optionsSha;plan_sha=(Get-OwnedHash $plan).ToLowerInvariant();plan_path=$plan;target_key_sha=$c.target_key_sha;evidence_path=$events;allowed_parse_sha=@($registry.allowed_parse_sha);allowed_simple=@($registry.allowed_simple);control_path=$control;control_nonce=$nonce}
 [string[]]$observerArgs=@($c.boundary_observer)
 $observer=Start-OwnedCapturedProcess -Program $c.node -ProgramSha256 $c.node_sha -Arguments $observerArgs -WorkingDirectory $pkg -OutputDirectory $out -Label 'boundary-observer' -MaxOutputBytes 1MB -Environment @{PI_FULL_OBSERVER_CONFIG=$observerConfig}
 $readyEnd=[DateTime]::UtcNow.AddSeconds(10)
 do{$trace=@(Trace);if(@($trace|Where-Object kind -ceq 'listener_ready').Count -eq 1){break};if($observer.Process.HasExited -or [DateTime]::UtcNow -ge $readyEnd){throw 'boundary_proxy_not_ready'};Start-Sleep -Milliseconds 50}while($true)
 $listeners=@(Get-NetTCPConnection -LocalPort 5467 -State Listen -ErrorAction Stop)
 if(@($listeners.OwningProcess|Select-Object -Unique).Count -ne 1 -or $listeners[0].OwningProcess -ne $observer.Process.Id -or @($listeners|Where-Object LocalAddress -notin @('127.0.0.1','::1')).Count){throw 'boundary_proxy_actual_listener'}
 $nodeCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$observer.Process.Id);$pg=@($service.Processes|Where-Object Name -ceq 'postgres');if($pg.Count -ne 1){throw 'boundary_stock_pg_retained'}
 $pgCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id)
 if(!$nodeCim -or $nodeCim.ExecutablePath -cne $c.node -or $observer.Process.HasExited -or $observer.Process.StartTime.ToUniversalTime().ToString('o') -cne $observer.Record.native_creation_utc -or !$pgCim -or $pg[0].Process.HasExited -or $pgCim.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe')){throw 'boundary_actual_node_pg_identity'}
 Write-OwnedJson (Join-Path $out 'boundary-proxy-identity.json') @{node_pid=$observer.Process.Id;node_native_creation_utc=$observer.Record.native_creation_utc;node_cim_creation_utc=$nodeCim.CreationDate.ToUniversalTime().ToString('o');node_image=$nodeCim.ExecutablePath;node_sha256=$c.node_sha;port=5467;listener_addresses=@($listeners.LocalAddress);postgres_pid=$pg[0].Process.Id;postgres_cim_creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o');postgres_image=$pgCim.ExecutablePath;scope='Fresh actual retained PID/nativecreation plus CIMimage/creation and exactloopback5467 before outerJob membership request'}
 # Exactly ONE outer membership request, only now both retained processes exist.
 Wait-OwnedReadyJob @(@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o')},@{name='observer';pid=$observer.Process.Id;creation_utc=$nodeCim.CreationDate.ToUniversalTime().ToString('o')}) $out
 $envApply=@{PI_DATABASE_URL="host=127.0.0.1 port=5467 user=pi_admin password=$($secret.admin_password) dbname=$($c.source_db) connect_timeout=5";PI_CLEANUP_RESTORE_URL=$restoreUrl;PI_CLEANUP_ARCHIVE=$archive;PI_CLEANUP_PLAN=$plan;PI_CLEANUP_CONFIRM_SHA=(Get-OwnedHash $plan);PI_CLEANUP_RECEIPT=$receipt}
 $command=Start-OwnedCapturedProcess -Program $exe -ProgramSha256 $c.app_sha -Arguments @('--cleanup-storage-apply') -WorkingDirectory $pkg -OutputDirectory $out -Label 'boundary-apply' -MaxOutputBytes 1MB -Environment $envApply
 $until=[DateTime]::UtcNow.AddSeconds(300);$forced=$false;$controlSent=$false
 while(!$command.Process.WaitForExit(50)){
  if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or $command.OutCapture.LimitReached -or $command.ErrCapture.LimitReached -or $command.OutCapture.Pump.IsFaulted -or $command.ErrCapture.Pump.IsFaulted){$forced=$true;$command.Process.Kill($true);if(!$command.Process.WaitForExit(10000)){throw 'boundary_apply_owned_stop'};break}
  if($c.boundary_mode -ceq 'f01' -and !$controlSent){
   $heldFrames=@(Trace|Where-Object {$_.kind -ceq 'original_frame_held_before_backend_forward' -and $_.held_kind -ceq 'delete_execute'})
   if($heldFrames.Count -gt 1){throw 'boundary_f01_multiple_held_frames'}
   if($heldFrames.Count -eq 1){
    $f=$heldFrames[0];if($f.actual_ready_status -cne 'T' -or $f.backend_pid -le 0 -or $f.frame_sha -cnotmatch '^[a-f0-9]{64}$' -or $f.backend_bytes_forwarded -ne 0){throw 'boundary_f01_held_binding'}
    $wsql="SELECT jsonb_build_object('pid',a.pid,'database',a.datname,'username',a.usename,'application_name',a.application_name,'state',a.state,'xact_start',a.xact_start,'backend_start',a.backend_start,'locks',(SELECT jsonb_agg(c.relname ORDER BY c.relname) FROM pg_locks l JOIN pg_class c ON c.oid=l.relation JOIN pg_namespace n ON n.oid=c.relnamespace WHERE l.pid=a.pid AND l.database=(SELECT oid FROM pg_database WHERE datname=current_database()) AND n.nspname='public' AND c.relname IN ('pi_kv','pi_migration_v2','pi_projects','pi_records','pi_schema_migrations') AND l.mode='ShareRowExclusiveLock' AND l.granted)) FROM pg_stat_activity a WHERE a.pid="+[string][int]$f.backend_pid+" AND a.datname=current_database();"
    [void](Sql -Database $c.source_db -Label 'f01-actual-lock-witness' -Arguments @('-c',$wsql) -Cap 1MB -SqlMs 2000)
    $w=Get-Content -LiteralPath (Join-Path $out 'f01-actual-lock-witness.stdout') -Raw|ConvertFrom-Json
    if(!$w -or $w.pid -ne $f.backend_pid -or $w.database -cne $c.source_db -or $w.username -cne 'pi_admin' -or $w.application_name -cne 'pi_cleanup_offline' -or $w.state -cne 'idle in transaction' -or !$w.xact_start -or !$w.backend_start -or (@($w.locks)-join ',') -cne 'pi_kv,pi_migration_v2,pi_projects,pi_records,pi_schema_migrations'){throw 'boundary_f01_granted_all5_transaction_not_proven'}
    Write-OwnedJson (Join-Path $out 'f01-external-bound-witness.json') @{held=$f;native_query='f01-actual-lock-witness.process.json';actual_backend=$w;control_nonce=$nonce;scope='Actual heldoriginalExecute plus samebackend transaction and all5 granted source ShareRowExclusiveLocks BEFOREdrop; no DELETE injected'}
    Write-OwnedJson $control @{command='drop';nonce=$nonce;backend_pid=$f.backend_pid;frame_sha=$f.frame_sha};$controlSent=$true
   }
  }
 }
 $native=Complete-OwnedCapturedProcess $command;$commandCompleted=$true
 $observerForced=!$observer.Process.WaitForExit(10000);if($observerForced){$observer.Process.Kill($true);if(!$observer.Process.WaitForExit(10000)){throw 'boundary_observer_owned_stop'}}
 $observerNative=Complete-OwnedCapturedProcess $observer;$observerCompleted=$true;$trace=@(Trace)
 Write-OwnedJson (Join-Path $out 'boundary-native-completion.json') @{apply=$native;observer=$observerNative;apply_forced=$forced;observer_forced=$observerForced}
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
 if($c.boundary_mode -ceq 'observe-delete'){
  $passed=$native.native_exit -eq 0 -and $outcome.outcome -ceq 'cleanup_committed' -and $outcome.deleted_rows -eq 10 -and $classification -ceq 'EXPECTED_POST' -and $deleteProof -and @($trace|Where-Object kind -ceq 'actual_final_commit_complete').Count -eq 1
  if($passed){[string[]]$receiptArgs=@($c.receipt_oracle,$plan,$receipt,(Join-Path $out 'boundary-apply.stdout'),(Join-Path $out 'source-identity-receipt.json'),(Join-Path $out 'restore-identity-receipt.json'),$archive);[void](Native -Label 'receipt-full-contract' -Program $c.node -Sha $c.node_sha -Arguments $receiptArgs -Seconds 60 -Cap 1MB);$rp=Get-Content -LiteralPath (Join-Path $out 'receipt-full-contract.stdout') -Raw|ConvertFrom-Json;$passed=$rp.status -ceq 'COMMITTED_RECEIPT_FULL_CONTRACT_BOUND'}
 }elseif($c.boundary_mode -ceq 'f02'){$passed=$native.native_exit -eq 2 -and $outcome.outcome -ceq 'cleanup_outcome_unconfirmed' -and $outcome.automatic_retry -eq $false -and $classification -ceq 'COMPLETE_PRE' -and $deleteProof -and $stops[0].reason -ceq 'f02_before_commit_connection_drop' -and @($trace|Where-Object kind -ceq 'f02_original_commit_never_forwarded').Count -eq 1 -and !(Test-Path -LiteralPath $receipt)}
 elseif($c.boundary_mode -ceq 'f03'){$passed=$native.native_exit -eq 2 -and $outcome.outcome -ceq 'cleanup_outcome_unconfirmed' -and $outcome.automatic_retry -eq $false -and $classification -ceq 'EXPECTED_POST' -and $deleteProof -and $stops[0].reason -ceq 'f03_after_commit_ack_connection_drop' -and @($trace|Where-Object kind -ceq 'f03_actual_server_commit_ack_withheld').Count -eq 1 -and @($trace|Where-Object {$_.kind -ceq 'actual_complete_server_commit_frame_held' -and $_.client_bytes_forwarded -eq 0}).Count -eq 1 -and !(Test-Path -LiteralPath $receipt)}
 else{
  $passed=$native.native_exit -eq 1 -and $outcome.outcome -ceq 'cleanup_refused' -and $outcome.code -ceq 'cleanup_storage_unavailable' -and $classification -ceq 'COMPLETE_PRE' -and $deleted.Count -eq 0 -and $pairs.Count -eq 0 -and !(Test-Path -LiteralPath $receipt)
  if($c.boundary_mode -ceq 'f01'){$passed=$passed -and $controlSent -and $stops[0].reason -ceq 'f01_before_delete_connection_drop' -and @($trace|Where-Object kind -ceq 'f01_original_delete_never_forwarded').Count -eq 1}
  else{$tx=@($trace|Where-Object {$_.kind -ceq 'boundary_server_error_no_fault_credit' -and $_.sqlstate -ceq '25P04' -and $_.actual_transaction_timeout -and $_.target_execution -and $_.original_delete_held});$passed=$passed -and $stops[0].reason -ceq 'actual_server_transaction_timeout_before_delete' -and $tx.Count -eq 1}
 }
 $passed=$common -and $passed
 if($c.boundary_mode -cin @('f01','tx10')){$passed=$passed -and $stops[0].held_original_kind -ceq 'delete_execute' -and $stops[0].delete_execute_forwarded -eq $false}
 Write-OwnedJson (Join-Path $out 'full-boundary-result.json') @{status=$(if($passed){'CURRENT_FULL_C2_BOUNDARY_EVIDENCE_PENDING_QA_TD'}else{'FAILED_RETAINED'});mode=$c.boundary_mode;native=$native;observer_native=$observerNative;source_classification=$classification;source_after=$sourceAfter;restore_after=$restoreAfter;catalog_pre=$catalogPre;catalog_after=$catalogAfter;restore_catalog_pre=$restoreCatalogPre;restore_catalog_after=$restoreCatalogAfter;outcome=$outcome;source_backend_gone=$gone;control_sent=$controlSent;automatic_retry=$false;no_compression_assumed=$true;limits=@('Full new current0.7.3 native run only, no old EXE/proof transfer','Actual fullstate classification independent of CLI acknowledgement; no inferred rollback/commit fromexit','tx10 exact25P04 with unchanged production10s; held-frame elapsed is NOT entiretransaction duration proof','lock2/SQL5/C18HTTP and other corpus cases NOT EXECUTED here','No physical shrink or whole R3/release acceptance')}
 if(!$passed){throw 'boundary_failed_retained_no_retry'}
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256};Assert-OwnedHash $c.boundary_registry $registrySha;Assert-OwnedHash $c.boundary_observer $observerSha;Test-OwnedPackageTree $pkg $c.manifest_sha $true;Budget
}finally{
 try{
 foreach($item in @(@{name='apply';child=$command;completed=$commandCompleted},@{name='observer';child=$observer;completed=$observerCompleted})){
  if($item.child -and !$item.completed){$p=$item.child.Process;$wasAlive=!$p.HasExited;if($wasAlive){$p.Kill($true)};if(!$p.WaitForExit(10000)){throw 'boundary_final_owned_child_stop'};$n=Complete-OwnedCapturedProcess $item.child;Write-OwnedJson (Join-Path $out ($item.name+'-finally-stop.json')) @{native=$n;forced=$wasAlive;successful_boundary_claim=$false}}
 }
 }finally{
 $secret=$null;$admin=$null;$envApply=$null
 if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'}
 }
}

<#
UNEXECUTED SOURCE DRAFT. New current0.7.3 package/EXE/manifest and all helper/runtime
pins required; outer waitingworkerJob beforeGO. Modes onlyobserve/f01/f02/f03/tx10,
each NEW install/output/source/restore pair; no lock2/SQL5 permission here.
Real immutableC2archive3A0E+manifestBD4B copiedUNCHANGED into newprivatepackage;
stockrestore NEWsource -> truthfulsourcebackup/newmanifest -> NEWverification.
FullPRE9959/614304123 both + current config-pinnedlogicalcatalog (latest312137)
before currentVerify10; newactualplan drives independenttenKV POST4F30/307159782.
RegistryD587 exact36Parse/9Simple arrays DIRECT, sources[].sha256; startuphash3bfb
unchanged5sSQL/2slock/10sTX. Observer6F0E nativeNode5467 actualPID/CIMcreation/image/
listener then exactlyONE outerReadyJob witness BOTHPGCIM+Node. No earlier outer
request from this phase; stockinnerPGJob identity already checked by service.
F01 originalExecute held, actualsamebackendidleTX +ALL5 grantedShareRowExclusive
locks nativewitness BEFORE exactnonce/PID/frameSHA dropcontrol. Never injectSQL.
Native1 cleanup_storage_unavailable forF01/tx10; native2unconfirmedfalseRetry for
F02/03; native0+receiptfullcontract forObserve. Actualobserver0/fullEOF/nonforced
mandatory. BackendPIDgone observedBEFORE fullPOST/PRE and catalogconservation;
F01/F02/tx10 fullPRE,Observe/F03 fullPOST. No outcomeinference fromexit alone.
PerApply300s/wholephase1800s/runtimefreeze; initialfree8/floor4 unchanged. Capture
reservation EXACT4e9/fullphase<=6GiB; no corpus/capture reductions. Before package
creation and PGstart, dynamically config-pinned resource-phase-budget helper must
perform actual fresh allfile native baseline, validate actual adopted Council
decision/all5authoredFOR and Root/QA/TD exact full UNCOMPRESSED peak reservations.
No future40GiB allocation proposal is adopted by this source. A changed helper
requires new exact source/config review; no permissive config cap override.
Phase logical/allocation/DBWAL/temp/extract/archive and rounding reserves bind
phase_budget reviews. Each State reserves its full1GiB NEXT (catalog16MiB) before
capture. ActivePG checks use actual logical+NEXT and baseline+FULLphase conservative
allocation bound, not fresh activePG physical meter or guessed compression ratio.
If retainedbaseline+reserve cannotfit STOP. Fullfailed
streams retained; finally bounded ownedchildren teardown explicitlyforcedifneeded
and retainedstockPGfaststop actualexit0 required, no globalprocess kill.
Config fields mirror S13fullcleanup plus boundary_mode,proxy_port5467,target_key_sha,
boundary_registry,boundary_observer,observe_qa_review/td_review forfaults, exactpins,
phase_allocation_reservation_bytes,phase_budget={module_sha,phase_sha,decision:
{path,sha256},db_wal_temp_extract_archive_bytes,reviews:{Root,QA,TD:{path,sha256}}}.
Exact phaseSHA binds mode/proxy/currentObserve gates; independent reviews must
review actual config and full named reservations. SQL5 remains explicitly OPEN:
this draft does not admit/run its observer or claim57014 evidence. Credentials
privateenv only, no argv/password printing.
#>
