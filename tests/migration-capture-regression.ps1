param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../tools/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../tools/owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
if($c.scope -cne 'benign-native-sequence-capture-regression' -or $c.database -cne 'process_intelligence' -or $c.pg_port -ne 5462 -or $c.app_port -ne 3095){throw 'benign_capture_scope'}
Import-Module $c.service_module -Force -DisableNameChecking
$out=$c.output_directory;Assert-OwnedPrivateDirectory $out
$pkg=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$service=$null;$stopped=$false
try{
 $service=Start-OwnedStockService $c $pkg 'startup01';[void](Wait-OwnedStockService $service)
 $secret=Get-Content (Join-Path $pkg '.local/postgres-private.json') -Raw|ConvertFrom-Json
 $admin=@{PGPASSWORD=$secret.admin_password;PGOPTIONS='-c statement_timeout=60000 -c TimeZone=UTC'}
 $psql=Join-Path $pkg 'runtime/postgresql/pgsql/bin/psql.exe'
 $argsSql=@('-h','127.0.0.1','-p',[string]$c.pg_port,'-U','pi_admin','-w','-d',$c.database,'-At','-v','ON_ERROR_STOP=1')
 $before=Invoke-OwnedPhaseCommand $psql $c.psql_sha ($argsSql+@('-f',$c.catalog_sql)) $pkg $out 'catalog-pre' $admin 60 16MB
 $old=Start-OwnedCapturedProcess -Program $psql -ProgramSha256 $c.psql_sha -Arguments ($argsSql+@('-f',$c.old_capture)) -WorkingDirectory $pkg -OutputDirectory $out -Label 'old-composite-capture' -MaxOutputBytes 16MB -Environment $admin
 if(-not $old.Process.WaitForExit(60000)){$old.Process.Kill($true);[void]$old.Process.WaitForExit(10000);throw 'benign_old_capture_timeout'}
 $oldNative=Complete-OwnedCapturedProcess $old
 $oldError=Get-Content (Join-Path $out 'old-composite-capture.stderr') -Raw
 if($oldNative.native_exit -ne 3 -or -not $oldNative.stdout_complete -or -not $oldNative.stderr_complete -or $oldNative.capture_fault -or $oldNative.output_limit -or $oldNative.drain_timeout -or -not $oldError.Contains('does not have a composite type')){throw 'actual_old_sequence_cause_not_reproduced'}
 $first=Invoke-OwnedPhaseCommand $psql $c.psql_sha ($argsSql+@('-f',$c.migration_capture)) $pkg $out 'new-full-capture01' $admin 60 16MB
 $second=Invoke-OwnedPhaseCommand $psql $c.psql_sha ($argsSql+@('-f',$c.migration_capture)) $pkg $out 'new-full-capture02' $admin 60 16MB
 if($first.stdout_sha256 -cne $second.stdout_sha256 -or $first.stdout_bytes_persisted -ne $second.stdout_bytes_persisted){throw 'benign_capture_not_quiescent_exact'}
 [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha ($argsSql+@('-c',"SELECT last_value::text||'|'||log_cnt::text||'|'||is_called::text FROM public.pi_resource_sequence")) $pkg $out 'direct-sequence-fields' $admin 60 1MB)
 $raw=(Get-Content (Join-Path $out 'direct-sequence-fields.stdout') -Raw).Trim().Split('|')
 $rows=@(Get-Content (Join-Path $out 'new-full-capture01.stdout')|Where-Object {$_ -match '^\['}|ForEach-Object {ConvertFrom-Json $_ -NoEnumerate})
 $sequence=@($rows|Where-Object {$_[0] -ceq 'pi_resource_sequence'})
 $definitions=@($rows|Where-Object {$_[0] -ceq 'sequence_definition'})
 $relations=@($rows|Where-Object {$_[0] -ceq 'managed_relation'})
 if($raw.Count -ne 3 -or $sequence.Count -ne 1 -or $definitions.Count -ne 1 -or $relations.Count -ne 6 -or [string]$sequence[0][1].last_value -cne $raw[0] -or [string]$sequence[0][1].log_cnt -cne $raw[1] -or $sequence[0][1].is_called.ToString().ToLowerInvariant() -cne $raw[2]){throw 'actual_full_scalar_sequence_oracle'}
 $after=Invoke-OwnedPhaseCommand $psql $c.psql_sha ($argsSql+@('-f',$c.catalog_sql)) $pkg $out 'catalog-post' $admin 60 16MB
 if($before.stdout_sha256 -cne $after.stdout_sha256){throw 'benign_readonly_catalog_changed'}
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 Write-OwnedJson (Join-Path $out 'regression-result.json') @{status='NATIVE_SEQUENCE_CAPTURE_CAUSE_AND_REPAIR_VERIFIED';old_capture=$oldNative;old_reason='Sequence relation lacks composite row type';new_capture=$first;repeat_capture=$second;explicit_sequence_fields_match=$true;managed_relation_count=6;sequence_definition_count=1;catalog_unchanged=$true;limits=@('New empty owned stock fixture and read-only snapshot commands only','No migration/schema-refusal/Auth case or R3 acceptance')}
}finally{
 $secret=$null;$admin=$null
 if($service -and -not $stopped -and -not $service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}
}
