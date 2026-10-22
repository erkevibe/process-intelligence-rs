param(
 [Parameter(Mandatory)][string]$Workspace,
 [Parameter(Mandatory)][string]$Config,
 [Parameter(Mandatory)][string]$ConfigSha,
 [Parameter(Mandatory)][string]$Python,
 [Parameter(Mandatory)][string]$PythonSha,
 [switch]$CheckOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
try {
 if($PythonSha -cnotmatch '^[A-F0-9]{64}$' -or (Get-FileHash -LiteralPath $Python).Hash -cne $PythonSha){throw 'python_pin'}
 $validator=Join-Path $PSScriptRoot 'validate-config.py'
 # Updated only when the independently reviewed validator changes.
 $validatorSha='A4699B9F67D3C03A0469E56152A79FDAB843E0BD2C75B9D8E56FC0919488FA6D'
 if((Get-FileHash -LiteralPath $validator).Hash -cne $validatorSha){throw 'validator_pin'}
 $runner=Join-Path $Workspace 'tools/sprint21-capacity/continuation-phase-runner.ps1'
 if((Get-FileHash -LiteralPath $runner).Hash -cne '657876F9798AAB43F4E2DB61C08CA32FA90CB2F1D292A3116B1FA22A7BC1929E'){throw 'accepted_runner_pin'}
 $worker=Join-Path $Workspace 'tools/sprint21-capacity/continuation-phase-worker.ps1'
 if((Get-FileHash -LiteralPath $worker).Hash -cne '5413D83848F4469669723F478E7347F48825703DC8BE160DBD105A2620BC3BF5'){throw 'accepted_worker_pin'}
 & $Python -I -B -X utf8 $validator --workspace $Workspace --config $Config --config-sha $ConfigSha
 $validationExit=$LASTEXITCODE
 if($validationExit -ne 0){exit $validationExit}
 if($CheckOnly){exit 0}
 Set-Location -LiteralPath $Workspace
 # The single delegate call is dominated by validator exit0. This observable
 # marker is unconditional and immediately precedes that fixed delegate.
 [Console]::Out.WriteLine('{"status":"RUNNER_DELEGATION"}')
 & $runner -Config $Config -ConfigSha $ConfigSha
 exit $LASTEXITCODE
} catch {
 [Console]::Out.WriteLine('{"status":"PREFLIGHT_OR_DELEGATE_FAILED","private_error_text_omitted":true}')
 exit 1
}
