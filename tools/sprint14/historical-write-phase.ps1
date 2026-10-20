param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE ONLY: full historical write roles, restart, future/checksum refusal fixtures.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'historical_write_config_preimport'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if($p[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1].ToUpperInvariant()){throw 'historical_write_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's14-full-historical-write-rbac' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5475 -or $c.app_port -ne 3098 -or $c.database -cne 'process_intelligence'){throw 'historical_write_finite_scope'}
if($c.app_sha -cne '23563DFF8FE93F339AD7F12FD0783AC3E2C53B8D9368C00D772A8FBABBE5F292' -or $c.package_sha -cne 'E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C'){throw 'historical_write_existing_candidate_only'}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
$names=@($c.source_db,$c.verify_db,$c.runtime_db,$c.future_db,$c.checksum_db)
foreach($db in $names){if($db -cnotmatch '^pi_restore_s14_[a-z0-9_]{1,35}$'){throw 'historical_write_new_database'}}
if(@($names|Select-Object -Unique).Count -ne 5){throw 'historical_write_distinct_databases'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
foreach($p in @(@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.node,$c.node_sha),@($c.probe,$c.probe_sha),@($c.capture_sql,$c.capture_sql_sha),@($c.catalog_sql,$c.catalog_sql_sha),@($c.summary_sql,$c.summary_sql_sha),@($c.state_helper,$c.state_helper_sha))){Assert-OwnedHash $p[0] $p[1]}
foreach($pair in @(@($c.probe,(Join-Path $PSScriptRoot 'historical-write-probe.cjs')),@($c.capture_sql,(Join-Path $workspace '.local/sprint11/root/sql5-inputs01/capture.sql')),@($c.catalog_sql,(Join-Path $PSScriptRoot 'logical-catalog.sql')),@($c.summary_sql,(Join-Path $PSScriptRoot 'historical-write-summary.sql')),@($c.state_helper,(Join-Path $PSScriptRoot 'historical-write-state.cjs')))){if((Get-OwnedCanonicalPath $pair[0]) -cne (Get-OwnedCanonicalPath $pair[1])){throw 'historical_write_literal_source_paths'}}
$original=Join-Path $workspace '.local/sprint09/qa/package-c2/process-intelligence-rs-0.7.1-windows-x86_64/.local/c2-c02-normalized01.dump'
if((Get-OwnedCanonicalPath $c.original_archive) -cne (Get-OwnedCanonicalPath $original) -or $c.capture_sql_sha -cne '054242566AC35D3AFAC986298BB030D8536A72710FA40F30ECA3193D8361A45B'){throw 'historical_write_full_original_inputs'}
Assert-OwnedHash $original '3A0E6E244384D141A326345E0161AEC0AFA7EC9AF2563E9C03CBDD1B04770274';Assert-OwnedHash ($original+'.manifest.json') 'BD4BC1F45EA1AEB3A8D2668C6D0E7EFF39413A98CD27FD65C4B272ED10C735D7'
$credentialBase=Join-Path $workspace '.local/sprint13/root/historical-credentials-check02'
foreach($pair in @(@($c.credentials,(Join-Path $credentialBase 'credentials-private.json'),'8CB1AD456ED31812780C5844D6F8D5145F08C83801489B0C315C88FF45D5E040'),@($c.credential_native_record,(Join-Path $credentialBase 'child.process.json'),'A765A56DD676455A046611D754A06FCB8E3287A73BAB959740F34A2C19864372'),@($c.credential_result,(Join-Path $credentialBase 'child.stdout'),'879C54C6DD5C88A568F3CF9AD9B4448683C911AA2B889ADB1358226869C680E9'))){if((Get-OwnedCanonicalPath $pair[0].path) -cne (Get-OwnedCanonicalPath $pair[1]) -or $pair[0].sha256.ToUpperInvariant() -cne $pair[2]){throw 'historical_write_actual_credential_proofs'};Assert-OwnedNoReparse $pair[1];Assert-OwnedHash $pair[1] $pair[2]}
$acl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($credentialBase));$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;$rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value -or !$acl.AreAccessRulesProtected -or $rules.Count -ne 1 -or $rules[0].IdentityReference.Value -cne $sid.Value -or $rules[0].AccessControlType -ne 'Allow' -or $rules[0].FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl){throw 'historical_write_readonly_old_credential_ACL'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($c.required_free_bytes -ne 8GB -or $c.runtime_floor_bytes -ne 8GB -or $deadline -gt [DateTimeOffset]::Parse('2026-10-20T09:54:16Z').UtcDateTime -or $started -ge $deadline -or $c.capture_reservation_bytes -ne 2500000000L -or $c.phase_reservation_bytes -gt 8GB){throw 'historical_write_resource_freeze'}
$resource=New-S14PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S14PhaseBudget -Proof $resource -Next $Next}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$m=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($m.version -cne '0.7.3' -or $m.source_commit -cne $c.source_commit){throw 'historical_write_candidate'}
$app=Join-Path $pkg 'process-intelligence-rs.exe';$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
Assert-OwnedHash $app $c.app_sha;Assert-OwnedHash $psql $c.psql_sha;Assert-OwnedHash $backup $c.backup_sha
$service=$null;$secret=$null;$runtime=$null;$runtimeClosed=$false;$success=$false
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int[]]$Exits=@(0),[int]$Seconds=120,[long]$Cap=8MB){
 Budget $Cap;$p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'historical_write_child_stop'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;single_invocation=$true}
 if($forced -or $r.native_exit -notin $Exits -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw ('historical_write_native_'+$Label)};Budget;return $r
}
function Sql([string]$Db,[string]$Label,[string[]]$Arguments,[long]$Cap=16MB,[bool]$Writable=$false){
 if($Db -cnotin ($names+@('postgres'))){throw 'historical_write_SQL_scope'}
 [string[]]$argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p','5475','-U','pi_admin','-w','-d',$Db)+$Arguments
 if($Writable){$allowed=if($Db -ceq $c.future_db){$futureSQL}elseif($Db -ceq $c.checksum_db){$checksumSQL}else{throw 'historical_write_setup_db'};if($Arguments.Count -ne 2 -or $Arguments[0] -cne '-c' -or $Arguments[1] -cne $allowed -or !$script:fixtureMutations.Add($Db)){throw 'historical_write_exact_single_fixture_setup_SQL'}}
 $options=if($Writable){'-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c TimeZone=Etc/GMT-5 -c DateStyle=ISO,YMD'}else{'-c statement_timeout=60000 -c default_transaction_read_only=on -c TimeZone=Etc/GMT-5 -c DateStyle=ISO,YMD'}
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments $argv -Environment @{PGPASSWORD=$secret.admin_password;PGOPTIONS=$options} -Cap $Cap
}
function EqualState($a,$b){if($a.bytes -ne $b.bytes -or $a.sha256.ToUpperInvariant() -cne $b.sha256.ToUpperInvariant()){throw 'historical_write_full_state_or_historical_changed'}}
function Stock([string]$Label,[hashtable]$Fields){[string[]]$argv=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Fields|ConvertTo-Json -Compress));[void](Native -Label $Label -Program $c.pwsh -Sha $c.pwsh_sha -Arguments $argv -Seconds 180)}
function URL([string]$Db,[string]$User='pi_admin'){$pw=if($User -ceq 'pi_app'){$secret.app_password}else{$secret.admin_password};return "host=127.0.0.1 port=5475 user=$User password=$pw dbname=$Db connect_timeout=5 application_name=s14_historical_write"}
function StopRuntime{
 if(!$runtime -or $runtimeClosed){return};if($runtime.Process.HasExited){throw 'historical_write_unexpected_app_exit'}
 $again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id)
 if(!$again -or $again.ExecutablePath -cne $app -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation){throw 'historical_write_retained_app_identity'}
 $runtime.Process.Kill();if(!$runtime.Process.WaitForExit(10000)){throw 'historical_write_app_stop'};$r=Complete-OwnedCapturedProcess $runtime;$script:runtimeClosed=$true
 Write-OwnedJson (Join-Path $out ($runtimeLabel+'-controlled-stop.json')) @{native=$r;controlled_forced_stop=$true;no_clean_exit_claim=$true}
 if(!$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'historical_write_app_streams_or_listener'}
}
function StartHistoricalRuntime([string]$Db,[string]$Label,$Expected){
 if($Db -cnotin @($c.runtime_db) -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'historical_runtime_new_target_listener'}
 $script:runtimeLabel=$Label;$script:runtimeClosed=$false;Budget 8MB
 $script:runtime=Start-OwnedCapturedProcess -Program $app -ProgramSha256 $c.app_sha -Arguments @() -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes 8MB -Environment @{PI_DATABASE_URL=(URL $Db 'pi_app');PORT='3098';RUST_LOG='info'}
 $script:creation=$runtime.Process.StartTime.ToUniversalTime().ToString('o');$until=[DateTime]::UtcNow.AddSeconds(30)
 do{Budget;if($runtime.Process.HasExited -or [DateTime]::UtcNow -ge $until){throw 'historical_app_not_ready'};$listeners=@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue);if($listeners.Count){if(@($listeners|Where-Object {$_.OwningProcess -ne $runtime.Process.Id -or $_.LocalAddress -notin @('127.0.0.1','::1')}).Count){throw 'historical_listener_identity'};break};Start-Sleep -Milliseconds 100}while($true)
 $native=Get-CimInstance Win32_Process -Filter ('ProcessId='+$runtime.Process.Id);$pgCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id)
 if(!$native -or $native.ExecutablePath -cne $app -or $runtime.Process.StartTime.ToUniversalTime().ToString('o') -cne $creation -or !$pgCim -or $pg[0].Process.HasExited -or $pgCim.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe')){throw 'historical_actual_native_identity'}
 if(!$script:readyRequested){Wait-OwnedReadyJob @(@{name='app';pid=$runtime.Process.Id;creation_utc=$native.CreationDate.ToUniversalTime().ToString('o')},@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o')}) $out;$script:readyRequested=$true}
 $before=Capture $Db ($Label+'-before-login');CompareIndex $Expected $before ($Label+'-startup-equal')
 $admission=Join-Path $out ($Label+'-admission.json');Write-OwnedJson $admission @{scope='S14_FULL_HISTORICAL_WRITE_RUNTIME';database=$Db;app_port=3098;pg_port=5475;version='0.7.3';app_sha256=$c.app_sha;app_pid=$runtime.Process.Id;native_creation=$creation;cim_creation=$native.CreationDate.ToUniversalTime().ToString('o');outer_first_ready_sha256=Get-OwnedHash (Join-Path $out 'ready-response.json');startup_full_unchanged=$true;job_basis='Initial app+PG actual outer-ready; subsequent retained children inherit same admitted no-breakaway waiting worker Job. No separate direct outer Job.Member claim'}
 return @{before=$before;admission=@{path=$admission;sha256=Get-OwnedHash $admission}}
}
function Capture([string]$Db,[string]$Label,[bool]$Full=$false){
 $sql=if($Full){$c.capture_sql}else{$c.summary_sql};$cap=if($Full){1GB}else{16MB};Budget $cap;$r=Sql $Db $Label @('-f',$sql) $cap
 $raw=@{path=Join-Path $out ($Label+'.stdout');bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256}
 if($Full -and $Label -ceq 'source-full-pre' -and ($raw.bytes -ne 614304123 -or $raw.sha256.ToUpperInvariant() -cne '9959D3E9E746460C0C52853D139DCBCCFF37EE230907537AB437FCFE33933DA1')){throw 'historical_write_actual_original_full130_required'}
 $indexFile=Join-Path $out ($Label+'-index.json');$cfg=Join-Path $out ($Label+'-index-config.json');Write-OwnedJson $cfg @{scope='s14-historical-write-state';mode=$(if($Full){'full'}else{'summary'});input=$raw;output=$indexFile;deadline_utc=$c.deadline_utc}
 [void](Native -Label ($Label+'-index') -Program $c.node -Sha $c.node_sha -Arguments @($c.state_helper,$cfg) -Environment @{PI_HISTORICAL_STATE_CONFIG_SHA=(Get-OwnedHash $cfg).ToLowerInvariant()} -Seconds 200 -Cap 1MB)
 $result=Get-Content (Join-Path $out ($Label+'-index.stdout')) -Raw|ConvertFrom-Json
 if($result.status -cne 'COMPLETE_ALL_VALUE_TYPED_TUPLE_INDEX_PENDING_QA_TD' -or $result.rows -notin @(130,131) -or $result.legacy -ne 10 -or $result.logs -ne 20 -or $result.models -ne 14){throw 'historical_write_complete_index_coverage'}
 return @{path=$indexFile;sha256=Get-OwnedHash $indexFile}
}
function Oracle([string]$Label,[hashtable]$Fields){$cfg=@{scope=$c.scope;output_directory=$out;database=$c.runtime_db};foreach($k in $Fields.Keys){$cfg[$k]=$Fields[$k]};$p=Join-Path $out ($Label+'-config.json');Write-OwnedJson $p $cfg;[void](Native -Label $Label -Program $c.node -Sha $c.node_sha -Arguments @($c.probe,$p) -Environment @{PI_HISTORICAL_WRITE_CONFIG_SHA=(Get-OwnedHash $p).ToLowerInvariant()} -Seconds 60 -Cap 1MB)}
function CompareIndex($Before,$After,[string]$Label){Oracle $Label @{mode='equal';before=$Before;after=$After}}
function Catalog([string]$Db,[string]$Label){Budget 16MB;$r=Sql $Db $Label @('-f',$c.catalog_sql) 16MB;return @{bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256;path=Join-Path $out ($Label+'.stdout')}}
function RunHistoricalProbe([string]$Run,$Admission){
 $cfg=@{scope=$c.scope;mode=$Run;run=$Run;database=$c.runtime_db;app_port=3098;pg_port=5475;output_directory=$out;before=$Admission.before;deadline_utc=$c.deadline_utc;credentials=$c.credentials;credential_native_record=$c.credential_native_record;credential_result=$c.credential_result;runtime_admission=$Admission.admission;http_client_sha=$c.http_client_sha}
 $p=Join-Path $out ($Run+'-http-config.json');Write-OwnedJson $p $cfg
 [void](Native -Label ($Run+'-http') -Program $c.node -Sha $c.node_sha -Arguments @($c.probe,$p) -Environment @{PI_HISTORICAL_WRITE_CONFIG_SHA=(Get-OwnedHash $p).ToLowerInvariant()} -Seconds 320 -Cap 1MB)
 $result=Get-Content (Join-Path $out ($Run+'-summary.json')) -Raw|ConvertFrom-Json
 if($result.status -cne 'HISTORICAL_OWNER_EDITOR_WRITE_RBAC_CAPTURED_PENDING_FULL_DELTA_AND_QA_TD' -or ($Run -ceq 'write' -and ($result.write_commits -ne 7 -or (@($result.positive_writers|Sort-Object)-join ',') -cne 'editor,owner')) -or ($Run -ceq 'restart' -and $result.write_commits -ne 0)){throw 'historical_write_actual_role_coverage'}
 StopRuntime
 [void](Sql 'postgres' ($Run+'-backends-gone') @('-c',("SELECT count(*) FROM pg_stat_activity WHERE datname='"+$c.runtime_db+"' AND backend_type='client backend';")) 1MB)
 if((Get-Content (Join-Path $out ($Run+'-backends-gone.stdout')) -Raw).Trim() -cne '0'){throw 'historical_write_app_backend_remains'}
 $after=Capture $c.runtime_db ($Run+'-after') ($Run -ceq 'write')
 if($Run -ceq 'write'){$calibration=Capture $c.runtime_db 'write-after-summary';CompareIndex $after $calibration 'post-full-summary-calibration'}
 $w=Join-Path $out ($Run+'-witness-private.json');Oracle ($Run+'-exact-delta') @{mode='delta';run=$Run;before=$Admission.before;after=$after;witness=@{path=$w;sha256=Get-OwnedHash $w}}
 $delta=Get-Content (Join-Path $out ($Run+'-exact-delta.stdout')) -Raw|ConvertFrom-Json
 if($delta.status -cne 'HISTORICAL_OWNER_EDITOR_WRITES_AUTH_SESSIONS_HEADER_AND_ALL_OTHER_TUPLES_EXACT_PENDING_QA_TD' -or !$delta.all20_logs14_models_legacy_markers_ledger_sequence_unchanged){throw 'historical_write_complete_tuple_delta_required'}
 return $after
}
$script:readyRequested=$false
$script:fixtureMutations=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$futureSQL="INSERT INTO public.pi_schema_migrations(version,name,checksum,applied_at) VALUES(2147483647,'s14_future_fixture',repeat('f',64),TIMESTAMPTZ '2026-10-20 00:00:00+00') RETURNING version;"
$checksumSQL="UPDATE public.pi_schema_migrations SET checksum=repeat('f',64) WHERE version=1 RETURNING version;"
try{
 $service=Start-OwnedStockService $c $pkg 'historical-stock';[void](Wait-OwnedStockService $service)
 $boot=@($service.Processes|Where-Object Name -ceq 'app');$pg=@($service.Processes|Where-Object Name -ceq 'postgres');if($boot.Count -ne 1 -or $pg.Count -ne 1 -or !$service.Job.Member($boot[0].Handle)){throw 'historical_write_bootstrap_identity'}
 $boot[0].Process.Kill();if(!$boot[0].Process.WaitForExit(10000)){throw 'historical_write_bootstrap_stop'}
 Write-OwnedJson (Join-Path $out 'bootstrap-app-forced-stop.json') @{pid=$boot[0].Process.Id;native_exit=$boot[0].Process.ExitCode;controlled_forced_stop=$true;no_clean_app_exit_claim=$true}
 if(@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'historical_write_bootstrap_listener'}
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5475){throw 'historical_write_private_port'}
 foreach($pair in @(@('source',$c.source_db),@('verify',$c.verify_db),@('runtime',$c.runtime_db),@('future',$c.future_db),@('checksum',$c.checksum_db))){$label='absent-'+$pair[0];[void](Sql 'postgres' $label @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$pair[1]+"');")) 1MB);if((Get-Content (Join-Path $out ($label+'.stdout')) -Raw).Trim() -cne 'f'){throw 'historical_write_database_not_new'}}
 $input=Join-Path $pkg '.local/historical-original.dump';[IO.File]::Copy($original,$input,$false);[IO.File]::Copy(($original+'.manifest.json'),($input+'.manifest.json'),$false);$old=Get-Content ($input+'.manifest.json') -Raw|ConvertFrom-Json
 Stock 'restore-source' @{Mode='Restore';Database=$old.database;TargetDatabase=$c.source_db;BackupFile=$input}
 $archive=Join-Path $pkg '.local/historical-source.dump';Stock 'backup-source' @{Mode='Backup';Database=$c.source_db;BackupFile=$archive}
 foreach($pair in @(@('verify',$c.verify_db),@('runtime',$c.runtime_db),@('future',$c.future_db),@('checksum',$c.checksum_db))){Stock ('restore-'+$pair[0]) @{Mode='Restore';Database=$c.source_db;TargetDatabase=$pair[1];BackupFile=$archive}}
 $sourcePre=Capture $c.source_db 'source-full-pre' $true;$sourceSummary=Capture $c.source_db 'source-summary-pre';CompareIndex $sourcePre $sourceSummary 'pre-full-summary-calibration'
 $verifyPre=Capture $c.verify_db 'verification-pre';$runtimePre=Capture $c.runtime_db 'runtime-pre';CompareIndex $sourcePre $verifyPre 'verification-pre-equal';CompareIndex $sourcePre $runtimePre 'runtime-pre-equal'
 $catalogPre=Catalog $c.source_db 'catalog-pre'
 $a=StartHistoricalRuntime $c.runtime_db 'write-app' $runtimePre;$writeAfter=RunHistoricalProbe 'write' $a
 $a=StartHistoricalRuntime $c.runtime_db 'restart-app' $writeAfter;$restartAfter=RunHistoricalProbe 'restart' $a
 $fixtures=@()
 foreach($case in @(@('future',$c.future_db),@('checksum',$c.checksum_db))){
  $tag=$case[0];$db=$case[1];$pre=Capture $db ($tag+'-pre');CompareIndex $sourcePre $pre ($tag+'-pre-equal')
  $ownArchive=Join-Path $pkg ('.local/'+$tag+'-valid-pre.dump');Stock ($tag+'-backup-valid-pre') @{Mode='Backup';Database=$db;BackupFile=$ownArchive}
  $plan=Join-Path $pkg ('.local/'+$tag+'-valid.plan.json');$envCLI=@{PI_DATABASE_URL=URL $db;PI_CLEANUP_RESTORE_URL=URL $c.verify_db;PI_CLEANUP_ARCHIVE=$ownArchive;PI_CLEANUP_PLAN=$plan}
  [void](Native -Label ($tag+'-valid-pre-verify') -Program $app -Sha $c.app_sha -Arguments @('--cleanup-storage-verify') -Environment $envCLI -Seconds 300 -Cap 1MB)
  $v=Get-Content (Join-Path $out ($tag+'-valid-pre-verify.stdout')) -Raw|ConvertFrom-Json;if($v.outcome -cne 'cleanup_verified' -or $v.candidate_rows -ne 10){throw 'historical_write_valid_fixture_precondition'}
  $mutation=if($tag -ceq 'future'){$futureSQL}else{$checksumSQL};[void](Sql $db ($tag+'-one-ledger-mutation') @('-c',$mutation) 1MB $true)
  $expected=if($tag -ceq 'future'){'2147483647'}else{'1'};if((Get-Content (Join-Path $out ($tag+'-one-ledger-mutation.stdout')) -Raw).Trim() -cne $expected){throw 'historical_write_exact_one_ledger_row'}
  $setup=Capture $db ($tag+'-setup')
  [void](Native -Label ($tag+'-normal-app-refusal') -Program $app -Sha $c.app_sha -Arguments @() -Environment @{PI_DATABASE_URL=(URL $db 'pi_app');PORT='3098';RUST_LOG='info'} -Exits @(1) -Seconds 30 -Cap 1MB)
  $err=Get-Content (Join-Path $out ($tag+'-normal-app-refusal.stderr')) -Raw
  if(!$err.Contains('Схема базы не поддерживается или повреждена.') -or $err.Contains('app_started') -or @(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'historical_write_actual_startup_schema_refusal_required'}
  $afterApp=Capture $db ($tag+'-after-app-refusal');$noPlan=Join-Path $pkg ('.local/'+$tag+'-never.plan.json');$envCLI.PI_CLEANUP_PLAN=$noPlan
  [void](Native -Label ($tag+'-cleanup-schema-refusal') -Program $app -Sha $c.app_sha -Arguments @('--cleanup-storage-verify') -Environment $envCLI -Exits @(1) -Seconds 300 -Cap 1MB)
  $refusal=Get-Content (Join-Path $out ($tag+'-cleanup-schema-refusal.stdout')) -Raw|ConvertFrom-Json;if($refusal.outcome -cne 'cleanup_refused' -or $refusal.code -cne 'cleanup_schema' -or (Test-Path $noPlan)){throw 'historical_write_actual_cleanup_schema_code'}
  $afterCleanup=Capture $db ($tag+'-after-cleanup-refusal');Oracle ($tag+'-exact-fixture-oracle') @{mode='fixture';fixture=$tag;before=$pre;setup=$setup;after_app=$afterApp;after_cleanup=$afterCleanup}
  $fixtures+=@{fixture=$tag;database=$db;before=$pre;setup=$setup;after_app=$afterApp;after_cleanup=$afterCleanup;startup_native=1;startup_message_bound_to_source=$true;startup_machine_code_not_exposed=$true;cleanup_native=1;cleanup_code='cleanup_schema';no_reset=$true}
 }
 $sourcePost=Capture $c.source_db 'source-post';$verifyPost=Capture $c.verify_db 'verification-post';CompareIndex $sourcePre $sourcePost 'source-final-equal';CompareIndex $verifyPre $verifyPost 'verification-final-equal'
 foreach($pair in @(@('source',$c.source_db),@('verify',$c.verify_db),@('runtime',$c.runtime_db),@('future',$c.future_db),@('checksum',$c.checksum_db))){$cat=Catalog $pair[1] ($pair[0]+'-catalog-post');EqualState $catalogPre $cat}
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256};Budget
 Write-OwnedJson (Join-Path $out 'historical-write-result.json') @{status='FULL_HISTORICAL_WRITE_RBAC_RESTART_AND_UNSUPPORTED_SCHEMA_EVIDENCE_PENDING_QA_TD';source_pre=$sourcePre;source_post=$sourcePost;verification_pre=$verifyPre;verification_post=$verifyPost;runtime_pre=$runtimePre;write_after=$writeAfter;restart_after=$restartAfter;fixtures=$fixtures;retained_complete_full_captures=2;limits=@('All130 tuples/10legacy/20logs/14models conserved except explicit Authsession and one header organization/audit changes','Whole fullPRE9959 and whole fullPOST newnative both calibrate all-row summary domain','Current Owner AND Editor7 actual normal writes, Viewer403/foreign403open+422crossfolder isolation','Restart startup unchanged plus explicit4login/3switch delta; no repeat103 exports','Separate NEW future/checksum ledger fixtures; no old downgrade/productchange/reset','Normalapp exposes exact schema message/native1, no invented JSONcode; cleanup exposes cleanup_schema','No browser/concurrency/wholeR3/release acceptance')};$success=$true
}finally{try{if($runtime -and !$runtimeClosed){StopRuntime}}finally{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'};$secret=$null}}
if(!$success){throw 'historical_write_incomplete_retained'}
Write-OwnedJson (Join-Path $out 'closed-phase-budget.json') (Get-S14ClosedPhaseBudgetTotals $resource)
# SOURCE ONLY. Exact config/source/native capture allowlist and independent QA/TD
# prospective review plus fresh all-file32GiB meter/full uncompressed peak required.
