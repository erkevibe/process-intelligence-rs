\set ON_ERROR_STOP on
BEGIN;
SET LOCAL statement_timeout='5s';
SET LOCAL lock_timeout='2s';
SET LOCAL transaction_timeout='10s';
DO $$ BEGIN IF current_database()<>'pi_s24_capacity_control02' OR to_regclass('public.pi_records') IS NOT NULL OR to_regclass('public.capacity_sentinel') IS NOT NULL THEN RAISE EXCEPTION 'fresh_control_database_required'; END IF; END $$;
CREATE TABLE public.capacity_sentinel(value integer NOT NULL);
INSERT INTO public.capacity_sentinel VALUES(17);
CREATE TABLE public.pi_schema_migrations(version integer,name text);
INSERT INTO public.pi_schema_migrations VALUES(1,'baseline_v1'),(2,'normalized_v2'),(3,'conversion_artifacts_v3');
CREATE TABLE public.pi_kv(key text,version bigint,document jsonb);
CREATE TABLE public.pi_projects(project_id text,version bigint,document jsonb);
CREATE TABLE public.pi_records(project_id text,kind text,resource_id text,version bigint,document jsonb);
CREATE TABLE public.pi_migration_v2(project_id text,source_version bigint,source_sha text,checksum text);
INSERT INTO public.pi_records VALUES('control','unknown_kind','control',1,'{}');
COMMIT;
