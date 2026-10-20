-- Independent full-value tuple fingerprints. Same typed JSONB text domain as
-- immutable capture054242; small metadata remains complete, heavy rows are hashed.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
WITH rows AS (
 SELECT '1kv/'||key AS sort_key,jsonb_build_array('kv',key) AS identity,
   key='auth' AS small,jsonb_build_array('kv',key,version::text,document) AS value FROM public.pi_kv
 UNION ALL SELECT '2project/'||project_id,jsonb_build_array('project',project_id),true,
   jsonb_build_array('project',project_id,version::text,document) FROM public.pi_projects
 UNION ALL SELECT '3record/'||project_id||'/'||kind||'/'||resource_id,
   jsonb_build_array('record',project_id,kind,resource_id),false,
   jsonb_build_array('record',project_id,kind,resource_id,version::text,document) FROM public.pi_records
 UNION ALL SELECT '4marker/'||project_id,jsonb_build_array('marker',project_id),true,
   jsonb_build_array('marker',to_jsonb(m)) FROM public.pi_migration_v2 m
 UNION ALL SELECT '5ledger/'||version::text,jsonb_build_array('ledger',version::text),true,
   jsonb_build_array('ledger',to_jsonb(m)) FROM public.pi_schema_migrations m
 UNION ALL SELECT '6sequence',jsonb_build_array('sequence'),true,
   jsonb_build_array('sequence',last_value::text,log_cnt::text,is_called) FROM public.pi_resource_sequence
 UNION ALL SELECT '7sequence_definition',jsonb_build_array('sequence_definition'),true,
   jsonb_build_array('sequence_definition',seqtypid::text,seqstart::text,seqincrement::text,
     seqmax::text,seqmin::text,seqcache::text,seqcycle) FROM pg_sequence WHERE seqrelid='public.pi_resource_sequence'::regclass
)
SELECT CASE WHEN small THEN value ELSE jsonb_build_array('hashed',identity,
 octet_length(value::text)::text,encode(sha256(convert_to(value::text,'UTF8')),'hex')) END
FROM rows ORDER BY sort_key COLLATE "C";
COMMIT;
