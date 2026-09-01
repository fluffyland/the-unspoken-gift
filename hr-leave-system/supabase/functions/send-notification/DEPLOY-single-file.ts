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

import { createClient } from "npm:@supabase/supabase-js@2";

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


const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,   // reads every table; RLS does not apply
);
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("MAIL_FROM") ?? "LeaveDesk <onboarding@resend.dev>";
const APP_URL = Deno.env.get("APP_URL") ?? "";

// The Send test email button calls this from the browser, which means a CORS preflight.
// Without these the browser blocks the response and supabase-js reports the unhelpful
// "Failed to send a request to the Edge Function" -- indistinguishable from not deployed.
// Copied from create-login, the function in this project that is already proven in a browser.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function sendMail(to: string, subject: string, text: string) {
  if (!RESEND_KEY) { console.error("RESEND_API_KEY is not set — nothing sent"); return false; }
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [to], subject, text }),
  });
  if (!res.ok) { console.error("Resend", res.status, await res.text()); return false; }
  return true;
}

// The one employee notifications are limited to while testing, and the company name.
async function settings() {
  const { data } = await supabase.from("org_settings")
    .select("company_name, notify_only_emp").eq("id", 1).maybeSingle();
  let only = null;
  if (data?.notify_only_emp) {
    const { data: e } = await supabase.from("employees")
      .select("email").eq("id", data.notify_only_emp).maybeSingle();
    only = e?.email ?? null;
  }
  return { company: data?.company_name || "LeaveDesk", only };
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

  const { data: app } = await supabase.from("applications")
    .select("*, employee:employees!applications_emp_id_fkey(id,name,email), type:leave_types!applications_leave_type_fkey(name_en)")
    .eq("id", ev.application_id).maybeSingle();
  if (!app?.employee) return json({ ignored: "no application" });

  const { data: steps } = await supabase.from("approval_steps")
    .select("step_order,status,approver:employees!approval_steps_approver_id_fkey(name,email)")
    .eq("application_id", ev.application_id).order("step_order");
  const { data: actor } = await supabase.from("employees")
    .select("name").eq("id", ev.actor).maybeSingle();

  // What is left of that leave type once this application has been accounted for.
  const { data: bal } = await supabase.from("leave_balances")
    .select("balance").eq("emp_id", app.employee.id).eq("leave_type", app.leave_type).maybeSingle();

  const mails = buildMails({
    event: ev.action,
    app: { ...app, comment: ev.comment || "" },
    employee: app.employee,
    actor: { name: actor?.name ?? "LeaveDesk" },
    leaveType: app.type?.name_en ?? app.leave_type,
    nextApprover: steps?.find((s: any) => s.status === "pending")?.approver ?? null,
    firstApprover: steps?.[0]?.approver ?? null,
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
