Import-Module (Join-Path $PSScriptRoot 'ops-pg-protocol02.psm1') -Force
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PWD 'tools/sprint21/owned-runtime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PWD 'tools/sprint21-capacity/continuation-resource-guard.psm1') -Force
if ('S22Process' -as [type]) { throw 's22_type_already_loaded_use_fresh_host' }
Add-Type -Path (Join-Path $PWD 'tools/sprint22/BrokerRuntime.cs')
Add-Type -Path (Join-Path $PWD 'tools/sprint22/MemoryProbe.cs')

function Assert-S22Capacity([hashtable]$Config) {
 if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$Config.deadline_utc){throw 's22_deadline'}
 if((Get-PSDrive C).Free -lt 8GB){throw 's22_free_floor'}
 $r=Get-S20ResourceSnapshot (Join-Path $Config.workspace '.local/sprint21') (Join-Path $Config.workspace '.local/sprint21/root/target')
 if($r.root_logical_bytes -gt (10GB-512MB) -or $r.root_allocation_bytes -gt (10GB-512MB) -or $r.logical_bytes -gt (14GB-512MB) -or $r.allocation_bytes -gt (14GB-512MB)){throw 's22_headroom'}
 return $r
}
function Add-S22Event([hashtable]$State,[string]$Event,[string]$Label='') {
 if($State.events.Count -ge 4096){$State.stop.Stop('event_limit');throw 's22_event_limit'}
 $State.events.Add(@{sequence=$State.events.Count+1;utc=[DateTimeOffset]::UtcNow.ToString('o');event=$Event;label=$Label;stop_latched=$State.stop.Latched})
}
function Start-S22Command([hashtable]$State,[hashtable]$Command) {
 $State.stop.ThrowIfStopped()
 $label=[string]$Command.label
 if($label -cnotmatch '^[a-z][a-z0-9-]{0,47}$' -or $State.processes.ContainsKey($label) -or $State.processes.Count -ge 32){throw 's22_command_identity'}
 Assert-OwnedHash $Command.program $Command.sha256
 Assert-OwnedNoReparse $Command.program;Assert-OwnedNoReparse $Command.directory
 $base=Join-Path $State.output $label
 foreach($suffix in @('.stdout','.stderr','.start.json','.process.json')){if(Test-Path -LiteralPath ($base+$suffix)){throw 's22_output_collision'}}
 $environment=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($k in $Command.environment.Keys){$environment.Add([string]$k,[string]$Command.environment[$k])}
 $job=[S22Job]::new($label);$State.jobs.Add($job);$State.stop.Add($job)
 if($job.OwnerMember){$State.stop.Stop('collector_inside_workload_job');throw 'collector_inside_workload_job'}
 $controlFault=$Command.ContainsKey('control_fault') -and $Command.control_fault -ceq 'after-native-identity'
 try{$process=[S22Process]::new([IO.Path]::GetFullPath($Command.program),[string[]]$Command.arguments,[IO.Path]::GetFullPath($Command.directory),$environment,$base,[long]$Command.output_limit,$job,$State.stop,$controlFault)}catch{
  $cause=$_.Exception
  while($cause -and $cause -isnot [S22SpawnFailure]){$cause=$cause.InnerException}
  if($cause -is [S22SpawnFailure]){
   $process=$cause.Owner;$State.processes[$label]=$process;$State.failed_admission_label=$label
   Write-OwnedJson ($base+'.start.json') @{label=$label;pid=$process.Pid;native_creation_filetime=$process.CreationFileTime;native_creation_utc=$process.CreationUtc;native_creation_observed=($process.CreationFileTime -gt 0);image_observed=($null -ne $process.Image);program=$process.Image;created_suspended=$true;resumed=$false;admission_failed=$true;retained_native_handle=$true;capture_status='partial_or_missing';utc=[DateTimeOffset]::UtcNow.ToString('o')}
   Add-S22Event $State 'CREATED_CHILD_ADMISSION_FAILED_RETAINED' $label
  }
  throw
 }
 $State.processes[$label]=$process
 $start=@{label=$label;pid=$process.Pid;native_creation_filetime=$process.CreationFileTime;native_creation_utc=$process.CreationUtc;program=$process.Image;program_sha256=$Command.sha256;retained_native_handle=$true;job_member=$process.Member;collector_outside_job=(!$job.OwnerMember);stdout_capture_ready=$process.Out.Ready;stderr_capture_ready=$process.Err.Ready;created_suspended=$true;resumed=$false;utc=[DateTimeOffset]::UtcNow.ToString('o')}
 Write-OwnedJson ($base+'.start.json') $start
 Add-S22Event $State 'OWNED_SUSPENDED_CAPTURE_READY' $label
 if($Command.ContainsKey('deny_admission') -and $Command.deny_admission){$State.stop.Stop('ownership_confirmation_withheld');Add-S22Event $State 'ADMISSION_REFUSED' $label;return $process}
 # A record failure above never grants execution. The synchronized controller
 # is the final guard against a concurrent STOP from another capture pump.
 if($Command.ContainsKey('absolute_stop_ticks') -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Command.absolute_stop_ticks){$State.stop.Stop('pg_stop_absolute_deadline_before_resume');return $process}
 if($Command.ContainsKey('service') -and $Command.service){
  $callback=[Delegate]::CreateDelegate([Action[string]],$State.stop,'Stop')
  $State.service_watchers[$label]=[S22ServiceWatch]::new($process.Pid,$process.CreationFileTime,$process.Image,$callback)
  Add-S22Event $State 'SERVICE_EXIT_WATCH_ATTACHED' $label
 }
 if($Command.ContainsKey('pg_stop_generation')){
  $generation=[string]$Command.pg_stop_generation
  if(!$State.ContainsKey('pg_protocol') -or !$State.pg_protocol.window -or $State.pg_protocol.active -cne $generation -or !$State.pg_protocol.pairs.ContainsKey($generation) -or $State.pg_protocol.pairs[$generation] -cne $label -or !$State.processes.ContainsKey($generation) -or !$State.service_watchers.ContainsKey($generation)){throw 'pg_expect_exit_marker_scope'}
  $pg=$State.processes[$generation]
  if($pg.Exited -or !$pg.Resumed -or !$pg.Member -or $pg.Pid -ne $State.pg_protocol.pending_pg_pid -or $pg.CreationFileTime -ne $State.pg_protocol.pending_pg_birth){throw 'pg_changed_during_stop_prepare'}
  $State.stop.ThrowIfStopped()
  # All fallible hash/spawn/receipt setup is complete. No work between ExpectExit and Admit.
  $State.service_watchers[$generation].ExpectExit()
 }
  $State.stop.Admit($process)
  if($label -cne 'worker'){[void]$process.WatchDeadline([int]($Command.seconds*1000))}
  Add-S22Event $State 'RESUMED' $label
 return $process
}
function Get-S22Stream([object]$Capture,[string]$Path,[bool]$Drained){
 if(!$Capture){return @{eof=$false;complete=$false;truncated=$false;fault=$true;bytes=0;observed=$null;sha256=$null}}
 return @{eof=$Capture.Eof;complete=($Drained -and $Capture.Eof -and !$Capture.Truncated -and !$Capture.Fault);truncated=$Capture.Truncated;fault=$Capture.Fault;bytes=$Capture.Persisted;observed=$Capture.Observed;sha256=$(if($Capture.Pump.IsCompleted){Get-OwnedHash $Path}else{$null})}
}
function Test-S22Barrier([string]$Path,[string]$Expected){
 $s=[IO.File]::Open($Path,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 try{$b=[byte[]]::new(13);$n=$s.Read($b,0,13);return $n -eq 12 -and $s.Length -eq 12 -and [Text.Encoding]::ASCII.GetString($b,0,$n) -ceq $Expected}finally{$s.Dispose()}
}
function Complete-S22Command([hashtable]$State,[string]$Label,[int]$DrainMilliseconds=10000) {
 if($State.completed.ContainsKey($Label)){return $State.completed[$Label]}
 $p=$State.processes[$Label]
 if(!$p.Exited){throw 's22_real_exit_required'}
 $drained=$p.Drain($DrainMilliseconds)
 $o=Get-S22Stream $p.Out ($p.Base+'.stdout') $drained;$e=Get-S22Stream $p.Err ($p.Base+'.stderr') $drained
 $r=@{label=$Label;pid=$p.Pid;native_creation_filetime=$p.CreationFileTime;program=$p.Image;retained_native_handle=$true;native_exit=$p.ExitCode;resumed=$p.Resumed;resume_utc=$p.ResumeUtc;completed_utc=[DateTimeOffset]::UtcNow.ToString('o');stdout_capture_initialized=($null -ne $p.Out);stderr_capture_initialized=($null -ne $p.Err);stdout_eof=$o.eof;stderr_eof=$e.eof;stdout_complete=$o.complete;stderr_complete=$e.complete;stdout_truncated=$o.truncated;stderr_truncated=$e.truncated;stdout_fault=$o.fault;stderr_fault=$e.fault;stdout_bytes_persisted=$o.bytes;stderr_bytes_persisted=$e.bytes;stdout_bytes_observed=$o.observed;stderr_bytes_observed=$e.observed;stdout_sha256=$o.sha256;stderr_sha256=$e.sha256;drain_timeout=(!$drained);source_status=$(if(!$drained -or $o.fault -or $e.fault){'missing_or_fault'}elseif($o.truncated -or $e.truncated){'truncated'}else{'captured'})}
 Write-OwnedJson ($p.Base+'.process.json') $r
 $State.completed[$Label]=$r
 Add-S22Event $State 'ACTUAL_EXIT_AND_CAPTURE_SAVED' $Label
 return $r
}
function Invoke-S22Broker([hashtable]$Config,[hashtable]$Worker,[hashtable[]]$Commands,[string]$Output,[string]$Control='none') {
 Assert-OwnedPrivateDirectory $Output
 $state=@{stop=[S22Stop]::new();output=$Output;processes=@{};completed=@{};service_watchers=@{};jobs=[Collections.Generic.List[S22Job]]::new();events=[Collections.Generic.List[object]]::new()}
 $allow=@{};foreach($cmd in $Commands){if($allow.ContainsKey($cmd.label)){throw 's22_duplicate_command'};$allow[$cmd.label]=$cmd}
 $ipc=New-OwnedPrivateDirectory (Join-Path $Output 'ipc')
 $Worker.arguments=@($Worker.arguments)+@('-Ipc',$ipc)
 $watch=$null;$guardLock=$null;$failure=$null;$guardFailure=$null;$primaryException=$null;$secondaryDiagnostics=[Collections.Generic.List[object]]::new();$workerProcess=$null;$controlTriggered=$false
 $sampleBarrier=$null;$absoluteStop=$null;$stopStage=$false;$pgProtocol=New-S24PgProtocol;$state.pg_protocol=$pgProtocol;$pgTransactions=[Collections.Generic.List[object]]::new()
 $nextSequence=1;$nextSample=[DateTimeOffset]::UtcNow.AddSeconds(20)
 $start=[DateTimeOffset]::UtcNow
 $remaining=[Math]::Min([double]$Config.session_seconds,([DateTimeOffset]$Config.deadline_utc-$start).TotalSeconds)
 if($remaining -le 0){throw 's22_session_expired'}
 $state.stop.ArmDeadline([int][Math]::Floor($remaining*1000))
 try{
  $workerProcess=Start-S22Command $state $Worker
  $watch=$workerProcess.WatchWorker()
  while(!$state.stop.Latched){
   if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$Config.deadline_utc){$state.stop.Stop('deadline');break}
   if(([DateTimeOffset]::UtcNow-$start).TotalSeconds -ge $Config.session_seconds){$state.stop.Stop('session_timeout');break}
   foreach($label in @($state.processes.Keys)){
    $p=$state.processes[$label]
    if($p.Exited -and !$state.completed.ContainsKey($label)){[void](Complete-S22Command $state $label 1000)}
    if($label -cne $Worker.label -and !$p.Exited -and $p.Resumed -and $allow.ContainsKey($label) -and ([DateTimeOffset]::UtcNow-[DateTimeOffset]$p.ResumeUtc).TotalSeconds -ge $allow[$label].seconds){$state.stop.Stop('child_timeout');break}
   }
   if($state.stop.Latched){break}
   $request=Join-Path $ipc ('{0:D6}.req' -f $nextSequence)
   if(Test-Path -LiteralPath $request){
    if($nextSequence -gt 512){$state.stop.Stop('ipc_bound');throw 's22_ipc_bound'}
    Assert-OwnedNoReparse $request
    $payload=Join-Path $ipc ('{0:D6}.reqdata' -f $nextSequence);Assert-OwnedNoReparse $payload
    $input=[IO.File]::Open($payload,'Open','Read','Read')
    try{$bytes=[byte[]]::new(257);$n=$input.Read($bytes,0,257);if($n -gt 256 -or $input.Length -ne $n -or @($bytes[0..($n-1)]|Where-Object{$_ -gt 127}).Count){$state.stop.Stop('ipc_bound');throw 's22_ipc_bound'};$line=[Text.Encoding]::ASCII.GetString($bytes,0,$n)}finally{$input.Dispose()}
    if($line -cnotmatch '^(START|STATUS|KILL|PGSTOP) ([a-z][a-z0-9-]{0,47})\n$'){$state.stop.Stop('ipc_shape');throw 's22_ipc_shape'}
    $op=$Matches[1];$label=$Matches[2]
    Add-S22Event $state ('REQUEST_'+$op) $label
    if(!$allow.ContainsKey($label)){$state.stop.Stop('ipc_not_allowlisted');throw 's22_unknown_command'}
    Assert-S24PgOperation $pgProtocol $op $label
    if($op -ceq 'START'){
     if($pgProtocol.pairs.ContainsKey($label)){
      if(Test-Path -LiteralPath (Join-Path $Config.pgdata 'postmaster.pid')){throw 'pg_start_pid_present'}
      $bind=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,55449);try{$bind.Start()}finally{$bind.Stop()}
     }
     [void](Start-S22Command $state $allow[$label])
     if($pgProtocol.pairs.ContainsKey($label)){$pgProtocol.active=$label;$pgProtocol.generations[$label]='Running';Add-S22Event $state 'PG_GENERATION_STARTED' $label}
    }
    elseif($op -ceq 'PGSTOP'){
     $stopLabel=$pgProtocol.pairs[$label]
     if(!$allow.ContainsKey($stopLabel) -or !$state.processes.ContainsKey($label) -or $state.processes[$label].Exited -or !$state.service_watchers.ContainsKey($label)){throw 'pg_stop_live_owned_required'}
     if($label -ceq 'postgres-g1'){
      if(!$state.processes.ContainsKey('app-live') -or $state.processes['app-live'].Exited -or !$state.processes['app-live'].Resumed -or !$state.processes['app-live'].Member -or !$state.service_watchers.ContainsKey('app-live')){throw 'pg_first_stop_live_app_required'}
     }
     if($label -ceq 'postgres-g2'){
      if(!$state.completed.ContainsKey('app-restarted') -or !$state.completed['app-restarted'].stdout_complete -or !$state.completed['app-restarted'].stderr_complete -or $state.completed['app-restarted'].native_exit -ne 137){throw 'pg_final_stop_app_not_closed'}
     }
     foreach($other in @($state.processes.Keys)){
      if($other -in @($Worker.label,$label)){continue}
      if($label -ceq 'postgres-g1' -and $other -ceq 'app-live'){continue}
      if(!$state.completed.ContainsKey($other) -or !$state.completed[$other].stdout_complete -or !$state.completed[$other].stderr_complete -or $state.completed[$other].source_status -cne 'captured'){throw 'pg_stop_observations_not_quiescent'}
     }
     Add-S22Event $state 'PG_STOP_GUARD_BEGIN' $label
     try{$fresh=Assert-S22Capacity $Config}catch{if(!$guardFailure){$cause=$_.Exception.GetBaseException();$guardFailure=@{type=$cause.GetType().FullName;hresult=$cause.HResult;message=$cause.Message;utc=[DateTimeOffset]::UtcNow.ToString('o');source='pg_stop_pre_guard'}};$state.stop.Stop('resource_guard_failure');throw}
     Add-S22Event $state 'PG_STOP_GUARD_COMPLETE' $label
     $state.stop.ThrowIfStopped();if($state.processes[$label].Exited){throw 'pg_exit_before_stop_admission'}
     $ticks=[Diagnostics.Stopwatch]::GetTimestamp();$deadlineTicks=$ticks+19*[Diagnostics.Stopwatch]::Frequency
     $callback=[Delegate]::CreateDelegate([Action[string]],$state.stop,'Stop')
     $absoluteStop=[S22AbsoluteStop]::new($deadlineTicks,$callback);$pgProtocol.window=$true
     Add-S22Event $state 'PG_STOP_TIMER_ARMED' $label
     $allow[$stopLabel].absolute_stop_ticks=$deadlineTicks
     $pgProtocol.pending_pg_pid=$state.processes[$label].Pid;$pgProtocol.pending_pg_birth=$state.processes[$label].CreationFileTime
     $allow[$stopLabel].pg_stop_generation=$label
     [void](Start-S22Command $state $allow[$stopLabel])
     while(!$state.processes[$stopLabel].Exited -or !$state.processes[$label].Exited){$state.stop.ThrowIfStopped();if([Diagnostics.Stopwatch]::GetTimestamp() -ge $deadlineTicks){$state.stop.Stop('pg_stop_absolute_deadline');throw 'pg_stop_absolute_deadline'};Start-Sleep -Milliseconds 20}
     foreach($closed in @($stopLabel,$label)){
      $left=[int][Math]::Max(0,[Math]::Min(1000,1000*($deadlineTicks-[Diagnostics.Stopwatch]::GetTimestamp())/[Diagnostics.Stopwatch]::Frequency))
      $record=Complete-S22Command $state $closed $left
      if($record.native_exit -ne 0 -or !$record.stdout_complete -or !$record.stderr_complete -or $record.source_status -cne 'captured'){throw 'pg_stop_complete_capture_required'}
     }
     if(Test-Path -LiteralPath (Join-Path $Config.pgdata 'postmaster.pid')){throw 'pg_stop_pid_remains'}
     if([Diagnostics.Stopwatch]::GetTimestamp() -ge $deadlineTicks -or $absoluteStop.Fired){throw 'pg_stop_absolute_deadline'}
     Add-S22Event $state 'PG_STOP_CAPTURE_CLOSED' $label
     $absoluteStop.Dispose();if($absoluteStop.Fired){throw 'pg_stop_absolute_deadline'};$absoluteStop=$null
     Add-S22Event $state 'PG_STOP_TIMER_DISPOSED' $label
     Add-S22Event $state 'PG_POST_STOP_GUARD_BEGIN' $label
     try{$post=Assert-S22Capacity $Config}catch{if(!$guardFailure){$cause=$_.Exception.GetBaseException();$guardFailure=@{type=$cause.GetType().FullName;hresult=$cause.HResult;message=$cause.Message;utc=[DateTimeOffset]::UtcNow.ToString('o');source='pg_stop_post_guard'}};$state.stop.Stop('resource_guard_failure');throw}
     $state.stop.ThrowIfStopped();$pgProtocol.generations[$label]='Closed';$pgProtocol.active=$null;$pgProtocol.window=$false
     $nextSample=[DateTimeOffset]::UtcNow.AddSeconds(20);Add-S22Event $state 'PG_POST_STOP_GUARD_COMPLETE_COMMANDS_REOPENED' $label
     $transaction=@{generation=$label;pg_pid=$state.processes[$label].Pid;pg_birth=$state.processes[$label].CreationFileTime;stop_label=$stopLabel;before=$fresh;after=$post;stop_window_seconds=19;scanner_unchanged=$true;both_full_eof=$true;pid_absent=$true;completed_utc=[DateTimeOffset]::UtcNow.ToString('o')}
     $pgTransactions.Add($transaction);Write-OwnedJson (Join-Path $Output ($label+'-stop-transaction.json')) $transaction
    }
    elseif(!$state.processes.ContainsKey($label)){$state.stop.Stop('ipc_unknown_process');throw 's22_unknown_process'}
    elseif($op -ceq 'KILL'){if($state.service_watchers.ContainsKey($label)){$state.service_watchers[$label].ExpectExit()};$state.processes[$label].StopOwnJob();Add-S22Event $state 'REQUESTED_JOB_STOP' $label}
    $p=$state.processes[$label]
    $response=@{sequence=$nextSequence;label=$label;pid=$p.Pid;creation_filetime=$p.CreationFileTime;resumed=$p.Resumed;exited=$p.Exited;stop_latched=$state.stop.Latched;native_exit=$(if($p.Exited){$p.ExitCode}else{$null})}
    $data=Join-Path $ipc ('{0:D6}.ackdata' -f $nextSequence);$ack=Join-Path $ipc ('{0:D6}.ack' -f $nextSequence)
    Write-OwnedJson $data $response
    $ready=[IO.File]::Open($ack,'CreateNew','Write','Read');try{$ready.WriteByte(1);$ready.Flush($true)}finally{$ready.Dispose()}
    $nextSequence++
   }
   if(!$controlTriggered -and $state.processes.ContainsKey('child')){
    $p=$state.processes.child
    # The exact ASCII barrier is emitted before the child's indefinite work.
    if($p.Out.Persisted -eq 12 -and $p.Err.Persisted -eq 12 -and $p.Resumed -and (Test-S22Barrier ($p.Base+'.stdout') "child-ready`n") -and (Test-S22Barrier ($p.Base+'.stderr') "child-error`n")){
      if($Control -ceq 'absolute-stop'){$controlTriggered=$true;$ticks=[Diagnostics.Stopwatch]::GetTimestamp()+[long]([Diagnostics.Stopwatch]::Frequency/2);$callback=[Delegate]::CreateDelegate([Action[string]],$state.stop,'Stop');$absoluteStop=[S22AbsoluteStop]::new($ticks,$callback);Add-S22Event $state 'CONTROL_ABSOLUTE_STOP_ARMED' 'child';Add-S22Event $state 'CONTROL_BROKER_BLOCK_BEGIN' 'child';[Threading.Thread]::Sleep(1200);Add-S22Event $state 'CONTROL_BROKER_BLOCK_END' 'child'}
     elseif($Control -ceq 'kill-worker'){$controlTriggered=$true;Add-S22Event $state 'CONTROL_KILL_WORKER' 'worker';$workerProcess.StopOwnJob()}
     elseif($Control -ceq 'guard-failure'){
      $controlTriggered=$true;Add-S22Event $state 'CONTROL_GUARD_SHARING_DENIAL' 'child'
      $locked=Join-Path $Output 'guard-denial.bin';[IO.File]::WriteAllBytes($locked,[byte[]]@(83,50,50));$guardLock=[IO.File]::Open($locked,'Open','ReadWrite','None')
      # Genuine unchanged resource scanner failure; not an injected return value.
      $guardFailed=$false
      try{[void](Assert-S22Capacity $Config)}catch{
       $cause=$_.Exception.GetBaseException();$guardFailed=$true
       $expectedSharing=$cause -is [IO.IOException] -and $cause.HResult -eq -2147024864 -and $cause.Message.Contains($locked,[StringComparison]::OrdinalIgnoreCase)
       $guardFailure=@{type=$cause.GetType().FullName;hresult=$cause.HResult;target=$locked;expected_owned_sharing_failure=$expectedSharing;message=$cause.Message;utc=[DateTimeOffset]::UtcNow.ToString('o');source='owned_sharing_control'};$state.stop.Stop('resource_guard_failure')
       if(!$expectedSharing){$failure='unexpected_guard_failure'}
       Add-S22Event $state 'ACTUAL_GUARD_FAILURE' 'child'
      }
      if(!$guardFailed){$state.stop.Stop('guard_control_failed');throw 'guard_denial_not_observed'}
      break
     }
    }
   }
   if([DateTimeOffset]::UtcNow -ge $nextSample){
    $periodicStartedUtc=[DateTimeOffset]::UtcNow.ToString('o')
    try{$periodicCapacity=Assert-S22Capacity $Config}catch{if(!$guardFailure){$cause=$_.Exception.GetBaseException();$guardFailure=@{type=$cause.GetType().FullName;hresult=$cause.HResult;message=$cause.Message;utc=[DateTimeOffset]::UtcNow.ToString('o');source='capacity_sample'}};$state.stop.Stop('resource_guard_failure');throw}
    $capacitySequence = 1 + @($state.events | Where-Object { $_.event -ceq 'PERIODIC_CAPACITY_RECEIPT' }).Count
    $capacityReceipt = Join-Path $Output ('capacity-' + ('{0:D4}' -f $capacitySequence) + '.json')
    if(Test-Path -LiteralPath $capacityReceipt){throw 'capacity_receipt_collision'}
    Write-OwnedJson $capacityReceipt @{started_utc=$periodicStartedUtc;completed_utc=[DateTimeOffset]::UtcNow.ToString('o');snapshot=$periodicCapacity;source='unchanged_serial_periodic_guard';root_guard_sha256='8EC87E1E91F07514C18B2698F5E77B35CD7A02AB8DCEEA4FF7268FB8609C3EC6'}
    Add-S22Event $state 'PERIODIC_CAPACITY_RECEIPT'
    $nextSample=[DateTimeOffset]::UtcNow.AddSeconds(20)
   }
   Start-Sleep -Milliseconds 20
  }
 }catch{$cause=$_.Exception.GetBaseException();$primaryException=@{type=$cause.GetType().FullName;hresult=$cause.HResult;message=$cause.Message;utc=[DateTimeOffset]::UtcNow.ToString('o')};$caught=$(if($state.ContainsKey('failed_admission_label')){'spawn_admission_failure'}else{$_.Exception.Message});if(!$failure){$failure=$caught}else{$secondaryDiagnostics.Add(@{code=$caught;stage='broker_catch';exception=$primaryException})};$state.stop.Stop('broker_exception')}
 finally{
  # STOP is in memory and terminates Jobs before any fallible evidence write.
  $state.stop.Stop('broker_finalization')
  $finalEnd=[DateTimeOffset]$state.stop.FinalizationDeadlineUtc
  $probe=@{label=$null;attempted=$false;refused=$false;exception_code=$null;process_count_before=$state.processes.Count;process_count_after=$null;resume_unchanged=$false}
  $probeLabel=$(if($state.processes.ContainsKey('child')){'child'}elseif($state.processes.Count -gt 0){@($state.processes.Keys|Sort-Object)[0]}else{$null})
  if($null -ne $probeLabel){
   $probe.label=$probeLabel;$probe.attempted=$true;$probeProcess=$state.processes[$probeLabel];$beforeResume=$probeProcess.ResumeUtc
   try{$state.stop.Admit($probeProcess)}catch{$probe.exception_code=$_.Exception.GetBaseException().Message;$probe.refused=$probe.exception_code -ceq 'stop_latched_no_admission'}
   $probe.resume_unchanged=$beforeResume -ceq $probeProcess.ResumeUtc
  }
  $probe.process_count_after=$state.processes.Count
  if(!$probe.refused -or !$probe.resume_unchanged -or $probe.process_count_before -ne $probe.process_count_after){if(!$failure){$failure='post_stop_admission_not_refused'}else{$secondaryDiagnostics.Add(@{code='post_stop_admission_not_refused';stage='finalization'})}}
  foreach($label in @($state.processes.Keys)){
   try{
    $left=[int][Math]::Max(0,[Math]::Min(10000,($finalEnd-[DateTimeOffset]::UtcNow).TotalMilliseconds))
    if(!$state.processes[$label].Wait($left)){throw 'actual_exit_missing'}
    $left=[int][Math]::Max(0,[Math]::Min(10000,($finalEnd-[DateTimeOffset]::UtcNow).TotalMilliseconds))
    [void](Complete-S22Command $state $label $left)
   }catch{if(!$failure){$failure='collector_completion_missing'}else{$secondaryDiagnostics.Add(@{code='collector_completion_missing';stage='finalization'})};Add-S22Event $state 'UNKNOWN_COMPLETION' $label}
  }
  if($guardLock){$guardLock.Dispose()}
  if($watch){[void]$watch.Wait(1000)}
  foreach($p in $state.processes.Values){$p.Dispose()};foreach($job in $state.jobs){$job.Dispose()}
  $watchSummary=@{};foreach($label in $state.service_watchers.Keys){$w=$state.service_watchers[$label];$w.Dispose();$watchSummary[$label]=@{attached_utc=$w.AttachedUtc;expected_exit=$w.ExpectedExit;triggered=$w.Triggered}}
  if($state.stop.KillFault){if(!$failure){$failure='kill_request_fault'}else{$secondaryDiagnostics.Add(@{code='kill_request_fault';stage='finalization'})}}
  if([DateTimeOffset]::UtcNow -ge $finalEnd){throw 'collector_finalization_expired'}
  if($absoluteStop){$absoluteStop.Dispose();if($absoluteStop.Fired){if(!$failure){$failure='pg_stop_absolute_deadline'}else{$secondaryDiagnostics.Add(@{code='pg_stop_absolute_deadline';stage='finalization'})}}}
  Write-OwnedJson (Join-Path $Output 'broker-result.json') @{stop_reason=$state.stop.Reason;stop_utc=$state.stop.Utc;kill_requests_completed_utc=$state.stop.KillCompletedUtc;kill_fault=$state.stop.KillFault;native_kill_operations=$state.stop.KillOperations();failure=$failure;primary_exception=$primaryException;secondary_diagnostics=$secondaryDiagnostics.ToArray();guard_failure=$guardFailure;post_stop_probe=$probe;service_watchers=$watchSummary;sample_barrier=$sampleBarrier;pg_stop_transactions=$pgTransactions.ToArray();pg_protocol=$pgProtocol;absolute_stop_timer_fired=$(if($absoluteStop){$absoluteStop.Fired}else{$false});control=$Control;control_triggered=$controlTriggered;events=$state.events.ToArray();process_count=$state.processes.Count;completed_count=$state.completed.Count;requests=$nextSequence-1;collector_finalization_deadline=$finalEnd.ToString('o');cleanup_completed_utc=[DateTimeOffset]::UtcNow.ToString('o');receipt_write_hard_timer_still_armed=$true;no_new_go_after_stop=($probe.refused -and $probe.resume_unchanged);collector_host_death_supported=$false}
  $state.stop.Dispose()
 }
 return @{records=$state.completed;failure=$failure;primary_exception=$primaryException;secondary_diagnostics=$secondaryDiagnostics.ToArray();kill_fault=$state.stop.KillFault;guard_failure=$guardFailure;stop_reason=$state.stop.Reason;output=$Output}
}
# Explicitly forward the metadata/private-directory helpers used by the phase.
# Legacy process-spawn helpers remain private to this module.
Export-ModuleMember -Function *-S22*,Assert-OwnedPrivateDirectory,New-OwnedPrivateDirectory,Write-OwnedJson,Get-OwnedHash,Assert-OwnedHash
