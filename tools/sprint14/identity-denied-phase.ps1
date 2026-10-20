param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY single Council-adopted NEW synthetic identity-denial fixture.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'identity_denied_config_preimport'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('owned-phase-support.psm1',$c.phase_support_sha),@('owned-stock-service.psm1',$c.service_sha),@('resource-phase-budget.psm1',$c.phase_budget.module_sha))){if($p[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1].ToUpperInvariant()){throw 'identity_denied_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-stock-service.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'resource-phase-budget.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha;Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's14-new-synthetic-identity-denial' -or $c.version -cne '0.7.3' -or $c.pg_port -ne 5475 -or $c.app_port -ne 3098 -or $c.database -cne 'process_intelligence'){throw 'identity_denied_finite_scope'}
if($c.app_sha -cne '23563DFF8FE93F339AD7F12FD0783AC3E2C53B8D9368C00D772A8FBABBE5F292' -or $c.package_sha -cne 'E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C'){throw 'identity_denied_existing_candidate_only'}
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..');$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
if($c.source_db -cne 'pi_restore_s14_identity_source01' -or $c.restore_db -cne 'pi_restore_s14_identity_restore01' -or $out -cne (Get-OwnedCanonicalPath (Join-Path $workspace '.local/sprint14/root/identity-denied01')) -or (Get-OwnedCanonicalPath $c.install_parent) -cne (Get-OwnedCanonicalPath (Join-Path $workspace '.local/sprint14/root/identity-denied-install01'))){throw 'identity_denied_proposal_exact_NEW_names'}
function ReadIdentityProof($Pin){Assert-OwnedNoReparse $Pin.path;Assert-OwnedHash $Pin.path $Pin.sha256;Assert-OwnedPrivateDirectory (Split-Path -Parent $Pin.path);if((Get-Item $Pin.path).Length -gt 4MB){throw 'identity_proof_bound'};return Get-Content $Pin.path -Raw|ConvertFrom-Json -AsHashtable -DateKind String}
$proposalSha='362211D51D1B6C0AD8954EC4ADC36AD47F26131A7278A6C54EB73717021CE8BA';$decisionSha='F4259C41FF916A0A0B45EF1F7FC14045D1F1F047139BC70907286F19F8338F96'
if((Get-OwnedCanonicalPath $c.identity_decision.path) -cne (Get-OwnedCanonicalPath (Join-Path $workspace '.local/sprint14/root/identity-decision01.json')) -or $c.identity_decision.sha256 -cne $decisionSha){throw 'identity_denied_actual_decision_pin'}
$decision=ReadIdentityProof $c.identity_decision
if($decision.author_role -cne 'Root' -or $decision.verdict -cne 'ADOPTED_SINGLE_NEW_SYNTHETIC_IDENTITY_DENIAL_FIXTURE' -or $decision.proposal.sha256 -cne $proposalSha -or (Get-OwnedCanonicalPath $decision.proposal.path) -cne (Get-OwnedCanonicalPath (Join-Path $workspace '.local/sprint14/root/identity-proposal01.json')) -or $decision.for -ne 5 -or $decision.against -ne 0 -or $decision.abstain -ne 0 -or @($decision.votes).Count -ne 5 -or (@($decision.votes.author_role|Sort-Object)-join ',') -cne 'Customer,PM,QA,Root,TD'){throw 'identity_denied_actual_fixed_five_adoption'}
$proposal=ReadIdentityProof $decision.proposal
$revoke='REVOKE EXECUTE ON FUNCTION pg_catalog.pg_control_system() FROM PUBLIC;'
if($proposal.scope -cne 'S14_IDENTITY_NEGATIVE_SYNTHETIC_FIXTURE_POLICY_AMENDMENT' -or $proposal.exception.only_acl_mutation_sql -cne $revoke -or $proposal.exception.only_acl_mutation_database -cne $c.source_db -or $proposal.exception.new_source_database -cne $c.source_db -or $proposal.exception.new_restore_database -cne $c.restore_db -or $proposal.exception.new_output -cne $out -or $proposal.exception.new_install_parent -cne $c.install_parent -or !$proposal.exception.no_grant_or_acl_reset -or !$proposal.exception.leave_fixture_cold){throw 'identity_denied_exact_single_fixture_exception'}
foreach($v in $decision.votes){$vote=ReadIdentityProof $v;$actual=if($vote.ContainsKey('vote')){$vote.vote}else{$vote.verdict};if($v.vote -cne 'FOR' -or $vote.author_role -cne $v.author_role -or $vote.proposal_sha256 -cne $proposalSha -or $actual -cne 'FOR' -or $v.authored_verdict -cne $vote.verdict){throw 'identity_denied_actual_authored_vote'}}
$names=@($c.source_db,$c.restore_db)
foreach($db in $names){if($db -cnotmatch '^pi_restore_s14_[a-z0-9_]{1,35}$'){throw 'identity_denied_new_database'}}
if($names[0] -ceq $names[1]){throw 'identity_denied_distinct_databases'}
if($c.small_archive_sha -cne 'A18E0BF2E061B350B0918D9116BBC4F7C0E46EE8F28FDF0C7FA342BA725A030C' -or $c.small_manifest_sha -cne '0F21A1FBDBFACCF03C7C666ABF977B0605A6EA7704BDE1D3D1A5EF52846EDACA'){throw 'identity_denied_exact_seed02'}
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedHash $c.acl_sql $c.acl_sql_sha
if((Get-OwnedCanonicalPath $c.acl_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'identity-denied-acl.sql'))){throw 'identity_denied_exact_acl_source'}
foreach($role in @('QA','TD')){$r=ReadIdentityProof $c.identity_reviews[$role];if($r.author_role -cne $role -or $r.verdict -cne 'PROSPECTIVE_EXACT_SINGLE_NEW_IDENTITY_DENIAL_FIXTURE_GO' -or $r.identity_decision_sha256 -cne $decisionSha -or $r.proposal_sha256 -cne $proposalSha -or $r.phase_sha256 -cne (Get-OwnedHash $PSCommandPath) -or $r.acl_sql_sha256 -cne $c.acl_sql_sha -or $r.probe_sha256 -cne $c.probe_sha -or $r.package_sha256 -cne $c.package_sha -or $r.source_db -cne $c.source_db -or $r.restore_db -cne $c.restore_db -or $r.output_directory -cne $out -or $r.install_parent -cne $c.install_parent -or $r.only_acl_mutation_sql -cne $revoke){throw 'identity_denied_actual_exact_source_config_prospective'}}
foreach($p in @(@($c.small_archive,$c.small_archive_sha),@(($c.small_archive+'.manifest.json'),$c.small_manifest_sha),@($c.pwsh,$c.pwsh_sha),@($c.stdio_wrapper,$c.stdio_sha),@($c.node,$c.node_sha),@($c.probe,$c.probe_sha),@($c.capture_sql,$c.capture_sql_sha),@($c.catalog_sql,$c.catalog_sql_sha))){Assert-OwnedHash $p[0] $p[1]}
if((Get-OwnedCanonicalPath $c.probe) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'identity-denied-probe.cjs')) -or (Get-OwnedCanonicalPath $c.capture_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'managed-state.sql')) -or (Get-OwnedCanonicalPath $c.catalog_sql) -cne (Get-OwnedCanonicalPath (Join-Path $PSScriptRoot 'logical-catalog.sql'))){throw 'identity_denied_source_paths'}
$started=[DateTime]::UtcNow;$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($c.required_free_bytes -ne 8GB -or $c.runtime_floor_bytes -ne 8GB -or $deadline -gt [DateTimeOffset]::Parse('2026-10-20T09:54:16Z').UtcDateTime -or $started -ge $deadline -or $c.capture_reservation_bytes -ne 512MB -or $c.phase_reservation_bytes -gt 2GB){throw 'identity_denied_resource_freeze'}
$resource=New-S14PhaseBudget -Config $c -ConfigPath $PhaseConfig -ConfigSha $PhaseConfigSha -PhasePath $PSCommandPath -Deadline $deadline -Started $started
function Budget([long]$Next=0){Assert-S14PhaseBudget -Proof $resource -Next $Next}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$m=Get-Content (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json
if($m.version -cne '0.7.3' -or $m.source_commit -cne $c.source_commit){throw 'identity_denied_candidate'}
$app=Join-Path $pkg 'process-intelligence-rs.exe';$psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe';$backup=Join-Path $pkg 'tools/database-backup.ps1'
Assert-OwnedHash $app $c.app_sha;Assert-OwnedHash $psql $c.psql_sha;Assert-OwnedHash $backup $c.backup_sha
$service=$null;$secret=$null;$success=$false;$script:usedRevoke=$false
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment=@{},[int[]]$Exits=@(0),[int]$Seconds=120,[long]$Cap=8MB){
 Budget $Cap;$p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $until=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(!$p.Process.WaitForExit(100)){if([DateTime]::UtcNow -ge $until -or [DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -ge 1800 -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'identity_denied_child_stop'};break}}
 $r=Complete-OwnedCapturedProcess $p;Write-OwnedJson (Join-Path $out ($Label+'-native.json')) @{native=$r;forced=$forced;single_invocation=$true}
 if($forced -or $r.native_exit -notin $Exits -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw ('identity_denied_native_'+$Label)};Budget;return $r
}
function Sql([string]$Db,[string]$Label,[string[]]$Arguments,[long]$Cap=8MB,[string]$User='pi_admin',[int[]]$Exits=@(0),[bool]$Writable=$false){
 if($Db -cnotin ($names+@('postgres'))){throw 'identity_denied_SQL_scope'}
 if($User -cnotin @('pi_admin','pi_app')){throw 'identity_denied_SQL_role'}
 if($Writable -and ($Db -cne $c.source_db -or $User -cne 'pi_admin' -or $Label -cne 'one-source-function-revoke' -or $Arguments.Count -ne 2 -or $Arguments[0] -cne '-c' -or $Arguments[1] -cne $revoke)){throw 'identity_denied_only_one_literal_revoke'}
 if($Writable){if($script:usedRevoke){throw 'identity_denied_no_revoke_retry'};$script:usedRevoke=$true}
 [string[]]$argv=@('-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-h','127.0.0.1','-p','5475','-U',$User,'-w','-d',$Db)+$Arguments
 $pw=if($User -ceq 'pi_app'){$secret.app_password}else{$secret.admin_password};$options=if($Writable){'-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c TimeZone=UTC -c DateStyle=ISO,YMD'}else{'-c statement_timeout=60000 -c default_transaction_read_only=on -c TimeZone=UTC -c DateStyle=ISO,YMD'}
 return Native -Label $Label -Program $psql -Sha $c.psql_sha -Arguments $argv -Environment @{PGPASSWORD=$pw;PGOPTIONS=$options} -Cap $Cap -Exits $Exits
}
function State([string]$Db,[string]$Label,[bool]$Catalog=$false){Budget 8MB;$sql=if($Catalog){$c.catalog_sql}else{$c.capture_sql};$r=Sql $Db $Label @('-f',$sql);return @{path=Join-Path $out ($Label+'.stdout');bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256}}
function EqualState($a,$b){if($a.bytes -ne $b.bytes -or $a.sha256.ToUpperInvariant() -cne $b.sha256.ToUpperInvariant()){throw 'identity_denied_full_state_or_catalog_changed'}}
function Stock([string]$Label,[hashtable]$Fields){[string[]]$argv=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Fields|ConvertTo-Json -Compress));[void](Native -Label $Label -Program $c.pwsh -Sha $c.pwsh_sha -Arguments $argv -Seconds 180)}
function URL([string]$Db,[string]$User='pi_admin'){$pw=if($User -ceq 'pi_app'){$secret.app_password}else{$secret.admin_password};return "host=127.0.0.1 port=5475 user=$User password=$pw dbname=$Db connect_timeout=5 application_name=s14_identity_denied"}
function Cleanup([string]$Label,[string]$Mode,[hashtable]$Environment,[int]$Exit){
 [void](Native -Label $Label -Program $app -Sha $c.app_sha -Arguments @('--cleanup-storage-'+$Mode) -Environment $Environment -Exits @($Exit) -Seconds 300 -Cap 1MB)
 $v=Get-Content (Join-Path $out ($Label+'.stdout')) -Raw|ConvertFrom-Json
 if($Exit -eq 1){if($v.outcome -cne 'cleanup_refused' -or $v.code -cne 'cleanup_storage_unavailable' -or @($v.PSObject.Properties).Count -ne 3){throw 'identity_denied_exact_cleanup_storage_unavailable'}}elseif($v.outcome -cne 'cleanup_verified' -or $v.candidate_rows -ne 2){throw 'identity_denied_initial_Verify2'};return $v
}
function ACL([string]$Db,[string]$Label){Budget 32MB;$r=Sql $Db $Label @('-f',$c.acl_sql) 32MB;return @{path=Join-Path $out ($Label+'.stdout');bytes=$r.stdout_bytes_persisted;sha256=$r.stdout_sha256}}
function ACLOracle([string]$Mode,$Sources){$cfg=@{scope=$c.scope;mode=$Mode;source_db=$c.source_db;restore_db=$c.restore_db};foreach($k in $Sources.Keys){$cfg[$k]=$Sources[$k]};$p=Join-Path $out ($Mode+'-acl-config.json');Write-OwnedJson $p $cfg;[void](Native -Label ($Mode+'-exact-acl-oracle') -Program $c.node -Sha $c.node_sha -Arguments @($c.probe,$p) -Environment @{PI_IDENTITY_DENIED_CONFIG_SHA=(Get-OwnedHash $p).ToLowerInvariant()} -Seconds 60 -Cap 1MB);$r=Get-Content (Join-Path $out ($Mode+'-exact-acl-oracle.stdout')) -Raw|ConvertFrom-Json;if($r.status -cne 'EXACT_ONLY_SOURCE_FUNCTION_PUBLIC_EXECUTE_REMOVAL_PENDING_QA_TD' -or $r.public_execute_removed -ne 1 -or !$r.owner_and_all_other_grants_preserved -or !$r.all_other_raw_acl_fields_equal -or !$r.restore_whole_acl_equal){throw 'identity_denied_exact_acl_oracle_required'}}
try{
 $service=Start-OwnedStockService $c $pkg 'identity-stock';[void](Wait-OwnedStockService $service)
 $boot=@($service.Processes|Where-Object Name -ceq 'app');$pg=@($service.Processes|Where-Object Name -ceq 'postgres');if($boot.Count -ne 1 -or $pg.Count -ne 1 -or !$service.Job.Member($boot[0].Handle)){throw 'identity_denied_bootstrap_identity'}
 $boot[0].Process.Kill();if(!$boot[0].Process.WaitForExit(10000)){throw 'identity_denied_bootstrap_stop'}
 Write-OwnedJson (Join-Path $out 'bootstrap-app-forced-stop.json') @{pid=$boot[0].Process.Id;native_exit=$boot[0].Process.ExitCode;controlled_forced_stop=$true;no_clean_app_exit_claim=$true}
 if(@(Get-NetTCPConnection -State Listen -LocalPort 3098 -ErrorAction SilentlyContinue).Count){throw 'identity_denied_bootstrap_listener'}
 $pgCim=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pg[0].Process.Id);if(!$pgCim -or $pg[0].Process.HasExited -or $pgCim.ExecutablePath -cne (Join-Path $pkg 'runtime/postgresql/pgsql/bin/postgres.exe') -or $pg[0].Process.StartTime.ToUniversalTime().ToString('o') -cne $pg[0].Creation){throw 'identity_denied_actual_PG_identity'}
 Wait-OwnedReadyJob @(@{name='postgres';pid=$pg[0].Process.Id;creation_utc=$pgCim.CreationDate.ToUniversalTime().ToString('o')}) $out
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json;if($secret.port -ne 5475){throw 'identity_denied_private_port'}
 foreach($pair in @(@('source',$c.source_db),@('restore',$c.restore_db))){$label='absent-'+$pair[0];[void](Sql 'postgres' $label @('-c',("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='"+$pair[1]+"');")));if((Get-Content (Join-Path $out ($label+'.stdout')) -Raw).Trim() -cne 'f'){throw 'identity_denied_database_not_new'}}
 $seed=Join-Path $pkg '.local/identity-small.dump';[IO.File]::Copy($c.small_archive,$seed,$false);[IO.File]::Copy(($c.small_archive+'.manifest.json'),($seed+'.manifest.json'),$false);$sm=Get-Content ($seed+'.manifest.json') -Raw|ConvertFrom-Json
 Stock 'restore-source' @{Mode='Restore';Database=$sm.database;TargetDatabase=$c.source_db;BackupFile=$seed}
 $archive=Join-Path $pkg '.local/identity-source.dump';Stock 'backup-source' @{Mode='Backup';Database=$c.source_db;BackupFile=$archive};Stock 'restore-verification' @{Mode='Restore';Database=$c.source_db;TargetDatabase=$c.restore_db;BackupFile=$archive}
 $sp=State $c.source_db 'source-pre';$rp=State $c.restore_db 'restore-pre';EqualState $sp $rp;$sc=State $c.source_db 'source-catalog-pre' $true;$rc=State $c.restore_db 'restore-catalog-pre' $true;EqualState $sc $rc
 $plan=Join-Path $pkg '.local/identity.plan.json';$receipt=Join-Path $pkg '.local/identity.receipt.json';$admin=@{PI_DATABASE_URL=URL $c.source_db;PI_CLEANUP_RESTORE_URL=URL $c.restore_db;PI_CLEANUP_ARCHIVE=$archive;PI_CLEANUP_PLAN=$plan;PI_CLEANUP_RECEIPT=$receipt}
 [void](Cleanup 'admin-verify-before-denial' 'verify' $admin 0);$planSha=Get-OwnedHash $plan
 $identityFile=Join-Path $out 'actual-identity-function.sql';$b=[Text.UTF8Encoding]::new($false).GetBytes("SELECT jsonb_build_object('user',current_user,'system_identifier',(pg_catalog.pg_control_system()).system_identifier::text,'database',current_database(),'database_oid',(SELECT oid::text FROM pg_database WHERE datname=current_database()));`n");$f=[IO.File]::Open($identityFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$f.Write($b);$f.Flush($true)}finally{$f.Dispose()}
 [void](Sql $c.source_db 'admin-identity-before' @('-f',$identityFile) 1MB);[void](Sql $c.source_db 'default-app-identity-before' @('-f',$identityFile) 1MB 'pi_app')
 $ib=Get-Content (Join-Path $out 'admin-identity-before.stdout') -Raw|ConvertFrom-Json;$appBefore=Get-Content (Join-Path $out 'default-app-identity-before.stdout') -Raw|ConvertFrom-Json
 if($ib.user -cne 'pi_admin' -or $appBefore.user -cne 'pi_app' -or $ib.database -cne $c.source_db -or $appBefore.database -cne $c.source_db -or $ib.database_oid -cne $appBefore.database_oid -or $ib.system_identifier -cne $appBefore.system_identifier){throw 'identity_denied_actual_default_app_success_required'}
 $sb=ACL $c.source_db 'source-acl-before';$rb=ACL $c.restore_db 'restore-acl-before'
 [void](Sql $c.source_db 'one-source-function-revoke' @('-c',$revoke) 1MB 'pi_admin' @(0) $true)
 $ss=ACL $c.source_db 'source-acl-setup';$rs=ACL $c.restore_db 'restore-acl-setup';EqualState $rb $rs
 $aclInputs=@{source_before=$sb;restore_before=$rb;source_setup=$ss;restore_setup=$rs};ACLOracle 'setup' $aclInputs
 EqualState $sp (State $c.source_db 'source-setup');EqualState $rp (State $c.restore_db 'restore-setup');EqualState $sc (State $c.source_db 'source-catalog-setup' $true);EqualState $rc (State $c.restore_db 'restore-catalog-setup' $true)
 [void](Sql $c.source_db 'admin-identity-after' @('-f',$identityFile) 1MB)
 $ia=Get-Content (Join-Path $out 'admin-identity-after.stdout') -Raw|ConvertFrom-Json
 if(($ia|ConvertTo-Json -Compress) -cne ($ib|ConvertTo-Json -Compress)){throw 'identity_denied_admin_identity_changed'}
 [void](Sql $c.source_db 'restricted-app-actual-42501' @('-f',$identityFile) 1MB 'pi_app' @(3))
 if((Get-Item (Join-Path $out 'restricted-app-actual-42501.stdout')).Length -ne 0 -or (Get-Content (Join-Path $out 'restricted-app-actual-42501.stderr') -Raw) -cnotmatch '42501:.*permission denied for function pg_control_system'){throw 'identity_denied_actual_verbose_permission_error_required'}
 $failedPlan=Join-Path $pkg '.local/identity-no-new.plan.json';$limited=@{PI_DATABASE_URL=URL $c.source_db 'pi_app';PI_CLEANUP_RESTORE_URL=URL $c.restore_db 'pi_app';PI_CLEANUP_ARCHIVE=$archive;PI_CLEANUP_PLAN=$failedPlan;PI_CLEANUP_RECEIPT=$receipt}
 [void](Cleanup 'limited-verify-refusal' 'verify' $limited 1);if(Test-Path $failedPlan){throw 'identity_denied_refusal_created_plan'}
 $limited.PI_CLEANUP_PLAN=$plan;$limited.PI_CLEANUP_CONFIRM_SHA=$planSha;Assert-OwnedHash $plan $planSha;[void](Cleanup 'valid-old-plan-apply-refusal' 'apply' $limited 1)
 if(Test-Path $receipt){throw 'identity_denied_refusal_created_receipt'};Assert-OwnedHash $plan $planSha
 $sourcePost=State $c.source_db 'source-post';$restorePost=State $c.restore_db 'restore-post';EqualState $sp $sourcePost;EqualState $rp $restorePost;EqualState $sc (State $c.source_db 'source-catalog-post' $true);EqualState $rc (State $c.restore_db 'restore-catalog-post' $true)
 $sa=ACL $c.source_db 'source-acl-post';$ra=ACL $c.restore_db 'restore-acl-post';EqualState $ss $sa;EqualState $rb $ra;$aclInputs.source_after=$sa;$aclInputs.restore_after=$ra;ACLOracle 'final' $aclInputs
 foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256};Budget
 Write-OwnedJson (Join-Path $out 'identity-denied-result.json') @{status='SINGLE_NEW_SYNTHETIC_IDENTITY_DENIAL_EVIDENCE_PENDING_QA_TD';identity_decision_sha256=$decisionSha;proposal_sha256=$proposalSha;default_app_identity_succeeded_before=$true;admin_identity_unchanged=$true;restricted_native_exit=3;actual_sqlstate='42501';limited_verify_code='cleanup_storage_unavailable';valid_old_plan_apply_code='cleanup_storage_unavailable';plan_sha256=$planSha;source_pre=$sp;source_post=$sourcePost;restore_pre=$rp;restore_post=$restorePost;source_acl_before=$sb;source_acl_setup=$ss;source_acl_post=$sa;restore_acl_before=$rb;restore_acl_setup=$rs;restore_acl_post=$ra;acl_mutation_count=1;acl_reset_attempted=$false;limits=@('One explicit new synthetic SOURCE function PUBLIC EXECUTE revoke, no product/default restriction claim','Real native42501 and exactly one invocation each refusal; no grant/reset/retry','Complete managed/publiccatalog + complete raw/effective ACL oracle separately required','Old C13 failure untouched; no whole C13/R3/release acceptance')};$success=$true
}finally{if($service -and !$service.StopAttempted){Stop-OwnedStockService $service 'fixture-finalization'};$secret=$null}
if(!$success){throw 'identity_denied_incomplete_retained'}
Write-OwnedJson (Join-Path $out 'closed-phase-budget.json') (Get-S14ClosedPhaseBudgetTotals $resource)
# SOURCE ONLY: adoption is fixture policy, not source/config/resource admission.
# No old DB/cluster or system ACL is touched. No GRANT/reset; leave NEW fixture cold.
