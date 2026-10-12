-- New small migration fixtures only. Full fields, not value-size/hash samples.
-- Optional managed tables let the same oracle see a failed v1->v2 DDL rollback.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT jsonb_build_array('managed_relation',name,to_regclass('public.'||name)::text)
FROM unnest(ARRAY['pi_kv','pi_projects','pi_records','pi_migration_v2','pi_schema_migrations','pi_resource_sequence']) name ORDER BY name COLLATE "C";
SELECT format('SELECT jsonb_build_array(%L,to_jsonb(t)) FROM public.%I t ORDER BY to_jsonb(t)::text COLLATE "C";',name,name)
FROM unnest(ARRAY['pi_kv','pi_projects','pi_records','pi_migration_v2','pi_schema_migrations','pi_resource_sequence']) name
WHERE name <> 'pi_resource_sequence' AND to_regclass('public.'||name) IS NOT NULL ORDER BY name COLLATE "C"
\gexec
SELECT jsonb_build_array('pi_resource_sequence',jsonb_build_object('last_value',last_value,'log_cnt',log_cnt,'is_called',is_called)) FROM public.pi_resource_sequence;
SELECT jsonb_build_array('sequence_definition',to_jsonb(s)) FROM pg_sequence s
WHERE seqrelid=to_regclass('public.pi_resource_sequence');
COMMIT;
