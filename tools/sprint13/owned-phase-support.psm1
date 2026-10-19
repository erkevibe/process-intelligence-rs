# Helpers for finite Sprint13 fixtures; all processes inherit the outer owned Job.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Invoke-OwnedPhaseCommand([string]$Program,[string]$Sha,[string[]]$Arguments,[string]$Directory,[string]$Output,[string]$Label,[hashtable]$Environment=@{},[int]$Seconds=120,[long]$Cap=16MB) {
    $p=Start-OwnedCapturedProcess -Program $Program -ProgramSha256 $Sha -Arguments $Arguments -WorkingDirectory $Directory -OutputDirectory $Output -Label $Label -MaxOutputBytes $Cap -Environment $Environment
    $end=[DateTime]::UtcNow.AddSeconds($Seconds);$stopped=$false
    while (-not $p.Process.WaitForExit(100)) {
        if ([DateTime]::UtcNow -ge $end -or $p.OutCapture.LimitReached -or $p.ErrCapture.LimitReached -or $p.OutCapture.Pump.IsFaulted -or $p.ErrCapture.Pump.IsFaulted) {
            $stopped=$true;$p.Process.Kill($true);if (-not $p.Process.WaitForExit(10000)) { throw 'phase_child_stop' };break
        }
    }
    $r=Complete-OwnedCapturedProcess $p
    if ($stopped -or $r.native_exit -ne 0 -or -not $r.stdout_complete -or -not $r.stderr_complete -or $r.output_limit -or $r.capture_fault) { throw ('phase_command_failed_'+$Label) }
    return $r
}
function Expand-OwnedPackage([string]$Archive,[string]$ArchiveSha,[string]$Parent,[string]$ManifestSha) {
    Assert-OwnedHash $Archive $ArchiveSha
    [void](New-OwnedPrivateDirectory $Parent)
    $z=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $z.Entries) {
            $name=$entry.FullName
            if (-not $name.StartsWith('process-intelligence-rs-0.7.3-windows-x86_64/',[StringComparison]::Ordinal) -or $name.Contains('\') -or $name -match '(^/|:|[\x00-\x1f]|(^|/)\.{1,2}(/|$)|//)' -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or -not $seen.Add($name.TrimEnd('/'))) { throw 'package_unsafe_entry' }
            foreach ($part in $name.TrimEnd('/').Split('/')) { if ($part -match '[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { throw 'package_unsafe_component' } }
            $destination=Get-OwnedCanonicalPath (Join-Path $Parent $name)
            if (-not $destination.StartsWith($Parent.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'package_boundary' }
            if ($name.EndsWith('/')) { [void][IO.Directory]::CreateDirectory($destination);continue }
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            $i=$entry.Open();$o=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $i.CopyTo($o);$o.Flush($true) } finally { $i.Dispose();$o.Dispose() }
        }
    } finally { $z.Dispose() }
    $pkg=Join-Path $Parent 'process-intelligence-rs-0.7.3-windows-x86_64'
    Test-OwnedPackageTree $pkg $ManifestSha $false
    return $pkg
}
function Test-OwnedPackageTree([string]$Package,[string]$ManifestSha,[bool]$AllowLocal) {
    Assert-OwnedNoReparse $Package
    $manifest=Join-Path $Package 'build-manifest.json';Assert-OwnedHash $manifest $ManifestSha
    if ((Get-Item -LiteralPath $manifest).Length -gt 4MB) { throw 'package_manifest_cap' }
    $m=Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -DateKind String
    if ($m.version -cne '0.7.3' -or $m.source_commit -cnotmatch '^[0-9a-f]{40}$' -or $m.files.Count -lt 1) { throw 'package_manifest_identity' }
    $map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $m.files) { if (-not $map.TryAdd($f.path,$f)) { throw 'package_manifest_duplicate' } }
    $count=0
    foreach ($f in Get-ChildItem -LiteralPath $Package -Recurse -Force) {
        if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'package_tree_reparse' }
        if ($f.PSIsContainer) { continue }
        $rel=[IO.Path]::GetRelativePath($Package,$f.FullName).Replace('\','/')
        if ($AllowLocal -and $rel.StartsWith('.local/',[StringComparison]::Ordinal)) { continue }
        $count++
        if ($rel -ceq 'build-manifest.json') { continue }
        if (-not $map.ContainsKey($rel) -or $f.Length -ne $map[$rel].bytes) { throw 'package_tree_set' }
        Assert-OwnedHash $f.FullName $map[$rel].sha256
    }
    if ($count -ne ($m.files.Count + 1)) { throw 'package_tree_count' }
}
function Wait-OwnedReadyJob([object[]]$Processes,[string]$Output) {
    Write-OwnedJson (Join-Path $Output 'ready-request.json') @{processes=$Processes}
    $response=Join-Path $Output 'ready-response.json';$end=[DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $response)) { if ([DateTime]::UtcNow -ge $end) { throw 'exact_job_response_timeout' };Start-Sleep -Milliseconds 100 }
    $r=Get-Content -LiteralPath $response -Raw | ConvertFrom-Json -DateKind String
    if ($r.processes.Count -ne $Processes.Count -or @($r.processes | Where-Object { -not $_.exact_own_job }).Count) { throw 'exact_job_response' }
    foreach ($expected in $Processes) {
        $actual=@($r.processes | Where-Object { $_.name -ceq $expected.name })
        if ($actual.Count -ne 1 -or $actual[0].pid -ne $expected.pid -or $actual[0].creation_utc -cne $expected.creation_utc) { throw 'exact_job_response_identity' }
    }
}
Export-ModuleMember -Function *-Owned*
function Get-OwnedLivePrefix([string]$Path,[int]$MaxBytes=65536) {
    if ($MaxBytes -lt 1 -or $MaxBytes -gt 1MB) { throw 'live_prefix_bound' }
    Assert-OwnedNoReparse $Path
    $s=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        if ($s.Length -gt $MaxBytes) { throw 'live_prefix_file_bound' }
        $buffer=[byte[]]::new($MaxBytes);$read=$s.Read($buffer,0,$MaxBytes)
        if ($s.Length -gt $MaxBytes) { throw 'live_prefix_growth_bound' }
        return [Text.UTF8Encoding]::new($false,$true).GetString($buffer,0,$read)
    } finally { $s.Dispose() }
}
Export-ModuleMember -Function *-Owned*
