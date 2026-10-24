param(
 [Parameter(Mandatory)][string]$PackageZip,
 [Parameter(Mandatory)][string]$CoreSourceZip,
 [string]$Repository=(Join-Path $PSScriptRoot '../..'),
 [string]$ReportPath
)
# Offline validator only. No download, credentials, extraction, repack or publication.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$core='3f0b3caa34b9b4beaf4422f78c2e31c0f97d3209'
$packageSha='E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C'
$manifestSha='868D4CAD2BBBC57A5A0BCC55A82FF9C933C1260B16ECCD09510BF84FFD8AFF42'
$exeSha='23563DFF8FE93F339AD7F12FD0783AC3E2C53B8D9368C00D772A8FBABBE5F292'
$startSha='E80BD13F97E7AA1B9AF0406975D05D4A39C0E84ACF9842F51D69298579922CB6'
function InputFile([string]$Path){$f=Get-Item -LiteralPath $Path;if($f.PSIsContainer -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $f.Length -le 0){throw 'readback_input_file'};return $f}
$pf=InputFile $PackageZip;$sf=InputFile $CoreSourceZip
if($pf.FullName -ieq $sf.FullName -or [long]$pf.Length+[long]$sf.Length+4MB -gt 256MB){throw 'readback_public_aggregate_256MiB'}
function SafeRelative([string]$Name){if(!$Name -or $Name.Length -gt 512 -or $Name.Contains('\') -or $Name.Contains(':') -or $Name.StartsWith('/') -or @($Name.Split('/')|Where-Object {$_ -cin @('','.', '..')}).Count){throw 'readback_unsafe_zip_path'}}
function HashEntry($Entry,[string]$Algorithm,[long]$ExpectedLength,[bool]$GitBlob=$false){
 if($ExpectedLength -lt 0 -or $ExpectedLength -gt 256MB -or $Entry.Length -ne $ExpectedLength){throw 'readback_entry_length'}
 $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::new($Algorithm));$stream=$Entry.Open()
 try{
  if($GitBlob){$prefix=[Text.Encoding]::ASCII.GetBytes(('blob '+$ExpectedLength+[char]0));$hash.AppendData($prefix)}
  $buffer=[byte[]]::new(65536);$read=0L
  while(($n=$stream.Read($buffer,0,$buffer.Length)) -gt 0){$read+=$n;if($read -gt $ExpectedLength){throw 'readback_decoded_length_cap'};$hash.AppendData($buffer,0,$n)}
  if($read -ne $ExpectedLength){throw 'readback_decoded_length'}
  return [Convert]::ToHexString($hash.GetHashAndReset())
 }finally{$stream.Dispose();$hash.Dispose()}
}
function Entries($Zip,[string]$Prefix){
 $map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
 $fold=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 if($Zip.Entries.Count -gt 10000){throw 'readback_entry_count'}
 foreach($e in $Zip.Entries){
  $name=$e.FullName;$directory=$name.EndsWith('/');$safe=if($directory){$name.TrimEnd('/')}else{$name};SafeRelative $safe
  if(!$fold.Add($safe)){throw 'readback_duplicate_entry'}
  if(!$name.StartsWith($Prefix,[StringComparison]::Ordinal)){throw 'readback_zip_root'}
  $relative=$name.Substring($Prefix.Length)
  if($directory){if($e.Length -ne 0){throw 'readback_directory_payload'};continue}
  SafeRelative $relative
  # Reject Unix symlink/device entries; regular files and unspecified DOS mode only.
  $mode=($e.ExternalAttributes -shr 16) -band 0xF000
  if($mode -notin @(0,0x8000)){throw 'readback_nonregular_entry'}
  $map.Add($relative,$e)
 }
 return ,$map
}
if((Get-FileHash -LiteralPath $pf.FullName).Hash -cne $packageSha){throw 'readback_package_sha'}
$zip=[IO.Compression.ZipFile]::OpenRead($pf.FullName);$packageCount=0;$packageDecoded=0L
try{
 $entries=Entries $zip 'process-intelligence-rs-0.7.3-windows-x86_64/'
 if(!$entries.ContainsKey('build-manifest.json')){throw 'readback_manifest_missing'}
 $me=$entries['build-manifest.json'];if($me.Length -gt 1MB -or (HashEntry $me 'SHA256' $me.Length) -cne $manifestSha){throw 'readback_manifest_sha'}
 $reader=[IO.StreamReader]::new($me.Open(),[Text.Encoding]::UTF8,$true);try{$m=$reader.ReadToEnd()|ConvertFrom-Json -AsHashtable -Depth 100}finally{$reader.Dispose()}
 if($m.version -cne '0.7.3' -or $m.source_commit -cne $core -or $m.build_proof.executable_sha256 -cne $exeSha){throw 'readback_manifest_candidate_binding'}
 $expected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);[void]$expected.Add('build-manifest.json')
 foreach($f in $m.files){SafeRelative $f.path;if(!$expected.Add($f.path) -or !$entries.ContainsKey($f.path) -or $f.sha256 -cnotmatch '^[A-F0-9]{64}$'){throw 'readback_manifest_entry_set'}
  if((HashEntry $entries[$f.path] 'SHA256' ([long]$f.bytes)) -cne $f.sha256){throw ('readback_payload_sha_'+$f.path)}
  $packageDecoded+=[long]$f.bytes;if($packageDecoded -gt 2GB){throw 'readback_package_decoded_cap'};$packageCount++
 }
 if($entries.Count -ne $expected.Count){throw 'readback_package_extra_entry'}
 foreach($pin in @(@('process-intelligence-rs.exe',$exeSha),@('Start.ps1',$startSha))){$item=@($m.files|Where-Object path -ceq $pin[0]);if($item.Count -ne 1 -or $item[0].sha256 -cne $pin[1]){throw 'readback_entry_candidate_pin'}}
}finally{$zip.Dispose()}
# Exact core tree read only; no checkout, hooks, index mutation or build.
$git=(Get-Command git -CommandType Application -ErrorAction Stop).Source
$si=[Diagnostics.ProcessStartInfo]::new();$si.FileName=$git;$si.WorkingDirectory=[IO.Path]::GetFullPath($Repository);$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
foreach($a in @('--no-optional-locks','ls-tree','--full-tree','-r','-z',$core)){$si.ArgumentList.Add($a)}
$process=[Diagnostics.Process]::new();$process.StartInfo=$si
try{if(!$process.Start()){throw 'readback_git_start'};$ot=$process.StandardOutput.ReadToEndAsync();$et=$process.StandardError.ReadToEndAsync();if(!$process.WaitForExit(15000)){$process.Kill($true);$process.WaitForExit();throw 'readback_git_timeout'};$tree=$ot.GetAwaiter().GetResult();$err=$et.GetAwaiter().GetResult();if($process.ExitCode -ne 0 -or $tree.Length -gt 8MB -or $err.Length -gt 1MB){throw 'readback_git_exit_or_capture'}}finally{$process.Dispose()}
$blobs=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
foreach($line in $tree.Split([char]0,[StringSplitOptions]::RemoveEmptyEntries)){if($line -cnotmatch '^(100644|100755) blob ([a-f0-9]{40})\t(.+)$'){throw 'readback_core_tree_mode'};SafeRelative $Matches[3];$blobs.Add($Matches[3],$Matches[2])}
if(!$blobs.Count -or $blobs.Count -gt 10000){throw 'readback_core_tree_count'}
$sourceSha=(Get-FileHash -LiteralPath $sf.FullName).Hash;$sourceZip=[IO.Compression.ZipFile]::OpenRead($sf.FullName);$sourceCount=0;$sourceDecoded=0L
try{
 $prefix='process-intelligence-rs-'+$core+'/'
 $entries=Entries $sourceZip $prefix
 if($entries.Count -ne $blobs.Count){throw 'readback_source_entry_set'}
 foreach($path in $blobs.Keys){if(!$entries.ContainsKey($path)){throw 'readback_core_source_missing'};$e=$entries[$path];$sourceDecoded+=$e.Length;if($sourceDecoded -gt 256MB){throw 'readback_source_decoded_cap'}
  if((HashEntry $e 'SHA1' $e.Length $true).ToLowerInvariant() -cne $blobs[$path]){throw ('readback_core_blob_'+$path)};$sourceCount++
 }
}finally{$sourceZip.Dispose()}
$report=[ordered]@{status='OFFLINE_FULL_PACKAGE_AND_CORE_SOURCE_READBACK_VERIFIED';utc=[DateTime]::UtcNow.ToString('o');package_sha256=$packageSha;manifest_sha256=$manifestSha;exe_sha256=$exeSha;public_start_sha256=$startSha;package_files=$packageCount;package_decoded_bytes=$packageDecoded;source_archive_sha256=$sourceSha;source_core_commit=$core;source_files=$sourceCount;source_decoded_bytes=$sourceDecoded;git_blob_domain='SHA1 ASCII blob SP decimal-byte-length NUL followed by all decoded entry bytes';public_inputs_bytes=[long]$pf.Length+[long]$sf.Length;public_aggregate_cap_bytes=256MB;diagnostic_HEAD_is_not_executable_build_source=$true;no_download_extraction_repack_publication=$true;limits=@('Offline complete-byte validation only; URL provenance/upload/download and fresh runtime/browser/restart require separate actual evidence','Exact core source archive only; final diagnostic HEAD source must be separately named and validated','No full R3 or release acceptance')}
if($ReportPath){if(Test-Path -LiteralPath $ReportPath){throw 'readback_new_report_required'};$parent=Get-Item -LiteralPath (Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath)));if(!$parent.PSIsContainer -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'readback_report_parent'};$json=$report|ConvertTo-Json -Depth 10;$bytes=[Text.Encoding]::UTF8.GetBytes($json);if($bytes.Length -gt 1MB){throw 'readback_report_cap'};$writer=[IO.File]::Open([IO.Path]::GetFullPath($ReportPath),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$writer.Write($bytes,0,$bytes.Length)}finally{$writer.Dispose()}}
$report|ConvertTo-Json -Depth 10
