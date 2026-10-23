-- PostgreSQL 18; execute with psql -X -q -A -t -v ON_ERROR_STOP=1 -f this-file.
-- Counts are transaction-visible. Physical sizes are observations, not quota/free space.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '2s';
SET LOCAL transaction_timeout = '10s';
SET LOCAL search_path = pg_catalog;
DO $diagnostic$
DECLARE item record;
BEGIN
  FOR item IN SELECT * FROM (VALUES
    ('pi_schema_migrations','version','int4'),('pi_schema_migrations','name','text'),
    ('pi_kv','key','text'),('pi_kv','version','int8'),('pi_kv','document','jsonb'),
    ('pi_projects','project_id','text'),('pi_projects','version','int8'),('pi_projects','document','jsonb'),
    ('pi_records','project_id','text'),('pi_records','kind','text'),('pi_records','resource_id','text'),('pi_records','version','int8'),('pi_records','document','jsonb'),
    ('pi_migration_v2','project_id','text'),('pi_migration_v2','source_version','int8'),('pi_migration_v2','source_sha','text'),('pi_migration_v2','checksum','text')
  ) AS required(relation_name,column_name,type_name)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
      JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid JOIN pg_catalog.pg_type t ON t.oid=a.atttypid
      WHERE n.nspname='public' AND c.relname=item.relation_name AND c.relkind='r' AND NOT c.relrowsecurity AND NOT c.relforcerowsecurity
      AND a.attname=item.column_name AND a.attnum>0 AND NOT a.attisdropped AND t.typname=item.type_name AND t.typnamespace='pg_catalog'::regnamespace)
    THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='capacity_minimum_v3_schema_required'; END IF;
  END LOOP;
  IF (SELECT array_agg(version ORDER BY version) FROM public.pi_schema_migrations) IS DISTINCT FROM ARRAY[1,2,3]
     OR (SELECT array_agg(name ORDER BY version) FROM public.pi_schema_migrations) IS DISTINCT FROM ARRAY['baseline_v1','normalized_v2','conversion_artifacts_v3']::text[]
  THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='capacity_minimum_v3_ledger_required'; END IF;
  IF EXISTS (SELECT 1 FROM public.pi_records WHERE kind NOT IN ('log_state','log_data','log_source','log_analysis','model','conversion') OR kind IS NULL)
  THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='capacity_unknown_record_kind'; END IF;
END
$diagnostic$;
WITH kinds(kind) AS (VALUES ('log_state'),('log_data'),('log_source'),('log_analysis'),('model'),('conversion')),
counts AS (SELECT k.kind,count(r.kind) AS records FROM kinds k LEFT JOIN public.pi_records r ON r.kind=k.kind GROUP BY k.kind),
relations AS (SELECT c.oid,c.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relname IN ('pi_schema_migrations','pi_kv','pi_projects','pi_records','pi_migration_v2') AND c.relkind='r')
SELECT json_build_object(
 'schema_version',1,'status','CAPACITY_DIAGNOSTIC_ROW_REQUIRES_COMMIT_MARKER_AND_NATIVE_EXIT0',
 'observed_at',clock_timestamp(),'database',current_database(),'transaction_read_only',current_setting('transaction_read_only'),
 'transaction_isolation',current_setting('transaction_isolation'),'project_count',(SELECT count(*) FROM public.pi_projects),
 'record_counts',(SELECT json_object_agg(kind,records ORDER BY kind) FROM counts),
 'managed_relations',(SELECT json_agg(json_build_object('relation',relname,'table_including_toast_bytes',pg_table_size(oid),
   'indexes_bytes',pg_indexes_size(oid),'total_bytes',pg_total_relation_size(oid)) ORDER BY relname) FROM relations),
 'database_physical_bytes',pg_database_size(current_database()),
 'limitations','Logical counts are transaction-visible; physical bytes may change during execution. Managed table/TOAST/index and database sizes overlap: do not add. Not quota, schema certification, WAL, other databases, backups or filesystem free space.');
COMMIT;
SELECT 'CAPACITY_DIAGNOSTIC_COMMITTED_V1';
