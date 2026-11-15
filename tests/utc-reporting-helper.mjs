import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
export async function applyUtcReporting(db){
 await db.exec(await readFile('tests/fixtures/utc-reporting-before.sql','utf8'));
 const before=(await db.query("select oid::regprocedure::text signature,proacl,prosecdef,proconfig from pg_proc where pronamespace in ('public'::regnamespace,'private'::regnamespace) order by oid")).rows;
 await db.exec(await readFile('supabase/migrations/20261115144307_utc_reporting_calendar.sql','utf8'));
 const after=(await db.query("select oid::regprocedure::text signature,proacl,prosecdef,proconfig from pg_proc where pronamespace in ('public'::regnamespace,'private'::regnamespace) order by oid")).rows;
 assert.deepEqual(after,before,'UTC migration preserves signatures, grants and security settings');
 const stale=(await db.query("select proname from pg_proc where pronamespace in ('public'::regnamespace,'private'::regnamespace) and prosrc like '%Asia/Karachi%'")).rows;
 assert.deepEqual(stale,[],'No active reporting function retains Pakistan calendar boundaries');
}
