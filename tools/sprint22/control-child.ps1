param([Parameter(Mandatory)][ValidateSet('normal','hang','flood')][string]$Mode)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$stdout=[Console]::OpenStandardOutput();$stderr=[Console]::OpenStandardError()
if($Mode -ceq 'flood'){
 $bytes=[Text.Encoding]::ASCII.GetBytes("child-flood`n");$stderr.Write($bytes,0,$bytes.Length);$stderr.Flush()
 $bytes=[byte[]]::new(16384);[Array]::Fill[byte]($bytes,88)
 while($true){$stdout.Write($bytes,0,$bytes.Length);$stdout.Flush()}
}
$bytes=[Text.Encoding]::ASCII.GetBytes("child-ready`n");$stdout.Write($bytes,0,$bytes.Length);$stdout.Flush()
$bytes=[Text.Encoding]::ASCII.GetBytes("child-error`n");$stderr.Write($bytes,0,$bytes.Length);$stderr.Flush()
if($Mode -ceq 'hang'){while($true){Start-Sleep -Milliseconds 100}}
exit 0
