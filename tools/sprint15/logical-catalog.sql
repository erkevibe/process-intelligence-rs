-- Logical public-schema structure and privileges, suitable for NEW restores.
-- Object OIDs, database names and physical/statistical counters are excluded.
-- Native system/database identity is checked separately; no physical clone claim.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT jsonb_agg(x.v ORDER BY x.k COLLATE "C") FROM (
 SELECT 'schema/'||n.nspname AS k,jsonb_build_array('schema',n.nspname,n.nspowner::regrole::text,
  (SELECT jsonb_agg(jsonb_build_array(a.grantor::regrole::text,CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END,a.privilege_type,a.is_grantable) ORDER BY a.grantor::regrole::text,a.grantee::regrole::text,a.privilege_type,a.is_grantable) FROM aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) a)) AS v
 FROM pg_namespace n WHERE n.nspname='public'
 UNION ALL SELECT 'class/'||c.relname,jsonb_build_array('class',c.relname,c.relkind,c.relrowsecurity,c.relforcerowsecurity,c.relowner::regrole::text,
  (SELECT jsonb_agg(jsonb_build_array(a.grantor::regrole::text,CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END,a.privilege_type,a.is_grantable) ORDER BY a.grantor::regrole::text,a.grantee::regrole::text,a.privilege_type,a.is_grantable) FROM aclexplode(coalesce(c.relacl,acldefault(CASE WHEN c.relkind='S' THEN 's'::"char" ELSE 'r'::"char" END,c.relowner))) a))
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f')
 UNION ALL SELECT 'column/'||table_name||'/'||ordinal_position::text,jsonb_build_array('column',table_name,column_name,ordinal_position,data_type,udt_name,is_nullable,is_identity,is_generated,column_default,collation_name,identity_generation,identity_start,identity_increment,identity_minimum,identity_maximum,identity_cycle,generation_expression)
 FROM information_schema.columns WHERE table_schema='public'
 UNION ALL SELECT 'constraint/'||c.conrelid::regclass::text||'/'||c.conname,jsonb_build_array('constraint',c.conrelid::regclass::text,c.conname,c.contype,c.convalidated,c.condeferrable,c.condeferred,pg_get_constraintdef(c.oid))
 FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='public'
 UNION ALL SELECT 'index/'||tablename||'/'||indexname,jsonb_build_array('index',tablename,indexname,indexdef) FROM pg_indexes WHERE schemaname='public'
 UNION ALL SELECT 'trigger/'||tgrelid::regclass::text||'/'||tgname,jsonb_build_array('trigger',tgrelid::regclass::text,tgname,tgenabled,pg_get_triggerdef(oid)) FROM pg_trigger WHERE tgrelid IN (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public') AND NOT tgisinternal
 UNION ALL SELECT 'relation_options/'||c.relname,jsonb_build_array('relation_options',c.relname,c.relpersistence,c.relreplident,c.reloptions,c.relispartition,pg_get_expr(c.relpartbound,c.oid),CASE WHEN c.relkind='p' THEN pg_get_partkeydef(c.oid) END)
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f')
 UNION ALL SELECT 'view_definition/'||c.relname,jsonb_build_array('view_definition',c.relname,pg_get_viewdef(c.oid,true))
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('v','m')
 UNION ALL SELECT 'sequence_definition/'||s.seqrelid::regclass::text,jsonb_build_array('sequence_definition',s.seqrelid::regclass::text,s.seqtypid::regtype::text,s.seqstart::text,s.seqincrement::text,s.seqmax::text,s.seqmin::text,s.seqcache::text,s.seqcycle)
 FROM pg_sequence s JOIN pg_class c ON c.oid=s.seqrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'
 UNION ALL SELECT 'inheritance/'||i.inhrelid::regclass::text||'/'||i.inhseqno::text,jsonb_build_array('inheritance',i.inhrelid::regclass::text,i.inhparent::regclass::text,i.inhseqno,i.inhdetachpending)
 FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'
 UNION ALL SELECT 'foreign_table/'||f.ftrelid::regclass::text,jsonb_build_array('foreign_table',f.ftrelid::regclass::text,s.srvname,s.srvtype,s.srvversion,s.srvoptions,w.fdwname,f.ftoptions)
 FROM pg_foreign_table f JOIN pg_class c ON c.oid=f.ftrelid JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_foreign_server s ON s.oid=f.ftserver JOIN pg_foreign_data_wrapper w ON w.oid=s.srvfdw WHERE n.nspname='public'
 UNION ALL SELECT 'rule/'||tablename||'/'||rulename,jsonb_build_array('rule',tablename,rulename,definition) FROM pg_rules WHERE schemaname='public'
 UNION ALL SELECT 'policy/'||tablename||'/'||policyname,to_jsonb(p) FROM pg_policies p WHERE schemaname='public'
 UNION ALL SELECT 'function/'||p.oid::regprocedure::text,jsonb_build_array('function',p.oid::regprocedure::text,p.proowner::regrole::text,pg_get_functiondef(p.oid),
  (SELECT jsonb_agg(jsonb_build_array(a.grantor::regrole::text,CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END,a.privilege_type,a.is_grantable) ORDER BY a.grantor::regrole::text,a.grantee::regrole::text,a.privilege_type,a.is_grantable) FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a))
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
 UNION ALL SELECT 'column_acl/'||c.relname||'/'||a.attname,jsonb_build_array('column_acl',c.relname,a.attname,
  (SELECT jsonb_agg(jsonb_build_array(p.grantor::regrole::text,CASE WHEN p.grantee=0 THEN 'PUBLIC' ELSE p.grantee::regrole::text END,p.privilege_type,p.is_grantable) ORDER BY p.grantor::regrole::text,p.grantee::regrole::text,p.privilege_type,p.is_grantable) FROM aclexplode(a.attacl) p))
 FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND a.attnum>0 AND NOT a.attisdropped AND a.attacl IS NOT NULL
 UNION ALL SELECT 'default_acl/'||d.defaclrole::regrole::text||'/'||d.defaclobjtype::text,jsonb_build_array('default_acl',d.defaclrole::regrole::text,d.defaclobjtype,
  (SELECT jsonb_agg(jsonb_build_array(a.grantor::regrole::text,CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END,a.privilege_type,a.is_grantable) ORDER BY a.grantor::regrole::text,a.grantee::regrole::text,a.privilege_type,a.is_grantable) FROM aclexplode(d.defaclacl) a))
 FROM pg_default_acl d JOIN pg_namespace n ON n.oid=d.defaclnamespace WHERE n.nspname='public'
) x;
COMMIT;
