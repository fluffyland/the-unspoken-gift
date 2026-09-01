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
//          "Verify JWT" can be left at its default: the webhook sends the anon key and the
//          test button sends the signed-in user's token, so both pass verification.
// Secrets: supabase secrets set RESEND_API_KEY=re_xxx \
//            MAIL_FROM="LeaveDesk <onboarding@resend.dev>" \
//            APP_URL=https://fluffyland.github.io/hrleavesystem/
// Webhook: Dashboard → Database → Webhooks → table application_events, event INSERT,
//          type HTTP Request → this function's URL.
//
// Email never gates anything. If this function is not deployed, or Resend is down, leave
// applications and approvals carry on exactly as before -- nobody is blocked by a mail server.

import { createClient } from "npm:@supabase/supabase-js@2";
import { buildMails, applyTestMode } from "./templates.js";

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
