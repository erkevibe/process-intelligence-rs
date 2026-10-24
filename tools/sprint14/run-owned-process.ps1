param([Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$ConfigSha256)
$ErrorActionPreference='Stop'
if ((Get-Item -LiteralPath $ConfigPath).Length -gt 1MB) { throw 'config_size' }
if ((Get-FileHash -LiteralPath $ConfigPath).Hash -cne $ConfigSha256.ToUpperInvariant()) { throw 'config_sha_before_import' }
$c=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
$pwsh=(Get-Process -Id $PID).Path
$worker=Join-Path $PSScriptRoot 'owned-process-worker.ps1'
$sourcePins=@(@((Join-Path $PSScriptRoot 'owned-runtime.psm1'),$c.module_sha256),@($worker,$c.worker_sha256),@($PSCommandPath,$c.supervisor_sha256),@($pwsh,$c.pwsh_sha256))
foreach ($pin in $sourcePins) {
    if ($pin[1] -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $pin[0]).Hash -cne $pin[1].ToUpperInvariant()) { throw 'runtime_source_before_import' }
}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedNoReparse $ConfigPath
Assert-OwnedHash $ConfigPath $ConfigSha256
Assert-OwnedPrivateDirectory (Split-Path -Parent $ConfigPath)
Assert-OwnedPrivateDirectory $c.output_directory
Assert-OwnedHash $c.program $c.program_sha256
foreach ($pin in $c.inputs) { Assert-OwnedHash $pin.path $pin.sha256 }
if ($c.timeout_seconds -lt 1 -or $c.timeout_seconds -gt 1800 -or $c.required_free_bytes -lt 1GB -or $c.runtime_floor_bytes -lt 512MB -or $c.max_output_bytes -lt 1024 -or $c.max_output_bytes -gt 1GB) { throw 'phase_budget' }
$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if ($deadline -gt [DateTimeOffset]::Parse('2026-10-20T09:54:16Z').UtcDateTime -or [DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt $c.required_free_bytes) { throw 'phase_admission' }
$job=[PiOwnedJob]::new(); $child=$null; $record=$null
function Test-OwnedReadyProcesses {
    if (-not $c.ContainsKey('ready_processes') -or $record.Contains('ready_checked')) { return }
    $request=Join-Path $c.output_directory 'ready-request.json'
    if (-not (Test-Path -LiteralPath $request)) { return }
    Assert-OwnedNoReparse $request
    if ((Get-Item -LiteralPath $request).Length -gt 64KB) { throw 'ready_request_bound' }
    $ready=Get-Content -LiteralPath $request -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    if ($ready.processes.Count -ne $c.ready_processes.Count -or $ready.processes.Count -gt 8) { throw 'ready_process_count' }
    $checked=@()
    foreach ($expected in $c.ready_processes) {
        $actual=@($ready.processes | Where-Object { $_.name -ceq $expected.name })
        if ($actual.Count -ne 1 -or $actual[0].pid -lt 1) { throw 'ready_process_identity' }
        $p=[Diagnostics.Process]::GetProcessById([int]$actual[0].pid)
        try {
            $handle=$p.Handle
            $cp=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.Id)
            if (-not $cp -or $cp.ExecutablePath -cne $expected.path -or $cp.CreationDate.ToUniversalTime() -lt $start -or $cp.CreationDate.ToUniversalTime().ToString('o') -cne $actual[0].creation_utc -or -not $job.Member($handle)) { throw 'ready_exact_job_identity' }
            Assert-OwnedHash $expected.path $expected.sha256
            $listeners=@(Get-NetTCPConnection -LocalPort $expected.port -State Listen -ErrorAction Stop)
            if (-not $listeners.Count -or @($listeners | Where-Object { $_.OwningProcess -ne $p.Id -or $_.LocalAddress -notin @('127.0.0.1','::1') }).Count) { throw 'ready_loopback_listener' }
            if ($expected.datadir) {
                if ($cp.CommandLine.Length -gt 32768 -or $expected.name -cnotmatch '^[a-z][a-z0-9-]{0,31}$') { throw 'ready_argv_bound' }
                Write-OwnedJson (Join-Path $c.output_directory ('ready-argv-'+$expected.name+'.json')) @{pid=$p.Id;creation_utc=$actual[0].creation_utc;image_sha256=$expected.sha256;command_line=$cp.CommandLine;exact_own_job=$true;scope='Actual own PostgreSQL command line retained before datadir assertion'}
                Assert-OwnedNoReparse $expected.datadir; [void](Get-OwnedDatadirArgument $cp.CommandLine $expected.datadir)
            }
            $checked+=@{name=$expected.name;pid=$p.Id;creation_utc=$actual[0].creation_utc;image_sha256=$expected.sha256;port=$expected.port;exact_own_job=$true;canonical_datadir_checked=[bool]$expected.datadir}
        } finally { $p.Dispose() }
    }
    Write-OwnedJson (Join-Path $c.output_directory 'ready-response.json') @{processes=$checked;utc=[DateTime]::UtcNow.ToString('o');scope='Retained actual handles checked against this exact unnamed Job, image, creation and loopback listener'}
    $record.ready_checked=$true
}
try {
    $start=[DateTime]::UtcNow
    $child=Start-OwnedCapturedProcess -Program $pwsh -ProgramSha256 $c.pwsh_sha256 -Arguments @('-NoProfile','-File',$worker,'-ConfigPath',(Get-OwnedCanonicalPath $ConfigPath),'-ConfigSha256',$ConfigSha256.ToUpperInvariant()) -WorkingDirectory $c.cwd -OutputDirectory $c.output_directory -Label 'runner' -MaxOutputBytes $c.max_output_bytes -RedirectInput $true
    $job.Assign($child.Handle)
    if (-not $job.Member($child.Handle)) { throw 'waiting_worker_job_membership' }
    $record=[ordered]@{config_sha256=$ConfigSha256.ToUpperInvariant();worker_pid=$child.Process.Id;exact_own_job=$true;go_sent=$false;timeout=$false;capacity_stop=$false;freeze_stop=$false;output_stop=$false;capture_stop=$false;free_before=[IO.DriveInfo]::new('C').AvailableFreeSpace;module_sha256=Get-OwnedHash (Join-Path $PSScriptRoot 'owned-runtime.psm1');worker_sha256=Get-OwnedHash $worker;supervisor_sha256=Get-OwnedHash $PSCommandPath}
    Write-OwnedJson (Join-Path $c.output_directory 'job-admission.json') $record
    foreach ($pin in $sourcePins) { Assert-OwnedHash $pin[0] $pin[1] }
    Assert-OwnedHash $ConfigPath $ConfigSha256
    $child.Process.StandardInput.WriteLine('GO '+$ConfigSha256.ToUpperInvariant()); $child.Process.StandardInput.Close(); $record.go_sent=$true
    while (-not $child.Process.WaitForExit(100)) {
        Test-OwnedReadyProcesses
        $record.timeout=([DateTime]::UtcNow-$start).TotalSeconds -ge $c.timeout_seconds
        $record.capacity_stop=[IO.DriveInfo]::new('C').AvailableFreeSpace -lt $c.runtime_floor_bytes
        $record.freeze_stop=[DateTime]::UtcNow -ge $deadline
        $record.output_stop=$child.OutCapture.LimitReached -or $child.ErrCapture.LimitReached
        $record.capture_stop=$child.OutCapture.Pump.IsFaulted -or $child.ErrCapture.Pump.IsFaulted -or $child.OutCapture.Pump.IsCanceled -or $child.ErrCapture.Pump.IsCanceled
        if ($record.timeout -or $record.capacity_stop -or $record.freeze_stop -or $record.output_stop -or $record.capture_stop) { $job.Stop(); if (-not $child.Process.WaitForExit(10000)) { throw 'owned_worker_stop_timeout' }; break }
    }
    if ($c.ContainsKey('ready_processes') -and -not $record.Contains('ready_checked')) { throw 'ready_proof_missing' }
    # Close only this unnamed Job: descendants cannot keep inherited pipes indefinitely.
    $job.Dispose()
    $r=Complete-OwnedCapturedProcess $child
    $record.native_exit=$r.native_exit; $record.stdout_complete=$r.stdout_complete; $record.stderr_complete=$r.stderr_complete
    $record.child_record_status=if (Test-Path -LiteralPath (Join-Path $c.output_directory 'child.process.json')) { 'CAPTURED_SEPARATELY' } else { 'MISSING_ON_FORCED_OR_FAILED_WORKER_STOP' }
    $record.free_after=[IO.DriveInfo]::new('C').AvailableFreeSpace; $record.completed_utc=[DateTime]::UtcNow.ToString('o')
    $record.status=if ($record.timeout -or $record.capacity_stop -or $record.freeze_stop -or $record.output_stop -or $record.capture_stop -or $r.output_limit -or $r.capture_fault -or $r.drain_timeout) { 'STOPPED_OR_CAPTURE_FAILED' } elseif ($r.native_exit -ne 0) { 'COMMAND_FAILED' } else { 'COMMAND_COMPLETED' }
    Write-OwnedJson (Join-Path $c.output_directory 'result.json') $record
    $record | ConvertTo-Json -Depth 5
    if ($record.status -ne 'COMMAND_COMPLETED') { exit 1 }
} catch {
    $job.Dispose()
    if ($child) {
        try { if (-not $child.Process.HasExited) { $child.Process.Kill(); [void]$child.Process.WaitForExit(10000) }; if ($child.Process.HasExited -and -not (Test-Path -LiteralPath ($child.Base+'.process.json'))) { [void](Complete-OwnedCapturedProcess $child) } } catch { }
    }
    $failure=[ordered]@{utc=[DateTime]::UtcNow.ToString('o');status='SUPERVISOR_FAILED';failure='owned_runtime_refusal';scope='Original private runner stderr retained; no successful command or complete stream claim inferred'}
    try { Write-OwnedJson (Join-Path $c.output_directory 'failure.json') $failure } catch { }
    throw
} finally { $job.Dispose() }
