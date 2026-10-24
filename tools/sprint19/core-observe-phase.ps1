param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'core-compile-phase.ps1') -PhaseConfig $PhaseConfig -PhaseConfigSha $PhaseConfigSha -FunctionsOnly
Assert-CoreCanonical
Assert-OwnedHash $c.build_proof $c.build_proof_sha
$proof=Get-Content -LiteralPath $c.build_proof -Raw|ConvertFrom-Json -AsHashtable
if($proof.status -cne 'ACTUAL_OWN_JAVA_CLASSES_COMPILED_NO_R5_ENGINE_EXECUTION' -or $proof.classpath_sha256 -cne $c.classpath_sha -or $proof.canonical_proof_sha256 -cne $c.canonical_proof_sha){throw 'actual_compilation_required'}
$beforeClasses=Get-CoreClasses $proof.classes
Assert-CoreClassSet $beforeClasses $proof.class_files
Assert-OwnedHash $c.rust_observer $c.rust_observer_sha
Assert-OwnedHash $c.corpus $c.corpus_sha
$manifest=Get-Content -LiteralPath $c.corpus -Raw|ConvertFrom-Json -AsHashtable
$expected=if($c.mode -ceq 'calendar'){'F363E0952BCC8C153B7E269EBA6535787A856A7E8693961FDAEAF6CC77DE347E'}elseif($c.mode -ceq 'filters'){'87D9C3731C66EEDC0BF54FBB7A6652C8B20F507C9A1000F3D0FFEAC46ACFE5D3'}else{throw 'known_mode_required'}
if($c.corpus_sha -cne $expected -or $manifest.cases.Count -ne $(if($c.mode -ceq 'calendar'){13}else{8})){throw 'fixed_corpus_required'}
$inputs=@();$seen=@{}
foreach($case in $manifest.cases){
 if($case.id -notmatch '^[a-z0-9-]+$' -or $seen.ContainsKey($case.id) -or $case.file -notmatch '^[a-z0-9-]+\.json$'){throw 'unique_safe_case_required'}
 $seen[$case.id]=$true
 $path=Join-Path (Split-Path -Parent $c.corpus) $case.file
 Assert-OwnedHash $path $case.sha256.ToUpperInvariant()
 $inputs+=@{id=$case.id;path=$path;sha256=$case.sha256}
}
$environment=New-CoreEnvironment
$classpath=$proof.classes+';'+[IO.File]::ReadAllText($c.classpath_file).TrimEnd([char]13,[char]10)
if($classpath.Contains([char]10) -or $classpath.Contains([char]13)){throw 'single_classpath_required'}
$javaRows=@();$rustRows=@()
foreach($case in $inputs){
 $id=$case.id
 $javaName='java-'+$id+'.json'
 $javaObservation=Join-Path $c.output $javaName
 $argfile=Join-Path $c.output ('java-'+$id+'.args')
 $main=if($c.mode -ceq 'calendar'){'CoreCalendarHarness'}else{'CoreFilterExtendedHarness'}
 Write-CoreArgs $argfile (@(Get-CoreJvmArgs)+@('-classpath',$classpath,$main,$case.path,$javaObservation))
 $javaLabel='java-'+$id
 $java=Invoke-OwnedPhaseCommand $c.java $c.java_sha @('@'+$argfile) (Join-Path $c.output 'cwd') $c.output $javaLabel $environment 180 8MB
 Assert-OwnedNoReparse $javaObservation
 if(!(Test-Path -LiteralPath $javaObservation -PathType Leaf) -or (Get-Item -LiteralPath $javaObservation).Length -gt 8MB){throw 'bounded_java_observation_required'}
 $javaRecord=$javaLabel+'.process.json'
 $javaRows+=@{id=$id;input_sha256=$case.sha256;observation_path=$javaName;observation_sha256=Get-OwnedHash $javaObservation;native_record=$javaRecord;native_record_sha256=Get-OwnedHash (Join-Path $c.output $javaRecord)}
 $rustLabel='rust-'+$id
 $rust=Invoke-OwnedPhaseCommand $c.rust_observer $c.rust_observer_sha @('--trusted-corpus',$case.path) (Join-Path $c.output 'cwd') $c.output $rustLabel (@{RAYON_NUM_THREADS='1'}+$environment) 60 8MB
 $rustName=$rustLabel+'.stdout';$rustRecord=$rustLabel+'.process.json'
 $rustRows+=@{id=$id;input_sha256=$case.sha256;observation_path=$rustName;observation_sha256=Get-OwnedHash (Join-Path $c.output $rustName);native_record=$rustRecord;native_record_sha256=Get-OwnedHash (Join-Path $c.output $rustRecord)}
 Assert-OwnedHash $case.path $case.sha256.ToUpperInvariant()
}
Assert-CoreCanonical
Assert-OwnedHash $c.rust_observer $c.rust_observer_sha
Assert-OwnedHash $c.corpus $c.corpus_sha
Assert-OwnedHash $c.build_proof $c.build_proof_sha
$afterClasses=Get-CoreClasses $proof.classes
Assert-CoreClassSet $afterClasses $beforeClasses
foreach($input in $inputs){Assert-OwnedHash $input.path $input.sha256.ToUpperInvariant()}
Write-OwnedJson (Join-Path $c.output 'java-index.json') @{corpus_sha256=$c.corpus_sha;cases=$javaRows}
Write-OwnedJson (Join-Path $c.output 'rust-index.json') @{corpus_sha256=$c.corpus_sha;cases=$rustRows}
Write-OwnedJson (Join-Path $c.output 'core-observe-proof.json') @{status='ACTUAL_SEQUENTIAL_JAVA_AND_RUST_OBSERVATIONS_NOT_COMPARISON_ACCEPTANCE';mode=$c.mode;cases=$inputs.Count;canonical_5763_and_285_and_classes_and_inputs_unchanged=$true;java_index_sha256=Get-OwnedHash (Join-Path $c.output 'java-index.json');rust_index_sha256=Get-OwnedHash (Join-Path $c.output 'rust-index.json');no_new_rust_or_java_compilation=$true}
