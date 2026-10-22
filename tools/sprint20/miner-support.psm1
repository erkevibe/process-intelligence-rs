Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Get-S20GitBlob([string]$Path,[long]$Length){
 Assert-OwnedNoReparse $Path
 if((Get-Item -LiteralPath $Path).Length -ne $Length){throw 'canonical_source_length'}
 $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA1)
 $stream=[IO.File]::OpenRead($Path)
 try{
  $hash.AppendData([Text.Encoding]::ASCII.GetBytes(('blob '+$Length+[char]0)))
  $buffer=[byte[]]::new(65536)
  while(($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0){$hash.AppendData($buffer,0,$count)}
  return [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
 }finally{$stream.Dispose();$hash.Dispose()}
}
function Assert-S20MinerEnvironment([hashtable]$Config){
 foreach($pin in $Config.pins){Assert-OwnedHash $pin.path $pin.sha256}
 foreach($baseline in $Config.canonical_baselines){
  Assert-OwnedHash $baseline.proof $baseline.proof_sha
  $proof=Get-Content -LiteralPath $baseline.proof -Raw|ConvertFrom-Json -AsHashtable -DateKind String
  if($proof.unchanged_source.Count -ne 5763 -or $proof.runtime_files.Count -ne $baseline.runtime_count -or $proof.classpath_entries.Count -ne $baseline.classpath_count){throw 'canonical_inventory_count'}
  $sourcePrefix=[IO.Path]::GetFullPath($baseline.source_root).TrimEnd('\')+[IO.Path]::DirectorySeparatorChar
  foreach($row in $proof.unchanged_source){
   if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$Config.phase_deadline_utc){throw 'canonical_read_deadline'}
   $path=[IO.Path]::GetFullPath((Join-Path $baseline.source_root $row.path))
   if(!$path.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'canonical_path_escape'}
   if((Get-S20GitBlob $path $row.bytes) -cne $row.git_blob){throw 'canonical_git_blob'}
  }
  foreach($row in $proof.runtime_files){
   Assert-OwnedNoReparse $row.path
   if((Get-Item -LiteralPath $row.path).Length -ne $row.bytes){throw 'runtime_length'}
   Assert-OwnedHash $row.path $row.sha256.ToUpperInvariant()
  }
 }
 Assert-OwnedHash $Config.classpath_file $Config.classpath_sha
 $miner=Get-Content -LiteralPath $Config.miner_proof -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 $classpath=[IO.File]::ReadAllText($Config.classpath_file).TrimEnd([char]13,[char]10)
 $entries=@($classpath.Split(';'))
 if($entries.Count -ne 202 -or $classpath.Contains([char]10) -or $classpath.Contains([char]13)){throw 'miner_classpath_shape'}
 $actual=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 for($i=0;$i -lt $entries.Count;$i++){
  $entry=$miner.classpath_entries[$i]
  if($entry.path -cne $entries[$i] -or [bool](Test-Path -LiteralPath $entry.path) -ne [bool]$entry.exists){throw 'ordered_classpath_entry'}
  if(!$entry.exists){continue}
  Assert-OwnedNoReparse $entry.path
  if($entry.directory){
   foreach($file in Get-ChildItem -LiteralPath $entry.path -File -Recurse -Force){Assert-OwnedNoReparse $file.FullName;[void]$actual.Add($file.FullName)}
  }else{[void]$actual.Add([IO.Path]::GetFullPath($entry.path))}
 }
 if($actual.Count -ne $miner.runtime_files.Count){throw 'reachable_runtime_set_count'}
 foreach($row in $miner.runtime_files){if(!$actual.Contains($row.path)){throw 'reachable_runtime_set_member'}}
 if($Config.jdk_pins.Count -ne 504){throw 'jdk_pin_count'}
 $jdkFiles=@(Get-ChildItem -LiteralPath $Config.jdk_root -File -Recurse -Force)
 if($jdkFiles.Count -ne 504){throw 'jdk_actual_count'}
 foreach($pin in $Config.jdk_pins){Assert-OwnedNoReparse $pin.path;Assert-OwnedHash $pin.path $pin.sha256}
 return $classpath
}
function Write-S20JavaArgs([string]$Path,[string[]]$Arguments){
 $lines=foreach($argument in $Arguments){
  if($argument.Contains([char]0) -or $argument.Contains([char]10) -or $argument.Contains([char]13)){throw 'argfile_control'}
  '"'+$argument.Replace('\','\\').Replace('"','\"')+'"'
 }
 $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
 try{$bytes=[Text.Encoding]::UTF8.GetBytes(($lines -join [char]10)+[char]10);$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}
function New-S20JavaEnvironment([string]$Directory){
 Assert-OwnedPrivateDirectory $Directory
 foreach($name in @('home','temp','prefs-user','prefs-system','cwd')){[void](New-OwnedPrivateDirectory (Join-Path $Directory $name))}
 $logback=Join-Path $Directory 'logback.xml'
 $stream=[IO.File]::Open($logback,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
 try{$bytes=[Text.Encoding]::UTF8.GetBytes('<configuration><appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender"><encoder><pattern>%level %logger - %msg%n</pattern></encoder></appender><root level="WARN"><appender-ref ref="CONSOLE"/></root></configuration>');$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
 return @{JAVA_TOOL_OPTIONS='';JDK_JAVA_OPTIONS='';_JAVA_OPTIONS='';TEMP=(Join-Path $Directory 'temp');TMP=(Join-Path $Directory 'temp')}
}
function Get-S20JvmArgs([string]$Directory){
 return @('-Xmx512m','-XX:ActiveProcessorCount=2','-XX:-UsePerfData','-da',('-Duser.home='+(Join-Path $Directory 'home')),('-Djava.io.tmpdir='+(Join-Path $Directory 'temp')),('-Djava.util.prefs.userRoot='+(Join-Path $Directory 'prefs-user')),('-Djava.util.prefs.systemRoot='+(Join-Path $Directory 'prefs-system')),('-Dlogback.configurationFile='+(Join-Path $Directory 'logback.xml')),'-Dfile.encoding=UTF-8','-Duser.timezone=UTC','-Djava.awt.headless=true')
}
Export-ModuleMember -Function *-S20*
