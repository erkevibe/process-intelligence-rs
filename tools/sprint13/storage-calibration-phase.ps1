param([Parameter(Mandatory)][string]$PhaseConfig,[Parameter(Mandatory)][string]$PhaseConfigSha)
# SOURCE-ONLY DRAFT: outer owned waiting-worker Job and exact prospective approval required.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-Item -LiteralPath $PhaseConfig).Length -gt 1MB -or (Get-FileHash -LiteralPath $PhaseConfig).Hash -cne $PhaseConfigSha.ToUpperInvariant()){throw 'storage_config_before_import'}
$c=Get-Content -LiteralPath $PhaseConfig -Raw|ConvertFrom-Json -AsHashtable -DateKind String
foreach($p in @(@('owned-runtime.psm1',$c.module_sha),@('evidence-storage.psm1',$c.storage_module_sha))){if($p[1] -cnotmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $p[0])).Hash -cne $p[1].ToUpperInvariant()){throw 'storage_exact_module_pin'}}
Import-Module (Join-Path $PSScriptRoot 'owned-runtime.psm1') -Force -DisableNameChecking
Assert-OwnedHash $PhaseConfig $PhaseConfigSha
Assert-OwnedPrivateDirectory (Split-Path -Parent $PhaseConfig)
if($c.scope -cne 's13-public-synthetic-64mib-storage-calibration' -or $c.synthetic_bytes -ne 67108864 -or $c.maximum_phase_seconds -ne 120 -or $c.mutation_target -cne 'NEW_SYNTHETIC_FILE_ONLY'){throw 'storage_synthetic_only_scope'}
$out=Get-OwnedCanonicalPath $c.output_directory;Assert-OwnedPrivateDirectory $out
$target=Join-Path $out 'new-public-calibration'
if((Get-OwnedCanonicalPath $c.new_directory) -cne (Get-OwnedCanonicalPath $target) -or (Test-Path -LiteralPath $target)){throw 'storage_new_literal_target'}
$deadline=[DateTimeOffset]::Parse($c.deadline_utc).UtcDateTime
if($deadline -gt [DateTimeOffset]::Parse('2026-10-19T19:44:42Z').UtcDateTime -or [DateTime]::UtcNow -ge $deadline -or [IO.DriveInfo]::new('C').AvailableFreeSpace -lt 4GB){throw 'storage_finite_capacity_deadline'}
Assert-OwnedHash $c.pwsh $c.pwsh_sha
$native=[Diagnostics.Process]::GetCurrentProcess()
$actual=Get-CimInstance Win32_Process -Filter ('ProcessId='+$native.Id)
if(!$actual -or $actual.ExecutablePath -cne $c.pwsh -or $native.HasExited){throw 'storage_actual_host_image'}
# Native/Job membership, stdout/stderr EOF and exit0 are independently captured
# by the outer admitted runner; this script cannot award itself those facts.
if(@(@($c.root_review.path,$c.qa_review.path,$c.td_review.path)|Select-Object -Unique).Count -ne 3){throw 'storage_distinct_review_records'}
foreach($entry in @(@{role='Root';review=$c.root_review},@{role='QA';review=$c.qa_review},@{role='TD';review=$c.td_review})){
 $r=$entry.review
 Assert-OwnedHash $r.path $r.sha256;Assert-OwnedPrivateDirectory (Split-Path -Parent $r.path)
 $review=Get-Content -LiteralPath $r.path -Raw|ConvertFrom-Json
 if($review.author_role -cne $entry.role -or $review.scope -cne $c.scope -or $review.phase_sha256.ToUpperInvariant() -cne (Get-OwnedHash $PSCommandPath) -or $review.storage_module_sha256.ToUpperInvariant() -cne $c.storage_module_sha.ToUpperInvariant() -or $review.output_directory -cne $out -or $review.verdict -cne 'PROSPECTIVE_SYNTHETIC_CALIBRATION_ONLY_GO'){throw 'storage_prospective_exact_review'}
}
Import-Module (Join-Path $PSScriptRoot 'evidence-storage.psm1') -Force -DisableNameChecking
Write-OwnedJson (Join-Path $out 'storage-host.json') @{pid=$native.Id;creation_utc=$native.StartTime.ToUniversalTime().ToString('o');image=$actual.ExecutablePath;image_sha256=$c.pwsh_sha;phase_sha256=(Get-OwnedHash $PSCommandPath);module_sha256=$c.storage_module_sha;config_sha256=$PhaseConfigSha;no_native_exit_or_outer_job_self_claim=$true}
$operationDeadline=[DateTime]::UtcNow.AddSeconds(120)
if($operationDeadline -gt $deadline){$operationDeadline=$deadline}
$result=Invoke-S13SyntheticStorageCalibration -NewDirectory $target -DeadlineUtc $operationDeadline
if(!$result.all_three_api_returns_true -or !$result.whole_bytes_preserved -or $result.steps.Count -ne 3){throw 'storage_calibration_incomplete'}
Write-OwnedJson (Join-Path $out 'storage-calibration-result.json') $result

<#
UNEXECUTED DRAFT. Config pinned by outer currentSID private waiting-worker Job:
scope=s13-public-synthetic-64mib-storage-calibration,synthetic_bytes=67108864,
maximum_phase_seconds=120,mutation_target=NEW_SYNTHETIC_FILE_ONLY,
output_directory existing privateS13, new_directory EXACT output/new-public-calibration
absent. module_sha/storage_module_sha, actual pwsh/pwsh_sha; deadline_utc future
<=S13runtimefreeze; actual operation deadline=min(now+120s, runtimefreeze). root_review/qa_review/td_review each {path,sha256}
with distinct author_role Root/QA/TD, separately authored exact phase/module/output/
scope bound prospective GO. Review record presence is not an independent authorship
proof; Root must retain actual review messages and immutable full source reads.
Outer pins own worker/host/phase/config/helpers, owns Job BEFORE GO and bounds120s
with fullstdout/stderr+EOF+actualhost nativeexit0. No silent native success wrapper.

One NEW benign64MiB repetitive UTF8 file, never SQL/PG/data/binary/old resources.
ReadWrite FileShare.None synchronous retained handle throughout creation and three
DeviceIoControl FSCTL_SET_COMPRESSION steps1/0/1. No child compact.exe, no synthetic
flush/protocol/query. API BOOL/error/returnedbytes saved BEFORE refusal. Actual NTFS,
FileStandardInfo AllocationSize/EndOfFile/links1 and stable volume/fileID from
GetFileInformationByHandle; finalpath matches resolved privateS13 parent; EFS,
sparse/reparse/offline/directory/device/recall refused. ACL currentSID sole explicit
FullControl+protected owner enforced THROUGH samehandle; allbyteSHA and exactlength
before/after each step; expectedcompression queried by FSCTL_GET_COMPRESSION.
After writer close, read-only reopen fullread SHA+ACL+sameidentity+allocation proof.
The final file stays compressed and retained; failure retains original/step proof.
No whole-directory compression; no public/private customer file compression API.
No planned cap reinterpretation: prospective Council dual-cap amendment and actual
benign calibration review are prerequisites to ANY future real capture compression.

Constants independently read from local windows-sys0.61.2 System/Ioctl/mod.rs:
SET639040u32(line2621),GET589884u32(line2404). Official synchronous contract:
https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ni-winioctl-fsctl_set_compression
COMPRESSION_FORMAT_DEFAULT1 requests standardcompression; actual query returns
LZNT1=2 on NTFS; NONE0 for decompression. Failure is controlled STOP, no fallback.
#>
