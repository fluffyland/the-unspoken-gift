// Build ONE file that stands up the whole database, for a brand-new Supabase project.
//
// Why this exists, in the user's words: "all the migration why i have to do one by one,
// omg... cant you just compile into one". They were right. Nineteen separate pastes in the
// correct order, none skipped, is not a setup procedure — and the guide itself proved the
// point by listing only thirteen of them for months.
//
// The individual files STAY. They are the upgrade path for a database that already exists.
// This is only for a new one.
//
// Generated, never hand-edited: `node build-install.mjs`. install.sql is proved by building
// a fresh Postgres from it ALONE and running the entire SQL suite against the result.
import fs from 'fs';
const dir = new URL('.', import.meta.url).pathname;

// Order is the whole point. schema first, then every migration by number, then the heartbeat.
const nums = fs.readdirSync(dir)
  .map(f => (f.match(/^migration_app_v(\d+)\.sql$/) || [])[1])
  .filter(Boolean).map(Number).sort((a, b) => a - b);

const parts = ['schema.sql', ...nums.map(n => `migration_app_v${n}.sql`), 'keepalive_ping_v3.sql'];
for (const f of parts)
  if (!fs.existsSync(dir + f)) { console.error('BUILD FAILED — missing', f); process.exit(1); }

const head = `-- ============================================================================
-- LeaveDesk — install.sql   ⚙️  GENERATED FILE, do not edit by hand
--
-- ONE paste sets up a brand-new database. Supabase Dashboard → SQL Editor →
-- New query → paste all of this → Run. It takes a few seconds.
--
-- Then run ONE more file: bootstrap_owner.sql — kept separate because you have to
-- type your own email and password into it.
--
-- This replaces the old procedure of pasting ${parts.length} files one at a time in the
-- right order. Missing one left the system subtly wrong in a single place, which is
-- very hard to work out later.
--
-- ⚠️ For a NEW, EMPTY project only. If your database already exists, do NOT run this —
--    use the individual migration_app_vNN.sql files, which upgrade it in place.
--
-- Contains, in order:
${parts.map((f, i) => `--   ${String(i + 1).padStart(2)}. ${f}`).join('\n')}
--
-- Regenerate with:  node build-install.mjs
-- ============================================================================

`;

let out = head;
for (const f of parts) {
  const body = fs.readFileSync(dir + f, 'utf8');
  out += `\n\n-- ===========================================================================\n`
       + `-- ${f}\n`
       + `-- ===========================================================================\n\n`
       + body.trimEnd() + '\n';
}

out += `

-- ============================================================================
-- Done. If you can read this without a red error above, the database is built.
-- ============================================================================
do $$
begin
  raise notice ' ';
  raise notice 'LeaveDesk installed — now run bootstrap_owner.sql to create your first Owner.';
  raise notice ' ';
end $$;
`;

// A psql meta-command (\\i, \\set) would work in a terminal and fail silently-ish in the
// Supabase SQL editor, which is where this is actually pasted.
const meta = out.split('\n').find(l => /^\\\\[a-z]/.test(l));
if (meta) { console.error('BUILD FAILED — psql meta-command will not run in the dashboard:', meta); process.exit(1); }

fs.writeFileSync(dir + 'install.sql', out);
console.log(`wrote install.sql — ${parts.length} files, ${out.split('\n').length} lines`);
console.log('  ' + parts.join('  '));
