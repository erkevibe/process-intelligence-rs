param([Parameter(Mandatory)][ValidateSet('fmt','clippy','test','model')][string]$Mode)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$arguments=switch($Mode){
 'fmt' {@('fmt','--all','--','--check')}
 'clippy' {@('clippy','--offline','--locked','--all-targets','--jobs','2','--','-D','warnings')}
 'test' {@('test','--offline','--locked','--all-targets','--jobs','2')}
 'model' {@('run','--offline','--locked','--quiet','--example','sprint12_model_serialization','--jobs','2')}
}
# Named array binding preserves the literal cargo delimiter through PowerShell.
& (Join-Path $root 'tools/cargo.ps1') -CargoArgs $arguments
exit $LASTEXITCODE
