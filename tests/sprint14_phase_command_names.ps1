param([string[]]$AdditionalFiles=@())
# Read-only AST/current-alias guard. Never imports or executes an S14 module/phase.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$names=@('owned-runtime.psm1','owned-process-worker.ps1','run-owned-process.ps1','run-isolated-stdio.ps1','owned-phase-support.psm1','owned-stock-service.psm1','evidence-storage.psm1','evidence-meter.psm1')
foreach($name in $AdditionalFiles){if($name -cnotmatch '^[a-z][a-z0-9-]*\.(ps1|psm1)$' -or $name -cin $names){throw 's14_additional_source_name'};$names+=$name}
$files=@($names|ForEach-Object {Get-Item -LiteralPath (Join-Path $root ('tools/sprint14/'+$_))}|Sort-Object Name)
$definitions=@();$pins=@()
foreach($file in $files){
 $errors=@();$ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$errors)
 if($errors.Count){throw ('phase_parse_error_'+$file.Name)}
 foreach($definition in $ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
  if(@(Get-Alias -Name $definition.Name -ErrorAction SilentlyContinue).Count){throw ('phase_helper_shadows_alias_'+$definition.Name)}
  $definitions+=@{file=$file.Name;function=$definition.Name}
 }
 $pins+=@{path=$file.FullName;sha256=(Get-FileHash -LiteralPath $file.FullName).Hash}
}
if($files.Count -lt 8 -or $definitions.Count -lt 10){throw 'phase_inventory_unexpectedly_small'}
@{status='S14_PHASE_PARSER_AND_HELPER_ALIAS_GUARD_PASSED';files=$files.Count;functions=$definitions.Count;pins=$pins;limits=@('Read-only syntax/currenthost alias inspection of explicit new S14 sources only','No imports, native processes, SQL, API calls, runtime outcomes or old S13 proof transfer','Additional future phase/resource sources require explicit AdditionalFiles and separate prospective review')}|ConvertTo-Json -Depth 5 -Compress
