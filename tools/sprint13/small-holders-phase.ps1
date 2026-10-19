param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY C13 SmallS holders/default-role identity refusal; no lock2/C17 credit.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'holders_config_preimport'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if($p[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1].ToUpperInvariant()){throw 'holders_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's13-small-offline-holders-and-default-identity' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5465 -or $c.app_port -ne 3097 -or $c.database -cne 'process_intelligence'){throw 'holders_finite_scope'}
$modes=@('source-lease','restore-lease','row-writer','table-holder','identity-privilege')
if(@($c.cases).Count -ne 5 -or (@($c.cases.mode|Sort-Object)-join ',') -cne (@($modes|Sort-Object)-join ',')){throw 'holders_exact_five_cases'}
$allNames=@();foreach($case in $c.cases){foreach($n in @($case.source_db,$case.restore_db)){if($n -cnotmatch '^pi_restore_s13_[a-z0-9_]{1,35}$'){throw 'holders_NEW_db_names'};$allNames+=$n}}
if(@($allNames|Select-Object -Unique).Count -ne 10){throw 'holders_ten_distinct_NEW_databases'}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
function Proof($Pin){Assert-OwnedNoReparse $Pin.path;Assert-OwnedHash $Pin.path $Pin.sha256;if((Get-Item $Pin.path).Length -gt 4MB){throw 'holders_proof_size'};return Get-Content $Pin.path -Raw|ConvertFrom-Json -AsHashtable -DateKind String}
$fixture=Proof $c.fixture_review
if($fixture.status -cne 'S13_MAINTAINED_SMALL_S_INPUT_REVIEWED' -or $fixture.archive_sha -cne 'A18E0BF2E061B350B0918D9116BBC4F7C0E46EE8F28FDF0C7FA342BA725A030C' -or $fixture.manifest_sha -cne $c.small_manifest_sha -or $fixture.candidates.Count -ne 2 -or !$fixture.all_record_kinds -or !$fixture.normal_auth -or !$fixture.project_list_exercised -or $fixture.generic_key -cne 'fixture/keep'){throw 'holders_actual_seed02_required'}
Assert-OwnedHash $c.small_archive $fixture.archive_sha;Assert-OwnedHash ($c.small_archive+'.manifest.json') $c.small_manifest_sha
foreach($p in $c.pins){Assert-OwnedHash $p.path $p.sha256}
foreach($p in @(@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.capture_sql,$c.capture_sql_sha),@($c.catalog_sql,$c.catalog_sql_sha))){Assert-OwnedHash $p[0] $p[1]}
if((Get-OwnedCanonicalPath $c.capture_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'managed-state.sql')) -or (Get-OwnedCanonicalPath $c.catalog_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'logical-catalog.sql'))){throw 'holders_complete_capture_sources'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($deadline -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or $started -ge $deadline -or $c.capture_reservation_bytes -ne 512MB -or $c.phase_reservation_bytes -gt 2GB){throw 'holders_finite_peak_freeze'}
$resource=New-S13PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S13PhaseBudget -Proof $resource -Next $Next}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$manifest=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json;if($manifest.version -cne '0.7.3' -or $manifest.source_commit -cne $c.source_commit){throw 'holders_current_candidate'}
$app=Join-Path $pkg 'process-intelligence-rs.exe';$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
Assert-OwnedHash $app $c.app_sha;Assert-OwnedHash $psql $c.psql_sha;Assert-OwnedHash $backup $c.backup_sha
$service=$null;$secret=$null;$holder=$null;$holderComplete=$true;$results=@()
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int[]]$Exits=@(0),[int]$Seconds=120,[long]$Cap=8MB){
 Budget $Cap;$p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 4GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'holders_owned_child_stop'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;single_invocation=$true}
 if($forced -or $r.native_exit -notin $Exits -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw ('holders_native_failed_'+$Label)};return $r
}
function Sql([string]$Db,[string]$Label,[string[]]$Arguments,[long]$Cap=8MB,[string]$User='pi_admin',[int[]]$Exits=@(0)){
 if($Db -cnotin ($allNames+@('postgres')) -or $User -cnotin @('pi_admin','pi_app')){throw 'holders_SQL_owned_scope'}
 $pw=if($User -ceq 'pi_app'){$secret.app_password}else{$secret.admin_password}
 [string[]]$argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-h','127.0.0.1','-p','5465','-U',$User,'-w','-d',$Db)+$Arguments
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments $argv -Environment @{PGPASSWORD=$pw;PGOPTIONS='-c statement_timeout=60000 -c default_transaction_read_only=on -c TimeZone=UTC -c DateStyle=ISO,YMD'} -Exits $Exits -Cap $Cap
}
function State([string]$Db,[string]$Label,[bool]$Catalog=$false){Budget 8MB;$sql=if($Catalog){$c.catalog_sql}else{$c.capture_sql};$r=Sql $Db $Label @('-f',$sql);return @{path=Join-Path $out ($Label+'.stdout');sha256=$r.stdout_sha256;bytes=$r.stdout_bytes_persisted}}
function EqualState($a,$b){if($a.sha256 -cne $b.sha256 -or $a.bytes -ne $b.bytes){throw 'holders_full_state_or_catalog_changed'}}
function Stock([string]$Label,[hashtable]$Fields){[string[]]$argv=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Fields|ConvertTo-Json -Compress));[void](Native -Label $Label -Program $c.pwsh -Sha $c.pwsh_sha -Arguments $argv -Seconds 180)}
function URL([string]$Db,[string]$User='pi_admin'){$pw=if($User -ceq 'pi_app'){$secret.app_password}else{$secret.admin_password};return "host=127.0.0.1 port=5465 user=$User password=$pw dbname=$Db connect_timeout=5"}
function Cleanup([string]$Label,[string]$Mode,[hashtable]$Environment,[int]$Exit,[string]$Code=''){
 [void](Native -Label $Label -Program $app -Sha $c.app_sha -Arguments @('--cleanup-storage-'+$Mode) -Environment $Environment -Exits @($Exit) -Seconds 300 -Cap 1MB)
 $v=Get-Content (Join-Path $out ($Label+'.stdout')) -Raw|ConvertFrom-Json
 if($Exit -eq 1){if($v.outcome -cne 'cleanup_refused' -or $v.code -cne $Code){throw 'holders_exact_refusal_JSON'}}elseif($v.outcome -cne 'cleanup_verified' -or $v.candidate_rows -ne 2){throw 'holders_actual_Verify2'};return $v
}
try{
 $service=Start-OwnedStockService $c $pkg 'holders-stock';[void](Wait-OwnedStockService $service)
 $boot=@($service.Processes|Where-Object Name -ceq 'app');$pg=@($service.Processes|Where-Object Name -ceq 'postgres');if($boot.Count -ne 1 -or $pg.Count -ne 1 -or !$service.Job.Member($boot[0].Handle)){throw 'holders_bootstrap_identity'}
 $boot[0].Process.Kill();if(!$boot[0].Process.WaitForExit(10000)){throw 'holders_app_offline'}
 if(@(Get-NetTCPConnection -State Listen -LocalPort 3097 -ErrorAction SilentlyContinue).Count){throw 'holders_app_listener_remains'}
 Write-OwnedJson (Join-Path $out 'bootstrap-app-forced-stop.json') @{pid=$boot[0].Process.Id;native_exit=$boot[0].Process.ExitCode;controlled_forced_stop=$true}
 $pgCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id);if(!$pgCim -or $pgCim.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe') -or $pg[0].Process.HasExited){throw 'holders_actual_PG_identity'}
 Wait-OwnedReadyJob @(@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o')}) $out
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5465){throw 'holders_secret_port'}
 $seed=Join-Path $pkg '.local/holders-small.dump';[IO.File]::Copy($c.small_archive,$seed,$false);[IO.File]::Copy(($c.small_archive+'.manifest.json'),($seed+'.manifest.json'),$false);$sm=Get-Content ($seed+'.manifest.json') -Raw|ConvertFrom-Json
 foreach($case in $c.cases){$tag=$case.mode;$src=$case.source_db;$dst=$case.restore_db
  foreach($db in @($src,$dst)){$side=if($db -ceq $src){'source'}else{'restore'};$absentLabel=$tag+'-absent-'+$side;[void](Sql 'postgres' $absentLabel @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$db+"');")));if((Get-Content (Join-Path $out ($absentLabel+'.stdout')) -Raw).Trim() -cne 'f'){throw 'holders_database_must_be_NEW'}}
  Stock ($tag+'-restore-source') @{Mode='Restore';Database=$sm.database;TargetDatabase=$src;BackupFile=$seed}
  $archive=Join-Path $pkg ('.local/'+$tag+'.dump');Stock ($tag+'-backup-source') @{Mode='Backup';Database=$src;BackupFile=$archive};Stock ($tag+'-restore-copy') @{Mode='Restore';Database=$src;TargetDatabase=$dst;BackupFile=$archive}
  $sp=State $src ($tag+'-source-pre');$rp=State $dst ($tag+'-restore-pre');EqualState $sp $rp;$sc=State $src ($tag+'-source-catalog-pre') $true;$rc=State $dst ($tag+'-restore-catalog-pre') $true;EqualState $sc $rc
  $plan=Join-Path $pkg ('.local/'+$tag+'.plan.json');$receipt=Join-Path $pkg ('.local/'+$tag+'.receipt.json');$cli=@{PI_DATABASE_URL=URL $src;PI_CLEANUP_RESTORE_URL=URL $dst;PI_CLEANUP_ARCHIVE=$archive;PI_CLEANUP_PLAN=$plan;PI_CLEANUP_RECEIPT=$receipt}
  [void](Cleanup ($tag+'-verify') 'verify' $cli 0);$cli.PI_CLEANUP_CONFIRM_SHA=Get-OwnedHash $plan
  [void](Sql 'postgres' ($tag+'-other-clients-zero') @('-c',("SELECT count(*) FROM pg_stat_activity WHERE datname IN ('"+$src+"','"+$dst+"') AND backend_type='client backend';")) 1MB)
  if((Get-Content (Join-Path $out ($tag+'-other-clients-zero.stdout')) -Raw).Trim() -cne '0'){throw 'holders_no_unrelated_clients_before_holder'}
  $witness=$null;$cancel=$null
  if($tag -ceq 'identity-privilege'){
   [void](Sql $src 'identity-default-role' @('-c',"SELECT jsonb_build_object('current_user',current_user,'rolsuper',rolsuper,'rolcreaterole',rolcreaterole,'rolcreatedb',rolcreatedb) FROM pg_roles WHERE rolname=current_user;") 1MB 'pi_app')
   $role=Get-Content (Join-Path $out 'identity-default-role.stdout') -Raw|ConvertFrom-Json;if($role.current_user -cne 'pi_app' -or $role.rolsuper -or $role.rolcreaterole){throw 'holders_default_restricted_role_required'}
   [void](Sql $src 'identity-actual-permission' @('-c','SELECT (pg_control_system()).system_identifier::text;') 1MB 'pi_app' @(1,3))
   if((Get-Content (Join-Path $out 'identity-actual-permission.stderr') -Raw) -cnotmatch '42501'){throw 'holders_actual_42501_required_no_privilege_changes'}
   $limited=@{};foreach($k in $cli.Keys){$limited[$k]=$cli[$k]};$limited.PI_DATABASE_URL=URL $src 'pi_app';$limited.PI_CLEANUP_RESTORE_URL=URL $dst 'pi_app';$limited.PI_CLEANUP_PLAN=Join-Path $pkg '.local/identity-never-created.plan.json';$limited.Remove('PI_CLEANUP_CONFIRM_SHA')
   [void](Cleanup 'identity-limited-verify' 'verify' $limited 1 'cleanup_storage_unavailable');if(Test-Path $limited.PI_CLEANUP_PLAN){throw 'holders_limited_verify_created_plan'}
   $limited.PI_CLEANUP_PLAN=$plan;$limited.PI_CLEANUP_CONFIRM_SHA=Get-OwnedHash $plan;[void](Cleanup 'identity-limited-apply' 'apply' $limited 1 'cleanup_storage_unavailable')
  }else{
   $holdDb=if($tag -ceq 'restore-lease'){$dst}else{$src};$nonce='s13-c13-'+[Guid]::NewGuid().ToString('N');$sqlFile=Join-Path $out ($tag+'-holder.sql')
   $statement=switch($tag){'source-lease' {'SELECT pg_advisory_lock(5785256839849804116); SELECT pg_sleep(25);'} 'restore-lease' {'SELECT pg_advisory_lock(5785256839849804116); SELECT pg_sleep(25);'} 'row-writer' {"BEGIN; UPDATE public.pi_kv SET document=document WHERE key='fixture/keep'; SELECT pg_sleep(25);"} 'table-holder' {'BEGIN; LOCK TABLE public.pi_kv IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(25);'} default {throw 'holders_unknown_mode'}}
   $b=[Text.UTF8Encoding]::new($false).GetBytes($statement);$s=[IO.File]::Open($sqlFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$s.Write($b);$s.Flush($true)}finally{$s.Dispose()}
   Budget 1MB;$holder=Start-OwnedCapturedProcess -Program $psql -ProgramSha256 $c.psql_sha -Arguments @('-X','-qAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-h','127.0.0.1','-p','5465','-U','pi_admin','-w','-d',$holdDb,'-f',$sqlFile) -WorkingDirectory $pkg -OutputDirectory $out -Label ($tag+'-holder') -MaxOutputBytes 1MB -Environment @{PGPASSWORD=$secret.admin_password;PGAPPNAME=$nonce;PGOPTIONS='-c statement_timeout=60000'};$holderComplete=$false
   $ready=[DateTime]::UtcNow.AddSeconds(5);do{$connections=@(Get-NetTCPConnection -State Established -OwningProcess $holder.Process.Id -ErrorAction SilentlyContinue|Where-Object {$_.RemotePort -eq 5465 -and $_.RemoteAddress -eq '127.0.0.1'});if($connections.Count -eq 1){break};if($holder.Process.HasExited -or [DateTime]::UtcNow -ge $ready){throw 'holders_actual_client_socket_not_ready'};Start-Sleep -Milliseconds 50}while($true)
   $cim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$holder.Process.Id);if(!$cim -or $cim.ExecutablePath -cne $psql -or $holder.Process.StartTime.ToUniversalTime().ToString('o') -cne $holder.Record.native_creation_utc){throw 'holders_retained_native_client_identity'}
   $port=[int]$connections[0].LocalPort;$query="SELECT jsonb_build_object('pid',a.pid,'backend_start',a.backend_start,'datname',a.datname,'usename',a.usename,'application_name',a.application_name,'client_port',a.client_port,'state',a.state,'wait_event',a.wait_event,'query',a.query,'locks',(SELECT jsonb_agg(jsonb_build_object('locktype',l.locktype,'mode',l.mode,'granted',l.granted,'relation',l.relation::regclass::text,'classid',l.classid::text,'objid',l.objid::text,'objsubid',l.objsubid) ORDER BY l.locktype,l.mode) FROM pg_locks l WHERE l.pid=a.pid)) FROM pg_stat_activity a WHERE a.datname=current_database() AND a.application_name='"+$nonce+"' AND a.client_port="+$port+';'
   [void](Sql $holdDb ($tag+'-actual-holder-witness') @('-c',$query) 1MB);$witness=Get-Content (Join-Path $out ($tag+'-actual-holder-witness.stdout')) -Raw|ConvertFrom-Json -DateKind String
   if(!$witness -or $witness.pid -le 0 -or !$witness.backend_start -or $witness.datname -cne $holdDb -or $witness.usename -cne 'pi_admin' -or $witness.application_name -cne $nonce -or $witness.client_port -ne $port -or $witness.wait_event -cne 'PgSleep' -or $witness.query.Trim() -cne 'SELECT pg_sleep(25);'){throw 'holders_actual_backend_sleep_binding'}
   if($tag -cin @('source-lease','restore-lease')){$lock=@($witness.locks|Where-Object {$_.locktype -ceq 'advisory' -and $_.mode -ceq 'ExclusiveLock' -and $_.granted -and $_.classid -ceq '1346985073' -and $_.objid -ceq '3114631508' -and $_.objsubid -eq 1});if($lock.Count -ne 1){throw 'holders_exact_advisory_LEASE_witness'}}else{$mode=if($tag -ceq 'row-writer'){'RowExclusiveLock'}else{'AccessExclusiveLock'};if(@($witness.locks|Where-Object {$_.relation -ceq 'pi_kv' -and $_.mode -ceq $mode -and $_.granted}).Count -ne 1){throw 'holders_exact_table_lock_witness'}}
   Write-OwnedJson (Join-Path $out ($tag+'-native-backend-binding.json')) @{native_pid=$holder.Process.Id;native_creation=$holder.Record.native_creation_utc;cim_creation=$cim.CreationDate.ToUniversalTime().ToString('o');image=$cim.ExecutablePath;local_port=$port;remote_port=5465;backend=$witness;holder_SQL_sha256=Get-OwnedHash $sqlFile;job_basis='Source-reviewed no-breakaway inheritance from independently admitted outer waiting worker; NOT direct outer Job.Member assertion';admin_witness_native_closed_before_apply=$true}
   [void](Cleanup ($tag+'-apply-refusal') 'apply' $cli 1 'cleanup_busy')
   $againClient=Get-CimInstance Win32_Process -Filter ('ProcessId='+$holder.Process.Id)
   if($holder.Process.HasExited -or !$againClient -or $againClient.ExecutablePath -cne $psql -or $holder.Process.StartTime.ToUniversalTime().ToString('o') -cne $holder.Record.native_creation_utc -or @((Get-NetTCPConnection -State Established -OwningProcess $holder.Process.Id -ErrorAction Stop)|Where-Object {$_.LocalPort -eq $port -and $_.RemotePort -eq 5465 -and $_.RemoteAddress -eq '127.0.0.1'}).Count -ne 1){throw 'holders_cancel_client_binding_lost'}
   # A separate admin session re-binds PID+start+nonce+port before targeted cancellation.
   $where="pid="+[string][int]$witness.pid+" AND datname='"+$holdDb+"' AND usename='pi_admin' AND application_name='"+$nonce+"' AND client_port="+$port+" AND backend_start='"+$witness.backend_start+"'::timestamptz"
   [void](Sql $holdDb ($tag+'-cancel-exact-backend') @('-c',("SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE "+$where+';')) 1MB)
   if((Get-Content (Join-Path $out ($tag+'-cancel-exact-backend.stdout')) -Raw).Trim() -cne 't'){throw 'holders_cancel_target_not_rewitnessed'}
   if(!$holder.Process.WaitForExit(10000)){throw 'holders_canceled_client_exit_timeout'};$cancel=Complete-OwnedCapturedProcess $holder;$holderComplete=$true
   if($cancel.native_exit -notin @(1,3) -or !$cancel.stdout_complete -or !$cancel.stderr_complete -or $cancel.output_limit -or $cancel.capture_fault -or $cancel.drain_timeout){throw 'holders_actual_canceled_client_native'}
   $err=Get-Content (Join-Path $out ($tag+'-holder.stderr')) -Raw;if($err -cnotmatch '57014' -or $err -cnotmatch 'canceling statement due to user request'){throw 'holders_actual_user_cancel_SQLSTATE'}
   [void](Sql 'postgres' ($tag+'-backend-gone') @('-c',('SELECT count(*) FROM pg_stat_activity WHERE pid='+[string][int]$witness.pid+';')) 1MB);if((Get-Content (Join-Path $out ($tag+'-backend-gone.stdout')) -Raw).Trim() -cne '0'){throw 'holders_backend_must_be_gone_before_full_POST'}
  }
  if(Test-Path $receipt){throw 'holders_refusal_created_receipt'}
  $sa=State $src ($tag+'-source-post');$ra=State $dst ($tag+'-restore-post');EqualState $sp $sa;EqualState $rp $ra;EqualState $sc (State $src ($tag+'-source-catalog-post') $true);EqualState $rc (State $dst ($tag+'-restore-catalog-post') $true)
  $row=@{case=$tag;status='FINITE_SMALLS_HOLDER_OR_DEFAULT_PRIVILEGE_REFUSAL_PENDING_QA_TD';source_pre=$sp;source_post=$sa;restore_pre=$rp;restore_post=$ra;actual_holder=$witness;cancel_native=$cancel;whole_catalog_unchanged=$true;single_attempt_per_named_cleanup_operation=$true;cleanup_invocation_count=$(if($tag -ceq 'identity-privilege'){3}else{2});automatic_retry_basis='Source/runtime call count only; refusal JSON has no automatic_retry field';no_lock2_or_C17_credit=$true};Write-OwnedJson (Join-Path $out ($tag+'-result.json')) $row;$results+=$row
 }
 Write-OwnedJson (Join-Path $out 'small-holders-result.json') @{status='FIVE_SMALLS_CASES_EVIDENCE_PENDING_QA_TD';cases=$results;limits=@('No fullhistorical/C08/SQL5/lock2/C17/browser or release acceptance','Other-client offline gate is distinct from lock_timeout','No GRANT/REVOKE/passwordreset/old login/SQL or fallback URL','All actual witness/refusal/cancel/fullPOST evidence independently reviewed')}
}finally{
 try{if($holder -and !$holderComplete){$wasAlive=!$holder.Process.HasExited;if($wasAlive){$holder.Process.Kill($true)};if(!$holder.Process.WaitForExit(10000)){throw 'holders_final_owned_client_stop'};$n=Complete-OwnedCapturedProcess $holder;Write-OwnedJson (Join-Path $out 'holder-failure-forced-stop.json') @{native=$n;forced=$wasAlive;no_success_credit=$true}}}finally{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'};$secret=$null}
}
# SOURCE-ONLY. Prospective native/source/config/resource/SQL registry QA+TD required.
# Exact advisory classid/objid constants must match unsigned high/low LEASE5785256839849804116.
# Holder nonce/clientport/backend_start/clientnative identity and closed admin witness
# precede Apply. Cancel only exact owned backend; no arbitrary kill/query rewriting.
# Defaultpi_app must ACTUALLY fail pg_control_system42501; otherwise STOP, never revoke.
# Finally forced client kill is retained failure evidence only, not successful cancellation.
