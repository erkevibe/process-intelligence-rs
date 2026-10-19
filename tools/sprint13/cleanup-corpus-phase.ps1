param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# Developer draft: execute only through the independently reviewed S13 owned worker/Job.
# This file implements SMALL-S cases only. Full history, holder/proxy faults and clone5466 are separate.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'phase_config_before_import'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in @(@((Join-Path $PSScriptRoot 'owned-runtime.psm1'),$c.module_sha),@((Join-Path $PSScriptRoot 'owned-phase-support.psm1'),$c.phase_support_sha))){if($pin[1] -cnotmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $pin[0]).Hash -cne $pin[1].ToUpperInvariant()){throw 'phase_module_pin_before_import'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
$workspace=Get-OwnedCanonicalPath (Join-Path $PSScriptRoot '../..')
if((Get-OwnedCanonicalPath $c.install_parent).StartsWith($out.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Get-OwnedCanonicalPath $c.install_parent) -ceq $out){throw 'package_and_evidence_must_be_separate_new_s13_paths'}
if($c.scope -cne 's13-small-cleanup-corpus' -or $c.port -ne 5465 -or $c.version -cne '0.7.3' -or $c.source_commit -cnotmatch '^[a-f0-9]{40}$' -or $c.max_phase_seconds -lt 1 -or $c.max_phase_seconds -gt 1800){throw 'finite_small_corpus_scope'}
if(!$out.StartsWith((Join-Path $workspace '.local/sprint13/'),[StringComparison]::OrdinalIgnoreCase)){throw 's13_output_boundary'}
$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($deadline -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or [DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 8GB){throw 'small_corpus_time_capacity'}
$started=[DateTime]::UtcNow
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Assert-OwnedHash $c.pwsh $c.pwsh_sha;Assert-OwnedHash $c.stdio_wrapper $c.stdio_sha
Assert-OwnedHash $c.crosswalk $c.crosswalk_sha
$crosswalk=Get-Content -LiteralPath $c.crosswalk -Raw|ConvertFrom-Json -DateKind String
$implemented=@('C01','C03','C04','C06.archive_byte','C06.manifest_sha','C06.manifest_size','C06.archive_substitution','C07','C08.restore_value','C09','C10','C11.marker_source_sha','C11.marker_checksum','C11.unknown_legacy_key','C11.missing_header','C12.ledger1','C12.malformed_stage','C12.future_schema','C12.trigger','C12.rls','C12.rule','C14','C15.stale_plan_sha','C15.wrong_confirmation','C15.plan_identity_changed','C16.managed_rows.at','C16.managed_rows.over','C16.key_utf8_bytes.at','C16.key_utf8_bytes.over','C16.plan_bytes.at','C16.plan_bytes.over','operator.receipt_fail')
if(!$c.cases -or $c.cases.Count -gt $implemented.Count -or @($c.cases|Sort-Object -Unique).Count -ne $c.cases.Count -or @($c.cases|Where-Object {$_ -cnotin $implemented}).Count){throw 'finite_case_selection'}
foreach($id in $c.cases){if($id -cne 'operator.receipt_fail' -and @($crosswalk.cleanup_cases|Where-Object id -ceq $id).Count -ne 1){throw 'case_crosswalk_missing'}}
Write-OwnedJson (Join-Path $out 'corpus-not-executed-initial.json') @{status='S13_NOT_EXECUTED_INITIAL';selected_cases=@($c.cases);original_crosswalk_sha=$c.crosswalk_sha;implemented_source_selections=$implemented;all_original_cases=@($crosswalk.cleanup_cases|ForEach-Object {@{id=$_.id;status='NOT_EXECUTED_INITIAL'}});scope='Schedule/source capability is not executed evidence or acceptance';delegated_clone_port=5466}
Assert-OwnedHash $c.small_archive $c.small_archive_sha;Assert-OwnedHash ($c.small_archive+'.manifest.json') $c.small_manifest_sha
Assert-OwnedHash $c.fixture_review $c.fixture_review_sha
$fixture=Get-Content -LiteralPath $c.fixture_review -Raw|ConvertFrom-Json -AsHashtable -DateKind String
if($fixture.status -cne 'S13_MAINTAINED_SMALL_S_INPUT_REVIEWED' -or $fixture.candidates.Count -ne 2 -or ((@($fixture.candidates.source_version|Sort-Object) -join ',') -cne '7,11') -or $fixture.all_record_kinds -ne $true -or $fixture.normal_auth -ne $true -or $fixture.project_list_exercised -ne $true -or $fixture.generic_key -cne 'fixture/keep' -or $fixture.archive_sha -cne $c.small_archive_sha -or $fixture.manifest_sha -cne $c.small_manifest_sha){throw 'actual_independent_small_s_required'}
foreach($candidate in $fixture.candidates){if($candidate.key -cnotmatch '^repository/project-[a-f0-9]{32}$' -or $candidate.source_sha -cnotmatch '^[a-f0-9]{64}$' -or $candidate.checksum -cnotmatch '^[a-f0-9]{64}$'){throw 'small_candidate_binding'}}
if((Get-Item -LiteralPath $c.small_archive).Length -gt 32MB -or (Get-Item -LiteralPath $c.fixture_review).Length -gt 1MB){throw 'small_input_bound'}
if(@(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object LocalPort -eq 5465).Count){throw 'new_pg_port_required'}
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$manifest=Get-Content -LiteralPath (Join-Path $pkg 'build-manifest.json') -Raw|ConvertFrom-Json -DateKind String
if($manifest.source_commit -cne $c.source_commit -or $manifest.version -cne '0.7.3'){throw 'exact_current_candidate_manifest'}
$bin=Join-Path $pkg 'runtime/postgresql/pgsql/bin';$psql=Join-Path $bin 'psql.exe';$postgres=Join-Path $bin 'postgres.exe';$data=Join-Path $pkg '.local/pgdata'
$exe=Join-Path $pkg 'process-intelligence-rs.exe';Assert-OwnedHash $exe $c.cleanup_sha
$backup=Join-Path $pkg 'tools/database-backup.ps1';Assert-OwnedHash $backup $c.backup_sha
$setup=Join-Path $pkg 'tools/setup-postgres.ps1';Assert-OwnedHash $setup $c.setup_sha
$pgProcess=$null;$pg=$null;$secret=$null;$admin=$null;$envCli=$null;$activeCase='bootstrap'
try{
[void](Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$c.stdio_wrapper,'-Script',$setup,'-ScriptSha',$c.setup_sha,'-Proof',(Join-Path $out 'bootstrap-stdio.json'),'-ArgumentsJson',(@{Port=5465}|ConvertTo-Json -Compress)) $pkg $out 'bootstrap' @{} 120 4MB)
$listeners=@(Get-NetTCPConnection -LocalPort 5465 -State Listen)
if(@($listeners.OwningProcess|Sort-Object -Unique).Count -ne 1 -or @($listeners|Where-Object LocalAddress -cne '127.0.0.1').Count){throw 'actual_new_pg_listener'}
$pg=Get-CimInstance Win32_Process -Filter ('ProcessId='+$listeners[0].OwningProcess)
if($pg.ExecutablePath -cne $postgres){throw 'actual_new_pg_image'}
Assert-OwnedHash $postgres $c.postgres_sha;[void](Get-OwnedDatadirArgument $pg.CommandLine $data)
Write-OwnedJson (Join-Path $out 'postgres-actual.json') @{pid=[int]$pg.ProcessId;creation_utc=$pg.CreationDate.ToUniversalTime().ToString('o');image=$postgres;image_sha=$c.postgres_sha;datadir=$data;port=5465}
$pgProcess=[Diagnostics.Process]::GetProcessById([int]$pg.ProcessId);$pgHandle=$pgProcess.Handle
$pgNativeCreation=$pgProcess.StartTime.ToUniversalTime().ToString('o')
$pgAgain=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pgProcess.Id);$pgProcess.Refresh()
# Win32 process creation and CIM timestamps have different precision. Compare
# stable samples within each API while retaining the same live native handle.
if($pgProcess.HasExited -or $pgProcess.StartTime.ToUniversalTime().ToString('o') -cne $pgNativeCreation -or !$pgAgain -or $pgAgain.CreationDate.ToUniversalTime().ToString('o') -cne $pg.CreationDate.ToUniversalTime().ToString('o') -or $pgAgain.ExecutablePath -cne $postgres){throw 'corpus_retained_postmaster_identity'}
Write-OwnedJson (Join-Path $out 'postgres-retained-identity.json') @{pid=$pgProcess.Id;native_creation_utc=$pgNativeCreation;cim_creation_utc=$pg.CreationDate.ToUniversalTime().ToString('o');second_cim_creation_utc=$pgAgain.CreationDate.ToUniversalTime().ToString('o');same_native_handle_retained=$true;no_cross_api_precision_equality_claim=$true}
Wait-OwnedReadyJob @(@{name='postgres';pid=[int]$pg.ProcessId;creation_utc=$pg.CreationDate.ToUniversalTime().ToString('o')}) $out
$secret=Get-Content -LiteralPath (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json
if($secret.port -ne 5465 -or (Get-OwnedCanonicalPath $secret.cluster_path) -cne (Get-OwnedCanonicalPath $data)){throw 'private_cluster_config_binding'}
$admin=@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c TimeZone=UTC -c DateStyle=ISO,YMD'}
$connection=@('-h','127.0.0.1','-p','5465','-U','pi_admin','-w','-X','-q','-t','-A','-v','ON_ERROR_STOP=1')
$caseRoot=Join-Path $pkg '.local/corpus';[void](New-OwnedPrivateDirectory $caseRoot)
$seed=Join-Path $caseRoot 'maintained-small-s.dump';[IO.File]::Copy($c.small_archive,$seed,$false);[IO.File]::Copy(($c.small_archive+'.manifest.json'),($seed+'.manifest.json'),$false)
$seedManifest=Get-Content -LiteralPath ($seed+'.manifest.json') -Raw|ConvertFrom-Json
if($seedManifest.format -cne 'postgres_custom' -or !$seedManifest.includes_auth -or $seedManifest.sha256 -cne $c.small_archive_sha -or $seedManifest.size -ne (Get-Item $seed).Length){throw 'maintained_seed_manifest'}
$snapshotSql=@'
SELECT jsonb_build_object(
'kv',(SELECT jsonb_agg(to_jsonb(t) ORDER BY key) FROM public.pi_kv t),
'projects',(SELECT jsonb_agg(to_jsonb(t) ORDER BY project_id) FROM public.pi_projects t),
'records',(SELECT jsonb_agg(to_jsonb(t) ORDER BY project_id,kind,resource_id) FROM public.pi_records t),
'markers',(SELECT jsonb_agg(to_jsonb(t) ORDER BY project_id) FROM public.pi_migration_v2 t),
'ledger',(SELECT jsonb_agg(to_jsonb(t) ORDER BY version) FROM public.pi_schema_migrations t),
'sequence',(SELECT jsonb_build_array(s.seqtypid::regtype::text,s.seqstart::text,s.seqincrement::text,s.seqmax::text,s.seqmin::text,s.seqcache::text,s.seqcycle,q.last_value::text,q.log_cnt::text,q.is_called) FROM pg_sequence s CROSS JOIN public.pi_resource_sequence q WHERE s.seqrelid='public.pi_resource_sequence'::regclass),
'catalog',(SELECT jsonb_agg(x.v ORDER BY x.k) FROM (
 SELECT 'class/'||c.relname AS k,jsonb_build_array('class',c.relname,c.relkind,c.relrowsecurity,c.relforcerowsecurity,c.relowner::regrole::text) AS v FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f')
 UNION ALL SELECT 'column/'||table_name||'/'||ordinal_position::text,jsonb_build_array('column',table_name,column_name,ordinal_position,data_type,udt_name,is_nullable,is_identity,is_generated,column_default,collation_name,identity_generation,identity_start,identity_increment,identity_minimum,identity_maximum,identity_cycle,generation_expression) FROM information_schema.columns WHERE table_schema='public'
 UNION ALL SELECT 'constraint/'||c.conrelid::regclass::text||'/'||c.conname,jsonb_build_array('constraint',c.conrelid::regclass::text,c.conname,c.contype,c.convalidated,c.condeferrable,c.condeferred,pg_get_constraintdef(c.oid)) FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='public'
 UNION ALL SELECT 'index/'||tablename||'/'||indexname,jsonb_build_array('index',tablename,indexname,indexdef) FROM pg_indexes WHERE schemaname='public'
 UNION ALL SELECT 'trigger/'||tgrelid::regclass::text||'/'||tgname,jsonb_build_array('trigger',tgrelid::regclass::text,tgname,pg_get_triggerdef(oid)) FROM pg_trigger WHERE tgrelid IN (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public') AND NOT tgisinternal
 UNION ALL SELECT 'rule/'||schemaname||'/'||tablename||'/'||rulename,jsonb_build_array('rule',tablename,rulename,definition) FROM pg_rules WHERE schemaname='public'
 UNION ALL SELECT 'policy/'||tablename||'/'||policyname,to_jsonb(p) FROM pg_policies p WHERE schemaname='public'
 UNION ALL SELECT 'function/'||p.oid::regprocedure::text,jsonb_build_array('function',p.oid::regprocedure::text,pg_get_functiondef(p.oid)) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
) x));
'@
$snapshotPath=Join-Path $out 'small-snapshot.sql';[IO.File]::WriteAllText($snapshotPath,$snapshotSql,[Text.UTF8Encoding]::new($false))
$results=[Collections.Generic.List[object]]::new();$sequence=0
function Admission {
 if([DateTime]::UtcNow -ge $deadline -or ([DateTime]::UtcNow-$started).TotalSeconds -gt $c.max_phase_seconds -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 4GB){throw 'finite_phase_runtime_floor_or_deadline'}
 $bytes=(Get-ChildItem -LiteralPath $out,$caseRoot -Recurse -File|Measure-Object Length -Sum).Sum
 if($bytes -gt 1GB){throw 'small_corpus_evidence_budget_1gib'}
}
function Native([string]$Label,[string]$Program,[string]$Sha,[string[]]$Arguments,[hashtable]$Environment,[int]$Seconds=120,[long]$Cap=8MB){
 Admission
 $p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $pkg -OutputDirectory $out -Label $Label -MaxOutputBytes $Cap -Environment $Environment
 $end=[DateTime]::UtcNow.AddSeconds($Seconds);$forced=$false
 while(-not $p.Process.WaitForExit(100)){
  if([DateTime]::UtcNow -ge $end -or [DateTime]::UtcNow -ge $deadline -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted){$forced=$true;$p.Process.Kill($true);if(!$p.Process.WaitForExit(10000)){throw 'owned_child_stop_timeout'};break}
 }
 $r=Complete-OwnedCapturedProcess $p
 if($forced -or !$r.stdout_complete -or !$r.stderr_complete -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout){throw 'native_capture_incomplete'}
 return $r
}
function Sql([string]$Database,[string]$Label,[string]$Text){
 if($Database -cnotmatch '^pi_restore_s13_[a-z0-9_]{1,35}$'){throw 'sql_new_database_scope'}
 $r=Native $Label $psql $c.psql_sha ($connection+@('-d',$Database,'-c',$Text)) $admin 30 8MB
 if($r.native_exit -ne 0){throw ('fixture_sql_failed_'+$Label)}
 return $r
}
function State([string]$Database,[string]$Label){
 $r=Native $Label $psql $c.psql_sha ($connection+@('-d',$Database,'-f',$snapshotPath)) $admin 30 8MB
 if($r.native_exit -ne 0){throw 'complete_state_capture_failed'}
 return @{path=(Join-Path $out ($Label+'.stdout'));sha256=$r.stdout_sha256;bytes=$r.stdout_bytes_persisted;native=$r}
}
function EqualState($A,$B){if($A.sha256 -cne $B.sha256 -or $A.bytes -ne $B.bytes){throw 'complete_state_inequality'}}
function JsonState($Proof){Get-Content -LiteralPath $Proof.path -Raw|ConvertFrom-Json -AsHashtable -DateKind String}
function Identity([string]$Db,[string]$Label,[string]$HostName='127.0.0.1'){
 if($HostName -cnotin @('127.0.0.1','localhost') -or $Db -cnotmatch '^pi_restore_s13_[a-z0-9_]{1,35}$'){throw 'identity_new_loopback_scope'}
 $args=@($connection);$args[1]=$HostName
 $r=Native $Label $psql $c.psql_sha ($args+@('-d',$Db,'-c',"SELECT jsonb_build_object('system_identifier',(pg_control_system()).system_identifier::text,'database_oid',(SELECT oid::text FROM pg_database WHERE datname=current_database()),'database',current_database(),'version',current_setting('server_version_num'),'encoding',current_setting('server_encoding'),'recovery',pg_is_in_recovery(),'read_only',current_setting('transaction_read_only'));")) $admin 30 8MB
 if($r.native_exit -ne 0){throw 'identity_native_failure'}
 $v=Get-Content (Join-Path $out ($Label+'.stdout')) -Raw|ConvertFrom-Json -AsHashtable
 if($v.database -cne $Db -or $v.version -cne '180006' -or $v.encoding -cne 'UTF8' -or $v.recovery -or $v.read_only -cne 'off'){throw 'actual_pg_identity_contract'}
 return $v
}
function Stock([string]$Label,[hashtable]$Arguments){
 $args=@('-NoProfile','-File',$c.stdio_wrapper,'-Script',$backup,'-ScriptSha',$c.backup_sha,'-Proof',(Join-Path $out ($Label+'-stdio.json')),'-ArgumentsJson',($Arguments|ConvertTo-Json -Compress))
 $r=Native $Label $c.pwsh $c.pwsh_sha $args @{} 120 4MB
 if($r.native_exit -ne 0){throw ('stock_failed_'+$Label)}
}
function Invoke-CorpusCleanup([string]$Label,[string]$Mode,[hashtable]$Environment,[int]$ExpectedExit,[string]$ExpectedOutcome,[string]$ExpectedCode){
 $r=Native $Label $exe $c.cleanup_sha @('--cleanup-storage-'+$Mode) $Environment 300 1MB
 $stdout=Get-Content (Join-Path $out ($Label+'.stdout')) -Raw;$stderr=Get-Content (Join-Path $out ($Label+'.stderr')) -Raw
 if($r.native_exit -ne $ExpectedExit){throw ('unexpected_cleanup_exit_'+$Label)}
 $value=$null
 if($ExpectedOutcome){$value=$stdout|ConvertFrom-Json -AsHashtable -DateKind String;if($value.outcome -cne $ExpectedOutcome){throw 'unexpected_cleanup_outcome'}}
 elseif($ExpectedCode){$value=$stdout|ConvertFrom-Json -AsHashtable -DateKind String;if($value.outcome -cne 'cleanup_refused' -or $value.code -cne $ExpectedCode){throw 'specific_refusal_not_observed'}}
 return @{native=$r;json=$value;expected_code=$ExpectedCode}
}
function WritePlan([string]$Path,[object]$Value){
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 100))
 $f=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
}
function ExpectedPost([string]$Source,[string]$Destination){
 # Independent complete SQL snapshot with exactly the two frozen eligible KV keys filtered.
 $keys=@($fixture.candidates|ForEach-Object {"'"+$_.key+"'"}) -join ','
 $expectedSql=$snapshotSql.Replace('FROM public.pi_kv t)',('FROM public.pi_kv t WHERE key NOT IN ('+$keys+'))'))
 if($expectedSql -ceq $snapshotSql){throw 'post_oracle_filter_not_inserted'}
 $p=Join-Path $out ($Destination+'.sql');[IO.File]::WriteAllText($p,$expectedSql,[Text.UTF8Encoding]::new($false))
 $r=Native $Destination $psql $c.psql_sha ($connection+@('-d',$Source,'-f',$p)) $admin 30 8MB
 if($r.native_exit -ne 0){throw 'independent_post_oracle_failed'}
 return @{path=(Join-Path $out ($Destination+'.stdout'));sha256=$r.stdout_sha256;bytes=$r.stdout_bytes_persisted;native=$r}
}
 foreach($case in $c.cases){
  $activeCase=$case
  Admission;$sequence++;$tag='case-'+('{0:d2}' -f $sequence);$name=$case.ToLowerInvariant().Replace('.','-');$dir=Join-Path $caseRoot $tag;[void](New-OwnedPrivateDirectory $dir)
  $src='pi_restore_s13_'+$c.run_token+'_'+('{0:d2}' -f $sequence)+'s';$dst=$src.Substring(0,$src.Length-1)+'r'
  if($c.run_token -cnotmatch '^[a-z0-9]{1,12}$' -or $src -cnotmatch '^pi_restore_s13_[a-z0-9_]{1,35}$'){throw 'finite_case_db_names'}
  Stock ($tag+'-seed') @{Mode='Restore';Database=$seedManifest.database;BackupFile=$seed;TargetDatabase=$src}
  $archive=Join-Path $dir 'source.dump';Stock ($tag+'-backup') @{Mode='Backup';Database=$src;BackupFile=$archive}
  Stock ($tag+'-restore') @{Mode='Restore';Database=$src;BackupFile=$archive;TargetDatabase=$dst}
  $sourceIdentity=Identity $src ($tag+'-source-identity');$restoreIdentity=Identity $dst ($tag+'-restore-identity')
  if($sourceIdentity.system_identifier -cne $restoreIdentity.system_identifier -or $sourceIdentity.database_oid -ceq $restoreIdentity.database_oid){throw 'same_cluster_distinct_db_identity'}
  $baseSource=State $src ($tag+'-source-base');$baseRestore=State $dst ($tag+'-restore-base');EqualState $baseSource $baseRestore
  $base=JsonState $baseSource
  $authRows=@($base.kv|Where-Object key -ceq 'auth')
  if($authRows.Count -ne 1 -or !$authRows[0].document.ContainsKey('project_list') -or $authRows[0].document.project_list.revision -le 0 -or $authRows[0].document.project_list.folders.Count -lt 1 -or $authRows[0].document.project_list.project_folders.Count -lt 1){throw 'maintained_catalog_fixture_required'}
  foreach($candidate in $fixture.candidates){$rows=@($base.kv|Where-Object key -ceq $candidate.key);if($rows.Count -ne 1 -or $rows[0].version -ne $candidate.source_version){throw 'whole_small_candidate_version'}}
  $generic=@($base.kv|Where-Object key -ceq 'fixture/keep')
  if($generic.Count -ne 1 -or $generic[0].version -ne 3 -or $generic[0].document.a -ne 1 -or $generic[0].document.b.Count -ne 3 -or $generic[0].document.b[0] -ne $true -or $null -ne $generic[0].document.b[1] -or $generic[0].document.b[2] -cne 'é' -or (Get-Item $baseSource.path).Length -gt 8MB){throw 'small_s_generic_bound'}
  foreach($projectRow in $base.projects){$records=@($base.records|Where-Object project_id -ceq $projectRow.project_id);if((@($records.kind|Sort-Object -Unique) -join ',') -cne 'log_analysis,log_data,log_source,log_state,model'){throw 'small_s_all_actual_record_kinds_required'}}
  $plan=Join-Path $dir 'verify.plan.json';$receipt=Join-Path $dir 'apply.receipt.json'
  $envCli=@{PI_DATABASE_URL="host=127.0.0.1 port=5465 user=pi_admin password=$($secret.admin_password) dbname=$src connect_timeout=5";PI_CLEANUP_RESTORE_URL="host=127.0.0.1 port=5465 user=pi_admin password=$($secret.admin_password) dbname=$dst connect_timeout=5";PI_CLEANUP_ARCHIVE=$archive;PI_CLEANUP_PLAN=$plan;PI_CLEANUP_RECEIPT=$receipt}
  # A valid fresh Verify is both fixture eligibility check and plan provenance before mutation.
  $verified=Invoke-CorpusCleanup ($tag+'-verify') 'verify' $envCli 0 'cleanup_verified' ''
  if($verified.json.candidate_rows -ne 2){throw 'small_exact_two_eligible'}
  $validPlan=Get-Content -LiteralPath $plan -Raw|ConvertFrom-Json -AsHashtable -DateKind String
  foreach($expected in $fixture.candidates){$actual=@($validPlan.candidates|Where-Object key -ceq $expected.key);if($actual.Count -ne 1 -or $actual[0].source_version -ne $expected.source_version -or $actual[0].source_sha -cne $expected.source_sha -or $actual[0].checksum -cne $expected.checksum){throw 'independent_rust_source_sha_binding'}}
  $envCli.PI_CLEANUP_CONFIRM_SHA=Get-OwnedHash $plan
  $legacy=@($fixture.candidates|Where-Object source_version -eq 7)[0].key;$project=$legacy.Substring('repository/'.Length)
  $expectedExit=1;$expectedCode='cleanup_changed';$expectedOutcome='';$success=$false
  if($case.StartsWith('C06.',[StringComparison]::Ordinal)){[IO.File]::Copy($archive,(Join-Path $dir 'unmodified-source.dump'),$false);[IO.File]::Copy(($archive+'.manifest.json'),(Join-Path $dir 'unmodified-source.dump.manifest.json'),$false)}
  switch -CaseSensitive ($case){
   'C01' {$success=$true}
   'C04' {$success=$true}
   'C03' {$aliasIdentity=Identity $src ($tag+'-actual-alias-identity') 'localhost';if($aliasIdentity.system_identifier -cne $sourceIdentity.system_identifier -or $aliasIdentity.database_oid -cne $sourceIdentity.database_oid){throw 'actual_alias_not_equal'};$envCli.PI_CLEANUP_RESTORE_URL="host=localhost port=5465 user=pi_admin password=$($secret.admin_password) dbname=$src connect_timeout=5";$expectedCode='cleanup_identity'}
   'C06.archive_byte' {$f=[IO.File]::Open($archive,'Open','ReadWrite','None');try{$f.Position=$f.Length-1;$b=$f.ReadByte();$f.Position=$f.Length-1;$f.WriteByte([byte]($b -bxor 1));$f.Flush($true)}finally{$f.Dispose()};$expectedCode='cleanup_archive'}
   'C06.manifest_sha' {$m=Get-Content ($archive+'.manifest.json') -Raw|ConvertFrom-Json -AsHashtable;$m.sha256='0'*64;WritePlan (Join-Path $dir 'bad-manifest.json') $m;[IO.File]::Copy((Join-Path $dir 'bad-manifest.json'),($archive+'.manifest.json'),$true);$expectedCode='cleanup_archive'}
   'C06.manifest_size' {$m=Get-Content ($archive+'.manifest.json') -Raw|ConvertFrom-Json -AsHashtable;$m.size++;WritePlan (Join-Path $dir 'bad-manifest.json') $m;[IO.File]::Copy((Join-Path $dir 'bad-manifest.json'),($archive+'.manifest.json'),$true);$expectedCode='cleanup_archive'}
   'C06.archive_substitution' {if((Get-OwnedHash $seed) -ceq (Get-OwnedHash $archive)){throw 'archive_substitution_not_distinct'};[IO.File]::Copy($seed,$archive,$true);$expectedCode='cleanup_archive'}
   'C07' {[void](Sql $src ($tag+'-mutation') "UPDATE public.pi_kv SET document=jsonb_set(document,'{a}','2'::jsonb) WHERE key='fixture/keep';")}
   'C08.restore_value' {[void](Sql $dst ($tag+'-mutation') "UPDATE public.pi_kv SET document=jsonb_set(document,'{a}','2'::jsonb) WHERE key='fixture/keep';")}
   'C09' {[void](Sql $src ($tag+'-mutation') "UPDATE public.pi_kv SET version=version+1 WHERE key='$legacy';");$expectedCode='cleanup_source_invalid'}
   'C10' {[void](Sql $src ($tag+'-mutation') "UPDATE public.pi_kv SET document=jsonb_set(document,'{sequence}','999'::jsonb) WHERE key='$legacy';");$expectedCode='cleanup_source_invalid'}
   'C11.marker_source_sha' {[void](Sql $src ($tag+'-mutation') "UPDATE public.pi_migration_v2 SET source_sha=repeat('0',64) WHERE project_id='$project';");$expectedCode='cleanup_source_invalid'}
   'C11.marker_checksum' {[void](Sql $src ($tag+'-mutation') "UPDATE public.pi_migration_v2 SET checksum=repeat('0',64) WHERE project_id='$project';");$expectedCode='cleanup_schema'}
   'C11.unknown_legacy_key' {[void](Sql $src ($tag+'-mutation') "INSERT INTO public.pi_kv(key,version,document) VALUES('repository/unknown-project',1,'{}'::jsonb);");$expectedCode='cleanup_source_invalid'}
   'C11.missing_header' {[void](Sql $src ($tag+'-mutation') "DELETE FROM public.pi_records WHERE project_id='$project'; DELETE FROM public.pi_migration_v2 WHERE project_id='$project'; DELETE FROM public.pi_projects WHERE project_id='$project';");$expectedCode='cleanup_source_invalid'}
   'C12.ledger1' {[void](Sql $src ($tag+'-mutation') 'DELETE FROM public.pi_schema_migrations WHERE version=2;');$expectedCode='cleanup_schema'}
   'C12.malformed_stage' {[void](Sql $src ($tag+'-mutation') 'ALTER TABLE public.pi_migration_v2 ADD COLUMN unsupported_stage text;');$expectedCode='cleanup_schema'}
   'C12.future_schema' {[void](Sql $src ($tag+'-mutation') "INSERT INTO public.pi_schema_migrations(version,name,checksum) VALUES(3,'future','unsupported');");$expectedCode='cleanup_schema'}
   'C12.trigger' {[void](Sql $src ($tag+'-mutation') 'CREATE FUNCTION public.fixture_trigger() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$; CREATE TRIGGER fixture_trigger BEFORE UPDATE ON public.pi_kv FOR EACH ROW EXECUTE FUNCTION public.fixture_trigger();');$expectedCode='cleanup_schema'}
   'C12.rls' {[void](Sql $src ($tag+'-mutation') 'ALTER TABLE public.pi_kv ENABLE ROW LEVEL SECURITY;');$expectedCode='cleanup_schema'}
   'C12.rule' {[void](Sql $src ($tag+'-mutation') 'CREATE RULE fixture_rule AS ON UPDATE TO public.pi_kv DO ALSO SELECT 1;');$expectedCode='cleanup_schema'}
   'C14' {$keys=@($fixture.candidates|ForEach-Object {"'"+$_.key+"'"}) -join ',';[void](Sql $src ($tag+'-mutation') ("DELETE FROM public.pi_kv WHERE key IN ($keys);"));$emptyArchive=Join-Path $dir 'empty.dump';$emptyDb=$src.Substring(0,$src.Length-1)+'e';Stock ($tag+'-empty-backup') @{Mode='Backup';Database=$src;BackupFile=$emptyArchive};Stock ($tag+'-empty-restore') @{Mode='Restore';Database=$src;BackupFile=$emptyArchive;TargetDatabase=$emptyDb};$dst=$emptyDb;$archive=$emptyArchive;$plan=Join-Path $dir 'empty.plan.json';$envCli.PI_CLEANUP_ARCHIVE=$archive;$envCli.PI_CLEANUP_PLAN=$plan;$envCli.PI_CLEANUP_RESTORE_URL=$envCli.PI_CLEANUP_RESTORE_URL.Replace(('dbname='+$restoreIdentity.database+' '),('dbname='+$dst+' '));$emptyVerify=Invoke-CorpusCleanup ($tag+'-empty-verify') 'verify' $envCli 0 'cleanup_verified' '';if($emptyVerify.json.candidate_rows -ne 0){throw 'empty_plan_not_empty'};$envCli.PI_CLEANUP_CONFIRM_SHA=Get-OwnedHash $plan;$expectedExit=0;$expectedOutcome='cleanup_empty'}
   'C15.stale_plan_sha' {$copy=Join-Path $dir 'stale.plan.json';[IO.File]::Copy($plan,$copy,$false);[IO.File]::AppendAllText($copy,' ');$envCli.PI_CLEANUP_PLAN=$copy;$expectedCode='cleanup_plan_sha'}
   'C15.wrong_confirmation' {$envCli.PI_CLEANUP_CONFIRM_SHA='0'*64;$expectedCode='cleanup_plan_sha'}
   'C15.plan_identity_changed' {$validPlan.source.database_oid='0';$copy=Join-Path $dir 'changed.plan.json';WritePlan $copy $validPlan;$envCli.PI_CLEANUP_PLAN=$copy;$envCli.PI_CLEANUP_CONFIRM_SHA=Get-OwnedHash $copy;$expectedCode='cleanup_identity'}
   'C16.key_utf8_bytes.at' {[void](Sql $src ($tag+'-mutation') "INSERT INTO public.pi_kv(key,version,document) VALUES(repeat(chr(233),256),1,'{}'::jsonb);");$success=$true}
   'C16.key_utf8_bytes.over' {[void](Sql $src ($tag+'-mutation') "INSERT INTO public.pi_kv(key,version,document) VALUES(repeat(chr(233),256)||'x',1,'{}'::jsonb);");$expectedCode='cleanup_limit'}
   'C16.managed_rows.at' {$count=@($base.kv).Count+@($base.projects).Count+@($base.records).Count+@($base.markers).Count+@($base.ledger).Count;$needed=10000-$count;if($needed -lt 1){throw 'row_boundary_fixture_already_large'};[void](Sql $src ($tag+'-mutation') ("INSERT INTO public.pi_kv(key,version,document) SELECT 'fixture/boundary/'||i::text,1,'{}'::jsonb FROM generate_series(1,$needed) AS i;"));$success=$true}
   'C16.managed_rows.over' {$count=@($base.kv).Count+@($base.projects).Count+@($base.records).Count+@($base.markers).Count+@($base.ledger).Count;$needed=10001-$count;if($needed -lt 1){throw 'row_boundary_fixture_already_large'};[void](Sql $src ($tag+'-mutation') ("INSERT INTO public.pi_kv(key,version,document) SELECT 'fixture/boundary/'||i::text,1,'{}'::jsonb FROM generate_series(1,$needed) AS i;"));$expectedCode='cleanup_limit'}
   'C16.plan_bytes.at' {$n=4194304-(Get-Item $plan).Length;if($n -lt 0){throw 'base_plan_already_large'};$copy=Join-Path $dir 'limit.plan.json';[IO.File]::Copy($plan,$copy,$false);[IO.File]::AppendAllText($copy,(' '*$n),[Text.UTF8Encoding]::new($false));if((Get-Item $copy).Length -ne 4194304){throw 'plan_exact_bytes'};$envCli.PI_CLEANUP_PLAN=$copy;$envCli.PI_CLEANUP_CONFIRM_SHA=Get-OwnedHash $copy;$success=$true}
   'C16.plan_bytes.over' {$n=4194305-(Get-Item $plan).Length;$copy=Join-Path $dir 'over.plan.json';[IO.File]::Copy($plan,$copy,$false);[IO.File]::AppendAllText($copy,(' '*$n),[Text.UTF8Encoding]::new($false));if((Get-Item $copy).Length -ne 4194305){throw 'plan_over_bytes'};$envCli.PI_CLEANUP_PLAN=$copy;$envCli.PI_CLEANUP_CONFIRM_SHA=Get-OwnedHash $copy;$expectedCode='cleanup_limit'}
   'operator.receipt_fail' {$envCli.PI_CLEANUP_RECEIPT=Join-Path $dir (('r'*256)+'.json');$success=$true;$expectedExit=3;$expectedOutcome='cleanup_committed_receipt_failed'}
  }
  # Eligibility corruption must be equally present in a NEW stock restore, otherwise
  # the earlier pair inequality gate would mask the intended per-candidate refusal.
  if($case -cin @('C09','C10','C11.marker_source_sha','C11.unknown_legacy_key','C11.missing_header')){
   $archive=Join-Path $dir 'corrupt-source.dump';$corruptDb=$src.Substring(0,$src.Length-1)+'c';Stock ($tag+'-corrupt-backup') @{Mode='Backup';Database=$src;BackupFile=$archive};Stock ($tag+'-corrupt-restore') @{Mode='Restore';Database=$src;BackupFile=$archive;TargetDatabase=$corruptDb};$dst=$corruptDb;$envCli.PI_CLEANUP_ARCHIVE=$archive;$envCli.PI_CLEANUP_RESTORE_URL=$envCli.PI_CLEANUP_RESTORE_URL.Replace(('dbname='+$restoreIdentity.database+' '),('dbname='+$dst+' '));$envCli.PI_CLEANUP_PLAN=Join-Path $dir 'corrupt.plan.json';$modeOverride='verify'
  }else{$modeOverride=$null}
  # At/over key bounds require genuinely re-backed-up equal changed state, not a stale plan failure.
  if($case -cin @('C16.key_utf8_bytes.at','C16.key_utf8_bytes.over','C16.managed_rows.at','C16.managed_rows.over')){
   $archive=Join-Path $dir 'key.dump';$newDst=$src.Substring(0,$src.Length-1)+'k';Stock ($tag+'-key-backup') @{Mode='Backup';Database=$src;BackupFile=$archive};Stock ($tag+'-key-restore') @{Mode='Restore';Database=$src;BackupFile=$archive;TargetDatabase=$newDst};$dst=$newDst;$envCli.PI_CLEANUP_ARCHIVE=$archive;$envCli.PI_CLEANUP_PLAN=Join-Path $dir 'key.plan.json';$envCli.PI_CLEANUP_RESTORE_URL=$envCli.PI_CLEANUP_RESTORE_URL.Replace(('dbname='+$restoreIdentity.database+' '),('dbname='+$dst+' '));
   if($case.EndsWith('.at',[StringComparison]::Ordinal)){$v=Invoke-CorpusCleanup ($tag+'-key-verify') 'verify' $envCli 0 'cleanup_verified' '';$envCli.PI_CLEANUP_CONFIRM_SHA=Get-OwnedHash $envCli.PI_CLEANUP_PLAN}
   $measure=Sql $src ($tag+'-actual-boundary-measure') "SELECT jsonb_build_object('rows',(SELECT count(*) FROM public.pi_kv)+(SELECT count(*) FROM public.pi_projects)+(SELECT count(*) FROM public.pi_records)+(SELECT count(*) FROM public.pi_migration_v2)+(SELECT count(*) FROM public.pi_schema_migrations),'max_key_bytes',(SELECT max(octet_length(key)) FROM public.pi_kv));"
   $measured=Get-Content (Join-Path $out ($tag+'-actual-boundary-measure.stdout')) -Raw|ConvertFrom-Json -AsHashtable
   if(($case -ceq 'C16.managed_rows.at' -and $measured.rows -ne 10000) -or ($case -ceq 'C16.managed_rows.over' -and $measured.rows -ne 10001) -or ($case -ceq 'C16.key_utf8_bytes.at' -and $measured.max_key_bytes -ne 512) -or ($case -ceq 'C16.key_utf8_bytes.over' -and $measured.max_key_bytes -ne 513)){throw 'actual_boundary_measure_mismatch'}
  }
  $beforeSource=State $src ($tag+'-source-immediate-pre');$beforeRestore=State $dst ($tag+'-restore-immediate-pre')
  $postOracle=$null;if($success){$postOracle=ExpectedPost $src ($tag+'-independent-expected-post');if(!$expectedOutcome){$expectedExit=0;$expectedOutcome='cleanup_committed'}}
  $mode=if($modeOverride){$modeOverride}elseif($case -cin @('C16.key_utf8_bytes.over','C16.managed_rows.over')){'verify'}else{'apply'}
  $actual=Invoke-CorpusCleanup ($tag+'-operation-'+$mode) $mode $envCli $expectedExit $expectedOutcome $expectedCode
  $afterSource=State $src ($tag+'-source-post');$afterRestore=State $dst ($tag+'-restore-post');EqualState $beforeRestore $afterRestore
  if($success){EqualState $postOracle $afterSource;if($actual.json.deleted_rows -ne 2){throw 'exact_two_deleted'}}else{EqualState $beforeSource $afterSource}
  if($case -ceq 'C14' -and ($actual.json.deleted_rows -ne 0 -or $actual.json.database_writes -ne 0)){throw 'explicit_empty_no_writes'}
  if($case -ceq 'C14' -and (Test-Path -LiteralPath $receipt)){throw 'empty_receipt_unexpected'}
  if($case -ceq 'operator.receipt_fail' -and ($actual.json.automatic_retry -ne $false -or [IO.File]::Exists($envCli.PI_CLEANUP_RECEIPT))){throw 'known_commit_receipt_failure_contract'}
  $activeRestoreIdentity=Identity $dst ($tag+'-active-restore-identity')
  $receiptProof=$null
  if($success -and $case -cne 'operator.receipt_fail'){
   if(!(Test-Path -LiteralPath $receipt)){throw 'known_commit_receipt_missing'}
   $receiptProof=Native ($tag+'-receipt-oracle') $c.node $c.node_sha @($c.receipt_oracle,$envCli.PI_CLEANUP_PLAN,$receipt,(Join-Path $out ($tag+'-operation-'+$mode+'.stdout')),(Join-Path $out ($tag+'-source-identity.stdout')),(Join-Path $out ($tag+'-active-restore-identity.stdout')),$envCli.PI_CLEANUP_ARCHIVE) @{} 30 1MB
   if($receiptProof.native_exit -ne 0){throw 'committed_receipt_contract_failed'}
  }
  $result=@{id=$case;scope='SMALL_S_ONLY';status='ACTUAL_FINITE_EVIDENCE_READY_FOR_INDEPENDENT_REVIEW';cli_mode=$mode;source_identity=$sourceIdentity;initial_restore_identity=$restoreIdentity;active_restore_identity=$activeRestoreIdentity;alias_identity=$(if($case -ceq 'C03'){$aliasIdentity}else{$null});source_immediate_pre=$beforeSource;source_post=$afterSource;restore_immediate_pre=$beforeRestore;restore_post=$afterRestore;expected_post=$postOracle;cleanup=$actual;receipt_oracle=$receiptProof;product_budget='SQL5/lock2/tx10 unchanged';physical_shrink=$false;automatic_retry=$false;limits=@('No historical/current full corpus credit','Eligibility-corruption cases use fresh Verify on equal corrupt source/restore; do not claim invalid-source Apply path','No independently observed RETURNING or COMMIT wire boundary; delegated F cases','Full native+SQL values retained privately, no secret output')}
  $results.Add($result);Write-OwnedJson (Join-Path $out ($tag+'-result.json')) $result
 }
 Test-OwnedPackageTree $pkg $c.manifest_sha $true
 $remaining=@($crosswalk.cleanup_cases|Where-Object {$_.id -cnotin $c.cases}|ForEach-Object {@{id=$_.id;status='NOT_EXECUTED_BY_THIS_PHASE';scope=$_.fixture_scope}})
 Write-OwnedJson (Join-Path $out 'corpus-phase-result.json') @{status='FINITE_SMALL_S_RESULTS_NOT_WHOLE_R3_ACCEPTANCE';actual_cases=$results;not_executed=$remaining;partial_scope_not_executed=@{C01_full_historical_current='NOT_EXECUTED_BY_THIS_SMALL_PHASE'};operator_receipt_fail_scope='Known-commit CLI result plus complete expectedPOST; not F03';delegated=@('C01/C02/C18 full historical/current','C02 maintained normalized update','C05 clone5466 and identity privilege','C08 actual restore login','C13 actual holder/native locks','C17 SQL5/lock2/tx10 observers','F01/F02/F03 actual protocol','C18 recovery app/export/RBAC');failed_evidence_retained=$true}
}catch{
 $safeCode=if($_.Exception.Message -cmatch '^[A-Za-z0-9_-]{1,100}$'){$_.Exception.Message}else{'SEE_PRIVATE_CHILD_STDERR'}
 Write-OwnedJson (Join-Path $out 'primary-failure.json') @{status='FAILED_RETAINED';case=$activeCase;safe_code=$safeCode;recorded_before_teardown=$true;automatic_retry=$false}
 throw
}finally{
 $secret=$null;$admin=$null;$envCli=$null
 try{
  if($pgProcess -and !$pgProcess.HasExited){
   $again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pgProcess.Id)
   if(!$again -or $again.ExecutablePath -cne $postgres -or $again.CreationDate.ToUniversalTime().ToString('o') -cne $pg.CreationDate.ToUniversalTime().ToString('o') -or $pgProcess.StartTime.ToUniversalTime().ToString('o') -cne $pgNativeCreation){throw 'corpus_postmaster_stop_identity'}
   [void](Get-OwnedDatadirArgument $again.CommandLine $data)
   [void](Invoke-OwnedPhaseCommand (Join-Path $bin 'pg_ctl.exe') $c.pg_ctl_sha @('-D',$data,'-w','-t','15','stop','-m','fast') $pkg $out 'pg-fast-stop' @{} 30 1MB)
   if(!$pgProcess.WaitForExit(10000) -or $pgProcess.ExitCode -ne 0){throw 'corpus_postmaster_not_clean'}
   Write-OwnedJson (Join-Path $out 'postgres-clean-exit.json') @{pid=$pgProcess.Id;native_exit=$pgProcess.ExitCode;clean_before_outer_job_close=$true}
  }
 }finally{if($pgProcess){$pgProcess.Dispose()}}
}

<#
PROSPECTIVE CONTRACT — this source has not been executed or accepted.

The only owned developer file is this phase. Root freezes exact package/EXE/source,
module/phase-support/stdio/PowerShell/PostgreSQL pins and private PhaseConfig after
QA/TD review. Root runs it ONLY through tools/sprint13/run-owned-process.ps1 and
its waiting worker assigned to the owned Job before GO. ready_processes must name
the new PostgreSQL process so Wait-OwnedReadyJob gets the actual exact Job witness.
No current old process/installation/database is a permitted target; old proofs
give no acceptance credit. Port5465 is new and must be absent; clone5466 is NOT
opened/created by this phase. No fixture reset, DROP DATABASE or automatic retry.

PhaseConfig fields (all finite/pinned, no credentials): scope/version/source_commit,
port5465, run_token[a-z0-9]1..12, selected cases, deadline_utc<=19:44:42Z,
max_phase_seconds<=1800, output_directory/new install_parent under .local/sprint13,
package_archive/package_sha/manifest_sha, cleanup_sha, module_sha,
phase_support_sha, pwsh/pwsh_sha, stdio_wrapper/stdio_sha, setup_sha/backup_sha,
postgres_sha/psql_sha, pins[], crosswalk/crosswalk_sha, small_archive/
node/node_sha, receipt_oracle (pinned including its historical-state-oracle dependency),
small_archive_sha/small_manifest_sha, fixture_review/fixture_review_sha.
Install and evidence paths must be separate. Source/package pins are UNKNOWN
until Root freezes them: never default to a historical binary/source/manifest.
Private secrets come only from the newly bootstrapped installation; CLI env and
private full captures may contain secrets but no env values are emitted in proofs.

Input S is separately constructed from actual maintained0.7.3 writes: normal
owner/editor/viewer/foreign Auth, two project backups with log+model and all five
record kinds, positive creator-owned project-list/catalog placement, versions7/11,
Gversion3 exact {a:1,b:[true,null,"é"]}, actual baseline/migration+ledger/sequence.
Root's synthetic v1 assembly+maintained migration is explicitly SMALL S, never
the original full historical source. Additional lazy Auth projects without headers
are valid and not rejected by this phase. The independent input review status is
S13_MAINTAINED_SMALL_S_INPUT_REVIEWED, with archive_sha/manifest_sha, candidates2
(key/source_version/source_sha/checksum), all_record_kinds=true, normal_auth=true,
project_list_exercised=true, generic_key=fixture/keep. No generated fake password
hash/Rust source SHA or copied diagnostic success substitutes this actual review.

Snapshots retain complete ordered table values/versions, every ledger applied_at,
actual sequence definition/last/is_called and logical public catalog metadata
without physical OIDs/table_catalog database names that differ on new restore.
Raw bounded8MiB source/restore captures are byte-SHA/length compared, never PS
reserialization. Complete expectedPOST is a separate read-only SQL projection
of immediatePRE with exactly the two independently pinned KV keys filtered out;
full POST must match, all records/Auth/catalog/markers/ledger/sequence preserved.
Input fixture eligibility is additionally checked by actual current native Verify
and candidate bindings against the independent Rust-source hash review. This
developer oracle still needs independent QA/TD implementation/result review.

Each selected case starts stockRestore seed->NEWsource, stockBackup source->NEW
archive/manifest, stockRestore->NEWverification; original verification remains
untouched except specifically identified C08 contamination. C03 records actual
localhost alias identity; C04 proves same cluster/differentDB OIDs, not a blanket
different-cluster rule. Corrupted eligibility cases get NEW equal corrupted
verification and fresh Verify so earlier inequality cannot mask the binding gate;
they are VERIFY refusal evidence, not invalid-source Apply-path credit. Every
refusal compares immediate MUTATED PRE to POST, not original clean fixture.
Unsupported schema/trigger/RLS/rule setup is fixture SQL, no production bypass.
All C06 originals are copied privately before changing the owned fixture files.
At/over rows/UTF8-key bounds measured by actual SQL; plan bytes actual file length.
Whitespace padding changes plan hash and is explicitly re-confirmed, no MAX raise.

Known receipt failure uses a prospective >255-byte new leaf component under a
valid existing privateparent: prechecks may pass, postcommit create_new must fail.
Only actual exit3/cleanup_committed_receipt_failed + exact fullPOST, restorePRE
and automatic_retry=false get finite evidence. If an earlier guard refuses or
filesystem behavior differs, retain FAILED evidence; do not weaken the guard or
label it known-commit. No fault flag/hook/ACL change. This is NOT F03 wire proof.
C14 requires fresh POST backup/NEWrestore/empty plan, actual empty JSON0writes,
source/restore byte equality and no receipt; database equality alone is not a
continuous zero-writer protocol audit. Normal success requires actual receipt.

Budgets unchanged: SQL5/lock2/tx10, rows10000/key512/plan4MiB. Initial free>=8GiB,
runtime floor4GiB, capture/evidence<=1GiB, selected phase<=1800sec and runtime
freeze19:44:42UTC; Root outer additionally enforces total S13<=16GiB. No child
budget extension. Every native expected exit and complete stdout/stderr is
captured; truncated/capture fault/drain failure is STOP. Failed evidence retained.

Source-implemented32 selections are not32 executed/PASS cases. C02 maintained
normalized update, identity privilege/cloneC05(5466), actual restore loginC08,
C13 holders, C17 three timeouts, F01/F02/F03 protocol and full C01/C02/C18 recovery
are delegated and explicitly NOT EXECUTED here. Full counts/RETURNING/COMMIT wire,
new archive runtime recovery/RBAC, operator lifecycle/final CI/package and final
Council remain separate mandatory gates. No full R3/DISK/physical shrink claim.
#>
