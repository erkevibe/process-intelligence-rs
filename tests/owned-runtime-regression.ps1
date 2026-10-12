param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'tools/owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedPrivateDirectory $OutputDirectory
$pwsh=(Get-Process -Id $PID).Path
$node='C:/Users/alikh/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe'
$fixture=Join-Path $PSScriptRoot 'owned-runtime-fixture.cjs'
$pipeFixture=Join-Path $PSScriptRoot 'owned-runtime-pipe-fixture.ps1'
$supervisor=Join-Path $root 'tools/run-owned-process.ps1'
$checks=[Collections.Generic.List[object]]::new()
function Check([bool]$Condition,[string]$Name) { if (-not $Condition) { throw ('regression_failed:'+ $Name) }; $checks.Add(@{name=$Name;status='PASS'}) }
function Refuses([scriptblock]$Action,[string]$Name) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed $Name }
Assert-OwnedHash $node '3602F2BB1A10F2CBAB4C36886218A33C1AB3DB87290E73B033C46C77147D0237'
Assert-OwnedHash $fixture (Get-OwnedHash $fixture).ToLowerInvariant()
Check ((Get-OwnedByteSum @([ordered]@{bytes=147931704},[pscustomobject]@{bytes=10679768})) -eq 158611472) 'pg_bytes_and_mixed_dictionaries'
Check ((Get-OwnedByteSum @()) -eq 0) 'empty_byte_sum'
foreach ($bad in @($null,$true,'12',-1,1.5)) { Refuses { Get-OwnedByteSum @(@{bytes=$bad}) } ('invalid_bytes_'+[string]$bad) }
Refuses { Get-OwnedByteSum @(@{bytes=[long]::MaxValue},@{bytes=1}) } 'int64_overflow'
$data=Join-Path $OutputDirectory 'path with spaces/pgdata'
$line='"C:\fixture\postgres.exe" -D "'+$data+'" -p 5462'
Check ((Get-OwnedDatadirArgument $line ($data.Replace('\','/'))) -ceq (Get-OwnedCanonicalPath $data)) 'quoted_canonical_datadir'
Refuses { Get-OwnedDatadirArgument ($line+' -D "C:\other"') $data } 'duplicate_datadir'
Refuses { Get-OwnedDatadirArgument ($line+' --pgdata=C:\other') $data } 'conflicting_datadir'
Refuses { Get-OwnedDatadirArgument $line (Join-Path $OutputDirectory 'other') } 'wrong_datadir'
Refuses { Assert-OwnedPrivateDirectory ($OutputDirectory+'-sibling') } 'sibling_directory_not_owned'
Assert-OwnedNoReparse $OutputDirectory
Check $true 'workspace_handle_resolution_with_cloud_ancestors'
$insideTarget=New-OwnedPrivateDirectory (Join-Path $OutputDirectory 'reparse-target')
$insideLink=Join-Path $OutputDirectory 'reparse-link'
New-Item -ItemType Junction -Path $insideLink -Target $insideTarget | Out-Null
Refuses { Assert-OwnedNoReparse $insideLink } 'interior_reparse_refusal'
$inputStream=[IO.MemoryStream]::new([byte[]]@(1,2,3))
$failedOutput=[IO.MemoryStream]::new(); $failedOutput.Dispose()
$brokenCapture=[PiBoundedCapture]::new($inputStream,$failedOutput,1024)
try { [void]$brokenCapture.Pump.Wait(5000) } catch { }
Check ($brokenCapture.Pump.IsFaulted -and -not $brokenCapture.ReadComplete) 'capture_pump_failure_is_not_complete_unit'
$inputStream.Dispose()
function Case([string]$Name,[string[]]$CaseArguments,[int]$Seconds,[long]$Cap=1048576,[string]$BadPin='',[bool]$PipeHolder=$false) {
    $dir=New-OwnedPrivateDirectory (Join-Path $OutputDirectory $Name)
    $c=[ordered]@{
        program=$node;program_sha256=Get-OwnedHash $node;arguments=@($fixture)+$CaseArguments;cwd=$root;output_directory=$dir
        environment=@{};inputs=@(@{path=$fixture;sha256=Get-OwnedHash $fixture},@{path=$pipeFixture;sha256=Get-OwnedHash $pipeFixture})
        module_sha256=Get-OwnedHash (Join-Path $root 'tools/owned-runtime.psm1')
        worker_sha256=Get-OwnedHash (Join-Path $root 'tools/owned-process-worker.ps1')
        supervisor_sha256=Get-OwnedHash $supervisor;pwsh_sha256=Get-OwnedHash $pwsh
        timeout_seconds=$Seconds;required_free_bytes=1GB;runtime_floor_bytes=512MB;max_output_bytes=$Cap;deadline_utc='2026-10-12T17:21:00Z'
    }
    if ($PipeHolder) { $c.program=$pwsh; $c.program_sha256=Get-OwnedHash $pwsh; $c.arguments=@('-NoProfile','-File',$pipeFixture,'-NodeExe',$node,'-NodeSha256',(Get-OwnedHash $node)) }
    if ($BadPin) { $c[$BadPin]='0'*64 }
    $config=Join-Path $dir 'config.json'; Write-OwnedJson $config $c
    $parentDir=New-OwnedPrivateDirectory (Join-Path $OutputDirectory ($Name+'-launcher'))
    $parent=Start-OwnedCapturedProcess -Program $pwsh -ProgramSha256 (Get-OwnedHash $pwsh) -Arguments @('-NoProfile','-File',$supervisor,'-ConfigPath',$config,'-ConfigSha256',(Get-OwnedHash $config)) -WorkingDirectory $root -OutputDirectory $parentDir -Label 'launch' -MaxOutputBytes 1048576
    if (-not $parent.Process.WaitForExit(60000)) { $parent.Process.Kill($true); [void]$parent.Process.WaitForExit(10000); throw 'regression_parent_timeout' }
    $native=Complete-OwnedCapturedProcess $parent
    Check ($native.stdout_complete -and $native.stderr_complete) ($Name+'_launcher_capture')
    if ($BadPin) {
        Check ($native.native_exit -ne 0 -and -not (Test-Path (Join-Path $dir 'runner.start.json')) -and -not (Test-Path (Join-Path $dir 'child.start.json'))) ($Name+'_refused_before_worker_or_command')
        return @{Dir=$dir;Launcher=$native;AdmissionRefused=$true}
    }
    $result=Get-Content (Join-Path $dir 'result.json') -Raw|ConvertFrom-Json -DateKind String
    Check ($result.exact_own_job -and $result.go_sent) ($Name+'_job_before_go')
    return @{Dir=$dir;Result=$result;Launcher=$native;Config=$config}
}
$values=@('path with spaces','é漢字','$literal','--','quoted"value','trailing\')
[void](Case 'bad-source-pin' @('argv') 30 1048576 'module_sha256')
[void](Case 'bad-tool-pin' @('argv') 30 1048576 'pwsh_sha256')
$a=Case 'argv' (@('argv')+$values) 30
Check ($a.Result.status -ceq 'COMMAND_COMPLETED' -and $a.Launcher.native_exit -eq 0) 'argv_success'
$actual=@(Get-Content (Join-Path $a.Dir 'child.stdout') -Raw|ConvertFrom-Json)
Check (($actual|ConvertTo-Json -Compress) -ceq ($values|ConvertTo-Json -Compress)) 'literal_argument_transport'
Check ((Get-Content (Join-Path $a.Dir 'child.stderr') -Raw) -ceq "fixture-stderr`n") 'separate_complete_stderr'
Refuses { Write-OwnedJson $a.Config @{replacement=$true} } 'create_new_collision'
$e=Case 'exit7' @('exit7') 30
$er=Get-Content (Join-Path $e.Dir 'child.process.json') -Raw|ConvertFrom-Json
Check ($er.native_exit -eq 7 -and $e.Result.native_exit -eq 7 -and $e.Result.status -ceq 'COMMAND_FAILED') 'actual_nonzero_native_exit'
$f=Case 'flood' @('flood') 30 2048
$fr=Get-Content (Join-Path $f.Dir 'child.process.json') -Raw|ConvertFrom-Json
Check ($f.Result.status -ceq 'COMMAND_FAILED' -and $fr.output_limit -and (Get-Item (Join-Path $f.Dir 'child.stdout')).Length -eq 2048) 'bounded_output_with_actual_child_exit'
$o=Case 'orphan' @() 30 1048576 '' $true
$or=Get-Content (Join-Path $o.Dir 'child.process.json') -Raw|ConvertFrom-Json
Check ($o.Result.status -ceq 'COMMAND_FAILED' -and $or.drain_timeout -and -not $or.stdout_complete -and $null -eq $or.stdout_sha256) 'inherited_pipe_hang_honest_bounded_drain'
Check ($or.stdout_bytes_persisted -gt 0 -and (Get-Item (Join-Path $o.Dir 'child.stdout')).Length -ge $or.stdout_bytes_persisted) 'partial_output_prefix_persisted_before_eof'
$orphanLines=@(Get-Content (Join-Path $o.Dir 'child.stdout') | Where-Object { $_.StartsWith('{') } | ForEach-Object { $_|ConvertFrom-Json })
$op=@($orphanLines | Where-Object { $_.PSObject.Properties.Name -contains 'parent' })[0]
$holder=@($orphanLines | Where-Object { $_.PSObject.Properties.Name -contains 'holder' })[0]
Check ($op.inheritable_stdout_pipe_verified -and $holder.holder -eq $op.descendant) 'actual_inherited_writer_output_witness'
Check (-not (Get-Process -Id $op.descendant -ErrorAction SilentlyContinue)) 'orphan_descendant_job_teardown'
$h=Case 'hang' @('hang') 8
Check ($h.Result.timeout -and $h.Result.status -ceq 'STOPPED_OR_CAPTURE_FAILED' -and $h.Result.child_record_status -ceq 'MISSING_ON_FORCED_OR_FAILED_WORKER_STOP') 'timeout_missing_child_exit_is_explicit'
$hp=Get-Content (Join-Path $h.Dir 'child.stdout') -Raw|ConvertFrom-Json
Check (-not (Get-Process -Id $hp.descendant -ErrorAction SilentlyContinue) -and -not (Get-Process -Id $hp.parent -ErrorAction SilentlyContinue)) 'timeout_own_tree_teardown'
Write-OwnedJson (Join-Path $OutputDirectory 'regression-result.json') @{utc=[DateTime]::UtcNow.ToString('o');checks=@($checks);scope='Benign owned fixtures only; no PG/SQL/user data; negative exit/cap/timeout/drain cases expected, not successful product commands'}
@{status='PASS';checks=$checks.Count;output=$OutputDirectory}|ConvertTo-Json
