-- Same verified PG18 version only. ALL row columns are covered by jsonb_send(to_jsonb(row)).
-- Private snapshot: auth row values are never returned, only keyed hashes/lengths.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='5s';
SET LOCAL lock_timeout='2s';
SET LOCAL transaction_timeout='10s';
SET LOCAL search_path=pg_catalog;
SET LOCAL timezone='UTC';
DO $dr_guard$
DECLARE actual text[];
BEGIN
 SELECT array_agg(c.relname::text || ':' || c.relkind::text ORDER BY c.relname)
 INTO actual FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','f','S');
 IF actual IS DISTINCT FROM ARRAY['pi_kv:r','pi_migration_v2:r','pi_projects:r','pi_records:r','pi_resource_sequence:S','pi_schema_migrations:r']::text[] THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='dr_public_relation_inventory';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND (c.relrowsecurity OR c.relforcerowsecurity)) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='dr_rls_not_supported';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal) THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='dr_user_trigger_not_supported';
 END IF;
END $dr_guard$;
WITH row_digests AS (
SELECT 'pi_kv'::text AS table_name, jsonb_build_object('key',jsonb_build_array(r.key),'version',r.version,'encoded_bytes',octet_length(jsonb_send(to_jsonb(r))),'sha256',encode(sha256(jsonb_send(to_jsonb(r))),'hex')) AS item, jsonb_build_array(r.key) AS ordering_key FROM public.pi_kv r
UNION ALL
SELECT 'pi_projects'::text AS table_name, jsonb_build_object('key',jsonb_build_array(r.project_id),'version',r.version,'encoded_bytes',octet_length(jsonb_send(to_jsonb(r))),'sha256',encode(sha256(jsonb_send(to_jsonb(r))),'hex')) AS item, jsonb_build_array(r.project_id) AS ordering_key FROM public.pi_projects r
UNION ALL
SELECT 'pi_records'::text AS table_name, jsonb_build_object('key',jsonb_build_array(r.project_id,r.kind,r.resource_id),'version',r.version,'encoded_bytes',octet_length(jsonb_send(to_jsonb(r))),'sha256',encode(sha256(jsonb_send(to_jsonb(r))),'hex')) AS item, jsonb_build_array(r.project_id,r.kind,r.resource_id) AS ordering_key FROM public.pi_records r
UNION ALL
SELECT 'pi_migration_v2'::text AS table_name, jsonb_build_object('key',jsonb_build_array(r.project_id),'version',r.source_version,'encoded_bytes',octet_length(jsonb_send(to_jsonb(r))),'sha256',encode(sha256(jsonb_send(to_jsonb(r))),'hex')) AS item, jsonb_build_array(r.project_id) AS ordering_key FROM public.pi_migration_v2 r
UNION ALL
SELECT 'pi_schema_migrations'::text AS table_name, jsonb_build_object('key',jsonb_build_array(r.version),'version',NULL::bigint,'encoded_bytes',octet_length(jsonb_send(to_jsonb(r))),'sha256',encode(sha256(jsonb_send(to_jsonb(r))),'hex')) AS item, jsonb_build_array(r.version) AS ordering_key FROM public.pi_schema_migrations r
), managed AS (SELECT c.* FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname IN ('pi_kv','pi_projects','pi_records','pi_migration_v2','pi_schema_migrations'))
SELECT json_build_object('schema_version',1,'encoding','PG18-jsonb_send-to_jsonb-row-sha256-v1',
 'tables',(SELECT json_agg(json_build_object('schema','public','name',c.relname,'owner',pg_get_userbyid(c.relowner),'rls',c.relrowsecurity,'force_rls',c.relforcerowsecurity,
 'columns',(SELECT json_agg(json_build_object('position',a.attnum,'name',a.attname,'type',format_type(a.atttypid,a.atttypmod),'not_null',a.attnotnull,'default',pg_get_expr(d.adbin,d.adrelid),'identity',a.attidentity,'generated',a.attgenerated,'collation',CASE WHEN a.attcollation=0 THEN NULL ELSE a.attcollation::regcollation::text END) ORDER BY a.attnum) FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped),
 'constraints',coalesce((SELECT json_agg(json_build_object('name',conname,'definition',pg_get_constraintdef(oid,true)) ORDER BY conname) FROM pg_constraint WHERE conrelid=c.oid),'[]'::json),
 'indexes',coalesce((SELECT json_agg(json_build_object('name',ic.relname,'definition',pg_get_indexdef(i.indexrelid)) ORDER BY ic.relname) FROM pg_index i JOIN pg_class ic ON ic.oid=i.indexrelid WHERE i.indrelid=c.oid),'[]'::json),
 'rows',coalesce((SELECT json_agg(item ORDER BY ordering_key) FROM row_digests rd WHERE rd.table_name=c.relname),'[]'::json)) ORDER BY c.relname) FROM managed c),
 'sequences',(SELECT json_agg(json_build_object('schema','public','name','pi_resource_sequence','last_value',v.last_value,'is_called',v.is_called,'definition',json_build_object('type',format_type(s.seqtypid,NULL),'increment',s.seqincrement,'min',s.seqmin,'max',s.seqmax,'start',s.seqstart,'cache',s.seqcache,'cycle',s.seqcycle,'owner',pg_get_userbyid(c.relowner)))) FROM public.pi_resource_sequence v CROSS JOIN pg_sequence s JOIN pg_class c ON c.oid=s.seqrelid WHERE s.seqrelid='public.pi_resource_sequence'::regclass));
COMMIT;
SELECT 'DR24_SNAPSHOT_COMMITTED_V1';
