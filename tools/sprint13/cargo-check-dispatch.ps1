param([Parameter(Mandatory)][ValidateSet('format','fmt','clippy','test','test-build','build','model','receipt-calibration')][string]$Mode)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$arguments=switch($Mode){
 'format' {@('fmt','--all')}
 'receipt-calibration' {@('test','--offline','--locked','--lib','cleanup::tests::receipt_snapshot_digest_public_calibration','--jobs','2','--','--nocapture')}
 'test-build' {@('test','--offline','--locked','--no-run','--message-format=json','--jobs','2')}
 'build' {@('build','--offline','--locked','--jobs','2')}
 'fmt' {@('fmt','--all','--','--check')}
 'clippy' {@('clippy','--offline','--locked','--all-targets','--jobs','2','--','-D','warnings')}
 'test' {@('test','--offline','--locked','--all-targets','--jobs','2')}
 'model' {@('run','--offline','--locked','--quiet','--example','sprint12_model_serialization','--jobs','2')}
}
# Named array binding preserves the literal cargo delimiter through PowerShell.
& (Join-Path $root 'tools/cargo.ps1') -CargoArgs $arguments
exit $LASTEXITCODE
