-- Exact owned-fixture before/after comparison, not the quota metric.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT jsonb_build_object(
 'ledger',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY version),'[]') FROM public.pi_schema_migrations t),
 'projects',(SELECT coalesce(jsonb_agg(jsonb_build_array(project_id,version,encode(sha256(convert_to(document::text,'UTF8')),'hex')) ORDER BY project_id),'[]') FROM public.pi_projects),
 'records',(SELECT coalesce(jsonb_agg(jsonb_build_array(project_id,kind,resource_id,version,encode(sha256(convert_to(document::text,'UTF8')),'hex')) ORDER BY project_id,kind,resource_id),'[]') FROM public.pi_records),
 'quota',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY project_id),'[]') FROM public.pi_project_quota t),
 'kv',(SELECT coalesce(jsonb_agg(jsonb_build_array(key,version,encode(sha256(convert_to(document::text,'UTF8')),'hex')) ORDER BY key),'[]') FROM public.pi_kv),
 'markers',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY project_id),'[]') FROM public.pi_migration_v2 t),
 'sequence',(SELECT jsonb_build_object('last_value',last_value,'is_called',is_called) FROM public.pi_resource_sequence),
 'tables',(SELECT jsonb_agg(jsonb_build_array(c.relname,c.relkind,c.relpersistence,c.relrowsecurity,c.relforcerowsecurity) ORDER BY c.relname) FROM pg_class c JOIN pg_namespace s ON s.oid=c.relnamespace WHERE s.nspname='public' AND c.relkind IN ('r','p')),
 'columns',(SELECT jsonb_agg(jsonb_build_array(c.relname,a.attnum,a.attname,format_type(a.atttypid,a.atttypmod),a.attnotnull,a.attidentity,a.attgenerated,pg_get_expr(d.adbin,d.adrelid),co.collname) ORDER BY c.relname,a.attnum) FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace s ON s.oid=c.relnamespace LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum LEFT JOIN pg_collation co ON co.oid=a.attcollation WHERE s.nspname='public' AND c.relkind IN ('r','p') AND a.attnum>0 AND NOT a.attisdropped),
 'constraints',(SELECT jsonb_agg(jsonb_build_array(c.relname,n.conname,pg_get_constraintdef(n.oid),n.convalidated,n.condeferrable,n.condeferred) ORDER BY c.relname,n.conname) FROM pg_constraint n JOIN pg_class c ON c.oid=n.conrelid JOIN pg_namespace s ON s.oid=c.relnamespace WHERE s.nspname='public'),
 'indexes',(SELECT jsonb_agg(jsonb_build_array(tablename,indexname,indexdef) ORDER BY tablename,indexname) FROM pg_indexes WHERE schemaname='public'),
 'triggers',(SELECT coalesce(jsonb_agg(jsonb_build_array(c.relname,t.tgname,pg_get_triggerdef(t.oid)) ORDER BY c.relname,t.tgname),'[]') FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace s ON s.oid=c.relnamespace WHERE s.nspname='public' AND NOT t.tgisinternal)
);
COMMIT;
