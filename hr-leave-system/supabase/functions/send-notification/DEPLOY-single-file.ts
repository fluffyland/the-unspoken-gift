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
// Deploy:  paste DEPLOY-single-file.ts into the dashboard editor (Edge Functions → Deploy a
//          new function → name it send-notification → replace the sample index.ts contents).
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

/* ============================================================================
   GENERATED FILE — do not edit here.
   Paste this whole thing into the Supabase dashboard: Edge Functions →
   Deploy a new function → name it exactly  send-notification  → then replace the
   WHOLE CONTENTS of the sample index.ts with this. Keep the file, replace what is
   inside it. Leave "Verify JWT with legacy secret" ON -- this function has no auth
   logic of its own by design, so that setting is what protects it, and the anon key
   the webhook sends already satisfies it.
   The editable source is index.ts + templates.js in the repo; regenerate with
   `node build-single.mjs`.
   ============================================================================ */

// ---- the words, from templates.js -------------------------------------------
const DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function fmtDay(iso) {
  const [y, m, d] = String(iso).split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  return `${DOW[dt.getUTCDay()]} ${d} ${MON[m - 1]} ${y}`;
}
// One day reads as one day. "Mon 15 Dec 2026 to Mon 15 Dec 2026" is how software talks.
function fmtRange(start, end) {
  return start === end ? fmtDay(start) : `${fmtDay(start)} to ${fmtDay(end)}`;
}
function fmtDays(n) {
  const v = Number(n) || 0;
  return Number.isInteger(v) ? String(v) : String(v);          // 0.5 stays 0.5
}
const firstName = (n) => String(n || "").trim().split(/\s+/)[0] || "there";

// The details block every email shares. Aligned so it reads on a phone.
function block(rows) {
  const w = Math.max(...rows.map(([k]) => k.length));
  // A spacer row is a blank line, not a line of padding -- trailing spaces render as
  // stray whitespace in some mail clients and look like a bug.
  return rows.map(([k, v]) => (k === "" && v === "") ? "" : `  ${k.padEnd(w + 4)}${v}`).join("\n");
}

function body(greetName, lead, rows, tail, ctx) {
  return `Hi ${firstName(greetName)},\n\n${lead}\n\n${block(rows)}\n\n${tail}\n\n— LeaveDesk, ${ctx.company}`;
}

/* Every email this system can send, built from one application record.
   Returns [{ to, subject, text }]. An event nobody needs to hear about returns []. */
function buildMails(ctx) {
  const { event, app, employee, actor, leaveType, nextApprover, firstApprover,
          balanceAfter, appUrl, company } = ctx;
  const c = { company: company || "LeaveDesk" };
  const range = fmtRange(app.start_date, app.end_date);
  const days = fmtDays(app.days);
  const dayWord = Number(app.days) === 1 ? "day" : "days";
  const link = appUrl ? `\n${appUrl}` : "";
  const base = [["Leave type", leaveType], ["Dates", range], ["Working days", days]];
  const withReason = app.reason ? base.concat([["Reason", app.reason]]) : base;
  const out = [];
  const bal = () => balanceAfter == null ? [] : [["", ""], [`${leaveType} left`, `${fmtDays(balanceAfter)} days`]];

  switch (event) {
    case "submitted":
    case "resubmitted":
      if (nextApprover) out.push({
        to: nextApprover.email,
        subject: `${employee.name} has applied for leave — your approval is needed`,
        text: body(nextApprover.name,
          `${employee.name} has applied for leave and it is waiting for you.`,
          withReason, `Approve or reject it here:${link}`, c) });
      out.push({
        to: employee.email,
        subject: `We have received your leave request`,
        text: body(employee.name,
          nextApprover ? `We have received your leave request. It is now with ${nextApprover.name} for approval.`
                       : `We have received your leave request.`,
          withReason,
          `We will email you as soon as there is a decision.${link}`, c) });
      break;

    case "step_approved":
      if (nextApprover) out.push({
        to: nextApprover.email,
        subject: `${employee.name} has applied for leave — your final approval is needed`,
        text: body(nextApprover.name,
          `${actor.name} has already approved this. It needs your final approval.`,
          withReason, `Approve or reject it here:${link}`, c) });
      out.push({
        to: employee.email,
        subject: `${actor.name} has approved your leave — one more to go`,
        text: body(employee.name,
          `${actor.name} has approved your leave. It now needs${nextApprover ? ` ${nextApprover.name}'s` : " one more"} final approval.`,
          base, `We will email you when it is decided.${link}`, c) });
      break;

    case "approved":
      out.push({
        to: employee.email,
        subject: `Your leave has been approved`,
        text: body(employee.name,
          `Good news — ${actor.name} has approved your leave.`,
          base.concat(bal()), `Enjoy your time off.`, c) });
      break;

    case "auto_approved":
      out.push({
        to: employee.email,
        subject: `Your leave has been recorded and approved`,
        text: body(employee.name,
          `Your leave has been recorded and approved. Nobody else needed to approve it.`,
          base.concat(bal()), `Enjoy your time off.`, c) });
      break;

    case "rejected":
      out.push({
        to: employee.email,
        subject: `Your leave request was not approved`,
        text: body(employee.name,
          `${actor.name} has not approved your leave request.`,
          withReason.concat(app.comment ? [["", ""], ["They said", app.comment]] : []),
          `Your days have not been deducted. Speak to ${actor.name} if you would like to discuss it.${link}`, c) });
      break;

    case "returned":
      out.push({
        to: employee.email,
        subject: `Your leave request needs a bit more information`,
        text: body(employee.name,
          `${actor.name} has sent your leave request back to you.`,
          base.concat(app.comment ? [["", ""], ["They asked for", app.comment]] : []),
          `Open LeaveDesk, make the change and send it again.${link}`, c) });
      break;

    case "withdrawn":
      if (nextApprover) out.push({
        to: nextApprover.email,
        subject: `${employee.name} has withdrawn their leave request`,
        text: body(nextApprover.name,
          `${employee.name} has withdrawn the leave request that was waiting for you. There is nothing for you to do.`,
          base, `No days have been deducted.`, c) });
      break;

    case "cancel_requested":
      if (firstApprover) out.push({
        to: firstApprover.email,
        subject: `${employee.name} wants to cancel approved leave`,
        text: body(firstApprover.name,
          `${employee.name} is asking to cancel leave that was already approved.`,
          base, `Confirm it in LeaveDesk and the days go back to them.${link}`, c) });
      break;

    case "cancelled":
      out.push({
        to: employee.email,
        subject: `Your leave has been cancelled and the days returned`,
        text: body(employee.name,
          `Your leave has been cancelled, and the days are back in your balance.`,
          [["Leave type", leaveType], ["Dates", range], ["Days returned", days]].concat(bal()),
          `Nothing else to do.`, c) });
      break;

    case "cancel_denied":
      out.push({
        to: employee.email,
        subject: `Your leave has not been cancelled`,
        text: body(employee.name,
          `${actor.name} has not agreed to cancel this leave, so it still stands.`,
          base.concat(app.comment ? [["", ""], ["They said", app.comment]] : []),
          `The ${days} ${dayWord} remain deducted.${link}`, c) });
      break;

    case "hr_on_behalf":
      out.push({
        to: employee.email,
        subject: `HR has recorded leave for you`,
        text: body(employee.name,
          `${actor.name} has recorded this leave for you and approved it.`,
          base.concat(bal()),
          `If anything looks wrong, tell HR.${link}`, c) });
      break;
  }
  return out;
}

/* Test mode. While an employee is named, only mail addressed to THEM goes out — nobody
   else in the company can receive anything by accident. Blank = everyone, which is how it
   is left once you are happy. */
function applyTestMode(mails, onlyEmail) {
  if (!onlyEmail) return mails;
  const t = String(onlyEmail).trim().toLowerCase();
  return mails.filter(m => String(m.to || "").trim().toLowerCase() === t);
}
// ---- end of templates.js ----------------------------------------------------

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
