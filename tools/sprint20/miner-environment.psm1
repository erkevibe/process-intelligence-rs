Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Get-S20ClassResource([string]$Classpath,[string]$Class){
 $member=$Class.Replace('.','/')+'.class'
 foreach($entry in $Classpath.Split(';')){
  if(!(Test-Path -LiteralPath $entry)){continue}
  $stream=$null;$archive=$null
  try{
   if([IO.Directory]::Exists($entry)){
    $path=Join-Path $entry $member
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){continue}
    Assert-OwnedNoReparse $path
    $stream=[IO.File]::OpenRead($path);$origin=$path
   }else{
    $archive=[IO.Compression.ZipFile]::OpenRead($entry)
    $item=$archive.GetEntry($member)
    if($null -eq $item){continue}
    if($item.Length -gt 2MB){throw 'class_resource_bound'}
    $stream=$item.Open();$origin=$entry
   }
   $buffer=[IO.MemoryStream]::new()
   try{
    $chunk=[byte[]]::new(65536)
    while(($n=$stream.Read($chunk,0,$chunk.Length)) -gt 0){
     if($buffer.Length+$n -gt 2MB){throw 'class_resource_bound'}
     $buffer.Write($chunk,0,$n)
    }
    $data=$buffer.ToArray()
    return @{class=$Class;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($data)).ToLowerInvariant();bytes=$data.Length;derivation='first matching canonical ordered classpath resource';origin_path=$origin;origin_sha256=Get-OwnedHash $origin;member=$member}
   }finally{$buffer.Dispose()}
  }finally{if($stream){$stream.Dispose()};if($archive){$archive.Dispose()}}
 }
 throw ('class_resource_absent_'+$Class)
}
function Write-S20MinerEnvironment([hashtable]$Config,[hashtable]$Build,[string]$Classpath){
 $copy=Join-Path $Config.output 'compiled-build-proof.json'
 [IO.File]::Copy($Config.build_proof,$copy,$false)
 $identities=@{}
 foreach($pair in @(@('algorithm_identity','org.apromore.splitminer.SplitMiner'),@('parser_identity','org.deckfour.xes.in.XesXmlParser'),@('exporter_identity','org.apromore.processmining.plugins.bpmn.plugins.BpmnExportPlugin'))){
  $identities[$pair[0]]=Get-S20ClassResource $Classpath $pair[1]
 }
 foreach($pair in @(@('harness_identity','SplitMinerBenchmarkHarness'),@('xes_observer_identity','SplitMinerBenchmarkXesObserver'))){
  $row=@($Build.class_files|Where-Object{$_.path.Replace('\','/') -ceq ($pair[1]+'.class')})
  if($row.Count -ne 1){throw 'own_class_proof'}
  $path=Join-Path $Build.classes $row[0].path
  Assert-OwnedHash $path $row[0].sha256
  $identities[$pair[0]]=@{class=$pair[1];sha256=$row[0].sha256.ToLowerInvariant();bytes=$row[0].bytes;derivation='actual compiled buildproof class file';origin_path=$path;origin_sha256=$row[0].sha256;member=$row[0].path}
 }
 $proofHash=Get-OwnedHash $Config.build_proof
 Assert-OwnedHash $copy $proofHash
 Write-OwnedJson (Join-Path $Config.output 'environment.json') @{schema_version=1;status='ACTUAL_COMPILED_HARNESS_AND_RUNTIME_BYTECODE_PINS';original_build_proof_sha256=$proofHash;build_proof=@{file='compiled-build-proof.json';sha256=Get-OwnedHash $copy;bytes=(Get-Item -LiteralPath $copy).Length};class_identities=$identities;java_sha256=$Config.java_sha;javac_sha256=$Config.javac_sha;ordered_classpath_sha256=$Config.classpath_sha;canonical_miner_proof_sha256=Get-OwnedHash $Config.miner_proof;jdk_file_count=$Config.jdk_pins.Count}
}
Export-ModuleMember -Function Write-S20MinerEnvironment
