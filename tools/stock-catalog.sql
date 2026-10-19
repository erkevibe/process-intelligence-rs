-- Explicit structural catalog/ACL projection for same-database restart.
-- Physical pages, tuple estimates, vacuum/freeze counters are excluded.
-- pg_roles masks passwords; this is not a password/verifier export.
SELECT jsonb_build_object(
 'database',(SELECT to_jsonb(d)-'datfrozenxid'-'datminmxid' FROM pg_database d WHERE datname=current_database()),
 'roles',(SELECT jsonb_agg(to_jsonb(r) ORDER BY rolname) FROM pg_roles r),
 'namespaces',(SELECT jsonb_agg(to_jsonb(n) ORDER BY nspname) FROM pg_namespace n WHERE nspname='public'),
 'relations',(SELECT jsonb_agg(to_jsonb(c)-'relpages'-'reltuples'-'relallvisible'-'relallfrozen'-'relfrozenxid'-'relminmxid' ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'),
 'attributes',(SELECT jsonb_agg(to_jsonb(a) ORDER BY a.attrelid,a.attnum) FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'),
 'constraints',(SELECT jsonb_agg(to_jsonb(c) ORDER BY c.oid) FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='public'),
 'procedures',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'));
