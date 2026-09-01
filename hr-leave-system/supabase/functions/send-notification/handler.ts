// LeaveDesk — leave notification emails.
//
// How it fires: every state change writes a row to application_events. A Supabase Database
// Webhook on that table calls this function, which works out who needs to hear about it and
// sends the mail through Resend.
//
// The WORDS all live in ./templates.js, on purpose: that file has no Deno or Supabase
// imports, so the test suite imports the very same file and checks every sentence without
// sending anything. Wording that can only be checked by sending real email never gets
// checked.
//
// THIS FILE IS THE EDITABLE SOURCE. It is not what gets deployed. `node build-single.mjs`
// inlines templates.js into it and writes ./index.ts, and index.ts is what you paste.
//
// Why: the Supabase dashboard deploys ONE entry-point file, index.ts. A second file added
// in the editor is not part of the bundle -- so an entry point that imports "./templates.js"
// cannot resolve it, the module never starts, and every request hangs with no error at all
// while the dashboard still reports "successfully deployed". That happened three times on
// this project. Hence: one deployable file, named exactly what the editor already calls it,
// so there is no second name to reach for.
//
// Deploy:  Edge Functions → send-notification → delete any file that is not index.ts →
//          open index.ts, select all, replace with the repo's generated index.ts → Deploy.
//          Then prove it started: ./check-deploy.sh (OPTIONS only, sends nothing).
//          Leave "Verify JWT with legacy secret" ON. Supabase's own label recommends OFF
//          *with custom auth logic in your function code* -- this function has none on
//          purpose, so verification is what protects it. The anon key the webhook sends,
//          and the session token the test button sends, both satisfy it.
// Secrets: supabase secrets set RESEND_API_KEY=re_xxx \
//            MAIL_FROM="LeaveDesk <onboarding@resend.dev>" \
//            APP_URL=https://fluffyland.github.io/hrleavesystem/
// Webhook: Dashboard → Database → Webhooks → table application_events, event INSERT,
//          type HTTP Request → this function's URL.
//
// Email never gates anything. If this function is not deployed, or Resend is down, leave
// applications and approvals carry on exactly as before -- nobody is blocked by a mail server.

import { buildMails, applyTestMode } from "./templates.js";

/* No npm import, and every outbound call is timeboxed.
   The first version used npm:@supabase/supabase-js and SUPABASE_SERVICE_ROLE_KEY. On this
   project it HUNG -- no response at all, so the browser sat on "Sending…" forever, which is
   worse than any error. Two causes, both avoidable: an npm import has to be fetched and
   built on a cold start, and SUPABASE_SERVICE_ROLE_KEY is not guaranteed to exist now that
   Supabase has moved to sb_publishable_/sb_secret_ keys. Plain fetch needs no build step,
   and a function that always answers can always be diagnosed. */

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("MAIL_FROM") ?? "LeaveDesk <onboarding@resend.dev>";
const APP_URL = Deno.env.get("APP_URL") ?? "";

// A key that can read past RLS, under whichever name this project provides it. Newer
// projects expose SUPABASE_SECRET_KEYS; older ones SUPABASE_SERVICE_ROLE_KEY.
function serviceKey(): string {
  const direct = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_SECRET_KEY");
  if (direct) return direct;
  const many = Deno.env.get("SUPABASE_SECRET_KEYS") || "";
  if (!many) return "";
  try {
    const v = JSON.parse(many);
    if (Array.isArray(v)) return String(v[0]?.api_key ?? v[0] ?? "");
    if (v && typeof v === "object") return String(Object.values(v)[0] ?? "");
  } catch { /* not JSON — fall through */ }
  return many.split(",")[0].trim();
}
const DB_KEY = serviceKey();

// The Send test email button calls this from the browser, which means a CORS preflight.
// Without these the browser blocks the response and supabase-js reports the unhelpful
// "Failed to send a request to the Edge Function" -- indistinguishable from not deployed.
// Copied from create-login, the function in this project already proven in a browser.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// Every network call gets a deadline. A function that hangs cannot be diagnosed by anyone.
async function fetchT(url: string, init: RequestInit = {}, ms = 8000) {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), ms);
  try { return await fetch(url, { ...init, signal: c.signal }); }
  finally { clearTimeout(t); }
}

// One row (or none) from PostgREST, read with the service key so RLS does not apply.
async function q(path: string): Promise<any> {
  if (!SUPABASE_URL || !DB_KEY) return null;
  const res = await fetchT(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: { apikey: DB_KEY, Authorization: `Bearer ${DB_KEY}`, Accept: "application/json" },
  });
  if (!res.ok) { console.error("PostgREST", path, res.status, await res.text()); return null; }
  return await res.json();
}
const one = async (path: string) => (await q(path))?.[0] ?? null;

async function sendMail(to: string, subject: string, text: string) {
  if (!RESEND_KEY) { console.error("RESEND_API_KEY is not set — nothing sent"); return false; }
  const res = await fetchT("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [to], subject, text }),
  }, 10000);
  if (!res.ok) { console.error("Resend", res.status, await res.text()); return false; }
  return true;
}

// The one employee notifications are limited to while testing, and the company name.
async function settings() {
  const o = await one("org_settings?id=eq.1&select=company_name,notify_only_emp");
  let only: string | null = null;
  if (o?.notify_only_emp) {
    const e = await one(`employees?id=eq.${o.notify_only_emp}&select=email`);
    only = e?.email ?? null;
  }
  return { company: o?.company_name || "LeaveDesk", only };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  let payload: any = {};
  try { payload = await req.json(); } catch { /* empty body = test ping */ }
  const cfg = await settings();

  // ---- Test send. No recipient can be passed in: it goes to the employee named in
  // ---- "Only send notifications for", and nowhere else. So this cannot be used to mail
  // ---- an arbitrary address even by someone holding the public key.
  if (payload?.test) {
    if (!SUPABASE_URL || !DB_KEY) return json({ ok: false,
      error: "The function cannot read the database. No service key is available under SUPABASE_SERVICE_ROLE_KEY, SUPABASE_SECRET_KEY or SUPABASE_SECRET_KEYS — add one under Edge Functions → Secrets." });
    if (!RESEND_KEY) return json({ ok: false,
      error: "RESEND_API_KEY is not set. Edge Functions → Secrets → add it, then try again." });
    if (!cfg.only) return json(
      { ok: false, error: "Set 'Only send notifications for' to an employee first — the test email goes to them." });
    const [mail] = buildMails({
      event: "submitted", app: { start_date: "2026-12-15", end_date: "2026-12-17", days: 3,
        reason: "This is a test — no real leave has been applied for" },
      employee: { name: "Test Employee", email: cfg.only },
      actor: { name: "LeaveDesk" }, leaveType: "Annual Leave",
      nextApprover: { name: "there", email: cfg.only },
      appUrl: APP_URL, company: cfg.company,
    });
    const ok = await sendMail(cfg.only, "LeaveDesk test — " + mail.subject, mail.text);
    return json({ ok, sent: ok ? 1 : 0, to: cfg.only,
      error: ok ? null : "Resend refused it. Check RESEND_API_KEY and MAIL_FROM." });
  }

  const ev = payload?.record;
  if (!ev?.application_id) return json({ ignored: true });

  const app = await one(`applications?id=eq.${ev.application_id}&select=*,employee:employees!applications_emp_id_fkey(id,name,email),type:leave_types!applications_leave_type_fkey(name_en)`);
  if (!app?.employee) return json({ ignored: "no application" });

  const steps = await q(`approval_steps?application_id=eq.${ev.application_id}&order=step_order&select=step_order,status,approver:employees!approval_steps_approver_id_fkey(name,email)`) ?? [];
  const actor = ev.actor ? await one(`employees?id=eq.${ev.actor}&select=name`) : null;

  // What is left of that leave type once this application has been accounted for.
  const bal = await one(`leave_balances?emp_id=eq.${app.employee.id}&leave_type=eq.${app.leave_type}&select=balance`);

  const mails = buildMails({
    event: ev.action,
    app: { ...app, comment: ev.comment || "" },
    employee: app.employee,
    actor: { name: actor?.name ?? "LeaveDesk" },
    leaveType: app.type?.name_en ?? app.leave_type,
    nextApprover: steps.find((x: any) => x.status === "pending")?.approver ?? null,
    firstApprover: steps[0]?.approver ?? null,
    balanceAfter: ["approved", "auto_approved", "cancelled", "hr_on_behalf"].includes(ev.action)
      ? bal?.balance ?? null : null,
    appUrl: APP_URL,
    company: cfg.company,
  });

  const toSend = applyTestMode(mails, cfg.only);
  let sent = 0;
  for (const m of toSend) if (await sendMail(m.to, m.subject, m.text)) sent++;
  return json({ built: mails.length, sent, held_back: mails.length - toSend.length });
});
