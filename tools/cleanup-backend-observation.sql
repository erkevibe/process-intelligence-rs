-- New owned diagnostic source only. Safe phase metadata, no query payload.
SELECT jsonb_build_object(
 'pid',pid,'backend_start',backend_start,'database',datname,
 'application_name',application_name,'backend_type',backend_type,
 'state',state,'xact_start',xact_start,'query_start',query_start,
 'wait_event_type',wait_event_type,'wait_event',wait_event,
 'query_kind',CASE WHEN query LIKE 'DELETE FROM public.pi_kv%' THEN 'delete'
                   WHEN query='COMMIT' THEN 'commit' ELSE 'other' END)
FROM pg_stat_activity
WHERE datname=:'target_database' AND application_name='pi_cleanup_offline'
 AND backend_type='client backend' AND pid<>pg_backend_pid();
