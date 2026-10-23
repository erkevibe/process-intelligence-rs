param([Parameter(Mandatory)][string]$Protocol,[Parameter(Mandatory)][string]$ProtocolSha,[Parameter(Mandatory)][string]$Output)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if((Get-FileHash $Protocol).Hash -cne $ProtocolSha -or (Test-Path $Output)){throw 'control_scope'}
Import-Module $Protocol -Force
$checks=[Collections.Generic.List[string]]::new()
function Reject([scriptblock]$Action,[string]$Code){try{&$Action;throw 'expected_refusal_missing'}catch{if($_.Exception.Message -cne $Code){throw}};$checks.Add($Code)}
$p=New-S24PgProtocol
Assert-S24PgOperation $p 'START' 'postgres-g1';$checks.Add('first_generation_allowed')
Reject {Assert-S24PgOperation $p 'START' 'postgres-g2'} 'pg_previous_generation_not_closed'
$p.active='postgres-g1';$p.generations['postgres-g1']='Running'
Reject {Assert-S24PgOperation $p 'START' 'postgres-g2'} 'pg_generation_already_active_or_used'
Reject {Assert-S24PgOperation $p 'START' 'pg-stop-g1'} 'pg_stop_internal_only'
Reject {Assert-S24PgOperation $p 'PGSTOP' 'postgres-g2'} 'pg_stop_generation'
Reject {Assert-S24PgOperation $p 'KILL' 'postgres-g1'} 'pg_kill_not_operational_contract'
Assert-S24PgOperation $p 'PGSTOP' 'postgres-g1';$checks.Add('owned_current_stop_allowed')
$p.window=$true
Reject {Assert-S24PgOperation $p 'START' 'http-down'} 'pg_stop_window_no_external_operations'
Reject {Assert-S24PgOperation $p 'PGSTOP' 'postgres-g1'} 'pg_stop_window_no_external_operations'
$p.window=$false;$p.active=$null;$p.generations['postgres-g1']='Closed'
Reject {Assert-S24PgOperation $p 'START' 'postgres-g1'} 'pg_generation_already_active_or_used'
Assert-S24PgOperation $p 'START' 'postgres-g2';$checks.Add('second_generation_after_closed_allowed')
[IO.File]::WriteAllText($Output,(@{status='PURE_PG_GENERATION_RULES_PASS';checks=$checks.ToArray();no_process_or_database=$true;scope='Pure transition validation only; not native timer, watcher, EOF or scanner evidence'}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
