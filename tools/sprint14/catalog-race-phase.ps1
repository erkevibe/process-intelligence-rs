param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY current catalog/Auth lifecycle, retention, restart and wholeDB restore.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'catalog_race_config_preimport'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if($p[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1].ToUpperInvariant()){throw 'catalog_race_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's14-catalog-race-runtime' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5475 -or $c.app_port -ne 3098 -or $c.database -cne 'process_intelligence'){throw 'catalog_race_finite_scope'}
if($c.app_sha -cne '23563DFF8FE93F339AD7F12FD0783AC3E2C53B8D9368C00D772A8FBABBE5F292' -or $c.package_sha -cne 'E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C'){throw 'catalog_race_existing_candidate_only'}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
$names=@($c.source_db,$c.restore_db,$c.verify_db)
foreach($db in $names){if($db -cnotmatch '^pi_restore_s14_[a-z0-9_]{1,35}$'){throw 'catalog_race_new_database'}}
if(@($names|Select-Object -Unique).Count -ne 3){throw 'catalog_race_distinct_databases'}
$credentialPath=Get-OwnedCanonicalPath (Join-Path $workspace '.local/sprint13/root/small-seed02/small-credentials-private.json')
if((Get-OwnedCanonicalPath $c.credentials.path) -cne $credentialPath){throw 'catalog_race_exact_credentials_input'}
Assert-OwnedNoReparse $credentialPath;Assert-OwnedHash $credentialPath $c.credentials.sha256
# Closed S13 credentials are a read-only exception, not S14 runtime resources.
$acl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new((Split-Path -Parent $credentialPath)));$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;$rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value -or !$acl.AreAccessRulesProtected -or $rules.Count -ne 1 -or $rules[0].IdentityReference.Value -cne $sid.Value -or $rules[0].AccessControlType -ne 'Allow' -or $rules[0].FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or (Get-Item $credentialPath).Length -gt 64KB){throw 'catalog_race_closed_credentials_ACL'}
if($c.small_archive_sha -cne 'A18E0BF2E061B350B0918D9116BBC4F7C0E46EE8F28FDF0C7FA342BA725A030C' -or $c.small_manifest_sha -cne '0F21A1FBDBFACCF03C7C666ABF977B0605A6EA7704BDE1D3D1A5EF52846EDACA'){throw 'catalog_race_exact_seed02'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
foreach($p in @(@($c.small_archive,$c.small_archive_sha),@(($c.small_archive+'.manifest.json'),$c.small_manifest_sha),@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.node,$c.node_sha),@($c.probe,$c.probe_sha),@($c.capture_sql,$c.capture_sql_sha),@($c.catalog_sql,$c.catalog_sql_sha))){Assert-OwnedHash $p[0] $p[1]}
if((Get-OwnedCanonicalPath $c.probe) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'catalog-race-probe.cjs')) -or (Get-OwnedCanonicalPath $c.capture_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'managed-state.sql')) -or (Get-OwnedCanonicalPath $c.catalog_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'logical-catalog.sql'))){throw 'catalog_race_source_paths'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($c.required_free_bytes -ne 8GB -or $c.runtime_floor_bytes -ne 8GB -or $deadline -gt [DateTimeOffset]::Parse('2026-10-20T09:54:16Z').UtcDateTime -or $started -ge $deadline -or $c.capture_reservation_bytes -ne 512MB -or $c.hot_capture_reservation_bytes -ne 32MB -or $c.phase_reservation_bytes -gt 2GB){throw 'catalog_race_resource_freeze'}
$resource=New-S14PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S14PhaseBudget -Proof $resource -Next $Next}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$m=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($m.version -cne '0.7.3' -or $m.source_commit -cne $c.source_commit){throw 'catalog_race_candidate'}
$app=Join-Path $pkg 'process-intelligence-rs.exe';$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
Assert-OwnedHash $app $c.app_sha;Assert-OwnedHash $psql $c.psql_sha;Assert-OwnedHash $backup $c.backup_sha
$service=$null;$secret=$null;$runtime=$null;$runtimeClosed=$false;$success=$false
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int[]]$Exits=@(0),[int]$Seconds=120,[long]$Cap=8MB){
 Budget $Cap;$p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'catalog_race_child_stop'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;single_invocation=$true}
 if($forced -or $r.native_exit -notin $Exits -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw ('catalog_race_native_'+$Label)};Budget;return $r
}
function Sql([string]$Db,[string]$Label,[string[]]$Arguments,[long]$Cap=8MB){
 if($Db -cnotin ($names+@('postgres'))){throw 'catalog_race_SQL_scope'}
 [string[]]$argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5475','-U','pi_admin','-w','-d',$Db)+$Arguments
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments $argv -Environment @{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c default_transaction_read_only=on -c TimeZone=UTC -c DateStyle=ISO,YMD'} -Cap $Cap
}
function State([string]$Db,[string]$Label,[bool]$Catalog=$false){Budget 8MB;$sql=if($Catalog){$c.catalog_sql}else{$c.capture_sql};$r=Sql $Db $Label @('-f',$sql);return @{path=Join-Path $out ($Label+'.stdout');bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256}}
function EqualState($a,$b){if($a.bytes -ne $b.bytes -or $a.sha256.ToUpperInvariant() -cne $b.sha256.ToUpperInvariant()){throw 'catalog_race_full_state_or_catalog_changed'}}
function Stock([string]$Label,[hashtable]$Fields){[string[]]$argv=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Fields|ConvertTo-Json -Compress));[void](Native -Label $Label -Program $c.pwsh -Sha $c.pwsh_sha -Arguments $argv -Seconds 180)}
function URL([string]$Db,[string]$User='pi_admin'){$pw=if($User -ceq 'pi_app'){$secret.app_password}else{$secret.admin_password};return "host=127.0.0.1 port=5475 user=$User password=$pw dbname=$Db connect_timeout=5 application_name=s14_catalog_race"}
function StopRuntime{
 if(!$runtime -or $runtimeClosed){return};if($runtime.Process.HasExited){throw 'catalog_race_unexpected_app_exit'}
 $again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id)
 if(!$again -or $again.ExecutablePath -cne $app -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation){throw 'catalog_race_retained_app_identity'}
 $runtime.Process.Kill();if(!$runtime.Process.WaitForExit(10000)){throw 'catalog_race_app_stop'};$r=Complete-OwnedCapturedProcess $runtime;$script:runtimeClosed=$true
 Write-OwnedJson (Join-Path $out ($runtimeLabel+'-controlled-stop.json')) @{native=$r;controlled_forced_stop=$true;no_clean_exit_claim=$true}
 if(!$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'catalog_race_app_streams_or_listener'}
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
 $admission=Join-Path $out ($Label+'-admission.json');Write-OwnedJson $admission @{scope='S14_NEW_CATALOG_RACE_RUNTIME';database=$Db;app_port=3098;pg_port=5475;version='0.7.3';app_sha256=$c.app_sha;app_pid=$runtime.Process.Id;native_creation=$creation;cim_creation=$native.CreationDate.ToUniversalTime().ToString('o');outer_first_ready_sha256=Get-OwnedHash (Join-Path $out 'ready-response.json');startup_full_unchanged=$true;job_basis='Initial app+PG actual outer-ready; subsequent retained children inherit same admitted no-breakaway waiting worker Job. No separate direct outer Job.Member claim'}
 return @{before=$before;admission=@{path=$admission;sha256=Get-OwnedHash $admission}}
}
# All slow ownership/socket/SQL preparation occurs before the first blocked HTTP.
# The reviewed32MiB hot reserve is charged once before GO; no recursive Budget scans
# occur until the row-lock holder has been cancelled. Product5/2/10 remain unchanged.
function WaitSignal([string]$Name,[int]$Millis=20000){
 $p=Join-Path $out ($Name+'.json');$end=[DateTime]::UtcNow.AddMilliseconds($Millis)
 while(!(Test-Path -LiteralPath $p)){if($probeChild.Process.HasExited -or [DateTime]::UtcNow -ge $end -or [DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB -or $probeChild.OutCapture.LimitReached -or $probeChild.ErrCapture.LimitReached -or $probeChild.OutCapture.Pump.IsFaulted -or $probeChild.ErrCapture.Pump.IsFaulted){throw 'catalog_race_signal_missing'};Start-Sleep -Milliseconds 5}
 Assert-OwnedNoReparse $p;if((Get-Item -LiteralPath $p).Length -gt 4096){throw 'catalog_race_control_cap'};$x=Get-Content -LiteralPath $p -Raw|ConvertFrom-Json -DateKind String
 if($x.nonce -cne $nonce -or $x.kind -cne $Name){throw 'catalog_race_control_binding'};return $x
}
function SendControl([string]$Name){Write-OwnedJson (Join-Path $out ($Name+'.json')) @{kind=$Name;nonce=$nonce}}
function HotSql([string]$Label,[string]$Query){
 # Exclusive finite two-command hot path; no whole-directory measurement here.
 if($Label -cnotin @('cas-waiter','cas-cancel','demotion-waiter','demotion-cancel') -or !$script:hotCommands.Add($Label) -or [DateTime]::UtcNow -ge $hotEnd -or [DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'catalog_race_hot_scope_or_deadline'}
 $p=Start-OwnedCapturedProcess -Program $psql -ProgramSha256 $c.psql_sha -Arguments @('-X','-qAt','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5475','-U','pi_admin','-w','-d',$c.restore_db,'-c',$Query) -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes 32KB -Environment @{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=400 -c lock_timeout=200 -c transaction_timeout=800 -c default_transaction_read_only=on -c TimeZone=UTC'}
 while(!$p.Process.WaitForExit(5)){if([DateTime]::UtcNow -ge $hotEnd -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$p.Process.Kill();[void]$p.Process.WaitForExit(1000);throw 'catalog_race_hot_native_failure_retained'}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) $r
 if($r.native_exit -ne 0 -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw 'catalog_race_hot_native_incomplete'}
 return (Get-Content -LiteralPath (Join-Path $out ($Label+'.stdout')) -Raw).Trim()
}
function PrepareHolder([string]$Tag){
 Budget 32MB;$script:holderTag=$Tag;$script:holderNonce='s14-race-'+[Guid]::NewGuid().ToString('N');$sql=Join-Path $out ($Tag+'-holder.sql')
 [IO.File]::WriteAllText($sql,"BEGIN;`nSELECT version FROM public.pi_kv WHERE key='auth' FOR UPDATE;`nSELECT pg_sleep(25);`nROLLBACK;`n",[Text.UTF8Encoding]::new($false))
 $script:holder=Start-OwnedCapturedProcess -Program $psql -ProgramSha256 $c.psql_sha -Arguments @('-X','-qAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-h','127.0.0.1','-p','5475','-U','pi_admin','-w','-d',$c.restore_db,'-f',$sql) -WorkingDirectory $pkg -OutputDirectory $out -Label ($Tag+'-holder') -MaxOutputBytes 1MB -Environment @{PGPASSWORD=$secret.admin_password;PGAPPNAME=$holderNonce;PGOPTIONS='-c statement_timeout=30000 -c lock_timeout=2000 -c transaction_timeout=30000 -c TimeZone=UTC'}
 $script:holderClosed=$false;$until=[DateTime]::UtcNow.AddSeconds(3)
 do{$connections=@(Get-NetTCPConnection -State Established -OwningProcess $holder.Process.Id -ErrorAction SilentlyContinue|Where-Object {$_.RemotePort -eq 5475 -and $_.RemoteAddress -eq '127.0.0.1'});if($connections.Count -eq 1){break};if($holder.Process.HasExited -or [DateTime]::UtcNow -ge $until){throw 'catalog_race_holder_socket'};Start-Sleep -Milliseconds 10}while($true)
 $ci=Get-CimInstance Win32_Process -Filter ('ProcessId='+$holder.Process.Id);$script:holderPort=[int]$connections[0].LocalPort
 if(!$ci -or $ci.ExecutablePath -cne $psql -or $holder.Process.StartTime.ToUniversalTime().ToString('o') -cne $holder.Record.native_creation_utc){throw 'catalog_race_holder_native_identity'}
 $query="SELECT jsonb_build_object('pid',a.pid,'backend_start',a.backend_start,'datname',a.datname,'usename',a.usename,'application_name',a.application_name,'client_port',a.client_port,'wait_event',a.wait_event,'state',a.state,'xact_start',a.xact_start,'query',a.query,'row_share',(SELECT count(*) FROM pg_locks l WHERE l.pid=a.pid AND l.relation='public.pi_kv'::regclass AND l.mode='RowShareLock' AND l.granted)) FROM pg_stat_activity a WHERE a.datname=current_database() AND a.application_name='"+$holderNonce+"' AND a.client_port="+$holderPort+';'
 [void](Sql $c.restore_db ($Tag+'-holder-witness') @('-c',$query) 1MB);$script:holderWitness=Get-Content (Join-Path $out ($Tag+'-holder-witness.stdout')) -Raw|ConvertFrom-Json -DateKind String
 if(!$holderWitness -or $holderWitness.pid -le 0 -or !$holderWitness.backend_start -or !$holderWitness.xact_start -or $holderWitness.datname -cne $c.restore_db -or $holderWitness.usename -cne 'pi_admin' -or $holderWitness.application_name -cne $holderNonce -or $holderWitness.client_port -ne $holderPort -or $holderWitness.wait_event -cne 'PgSleep' -or $holderWitness.state -cne 'active' -or $holderWitness.query.Trim() -cne 'SELECT pg_sleep(25);' -or $holderWitness.row_share -ne 1){throw 'catalog_race_actual_auth_row_holder_not_proven'}
 $script:holderWhere="pid="+[string][int]$holderWitness.pid+" AND datname='"+$c.restore_db+"' AND usename='pi_admin' AND application_name='"+$holderNonce+"' AND client_port="+$holderPort+" AND backend_start='"+$holderWitness.backend_start+"'::timestamptz"
 Write-OwnedJson (Join-Path $out ($Tag+'-holder-binding.json')) @{backend=$holderWitness;native_pid=$holder.Process.Id;native_creation=$holder.Record.native_creation_utc;cim_creation=$ci.CreationDate.ToUniversalTime().ToString('o');image=$ci.ExecutablePath;socket_local_port=$holderPort;sql_sha256=Get-OwnedHash $sql;job_basis='Owned no-breakaway child inherits admitted waiting-worker Job; no direct unnamed outer Job.Member claim';hot_reservation=32MB}
 # Final native/client identity rebind is deliberately BEFORE any blocked HTTP.
 $again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$holder.Process.Id)
 if($holder.Process.HasExited -or !$again -or $again.ExecutablePath -cne $psql -or $holder.Process.StartTime.ToUniversalTime().ToString('o') -cne $holder.Record.native_creation_utc -or @(Get-NetTCPConnection -State Established -OwningProcess $holder.Process.Id -ErrorAction Stop|Where-Object {$_.LocalPort -eq $holderPort -and $_.RemotePort -eq 5475 -and $_.RemoteAddress -eq '127.0.0.1'}).Count -ne 1){throw 'catalog_race_holder_pre_go_rebind'}
 Budget 32MB
}
function WitnessWaiter([string]$Tag){
 $q="SELECT jsonb_build_object('pid',pid,'backend_start',backend_start,'client_port',client_port,'wait_event_type',wait_event_type,'blockers',pg_blocking_pids(pid)) FROM pg_stat_activity WHERE datname=current_database() AND usename='pi_app' AND application_name='s14_catalog_race' AND wait_event_type='Lock' AND "+[string][int]$holderWitness.pid+'=ANY(pg_blocking_pids(pid));'
 $s=HotSql ($Tag+'-waiter') $q;$x=$s|ConvertFrom-Json -DateKind String
 if(!$x -or $x.pid -le 0 -or !$x.backend_start -or $x.wait_event_type -cne 'Lock' -or [int]$holderWitness.pid -notin $x.blockers -or @(Get-NetTCPConnection -State Established -OwningProcess $runtime.Process.Id -ErrorAction Stop|Where-Object {$_.LocalPort -eq $x.client_port -and $_.RemotePort -eq 5475 -and $_.RemoteAddress -eq '127.0.0.1'}).Count -ne 1){throw 'catalog_race_actual_app_waiter_not_proven'}
 Write-OwnedJson (Join-Path $out ($Tag+'-actual-app-waiter.json')) @{waiter=$x;holder=$holderWitness;app_native_pid=$runtime.Process.Id;native_socket_matched=$true}
}
function CancelHolder([string]$Tag){
 if($holder.Process.HasExited -or [DateTime]::UtcNow -ge $hotEnd){throw 'catalog_race_holder_hot_deadline'}
 $q="SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE "+$holderWhere+" AND state='active' AND wait_event='PgSleep' AND query='SELECT pg_sleep(25);' AND EXISTS(SELECT 1 FROM pg_locks l WHERE l.pid=pg_stat_activity.pid AND l.relation='public.pi_kv'::regclass AND l.mode='RowShareLock' AND l.granted);"
 if((HotSql ($Tag+'-cancel') $q) -cne 't'){throw 'catalog_race_exact_holder_cancel_refused'}
 if(!$holder.Process.WaitForExit(3000)){throw 'catalog_race_holder_not_closed'};$r=Complete-OwnedCapturedProcess $holder;$script:holderClosed=$true
 Write-OwnedJson (Join-Path $out ($Tag+'-holder-native.json')) @{native=$r;controlled_targeted_cancel=$true;backend=$holderWitness;not_clean_exit0=$true;not_SQL5_credit=$true}
 if($r.native_exit -notin @(1,3) -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout -or (Get-Content (Join-Path $out ($Tag+'-holder.stderr')) -Raw) -cnotmatch '57014:.*canceling statement due to user request'){throw 'catalog_race_holder_usercancel_actual_required'}
 [void](Sql 'postgres' ($Tag+'-holder-gone') @('-c',('SELECT count(*) FROM pg_stat_activity WHERE pid='+[string][int]$holderWitness.pid+';')) 1MB)
 if((Get-Content (Join-Path $out ($Tag+'-holder-gone.stdout')) -Raw).Trim() -cne '0'){throw 'catalog_race_holder_backend_remains'};Budget
}
$script:readyRequested=$false;$script:hotCommands=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$holder=$null;$holderClosed=$true;$probeChild=$null;$probeComplete=$false
try{
 $service=Start-OwnedStockService $c $pkg 'race-stock';[void](Wait-OwnedStockService $service);$boot=@($service.Processes|Where-Object Name -ceq 'app');$pg=@($service.Processes|Where-Object Name -ceq 'postgres');if($boot.Count -ne 1 -or $pg.Count -ne 1 -or !$service.Job.Member($boot[0].Handle)){throw 'catalog_race_bootstrap_identity'}
 $boot[0].Process.Kill();if(!$boot[0].Process.WaitForExit(10000)){throw 'catalog_race_bootstrap_stop'};Write-OwnedJson (Join-Path $out 'bootstrap-app-forced-stop.json') @{native_exit=$boot[0].Process.ExitCode;controlled_forced_stop=$true;no_clean_exit_claim=$true}
 if(@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'catalog_race_bootstrap_listener'};$secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5475){throw 'catalog_race_private_port'}
 foreach($pair in @(@('source',$c.source_db),@('runtime',$c.restore_db),@('verification',$c.verify_db))){$label='absent-'+$pair[0];[void](Sql 'postgres' $label @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$pair[1]+"');")));if((Get-Content (Join-Path $out ($label+'.stdout')) -Raw).Trim() -cne 'f'){throw 'catalog_race_database_exists'}}
 $seed=Join-Path $pkg '.local/race-small.dump';[IO.File]::Copy($c.small_archive,$seed,$false);[IO.File]::Copy(($c.small_archive+'.manifest.json'),($seed+'.manifest.json'),$false);$sm=Get-Content ($seed+'.manifest.json') -Raw|ConvertFrom-Json
 Stock 'restore-source' @{Mode='Restore';Database=$sm.database;TargetDatabase=$c.source_db;BackupFile=$seed};$archive=Join-Path $pkg '.local/race-source.dump';Stock 'backup-source' @{Mode='Backup';Database=$c.source_db;BackupFile=$archive}
 Stock 'restore-runtime' @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.restore_db;BackupFile=$archive};Stock 'restore-verification' @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.verify_db;BackupFile=$archive}
 $sourcePre=State $c.source_db 'source-pre';$runtimePre=State $c.restore_db 'runtime-pre';$verifyPre=State $c.verify_db 'verification-pre';EqualState $sourcePre $runtimePre;EqualState $sourcePre $verifyPre;$catalogPre=State $c.source_db 'catalog-pre' $true
 $a=StartCatalogRuntime $c.restore_db 'race-app' $runtimePre;$nonce=[Guid]::NewGuid().ToString('N');$pc=Join-Path $out 'race-probe-config.json';Write-OwnedJson $pc @{scope='s14-new-small-catalog-race';mode='exercise';run='race';database=$c.restore_db;app_port=3098;pg_port=5475;output_directory=$out;before=$a.before;credentials=$c.credentials;runtime_admission=$a.admission;http_client_sha=$c.http_client_sha;deadline_utc=$c.deadline_utc;control_nonce=$nonce;deleted_projects=@()}
 Budget 32MB;$probeChild=Start-OwnedCapturedProcess -Program $c.node -ProgramSha256 $c.node_sha -Arguments @($c.probe,$pc) -WorkingDirectory $pkg -OutputDirectory $out -Label 'race-http-probe' -MaxOutputBytes 1MB -Environment @{PI_CATALOG_RACE_CONFIG_SHA=(Get-OwnedHash $pc).ToLowerInvariant()}
 [void](WaitSignal 'cas-prepared');PrepareHolder 'cas';$hotEnd=[DateTime]::UtcNow.AddMilliseconds(1500);SendControl 'cas-go';$sent=WaitSignal 'cas-requests-started' 300;WitnessWaiter 'cas';CancelHolder 'cas';[void](WaitSignal 'cas-complete')
 [void](WaitSignal 'demotion-prepared');PrepareHolder 'demotion';$hotEnd=[DateTime]::UtcNow.AddMilliseconds(1500);SendControl 'demotion-owner-go';[void](WaitSignal 'demotion-owner-started' 300);WitnessWaiter 'demotion';SendControl 'demotion-editor-go';[void](WaitSignal 'demotion-requests-started' 300);CancelHolder 'demotion'
 $until=[DateTime]::UtcNow.AddSeconds(60);while(!$probeChild.Process.WaitForExit(50)){Budget;if([DateTime]::UtcNow -ge $until -or $probeChild.OutCapture.LimitReached -or $probeChild.ErrCapture.LimitReached -or $probeChild.OutCapture.Pump.IsFaulted -or $probeChild.ErrCapture.Pump.IsFaulted){throw 'catalog_race_probe_incomplete'}}
 $r=Complete-OwnedCapturedProcess $probeChild;$probeComplete=$true;Write-OwnedJson (Join-Path $out 'race-http-probe-native.json') $r
 if($r.native_exit -ne 0 -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw 'catalog_race_probe_failed_retained'}
 $summary=Get-Content (Join-Path $out 'race-summary.json') -Raw|ConvertFrom-Json;if($summary.status -cne 'ACTUAL_CONCURRENT_HTTP_CATALOG_CAS_AND_QUEUED_SESSION_DEMOTION_PENDING_FULL_DELTA_QA_TD'){throw 'catalog_race_probe_result'}
 StopRuntime;[void](Sql 'postgres' 'app-backends-gone' @('-c',("SELECT count(*) FROM pg_stat_activity WHERE datname='"+$c.restore_db+"' AND backend_type='client backend';")) 1MB);if((Get-Content (Join-Path $out 'app-backends-gone.stdout') -Raw).Trim() -cne '0'){throw 'catalog_race_app_backend_remains'}
 $after=State $c.restore_db 'runtime-after';$dc=Join-Path $out 'race-delta-config.json';Write-OwnedJson $dc @{scope='s14-new-small-catalog-race';mode='delta';run='race';database=$c.restore_db;app_port=3098;pg_port=5475;output_directory=$out;before=$a.before;after=$after;expected=@{path=Join-Path $out 'race-expected-auth-private.json';sha256=Get-OwnedHash (Join-Path $out 'race-expected-auth-private.json')};deadline_utc=$c.deadline_utc}
 [void](Native -Label 'race-exact-delta' -Program $c.node -Sha $c.node_sha -Arguments @($c.probe,$dc) -Environment @{PI_CATALOG_RACE_CONFIG_SHA=(Get-OwnedHash $dc).ToLowerInvariant()} -Seconds 60 -Cap 1MB)
 $delta=Get-Content (Join-Path $out 'race-delta.json') -Raw|ConvertFrom-Json
 if($delta.status -cne 'EXACT_COMPLETE_SMALL_AUTH_SESSION_CATALOG_AUDIT_AND_ALLOWED_PROJECT_REMOVAL_PENDING_QA_TD' -or !$delta.all_other_raw_rows_equal -or $delta.deleted_projects -ne 0){throw 'catalog_race_full_delta_required'}
 $sourceAfter=State $c.source_db 'source-after';$verifyAfter=State $c.verify_db 'verification-after';EqualState $sourcePre $sourceAfter;EqualState $verifyPre $verifyAfter
 foreach($pair in @(@('source',$c.source_db),@('runtime',$c.restore_db),@('verification',$c.verify_db))){$cat=State $pair[1] ($pair[0]+'-catalog-after') $true;EqualState $catalogPre $cat};Budget
 Write-OwnedJson (Join-Path $out 'catalog-race-result.json') @{status='ACTUAL_HTTP_CATALOG_CAS_AND_QUEUED_DEMOTION_EVIDENCE_PENDING_QA_TD';source_pre=$sourcePre;source_after=$sourceAfter;verification_pre=$verifyPre;verification_after=$verifyAfter;runtime_pre=$runtimePre;runtime_after=$after;http=$summary;production_timeouts_unchanged=$true;hot_scope=@{reservation_bytes=32MB;maximum_ms=1500;no_recursive_budget_measurement_during_block=$true;commands=@($hotCommands)};limits=@('Actual HTTP concurrency and app DBwait required; not native-test substitution','Same logged-in Editor request queued while Owner holds Authmutation; no pre-middleware capturedActor claim','No SQL5/lock2/usercancel timeout credit, no browser/crossprocess/wholeR3 claim')};$success=$true
}finally{
 try{if($runtime -and !$runtimeClosed){StopRuntime}}
 finally{
  try{
   if($probeChild -and !$probeComplete){if(!$probeChild.Process.HasExited){$probeChild.Process.Kill();if(!$probeChild.Process.WaitForExit(3000)){throw 'catalog_race_failed_probe_stop'}};Write-OwnedJson (Join-Path $out 'failed-probe-controlled-stop.json') @{native=Complete-OwnedCapturedProcess $probeChild;forced_failure_cleanup=$true;no_clean_exit_claim=$true}}
  }finally{
   try{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'}}
   finally{if($holder -and !$holderClosed){if(!$holder.Process.HasExited){$holder.Process.Kill();if(!$holder.Process.WaitForExit(3000)){throw 'catalog_race_failed_holder_stop'}};Write-OwnedJson (Join-Path $out 'failed-holder-controlled-stop.json') @{native=Complete-OwnedCapturedProcess $holder;forced_failure_cleanup=$true;no_cancel_or_fault_credit=$true}};$secret=$null}
  }
 }
}
if(!$success){throw 'catalog_race_incomplete_retained'}
Write-OwnedJson (Join-Path $out 'closed-phase-budget.json') (Get-S14ClosedPhaseBudgetTotals $resource)
# SOURCE ONLY. Needs exact hot-reservation/resource/source QA+TD review and native admission.
