# Insert after D440 import/private path assertions and BEFORE any PostgreSQL START.
# Known failed owned PostgreSQL only. No PID/WAL deletion and no process kill.
function Assert-DRKnownStalePostgres([hashtable]$c){
 if(($c.expected_pg_pid -isnot [int] -and $c.expected_pg_pid -isnot [long]) -or $c.expected_pg_pid -ne 63344 -or $c.expected_pg_filetime -cne '134372569672472071'){throw 'dr_failed_pg_identity_pending'}
 foreach($pair in @(@($c.failed_pg_record,$c.failed_pg_record_sha),@($c.failed_attempt_review,$c.failed_attempt_review_sha),@($c.failed_attempt_qa,$c.failed_attempt_qa_sha))){if($pair[1] -cnotmatch '^[0-9A-F]{64}$'){throw 'dr_recovery_gate_pending'};Assert-OwnedHash $pair[0] $pair[1]}
 Assert-OwnedHash $c.postgres $c.postgres_sha
 $prior=Get-Content -LiteralPath $c.failed_pg_record -Raw|ConvertFrom-Json -AsHashtable -DateKind String
 if($prior.pid -ne $c.expected_pg_pid -or [string]$prior.native_creation_filetime -cne $c.expected_pg_filetime -or $prior.native_exit -ne 137 -or $prior.program -cne $c.postgres -or $prior.source_status -cne 'captured' -or !$prior.stdout_complete -or !$prior.stderr_complete){throw 'dr_failed_pg_not_full_owned137'}
 foreach($side in @('stdout','stderr')){
  $path=$c.failed_pg_record.Replace('.process.json','.'+$side);& (Get-Module broker) {param($value) Assert-OwnedNoReparse $value} $path
  if((Get-Item -LiteralPath $path).Length -ne $prior[$side+'_bytes_persisted'] -or (Get-FileHash -LiteralPath $path).Hash -cne $prior[$side+'_sha256']){throw 'dr_failed_pg_raw_capture'}
 }
 $pidpath=Join-Path $c.pgdata 'postmaster.pid';& (Get-Module broker) {param($value) Assert-OwnedNoReparse $value} $pidpath
 if($c.stale_pid_sha -cnotmatch '^[0-9A-F]{64}$'){throw 'dr_stale_pid_pending'};Assert-OwnedHash $pidpath $c.stale_pid_sha
 $stream=[IO.File]::Open($pidpath,'Open','Read','Read');try{if($stream.Length -gt 4096){throw 'dr_stale_pid_bound'};$bytes=[byte[]]::new([int]$stream.Length);$stream.ReadExactly($bytes)}finally{$stream.Dispose()}
 $lines=[Text.UTF8Encoding]::new($false,$true).GetString($bytes).Split([char]10)|ForEach-Object{$_.TrimEnd([char]13)}
 if($lines.Count -lt 4 -or $lines[0] -cne '63344' -or [IO.Path]::GetFullPath($lines[1]) -cne $c.pgdata -or $lines[3] -cne '55449'){throw 'dr_stale_pid_owned_data'}
 $alive=$null;try{$alive=[Diagnostics.Process]::GetProcessById(63344)}catch [ArgumentException]{};if($alive){$alive.Dispose();throw 'dr_failed_numeric_pid_reused_or_alive_no_kill'}
 foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='postgres.exe'" -OperationTimeoutSec 5)){if(($p.ExecutablePath -and [IO.Path]::GetFullPath($p.ExecutablePath).Equals([IO.Path]::GetFullPath($c.postgres),[StringComparison]::OrdinalIgnoreCase)) -or ($p.CommandLine -and $p.CommandLine.Contains($c.pgdata))){throw 'dr_owned_pg_present_no_kill'}}
 foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='process-intelligence-rs.exe'" -OperationTimeoutSec 5)){if($p.ExecutablePath -and [IO.Path]::GetFullPath($p.ExecutablePath).Equals([IO.Path]::GetFullPath($c.app),[StringComparison]::OrdinalIgnoreCase)){throw 'dr_owned_app_present_no_kill'}}
 foreach($port in @(55449,3146)){$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$listener.Start()}finally{$listener.Stop()}}
 # PostgreSQL itself handles this verified stale PID and WAL during ordinary startup.
}
