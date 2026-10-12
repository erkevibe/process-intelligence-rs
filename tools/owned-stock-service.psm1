# Sprint11 service fixture support. Reuses the waiting worker and common Job/capture ABI.
# This module never opens old installations and does not issue HTTP or SQL.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Start-OwnedStockService([hashtable]$Config,[string]$Package,[string]$Round) {
    if ($Round -cnotmatch '^[a-z][a-z0-9-]{0,30}$' -or $Config.app_port -ne 3095 -or $Config.pg_port -ne 5462 -or $Config.database -cnotmatch '^(process_intelligence|pi_restore_s11_[a-z0-9_]{1,35})$') { throw 'stock_service_scope' }
    if (@(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object LocalPort -in @($Config.app_port,$Config.pg_port)).Count) { throw 'stock_ports_not_absent' }
    $directory=Join-Path $Config.output_directory $Round
    [void](New-OwnedPrivateDirectory $directory)
    $starter=Join-Path $Package 'tools/start-packaged.ps1'
    $worker=Join-Path $PSScriptRoot 'owned-process-worker.ps1'
    $configPath=Join-Path $directory 'service-config.json'
    $service=@{
        program=$Config.pwsh;program_sha256=$Config.pwsh_sha;cwd=$Package;output_directory=$directory
        arguments=@('-NoProfile','-File',$Config.stdio_wrapper,'-Script',$starter,'-ScriptSha',(Get-OwnedHash $starter),'-Proof',(Join-Path $directory 'starter-stdio.json'),'-ArgumentsJson',(@{Port=$Config.app_port;PostgresPort=$Config.pg_port;Database=$Config.database}|ConvertTo-Json -Compress))
        environment=@{};max_output_bytes=4MB;module_sha256=$Config.module_sha;worker_sha256=$Config.worker_sha;pwsh_sha256=$Config.pwsh_sha
        inputs=@(@{path=$starter;sha256=Get-OwnedHash $starter},@{path=$Config.stdio_wrapper;sha256=$Config.stdio_sha})
    }
    Write-OwnedJson $configPath $service
    $configSha=Get-OwnedHash $configPath
    $job=[PiOwnedJob]::new();$coordinator=$null
    try {
        Assert-OwnedHash $worker $Config.worker_sha
        $coordinator=Start-OwnedCapturedProcess -Program $Config.pwsh -ProgramSha256 $Config.pwsh_sha -Arguments @('-NoProfile','-File',$worker,'-ConfigPath',$configPath,'-ConfigSha256',$configSha) -WorkingDirectory $Package -OutputDirectory $directory -Label 'coordinator' -MaxOutputBytes 4MB -RedirectInput $true
        $job.Assign($coordinator.Handle)
        if (-not $job.Member($coordinator.Handle)) { throw 'stock_coordinator_job' }
        Assert-OwnedHash $configPath $configSha
        foreach ($pin in $service.inputs) { Assert-OwnedHash $pin.path $pin.sha256 }
        Write-OwnedJson (Join-Path $directory 'service-admission.json') @{config_sha256=$configSha;coordinator_pid=$coordinator.Process.Id;creation_utc=$coordinator.Record.native_creation_utc;exact_inner_job=$true;scope='Waiting worker assigned before GO; descendants inherit this retained inner Job, itself inside outer fixture Job'}
        $coordinator.Process.StandardInput.WriteLine('GO '+$configSha)
        $coordinator.Process.StandardInput.Close()
        return @{Job=$job;Coordinator=$coordinator;Directory=$directory;Package=$Package;Config=$Config;Processes=@();Started=[DateTime]::UtcNow;StopAttempted=$false}
    } catch {
        $job.Stop();$job.Dispose()
        if ($coordinator -and $coordinator.Process.WaitForExit(10000)) { [void](Complete-OwnedCapturedProcess $coordinator) }
        throw
    }
}
function Wait-OwnedStockService([hashtable]$Service,[int]$Seconds=120) {
    $c=$Service.Config;$end=[DateTime]::UtcNow.AddSeconds($Seconds)
    while ($true) {
        if ($Service.Coordinator.Process.HasExited) { throw 'stock_coordinator_exited_before_ready' }
        if ($Service.Coordinator.OutCapture.LimitReached -or $Service.Coordinator.ErrCapture.LimitReached -or $Service.Coordinator.OutCapture.Pump.IsFaulted -or $Service.Coordinator.ErrCapture.Pump.IsFaulted) { throw 'stock_coordinator_capture_stop' }
        $listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object LocalPort -in @($c.app_port,$c.pg_port))
        if (@($listeners | Where-Object LocalPort -eq $c.app_port).Count -and @($listeners | Where-Object LocalPort -eq $c.pg_port).Count) { break }
        if ([DateTime]::UtcNow -ge $end) { throw 'stock_ready_timeout' }
        Start-Sleep -Milliseconds 100
    }
    $proof=@();$retained=@()
    try {
        foreach ($entry in @(@{name='app';port=$c.app_port;image=(Join-Path $Service.Package 'process-intelligence-rs.exe');sha=$c.app_sha},@{name='postgres';port=$c.pg_port;image=(Join-Path $Service.Package 'runtime/postgresql/pgsql/bin/postgres.exe');sha=$c.postgres_sha})) {
            $rows=@($listeners|Where-Object LocalPort -eq $entry.port)
            $ids=@($rows.OwningProcess|Select-Object -Unique)
            if ($ids.Count -ne 1 -or @($rows|Where-Object LocalAddress -notin @('127.0.0.1','::1')).Count) { throw 'stock_listener_identity' }
            $p=[Diagnostics.Process]::GetProcessById($ids[0]);$handle=$p.Handle
            $retained+=@{Process=$p;Handle=$handle;Name=$entry.name;Creation=$p.StartTime.ToUniversalTime().ToString('o')}
            $native=Get-CimInstance Win32_Process -Filter ('ProcessId='+$ids[0])
            $creation=$p.StartTime.ToUniversalTime().ToString('o')
            $cimCreation=$native.CreationDate.ToUniversalTime().ToString('o')
            $again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$ids[0])
            $p.Refresh()
            # Compare creation within each API, not across Win32/CIM precision.
            # The retained process is still alive throughout both CIM samples.
            if ($p.HasExited -or $p.StartTime.ToUniversalTime().ToString('o') -cne $creation -or [DateTime]$creation -lt [DateTime]$Service.Coordinator.Record.native_creation_utc -or -not $again -or $again.CreationDate.ToUniversalTime().ToString('o') -cne $cimCreation -or $native.ExecutablePath -cne $entry.image -or $again.ExecutablePath -cne $entry.image -or -not $Service.Job.Member($handle)) { throw 'stock_retained_identity' }
            Assert-OwnedHash $entry.image $entry.sha
            $row=@{name=$entry.name;pid=$p.Id;creation_utc=$creation;cim_creation_utc=$cimCreation;cim_creation_second_read_utc=$again.CreationDate.ToUniversalTime().ToString('o');port=$entry.port;image=$entry.image;image_sha256=$entry.sha;exact_inner_job=$true;listener_addresses=@($rows.LocalAddress)}
            if ($entry.name -ceq 'postgres') {
                $row.command_line=$native.CommandLine
                Write-OwnedJson (Join-Path $Service.Directory 'postgres-argv.json') $row
                $row.canonical_datadir=Get-OwnedDatadirArgument $native.CommandLine (Join-Path $Service.Package '.local/pgdata')
            }
            $proof+=$row
        }
        $Service.Processes=$retained
        Write-OwnedJson (Join-Path $Service.Directory 'service-ready.json') @{utc=[DateTime]::UtcNow.ToString('o');processes=$proof;scope='Actual retained inner Job membership before network or database checks; not outer Job membership inference'}
        return $proof
    } catch { foreach($p in $retained){$p.Process.Dispose()};throw }
}
function Stop-OwnedStockService([hashtable]$Service,[string]$Reason) {
    if ($Reason -cnotin @('fault-injection','fixture-finalization','fixture-failure')) { throw 'stock_stop_reason' }
    if($Service.StopAttempted){throw 'stock_stop_already_attempted'}
    $Service.StopAttempted=$true;$cleanPg=$false;$failure=$null
    # Controlled fault injection intentionally terminates the exact retained service Job.
    # Native exit 1 from TerminateJobObject is recorded, never translated into clean exit 0.
    try { if ($Reason -ceq 'fixture-finalization') {
        $app=@($Service.Processes|Where-Object Name -ceq 'app')
        if ($app.Count -ne 1 -or -not $Service.Job.Member($app[0].Handle)) { throw 'stock_final_app_identity' }
        if (-not $app[0].Process.HasExited) { $app[0].Process.Kill() }
        if (-not $app[0].Process.WaitForExit(10000)) { throw 'stock_final_app_stop' }
        $ctl=Join-Path $Service.Package 'runtime/postgresql/pgsql/bin/pg_ctl.exe'
        [void](Invoke-OwnedPhaseCommand $ctl $Service.Config.pg_ctl_sha @('-D',(Join-Path $Service.Package '.local/pgdata'),'-w','-t','15','stop','-m','fast') $Service.Package $Service.Directory 'pg-fast-stop' @{} 30)
        $pg=@($Service.Processes|Where-Object Name -ceq 'postgres')
        if($pg.Count -ne 1 -or -not $pg[0].Process.WaitForExit(10000) -or $pg[0].Process.ExitCode -ne 0 -or @(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object LocalPort -eq $Service.Config.pg_port).Count){throw 'stock_postmaster_not_clean_before_job_stop'}
        Write-OwnedJson (Join-Path $Service.Directory 'postmaster-clean-exit.json') @{pid=$pg[0].Process.Id;creation_utc=$pg[0].Creation;native_exit=$pg[0].Process.ExitCode;listener_absent=$true;job_stop_not_yet_issued=$true}
        $cleanPg=$true
    }}catch{$failure=$_.Exception.Message}finally{
        # Even a failed graceful command closes this exact Job; it is then a
        # failed/unclean fixture, never a successful clean-stop observation.
        try{$Service.Job.Stop()}finally{$Service.Job.Dispose()}
    }
    $processes=@()
    foreach ($p in $Service.Processes) {
        $ended=$p.Process.WaitForExit(10000)
        $processes+=@{name=$p.Name;pid=$p.Process.Id;creation_utc=$p.Creation;exited=$ended;native_exit=$(if($ended){$p.Process.ExitCode}else{$null});forced=(-not $cleanPg -or $p.Name -ceq 'app')}
        $p.Process.Dispose()
    }
    if (-not $Service.Coordinator.Process.WaitForExit(10000)) { throw 'stock_coordinator_stop_timeout' }
    $native=Complete-OwnedCapturedProcess $Service.Coordinator
    Write-OwnedJson (Join-Path $Service.Directory 'service-stop.json') @{reason=$Reason;retained_processes=$processes;coordinator=$native;forced_service_stop=$true;postmaster_clean_before_job_stop=$cleanPg;graceful_failure=$failure;child_native_record_present=(Test-Path (Join-Path $Service.Directory 'child.process.json'));scope='Fault/finalization teardown. Missing child native record remains missing; no graceful app stop claim'}
    if($failure){throw ('stock_graceful_failed_retained_'+$failure)}
    if (-not $native.stdout_complete -or -not $native.stderr_complete -or $native.capture_fault -or $native.drain_timeout -or $native.output_limit -or @($processes|Where-Object {-not $_.exited}).Count) { throw 'stock_teardown_incomplete' }
    if (@(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object LocalPort -in @($Service.Config.app_port,$Service.Config.pg_port)).Count) { throw 'stock_ports_remain' }
}
Export-ModuleMember -Function *-OwnedStockService
