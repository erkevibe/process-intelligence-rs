# Execute the actual production diagnostic's new state predicates from its AST.
# Injected process/capture objects only: no phase import, native process or PG.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../tools/sprint15/full-lock2-lifecycle-phase.ps1'
$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$errors)
if($errors.Count){throw 'lifecycle_source_parse'}
foreach($name in @('CaptureFlags','CaptureHealthy','HotProducerStates','AssertHot')){$f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object Name -ceq $name);if($f.Count -ne 1){throw 'lifecycle_function_unique'};. ([scriptblock]::Create($f[0].Extent.Text))}
# Isolate only unchanged file enumeration / diagnostic writes. On Windows also
# exercise the actual AssertHot wiring and its real drive-floor precondition.
function GetHotFiles {return @()}
function Write-OwnedJson([string]$Path,$Value){$script:lastDiagnostic=$Value}
$guardCases=0;$exerciseGuard=$IsWindows -and [IO.DriveInfo]::new('C').AvailableFreeSpace -ge 8GB
function Child([int]$Id,[bool]$Exited=$false){return @{Process=[pscustomobject]@{Id=$Id;HasExited=$Exited;ExitCode=-1};Record=@{native_creation_utc='2026-10-20T10:00:00Z'};OutCapture=[pscustomobject]@{Bytes=0L;LimitReached=$false;ReadComplete=$true;Pump=[pscustomobject]@{IsFaulted=$false;IsCanceled=$false;IsCompleted=$true}};ErrCapture=[pscustomobject]@{Bytes=0L;LimitReached=$false;ReadComplete=$true;Pump=[pscustomobject]@{IsFaulted=$false;IsCanceled=$false;IsCompleted=$true}}}}
$image=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'synthetic-postgres.exe'))
$stamp=[DateTimeOffset]::Parse('2026-10-20T10:00:00Z').UtcDateTime
$cases=@('expected-closed','holder-live','coordinator-live','coordinator-wrong-exit','coordinator-new-bytes','coordinator-missing-eof','coordinator-pump-pending','coordinator-wrong-creation','missing-proof','missing-command','missing-observer','command-exit','observer-exit','holder-exit','command-cap','observer-fault','holder-cancel','pg-exit','pg-not-member','pg-wrong-pid','pg-wrong-time','pg-wrong-image','pg-missing')
foreach($case in $cases){
 $command=Child 101;$observer=Child 102;$holder=$null;$co=Child 103 $true
 $job=[pscustomobject]@{Allows=$true};$job|Add-Member ScriptMethod Member {param($handle);return $this.Allows}
 $pr=@{Name='postgres';Handle=[IntPtr]::new(123);Creation=$stamp.ToString('o');Process=[pscustomobject]@{Id=104;HasExited=$false;StartTime=$stamp;MainModule=[pscustomobject]@{FileName=$image}}}
 $service=@{Coordinator=$co;Job=$job;Processes=@($pr)}
 $script:bootstrapClosure=@{coordinator=@{pid=103;creation=$co.Record.native_creation_utc;native_exit=-1;stdout_bytes=0L;stderr_bytes=0L};pg=@{pid=104;creation=$stamp.ToString('o');image=$image}}
 switch($case){
  holder-live{$holder=Child 105}
  coordinator-live{$co.Process.HasExited=$false}
  coordinator-wrong-exit{$co.Process.ExitCode=0}
  coordinator-new-bytes{$co.OutCapture.Bytes=1L}
  coordinator-missing-eof{$co.OutCapture.ReadComplete=$false}
  coordinator-pump-pending{$co.OutCapture.Pump.IsCompleted=$false}
  coordinator-wrong-creation{$co.Record.native_creation_utc='2026-10-20T10:00:01Z'}
  missing-proof{$script:bootstrapClosure=$null}
  missing-command{$command=$null}
  missing-observer{$observer=$null}
  command-exit{$command.Process.HasExited=$true}
  observer-exit{$observer.Process.HasExited=$true}
  holder-exit{$holder=Child 105 $true}
  command-cap{$command.OutCapture.LimitReached=$true}
  observer-fault{$observer.ErrCapture.Pump.IsFaulted=$true}
  holder-cancel{$holder=Child 105;$holder.OutCapture.Pump.IsCanceled=$true}
  pg-exit{$pr.Process.HasExited=$true}
  pg-not-member{$job.Allows=$false}
  pg-wrong-pid{$pr.Process.Id=999}
  pg-wrong-time{$pr.Process.StartTime=$stamp.AddSeconds(1)}
  pg-wrong-image{$pr.Process.MainModule.FileName=$image+'.other'}
  pg-missing{$service.Processes=@()}
 }
 $states=HotProducerStates;$bad=@($states|Where-Object {!$_.valid})
 $positive=$case -cin @('expected-closed','holder-live')
 if(($positive -and $bad.Count) -or (!$positive -and !$bad.Count)){throw ('lifecycle_case_failed_'+$case)}
 if(!$positive -and @($bad|Where-Object {!$_.name}).Count){throw 'lifecycle_failure_must_be_named'}
 if($exerciseGuard){
  $script:hotActive=$true;$script:hotBaseline=@{synthetic=0L};$script:hotCharged=0L;$script:hotEnd=[DateTime]::UtcNow.AddMinutes(1);$deadline=[DateTime]::UtcNow.AddMinutes(2);$out=[IO.Path]::GetTempPath();$script:lastDiagnostic=$null
  $rejected=$false;try{AssertHot}catch{if($_.Exception.Message -cne 'boundary_hot_named_producer_state_failed'){throw};$rejected=$true}
  if(($positive -and $rejected) -or (!$positive -and !$rejected)){throw ('actual_assert_hot_wiring_failed_'+$case)}
  if(!$positive -and (!$script:lastDiagnostic -or !$script:lastDiagnostic.no_boundary_success_claim)){throw 'actual_assert_hot_named_record_missing'}
  $guardCases++
 }
}
@{status='ACTUAL_HOT_PRODUCER_PREDICATES_REGRESSION_PASSED';cases=$cases.Count;actual_assert_hot_cases=$guardCases;source_sha256=(Get-FileHash $source).Hash;no_native_children_or_pg=$true;limits='Injected retained-process states test actual new predicates and Windows AssertHot wiring with enumeration/write stubs; native FreezeBootstrapClosure/ownership and full real fault still require separately reviewed runtime. Non-Windows runs only predicates.'}|ConvertTo-Json -Compress
