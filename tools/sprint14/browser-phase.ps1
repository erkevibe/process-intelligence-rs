param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY current catalog/Auth lifecycle, retention, restart and wholeDB restore.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'browser_config_preimport'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if($p[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1].ToUpperInvariant()){throw 'browser_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's14-browser-runtime' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5475 -or $c.app_port -ne 3098 -or $c.database -cne 'process_intelligence'){throw 'browser_finite_scope'}
if($c.app_sha -cne '23563DFF8FE93F339AD7F12FD0783AC3E2C53B8D9368C00D772A8FBABBE5F292' -or $c.package_sha -cne 'E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C'){throw 'browser_existing_candidate_only'}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
$names=@('process_intelligence');if($c.restore_db -cne 'process_intelligence'){throw 'browser_default_new_database_only'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
foreach($p in @(@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.node,$c.node_sha),@($c.probe,$c.probe_sha),@($c.capture_sql,$c.capture_sql_sha),@($c.catalog_sql,$c.catalog_sql_sha))){Assert-OwnedHash $p[0] $p[1]}
if((Get-OwnedCanonicalPath $c.probe) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'browser-bootstrap.cjs')) -or (Get-OwnedCanonicalPath $c.capture_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'managed-state.sql')) -or (Get-OwnedCanonicalPath $c.catalog_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'logical-catalog.sql'))){throw 'browser_source_paths'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($c.required_free_bytes -ne 8GB -or $c.runtime_floor_bytes -ne 8GB -or $deadline -gt [DateTimeOffset]::Parse('2026-10-20T09:54:16Z').UtcDateTime -or $started -ge $deadline -or $c.capture_reservation_bytes -ne 512MB -or $c.phase_reservation_bytes -gt 2GB){throw 'browser_resource_freeze'}
if($c.manual_capture_reservation_bytes -ne 32MB -or $c.manual_hold_seconds -isnot [long] -or $c.manual_hold_seconds -lt 1 -or $c.manual_hold_seconds -gt 1200 -or $c.restart_hold_seconds -isnot [long] -or $c.restart_hold_seconds -lt 1 -or $c.restart_hold_seconds -gt 300){throw 'browser_finite_manual_reservation'}
$resource=New-S14PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S14PhaseBudget -Proof $resource -Next $Next}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$m=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($m.version -cne '0.7.3' -or $m.source_commit -cne $c.source_commit){throw 'browser_candidate'}
$app=Join-Path $pkg 'process-intelligence-rs.exe';$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
Assert-OwnedHash $app $c.app_sha;Assert-OwnedHash $psql $c.psql_sha;Assert-OwnedHash $backup $c.backup_sha
$service=$null;$secret=$null;$runtime=$null;$runtimeClosed=$false;$success=$false
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int[]]$Exits=@(0),[int]$Seconds=120,[long]$Cap=8MB){
 Budget $Cap;$p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'browser_child_stop'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;single_invocation=$true}
 if($forced -or $r.native_exit -notin $Exits -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw ('browser_native_'+$Label)};Budget;return $r
}
function Sql([string]$Db,[string]$Label,[string[]]$Arguments,[long]$Cap=8MB){
 if($Db -cnotin ($names+@('postgres'))){throw 'browser_SQL_scope'}
 [string[]]$argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5475','-U','pi_admin','-w','-d',$Db)+$Arguments
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments $argv -Environment @{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c default_transaction_read_only=on -c TimeZone=UTC -c DateStyle=ISO,YMD'} -Cap $Cap
}
function State([string]$Db,[string]$Label,[bool]$Catalog=$false){Budget 8MB;$sql=if($Catalog){$c.catalog_sql}else{$c.capture_sql};$r=Sql $Db $Label @('-f',$sql);return @{path=Join-Path $out ($Label+'.stdout');bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256}}
function EqualState($a,$b){if($a.bytes -ne $b.bytes -or $a.sha256.ToUpperInvariant() -cne $b.sha256.ToUpperInvariant()){throw 'browser_full_state_or_catalog_changed'}}
function Stock([string]$Label,[hashtable]$Fields){[string[]]$argv=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Fields|ConvertTo-Json -Compress));[void](Native -Label $Label -Program $c.pwsh -Sha $c.pwsh_sha -Arguments $argv -Seconds 180)}
function URL([string]$Db,[string]$User='pi_admin'){$pw=if($User -ceq 'pi_app'){$secret.app_password}else{$secret.admin_password};return "host=127.0.0.1 port=5475 user=$User password=$pw dbname=$Db connect_timeout=5 application_name=s14_browser"}
function StopRuntime{
 if(!$runtime -or $runtimeClosed){return};if($runtime.Process.HasExited){throw 'browser_unexpected_app_exit'}
 $again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id)
 if(!$again -or $again.ExecutablePath -cne $app -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation){throw 'browser_retained_app_identity'}
 $runtime.Process.Kill();if(!$runtime.Process.WaitForExit(10000)){throw 'browser_app_stop'};$r=Complete-OwnedCapturedProcess $runtime;$script:runtimeClosed=$true
 Write-OwnedJson (Join-Path $out ($runtimeLabel+'-controlled-stop.json')) @{native=$r;controlled_forced_stop=$true;no_clean_exit_claim=$true}
 if(!$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'browser_app_streams_or_listener'}
}
function StartCatalogRuntime([string]$Db,[string]$Label,$Expected){
 if($Db -cnotin @($c.restore_db) -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'catalog_runtime_new_target_listener'}
 $script:runtimeLabel=$Label;$script:runtimeClosed=$false;Budget 8MB
 $script:runtime=Start-OwnedCapturedProcess -Program $app -ProgramSha256 $c.app_sha -Arguments @() -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes 8MB -Environment @{PI_DATABASE_URL=(URL $Db 'pi_app');PORT='3098';RUST_LOG='info'}
 $script:creation=$runtime.Process.StartTime.ToUniversalTime().ToString('o');$until=[DateTime]::UtcNow.AddSeconds(30)
 do{Budget;if($runtime.Process.HasExited -or [DateTime]::UtcNow -ge $until){throw 'catalog_app_not_ready'};$listeners=@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue);if($listeners.Count){if(@($listeners|Where-Object {$_.OwningProcess -ne $runtime.Process.Id -or $_.LocalAddress -notin @('127.0.0.1','::1')}).Count){throw 'catalog_listener_identity'};break};Start-Sleep -Milliseconds 100}while($true)
 $native=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id);$pgCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id)
 if(!$native -or $native.ExecutablePath -cne $app -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation -or !$pgCim -or $pg[0].Process.HasExited -or $pgCim.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe')){throw 'catalog_actual_native_identity'}
 if(!$script:readyRequested){Wait-OwnedReadyJob @(@{name='app';pid=$runtime.Process.Id;creation_utc=$native.CreationDate.ToUniversalTime().ToString('o')},@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o')}) $out;$script:readyRequested=$true}
 $before=State $Db ($Label+'-before-login');EqualState $Expected $before
 $admission=Join-Path $out ($Label+'-admission.json');Write-OwnedJson $admission @{scope='S14_NEW_BROWSER_RUNTIME';database=$Db;app_port=3098;pg_port=5475;version='0.7.3';app_sha256=$c.app_sha;app_pid=$runtime.Process.Id;native_creation=$creation;cim_creation=$native.CreationDate.ToUniversalTime().ToString('o');outer_first_ready_sha256=Get-OwnedHash (Join-Path $out 'ready-response.json');startup_full_unchanged=$true;job_basis='Initial app+PG actual outer-ready; subsequent retained children inherit same admitted no-breakaway waiting worker Job. No separate direct outer Job.Member claim'}
 return @{before=$before;admission=@{path=$admission;sha256=Get-OwnedHash $admission}}
}
function AssertLive{
 if(!$runtime -or $runtimeClosed -or $runtime.Process.HasExited -or $pg[0].Process.HasExited -or $runtime.OutCapture.LimitReached -or $runtime.ErrCapture.LimitReached -or $runtime.OutCapture.Pump.IsFaulted -or $runtime.ErrCapture.Pump.IsFaulted -or $service.Coordinator.OutCapture.LimitReached -or $service.Coordinator.ErrCapture.LimitReached -or $service.Coordinator.OutCapture.Pump.IsFaulted -or $service.Coordinator.ErrCapture.Pump.IsFaulted){throw 'browser_owned_runtime_not_live'}
 Budget
}
function ManualBytes{
 [long]$sum=0;$files=@(Get-ChildItem -LiteralPath $manual -Force);if($files.Count -gt 256){throw 'browser_manual_file_count'};foreach($f in $files){Assert-OwnedNoReparse $f.FullName;$relative=[IO.Path]::GetRelativePath($manual,$f.FullName);if($f.PSIsContainer -or $relative -cnotmatch '^[a-z][a-z0-9-]{0,63}\.(json|png|webp|jpg)$' -or $f.Length -gt 8MB){throw 'browser_manual_artifact_bound'};$sum+=$f.Length};if($sum -gt 32MB){throw 'browser_manual_whole32MiB_cap'};return $sum
}
function WaitBrowser([string]$Kind,[int]$Seconds){
 $file=Join-Path $out ($Kind+'.json');$end=[DateTime]::UtcNow.AddSeconds($Seconds);$control=$null
 while(!$control){AssertLive;[void](ManualBytes);if([DateTime]::UtcNow -ge $end -or [DateTime]::UtcNow -ge $deadline){throw 'browser_manual_deadline_no_completion_claim'};if(Test-Path -LiteralPath $file){Assert-OwnedNoReparse $file;if((Get-Item -LiteralPath $file).Length -gt 4096){throw 'browser_control_bound'};try{$control=Get-Content -LiteralPath $file -Raw|ConvertFrom-Json -AsHashtable -DateKind String}catch{$control=$null}};if(!$control){Start-Sleep -Milliseconds 100}}
 if($control.author_role -cne 'Root' -or $control.kind -cne $Kind -or $control.nonce -cne $nonce -or (@($control.Keys|Sort-Object)-join ',') -cne 'author_role,journal,kind,nonce'){throw 'browser_control_exact_binding'}
 $journal=Get-OwnedCanonicalPath $control.journal.path;$rel=[IO.Path]::GetRelativePath($manual,$journal);if($rel -cnotmatch '^[a-z][a-z0-9-]{0,63}\.json$'){throw 'browser_journal_literal_private_scope'};Assert-OwnedNoReparse $journal;Assert-OwnedHash $journal $control.journal.sha256
 if((Get-Item $journal).Length -gt 8MB){throw 'browser_journal_bound'};$j=Get-Content $journal -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if($j.author_role -cne 'Root' -or $j.control_nonce -cne $nonce -or $j.stage -cne $Kind -or $j.completed -isnot [bool] -or !$j.completed -or !$j.steps -or @($j.steps).Count -gt 128){throw 'browser_manual_journal_required'}
 # This proves only retained Root-authored finite journal bytes, never UI success
 # or exact Auth replay. Independent CUA records/screens and QA/TD remain required.
 return @{control_path=$file;control_sha256=Get-OwnedHash $file;journal=$control.journal;manual_tree_bytes=ManualBytes;independent_auth_oracle_pending=$true}
}
function BackendGone([string]$Label){[void](Sql 'postgres' $Label @('-c',"SELECT count(*) FROM pg_stat_activity WHERE datname='process_intelligence' AND backend_type='client backend';") 1MB);if((Get-Content (Join-Path $out ($Label+'.stdout')) -Raw).Trim() -cne '0'){throw 'browser_app_backend_remains'}}
$script:readyRequested=$false
try{
 $service=Start-OwnedStockService $c $pkg 'browser-stock';[void](Wait-OwnedStockService $service);$boot=@($service.Processes|Where-Object Name -ceq 'app');$pg=@($service.Processes|Where-Object Name -ceq 'postgres');if($boot.Count -ne 1 -or $pg.Count -ne 1 -or !$service.Job.Member($boot[0].Handle)){throw 'browser_stock_native_identity'}
 $boot[0].Process.Kill();if(!$boot[0].Process.WaitForExit(10000)){throw 'browser_initial_stock_app_stop'};Write-OwnedJson (Join-Path $out 'initial-stock-app-stop.json') @{native_exit=$boot[0].Process.ExitCode;controlled_forced_stop=$true;no_clean_exit_claim=$true}
 if(@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'browser_initial_listener_remains'};$secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5475){throw 'browser_private_port'}
 $empty=State 'process_intelligence' 'new-empty-before-app';$first=StartCatalogRuntime 'process_intelligence' 'browser-app' $empty
 $cfg=Join-Path $out 'bootstrap-config.json';Write-OwnedJson $cfg @{scope='s14-fresh-browser-bootstrap';database='process_intelligence';app_port=3098;pg_port=5475;output_directory=$out;deadline_utc=$c.deadline_utc;http_client_sha=$c.http_client_sha;runtime_admission=$first.admission}
 [void](Native -Label 'browser-bootstrap' -Program $c.node -Sha $c.node_sha -Arguments @($c.probe,$cfg) -Environment @{PI_BROWSER_BOOTSTRAP_CONFIG_SHA=(Get-OwnedHash $cfg).ToLowerInvariant()} -Seconds 200 -Cap 1MB)
 $bootstrap=Get-Content (Join-Path $out 'bootstrap-result.json') -Raw|ConvertFrom-Json;if($bootstrap.status -cne 'FRESH_PUBLIC_SYNTHETIC_BROWSER_FIXTURE_BOOTSTRAPPED_PENDING_ROOT_QA_TD' -or !$bootstrap.owner_logged_out -or @($bootstrap.project_payloads).Count -ne 2){throw 'browser_bootstrap_required'}
 $pre=State 'process_intelligence' 'browser-managed-pre';$catalogPre=State 'process_intelligence' 'browser-catalog-pre' $true
 $manual=Join-Path $out 'manual-root';[void](New-OwnedPrivateDirectory $manual);$nonce=[Guid]::NewGuid().ToString('N');Budget 32MB
 Write-OwnedJson (Join-Path $out 'browser-ready.json') @{scope='S14_NEW_MANUAL_BROWSER_FIXTURE_ONLY';control_nonce=$nonce;url='http://127.0.0.1:3098/projects';app_pid=$runtime.Process.Id;app_creation=$creation;database='process_intelligence';pg_pid=$pg[0].Process.Id;bootstrap=$bootstrap;whole_managed_pre=$pre;catalog_pre=$catalogPre;manual_directory=$manual;expected_finish='browser-finished';hold_seconds=$c.manual_hold_seconds;public_synthetic_credential_in_source_only=$true;no_automated_HTTP_during_manual=$true;independent_UI_and_Auth_acceptance_required=$true}
 $manualFirst=WaitBrowser 'browser-finished' $c.manual_hold_seconds;StopRuntime;BackendGone 'browser-backends-gone';$post=State 'process_intelligence' 'browser-managed-post';$catalogPost=State 'process_intelligence' 'browser-catalog-post' $true;EqualState $catalogPre $catalogPost
 $restart=StartCatalogRuntime 'process_intelligence' 'browser-restart-app' $post
 Write-OwnedJson (Join-Path $out 'browser-restart-ready.json') @{scope='S14_SAME_DB_BROWSER_RESTART_GET_ONLY';control_nonce=$nonce;url='http://127.0.0.1:3098/projects';app_pid=$runtime.Process.Id;app_creation=$creation;before_login=$restart.before;whole_managed_post=$post;startup_full_equal=$true;expected_finish='browser-restart-finished';instruction='Root reloads GET/projects using existing Editor browser session only; no login/logout/mutation'}
 $manualRestart=WaitBrowser 'browser-restart-finished' $c.restart_hold_seconds;StopRuntime;BackendGone 'browser-restart-backends-gone';$restartAfter=State 'process_intelligence' 'browser-restart-managed-after';EqualState $post $restartAfter;$restartCatalog=State 'process_intelligence' 'browser-restart-catalog-after' $true;EqualState $catalogPost $restartCatalog
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256};Budget
 Write-OwnedJson (Join-Path $out 'browser-phase-result.json') @{status='MANUAL_BROWSER_JOURNALS_AND_FULL_STATE_RETAINED_PENDING_ROOT_QA_TD';bootstrap=$bootstrap;managed_pre=$pre;managed_post=$post;restart_before=$restart.before;restart_after=$restartAfter;manual=$manualFirst;manual_restart=$manualRestart;no_automated_mutations_during_manual=$true;restart_full_state_equal=$true;catalog_equal=$true;limits=@('Root-authored control/journal is not independent browser proof or Auth oracle','All manual Owner/Viewer/Editor actions, stale CAS and visible/hidden controls need actual CUA/screenshots and independent fullAuth replay','Restart same-session GET equality is actual fullmanaged comparison, not login/reset','Fresh synthetic only, no historical/server/browser release acceptance')};$success=$true
}finally{try{if($runtime -and !$runtimeClosed){StopRuntime}}finally{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'};$secret=$null}}
if(!$success){throw 'browser_phase_incomplete_retained'}
Write-OwnedJson (Join-Path $out 'closed-phase-budget.json') (Get-S14ClosedPhaseBudgetTotals $resource)
# SOURCE ONLY. No CUA/browser/runtime executed by drafting this source.
