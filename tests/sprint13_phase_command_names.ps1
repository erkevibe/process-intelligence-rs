# Read-only parser/command-resolution guard. Never invokes a phase or its SQL.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$files=@(@('cleanup-corpus-phase.ps1','project-list-rbac-phase.ps1','full-cleanup-phase.ps1','migrated-cleanup-phase.ps1','full-boundary-phase.ps1','full-f01-phase.ps1','full-recovery-http-phase.ps1','futureclone-phase.ps1','small-holders-phase.ps1','resource-phase-budget.psm1','evidence-storage.psm1','evidence-meter.psm1','owned-runtime.psm1','owned-phase-support.psm1','owned-stock-service.psm1','run-owned-process.ps1','owned-process-worker.ps1','run-isolated-stdio.ps1')|ForEach-Object{Get-Item -LiteralPath (Join-Path $root ('tools/sprint13/'+$_))}|Sort-Object Name)
$names=@();$pins=@()
foreach($file in $files){
 $errors=@();$ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$errors)
 if($errors.Count){throw ('phase_parse_error_'+$file.Name)}
 foreach($definition in $ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
  if(@(Get-Alias -Name $definition.Name -ErrorAction SilentlyContinue).Count){throw ('phase_helper_shadows_alias_'+$definition.Name)}
  $names+=@{file=$file.Name;function=$definition.Name}
 }
 $pins+=@{path=$file.FullName;sha256=(Get-FileHash -LiteralPath $file.FullName).Hash}
}
if($files.Count -lt 5 -or $names.Count -lt 10){throw 'phase_inventory_unexpectedly_small'}
@{status='S13_PHASE_PARSER_AND_HELPER_ALIAS_GUARD_PASSED';files=$files.Count;functions=$names.Count;pins=$pins;limits=@('Read-only AST and current host alias lookup for SmallS/project-list/fullC2/currentC1/boundary phases plus newF01/fullHTTP/cold-clone/holder drafts and complete imported runner/resource/meter modules','Does not execute or validate SQL, native processes, actual phase outcomes, unrelated drafts or future sessions')}|ConvertTo-Json -Depth 5 -Compress
