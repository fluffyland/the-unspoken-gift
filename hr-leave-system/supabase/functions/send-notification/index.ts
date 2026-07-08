// LeaveDesk SG — 邮件通知 Edge Function
// 原理：application_events 表每插入一行（= 一次状态转移），
// Supabase Database Webhook 调用本函数，按事件类型给对应的人发邮件（Resend）。
//
// 部署：supabase functions deploy send-notification --no-verify-jwt
// 密钥：supabase secrets set RESEND_API_KEY=re_xxx MAIL_FROM="LeaveDesk <hr@yourcompany.sg>" APP_URL=https://your-app-url
// Webhook：Dashboard → Database → Webhooks → 新建
//   table: application_events, events: INSERT, type: HTTP Request → 本函数 URL

import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, // service role：函数内部读全表，不受 RLS 限制
);
const RESEND_KEY = Deno.env.get("RESEND_API_KEY")!;
const FROM = Deno.env.get("MAIL_FROM") ?? "LeaveDesk <onboarding@resend.dev>";
const APP_URL = Deno.env.get("APP_URL") ?? "";

async function sendMail(to: string, subject: string, body: string) {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: FROM,
      to: [to],
      subject,
      text: body + (APP_URL ? `\n\n登录系统处理：${APP_URL}` : ""),
    }),
  });
  if (!res.ok) console.error("Resend error", res.status, await res.text());
}

Deno.serve(async (req) => {
  const payload = await req.json(); // Database Webhook: { type:'INSERT', record: {...} }
  const ev = payload.record;
  if (!ev?.application_id) return new Response("ignored", { status: 200 });

  const { data: app } = await supabase
    .from("applications")
    .select("*, employee:employees!applications_emp_id_fkey(id,name,email), type:leave_types!applications_leave_type_fkey(name_zh)")
    .eq("id", ev.application_id).single();
  if (!app) return new Response("app not found", { status: 200 });

  const { data: steps } = await supabase
    .from("approval_steps")
    .select("step_order,status,comment,approver:employees!approval_steps_approver_id_fkey(name,email)")
    .eq("application_id", ev.application_id).order("step_order");

  const { data: actor } = await supabase.from("employees").select("name").eq("id", ev.actor).single();

  const emp = app.employee, tz = app.type.name_zh, actorName = actor?.name ?? "";
  const range = `${app.start_date}${app.end_date !== app.start_date ? " 至 " + app.end_date : ""}（${app.days} 天）`;
  const cur = steps?.find((s) => s.status === "pending");
  const note = ev.comment ? `\n备注：${ev.comment}` : "";
  const mails: Array<[string, string, string]> = [];

  switch (ev.action) {
    case "submitted":
    case "resubmitted":
      if (cur) mails.push([cur.approver.email, `【待审批】${emp.name}的${tz}申请`,
        `${emp.name} 申请 ${range}。\n事由：${app.reason}`]);
      break;
    case "step_approved":
      if (cur) mails.push([cur.approver.email, `【待审批·第 ${cur.step_order} 级】${emp.name}的${tz}申请`,
        `上一级（${actorName}）已批准，请您做最终审批。${note}`]);
      mails.push([emp.email, `【进度】您的${tz}申请已通过上一级审批`,
        `${actorName} 已批准，正等待下一级最终审批。${note}`]);
      break;
    case "approved": {
      mails.push([emp.email, `【已批准】您的${tz}申请（${app.days} 天）`,
        `${actorName} 已批准您 ${range} 的${tz}，天数已从余额扣除。${note}`]);
      const { data: hrs } = await supabase.from("employees").select("email").in("role", ["hr"]).eq("active", true);
      for (const h of hrs ?? []) if (h.email !== emp.email)
        mails.push([h.email, `【备案】${emp.name}的${tz}已批准`, `${range}，已记入假期账本。`]);
      break;
    }
    case "rejected":
      mails.push([emp.email, `【已拒绝】您的${tz}申请`, `${actorName} 拒绝了您的申请。${note}`]);
      break;
    case "returned":
      mails.push([emp.email, `【已退回】您的${tz}申请需补充材料`,
        `${actorName} 将申请退回给您。${note}\n请在系统中修改后重新提交。`]);
      break;
    case "withdrawn":
      if (cur) mails.push([cur.approver.email, `【已撤回】${emp.name}撤回了${tz}申请`, `无需再处理。`]);
      break;
    case "cancel_requested":
      if (steps?.[0]) mails.push([steps[0].approver.email, `【销假待确认】${emp.name}申请取消已批准的${tz}`,
        `${range}，确认后将返还天数。`]);
      break;
    case "cancelled":
      mails.push([emp.email, `【销假成功】${tz} ${app.days} 天已返还`, `您 ${range} 的${tz}已取消，天数已返还账户。`]);
      break;
    case "cancel_denied":
      mails.push([emp.email, `【销假被驳回】您的${tz}维持原批准`, note.trim()]);
      break;
  }

  await Promise.all(mails.map(([to, s, b]) => sendMail(to, s, b)));
  return new Response(JSON.stringify({ sent: mails.length }), {
    headers: { "Content-Type": "application/json" },
  });
});
