-- Read-only complete privilege-catalog snapshot, private NEW fixture only.
-- Full rows for EVERY pg_catalog aclitem[] column, including NULL/default ACLs.
-- No pg_authid/pg_shadow password verifier is selected.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT jsonb_build_array('acl_columns',n.nspname,c.relname,a.attname,a.atttypid::text)
FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='pg_catalog' AND a.atttypid='aclitem[]'::regtype
 AND a.attnum>0 AND NOT a.attisdropped AND c.relkind IN ('r','p')
ORDER BY n.nspname COLLATE "C",c.relname COLLATE "C",a.attname COLLATE "C";
SELECT format('SELECT jsonb_build_array(''acl_row'',%L,%L,%L,to_jsonb(t)) FROM %I.%I t ORDER BY to_jsonb(t)::text COLLATE "C";',n.nspname,c.relname,a.attname,n.nspname,c.relname)
FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='pg_catalog' AND a.atttypid='aclitem[]'::regtype
 AND a.attnum>0 AND NOT a.attisdropped AND c.relkind IN ('r','p')
ORDER BY n.nspname COLLATE "C",c.relname COLLATE "C",a.attname COLLATE "C"
\gexec
SELECT jsonb_build_array('roles',to_jsonb(r)-'rolpassword') FROM pg_roles r ORDER BY r.oid;
SELECT jsonb_build_array('memberships',to_jsonb(m)) FROM pg_auth_members m ORDER BY to_jsonb(m)::text COLLATE "C";
SELECT jsonb_build_array('security_metadata','pg_policy',to_jsonb(t)) FROM pg_policy t ORDER BY to_jsonb(t)::text COLLATE "C";
SELECT jsonb_build_array('security_metadata','pg_seclabel',to_jsonb(t)) FROM pg_seclabel t ORDER BY to_jsonb(t)::text COLLATE "C";
SELECT jsonb_build_array('security_metadata','pg_shseclabel',to_jsonb(t)) FROM pg_shseclabel t ORDER BY to_jsonb(t)::text COLLATE "C";
SELECT jsonb_build_array('security_metadata','pg_shdepend',to_jsonb(t)) FROM pg_shdepend t ORDER BY to_jsonb(t)::text COLLATE "C";
SELECT jsonb_build_array('security_metadata','pg_db_role_setting',to_jsonb(t)) FROM pg_db_role_setting t ORDER BY to_jsonb(t)::text COLLATE "C";
SELECT jsonb_build_array('target_function',p.oid::text,p.oid::regprocedure::text,p.proowner::text,
 p.proowner::regrole::text,to_jsonb(p),
 (SELECT jsonb_agg(jsonb_build_object('grantor',x.grantor::text,'grantee',x.grantee::text,
   'privilege_type',x.privilege_type,'is_grantable',x.is_grantable)
  ORDER BY x.grantor,x.grantee,x.privilege_type,x.is_grantable)
  FROM aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) x),
 has_function_privilege('pi_app',p.oid,'EXECUTE'))
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE p.oid='pg_catalog.pg_control_system()'::regprocedure AND n.nspname='pg_catalog'
 AND p.proname='pg_control_system' AND p.pronargs=0;
COMMIT;
