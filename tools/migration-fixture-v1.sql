-- New tiny causal fixture, not historical Apromore or full C2 corpus.
-- Schema and checksum are bound to the unchanged v1 baseline source literal.
CREATE TABLE public.pi_kv (key text PRIMARY KEY, version bigint NOT NULL, document jsonb NOT NULL);
CREATE SEQUENCE public.pi_resource_sequence;
CREATE TABLE public.pi_schema_migrations (version integer PRIMARY KEY, name text NOT NULL, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT clock_timestamp());
ALTER TABLE public.pi_kv ADD CONSTRAINT pi_kv_positive_version CHECK (version > 0);
INSERT INTO public.pi_schema_migrations(version,name,checksum)
VALUES (1,'baseline_v1', :'baseline_checksum');
INSERT INTO public.pi_kv(key,version,document)
VALUES ('sprint11/retained-sentinel',7,'{"fixture":"migration-causal-v1","preserve":["Ж","😀",1,true,null]}');
