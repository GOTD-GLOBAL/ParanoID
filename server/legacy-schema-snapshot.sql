-- Canonical structural snapshot for offline legacy comparison. Owner/ACL and
-- physical relation IDs intentionally excluded; the private DB owner is trusted.
SELECT value FROM (
 SELECT 'relation:'||c.relname||':'||c.relkind::text||':'||c.relrowsecurity||':'||c.relforcerowsecurity AS value
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1
 UNION ALL
 SELECT 'column:'||c.relname||':'||a.attnum||':'||a.attname||':'||format_type(a.atttypid,a.atttypmod)||':'||a.attnotnull||':'||a.attidentity::text||':'||a.attgenerated::text||':'||coalesce(pg_get_expr(d.adbin,d.adrelid),'')
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum
 WHERE n.nspname=$1 AND a.attnum>0 AND NOT a.attisdropped
 UNION ALL
 SELECT 'constraint:'||c.relname||':'||x.conname||':'||pg_get_constraintdef(x.oid,true)
 FROM pg_constraint x JOIN pg_class c ON c.oid=x.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1
 UNION ALL
 SELECT 'index:'||c.relname||':'||pg_get_indexdef(c.oid)
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relkind='i'
 UNION ALL
 SELECT 'trigger:'||c.relname||':'||t.tgenabled::text||':'||pg_get_triggerdef(t.oid,true)
 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND NOT t.tgisinternal
 UNION ALL
 SELECT 'function:'||p.proname||':'||p.prosrc||':'||p.prosecdef||':'||p.provolatile::text||':'||l.lanname||':'||pg_get_function_identity_arguments(p.oid)||':'||pg_get_function_result(p.oid)
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname=$1
 UNION ALL
 SELECT 'type:'||t.typname||':'||t.typtype::text FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname=$1 AND t.typrelid=0 AND t.typelem=0
) snapshot ORDER BY value;
