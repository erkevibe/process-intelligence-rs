-- Complete typed state, including optional v2 tables during historical migration.
-- Versions and sequence fields are decimal strings; JSON document numbers stay JSON.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT 'SELECT jsonb_build_array(''kv'',key,version::text,document) FROM public.pi_kv ORDER BY key COLLATE "C";'
WHERE to_regclass('public.pi_kv') IS NOT NULL
\gexec
SELECT 'SELECT jsonb_build_array(''project'',project_id,version::text,document) FROM public.pi_projects ORDER BY project_id COLLATE "C";'
WHERE to_regclass('public.pi_projects') IS NOT NULL
\gexec
SELECT 'SELECT jsonb_build_array(''record'',project_id,kind,resource_id,version::text,document) FROM public.pi_records ORDER BY project_id COLLATE "C",kind COLLATE "C",resource_id COLLATE "C";'
WHERE to_regclass('public.pi_records') IS NOT NULL
\gexec
SELECT 'SELECT jsonb_build_array(''marker'',to_jsonb(m)) FROM public.pi_migration_v2 m ORDER BY project_id COLLATE "C";'
WHERE to_regclass('public.pi_migration_v2') IS NOT NULL
\gexec
SELECT 'SELECT jsonb_build_array(''ledger'',to_jsonb(m)) FROM public.pi_schema_migrations m ORDER BY version;'
WHERE to_regclass('public.pi_schema_migrations') IS NOT NULL
\gexec
SELECT jsonb_build_array('sequence',last_value::text,log_cnt::text,is_called) FROM public.pi_resource_sequence;
SELECT jsonb_build_array('sequence_definition',seqtypid::text,seqstart::text,seqincrement::text,seqmax::text,seqmin::text,seqcache::text,seqcycle)
FROM pg_sequence WHERE seqrelid='public.pi_resource_sequence'::regclass;
COMMIT;
