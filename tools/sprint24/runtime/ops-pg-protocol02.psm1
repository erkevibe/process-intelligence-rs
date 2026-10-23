Set-StrictMode -Version Latest
function New-S24PgProtocol {
 return @{active=$null;window=$false;generations=@{'postgres-g1'='New';'postgres-g2'='New'};pairs=@{'postgres-g1'='pg-stop-g1';'postgres-g2'='pg-stop-g2'}}
}
function Assert-S24PgOperation([hashtable]$P,[string]$Op,[string]$Label){
 if($P.window){throw 'pg_stop_window_no_external_operations'}
 if($Op -ceq 'PGSTOP'){
  if(!$P.pairs.ContainsKey($Label) -or $P.active -cne $Label -or $P.generations[$Label] -cne 'Running'){throw 'pg_stop_generation'}
 }elseif($Op -ceq 'START'){
  if($Label -in @('pg-stop-g1','pg-stop-g2')){throw 'pg_stop_internal_only'}
  if($P.pairs.ContainsKey($Label)){
   if($P.active -or $P.generations[$Label] -cne 'New'){throw 'pg_generation_already_active_or_used'}
   if($Label -ceq 'postgres-g1' -and $P.generations['postgres-g2'] -cne 'New'){throw 'pg_generation_order'}
   if($Label -ceq 'postgres-g2' -and $P.generations['postgres-g1'] -cne 'Closed'){throw 'pg_previous_generation_not_closed'}
  }
 }elseif($Op -ceq 'KILL' -and $P.pairs.ContainsKey($Label)){throw 'pg_kill_not_operational_contract'}
 elseif($Op -cnotin @('STATUS','KILL')){throw 'pg_protocol_operation'}
}
Export-ModuleMember -Function New-S24PgProtocol,Assert-S24PgOperation
