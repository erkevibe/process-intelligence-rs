param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'owned-phase-support.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
$c=Get-Content $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
Assert-OwnedPrivateDirectory $c.output_directory
foreach($pin in $c.pins){Assert-OwnedNoReparse $pin.path;Assert-OwnedHash $pin.path $pin.sha256}
$proof=Get-Content $c.build_proof -Raw|ConvertFrom-Json -DateKind String
if($c.source_commit -cne $proof.source_commit -or $proof.package_version -cne '0.7.5' -or $proof.executable_sha256 -cne $c.app_sha -or $proof.tests_requested){throw 'package_proof_scope'}
$result=Invoke-OwnedPhaseCommand $c.pwsh $c.pwsh_sha @('-NoProfile','-File',$c.packager,'-SourceCommit',$c.source_commit,'-Version','0.7.5','-BuildProof',$c.build_proof,'-OutputDirectory',$c.package_output) $c.workspace $c.output_directory 'package' @{} 300 4MB
foreach($pin in $c.pins){Assert-OwnedHash $pin.path $pin.sha256}
$pkg=Join-Path $c.package_output 'process-intelligence-rs-0.7.5-windows-x86_64'
$archive=$pkg+'.zip';$manifest=Join-Path $pkg 'build-manifest.json';$manifestSha=Get-OwnedHash $manifest
Test-OwnedPackageTree $pkg $manifestSha $false
$m=Get-Content $manifest -Raw|ConvertFrom-Json -DateKind String
if($m.source_commit -cne $c.source_commit -or $m.build_proof.executable_sha256 -cne $c.app_sha){throw 'packaged_candidate_identity'}
$map=@{};foreach($file in $m.files){$map[$file.path]=$file}
# Every copied PG file is checked against its separately pinned actual input.
foreach($pin in $c.postgres_files){
 $relative='runtime/postgresql/pgsql/'+$pin.relative
 if(-not $map.ContainsKey($relative) -or $map[$relative].sha256 -cne $pin.sha256 -or $map[$relative].bytes -ne $pin.bytes){throw 'packaged_postgres_input_mismatch'}
}
foreach($name in @('setup-postgres.ps1','start-packaged.ps1','database-backup.ps1','migrate-storage.ps1','cleanup-legacy.ps1')){
 Assert-OwnedHash (Join-Path $pkg ('tools/'+$name)) (Get-OwnedHash (Join-Path $proof.source_directory ('tools/'+$name)))
}
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try{
 $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($entry in $zip.Entries){
  if($entry.FullName.EndsWith('/')){continue}
  $prefix='process-intelligence-rs-0.7.5-windows-x86_64/'
  if(-not $entry.FullName.StartsWith($prefix,[StringComparison]::Ordinal)){throw 'package_zip_root'}
  $rel=$entry.FullName.Substring($prefix.Length)
  if(-not $seen.Add($rel)){throw 'package_zip_duplicate'}
  $expected=if($rel -ceq 'build-manifest.json'){@{bytes=(Get-Item $manifest).Length;sha256=$manifestSha}}else{$map[$rel]}
  if(-not $expected -or $entry.Length -ne $expected.bytes){throw 'package_zip_set'}
  $stream=$entry.Open();try{$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))}finally{$stream.Dispose()}
  if($hash -cne $expected.sha256){throw 'package_zip_full_readback'}
 }
 if($seen.Count -ne ($m.files.Count+1)){throw 'package_zip_count'}
}finally{$zip.Dispose()}
Write-OwnedJson (Join-Path $c.output_directory 'package-result.json') @{status='IMMUTABLE_CANDIDATE_PACKAGE_FULL_TREE_AND_ZIP_READBACK_READY_FOR_REVIEW';source_commit=$c.source_commit;executable_sha256=$c.app_sha;archive=$archive;archive_bytes=(Get-Item $archive).Length;archive_sha256=Get-OwnedHash $archive;manifest=$manifest;manifest_sha256=$manifestSha;listed_files=$m.files.Count;package_files=$seen.Count;postgres_input_files=$c.postgres_files.Count;native=$result;limits=@('Private candidate only; no application/PostgreSQL startup or release/public download credit','Complete source is the exact frozen Git archive; future working helper changes are separately pinned')}
