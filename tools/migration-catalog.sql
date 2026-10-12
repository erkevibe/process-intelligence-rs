-- Additive projection for new migration fixtures; stock projection unchanged.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
\ir stock-catalog.sql
SELECT jsonb_build_object(
 'event_triggers',(SELECT jsonb_agg(to_jsonb(e) ORDER BY evtname) FROM pg_event_trigger e),
 'indexes',(SELECT jsonb_agg(to_jsonb(i) ORDER BY i.indexrelid) FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'),
 'triggers',(SELECT jsonb_agg(to_jsonb(t) ORDER BY t.oid) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'),
 'rewrites',(SELECT jsonb_agg(to_jsonb(r) ORDER BY r.oid) FROM pg_rewrite r JOIN pg_class c ON c.oid=r.ev_class JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'));
COMMIT;
