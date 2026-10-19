param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content -LiteralPath $PhaseConfig -Raw | ConvertFrom-Json -AsHashtable -DateKind String
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
Import-Module $c.service_module -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $c.output_directory
if($c.app_port -ne 3096 -or $c.pg_port -ne 5464 -or $c.database -cne 'process_intelligence' -or $c.tests.Count -ne 4){throw 'native_scope'}
$package=Expand-OwnedPackage $c.package_archive $c.package_sha $c.install_parent $c.manifest_sha
$service=$null;$stopped=$false
try{
 $service=Start-OwnedStockService $c $package 'startup01'
 [void](Wait-OwnedStockService $service)
 $secret=Get-Content (Join-Path $package '.local/postgres-private.json') -Raw | ConvertFrom-Json -DateKind String
 $psql=Join-Path $package 'runtime/postgresql/pgsql/bin/psql.exe'
 $connectionArgs=@('-h','127.0.0.1','-p','5464','-U','pi_admin','-w','-d','process_intelligence','-At','-v','ON_ERROR_STOP=1')
 $results=@()
 foreach($test in $c.tests){
  if($test.database -cnotmatch '^pi_restore_s12_native_[a-z0-9_]{1,20}$' -or $test.label -cnotmatch '^[a-z][a-z0-9-]{1,25}$' -or $test.environment_key -cnotin @('S12_AUTH_DATABASE_URL','S8_QA_AUTH_DATABASE_URL','S12_DELETE_DATABASE_URL','S12_JOB_DATABASE_URL')){throw 'native_test_scope'}
  $check=Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connectionArgs+@('-c',("SELECT count(*) FROM pg_database WHERE datname='"+$test.database+"'"))) $package $c.output_directory ($test.label+'-absent') @{PGPASSWORD=$secret.admin_password} 30 1MB
  if(([IO.File]::ReadAllText((Join-Path $c.output_directory ($test.label+'-absent.stdout')))).Trim() -cne '0'){throw 'native_database_not_new'}
  [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha ($connectionArgs+@('-c',('CREATE DATABASE '+$test.database))) $package $c.output_directory ($test.label+'-create') @{PGPASSWORD=$secret.admin_password} 30 1MB)
  $url='postgresql://pi_admin:'+([Uri]::EscapeDataString($secret.admin_password))+'@127.0.0.1:5464/'+$test.database+'?connect_timeout=5'
  $environment=@{};$environment[$test.environment_key]=$url
  if($test.environment_key -ceq 'S12_JOB_DATABASE_URL'){
   $evidence=Join-Path $c.output_directory 'job-commit-evidence';[void](New-OwnedPrivateDirectory $evidence)
   $environment.S12_JOB_EVIDENCE=$evidence
   $environment.S12_JOB_PG_LOG=Join-Path $package '.local/logs/postgres-server.log'
  }
  $r=Invoke-OwnedPhaseCommand $c.test_binary $c.test_binary_sha @('--ignored','--exact',$test.name,'--nocapture') $c.workspace $c.output_directory $test.label $environment 180 4MB
  $text=Get-Content (Join-Path $c.output_directory ($test.label+'.stdout')) -Raw
  if($text -cnotmatch 'running 1 test' -or $text -cnotmatch ('test '+[regex]::Escape($test.name)+' \.\.\. ok') -or $text -cnotmatch '1 passed; 0 failed; 0 ignored'){throw 'native_exact_one_test_not_passed'}
  $argsAfter=@('-h','127.0.0.1','-p','5464','-U','pi_admin','-w','-d',$test.database,'-At','-v','ON_ERROR_STOP=1')
  [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha ($argsAfter+@('-f',$c.capture_sql)) $package $c.output_directory ($test.label+'-full-after') @{PGPASSWORD=$secret.admin_password} 30 16MB)
  [void](Invoke-OwnedPhaseCommand $psql $c.psql_sha ($argsAfter+@('-f',$c.catalog_sql)) $package $c.output_directory ($test.label+'-catalog-after') @{PGPASSWORD=$secret.admin_password} 30 16MB)
  $residue=Invoke-OwnedPhaseCommand $psql $c.psql_sha ($argsAfter+@('-c',"SELECT (SELECT count(*) FROM pg_trigger WHERE tgname='pi_s12_refuse_job')+(SELECT count(*) FROM pg_proc WHERE proname='pi_s12_refuse_job')")) $package $c.output_directory ($test.label+'-no-fault-residue') @{PGPASSWORD=$secret.admin_password} 30 1MB
  if(([IO.File]::ReadAllText((Join-Path $c.output_directory ($test.label+'-no-fault-residue.stdout')))).Trim() -cne '0'){throw 'native_fault_catalog_residue'}
  $results+=@{test=$test.name;database=$test.database;native_exit=$r.native_exit;exact_one_test=$true;stdout_sha256=$r.stdout_sha256;stderr_sha256=$r.stderr_sha256}
  $environment=$null;$url=$null
 }
 Stop-OwnedStockService $service 'fixture-finalization';$stopped=$true
 Write-OwnedJson (Join-Path $c.output_directory 'native-result.json') @{status='NATIVE_FINITE_ACCEPTANCE_READY_FOR_REVIEW';tests=$results;limits=@('Production native APIs against fresh PostgreSQL; not a held final HTTP instruction','Guard sentinel/compound archive-delete proof distinct from HTTP lifecycle','Per-commit managed/Auth/sequence job oracle excludes catalog; final explicit fault trigger/function residue checked separately','No uncertain acknowledgement or infrastructure high availability proof','No full original R3 acceptance')}
}finally{
 $secret=$null;$environment=$null;$url=$null
 if($service -and -not $stopped -and -not $service.StopAttempted){Stop-OwnedStockService $service 'fixture-failure'}
}
