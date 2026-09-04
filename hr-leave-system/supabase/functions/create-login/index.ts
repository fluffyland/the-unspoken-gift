// LeaveDesk SG — 员工登录账号管理 Edge Function（创建 / 重置 / 移除）
// HR 在应用里「Add employee」后自动创建登录；「Reset password」重置为默认密码；「Offboard」后自动移除登录。
// 原理：用调用者的 JWT 校验其为 HR/admin →
//   · 创建：用 service_role 建 auth 用户（邮箱预确认）→ 回填 employees.auth_user_id → 返回默认密码（Ssu123@）。
//   · 重置（body.action="reset"）：把该员工登录密码重置为默认密码 Ssu123@。
//   · 移除（body.action="remove"）：查出该员工的 auth_user_id → 删除对应 auth 用户
//     （employees.auth_user_id 外键 on delete set null，自动清空，员工历史保留）。
//
// 部署（二选一）：
//   A. Dashboard → Edge Functions → Create a new function，命名 create-login，粘贴本文件 → Deploy
//   B. CLI： supabase functions deploy create-login
// 无需任何用户密钥：SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY 由平台自动注入。

import { createClient } from "npm:@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// 每个新账号统一使用这个默认密码；员工首次登录后可自行修改。
const DEFAULT_PASSWORD = "Ssu123@";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const authHeader = req.headers.get("Authorization") || "";
    if (!authHeader.startsWith("Bearer ")) return json({ error: "Not signed in." }, 401);

    // 1) 用调用者身份校验是否 HR/admin（is_hr()/is_admin() 依 auth.uid()）
    const asUser = createClient(URL, ANON, { global: { headers: { Authorization: authHeader } } });
    const { data: isHr, error: hrErr } = await asUser.rpc("is_hr");
    if (hrErr) return json({ error: "Could not verify permissions: " + hrErr.message }, 400);
    if (!isHr) return json({ error: "Only HR can manage logins." }, 403);
    // 调用者是否 Owner/Super Admin（is_admin 不存在或报错时按 false 处理）
    let isAdmin = false;
    try { const { data } = await asUser.rpc("is_admin"); isAdmin = !!data; } catch (_e) { /* treat as false */ }

    const { email, emp_id, password, action } = await req.json().catch(() => ({}));
    const mail = String(email || "").trim().toLowerCase();
    const admin = createClient(URL, SERVICE);

    // 2) 找到目标员工档案（按 emp_id 优先，否则按邮箱）。所有动作都必须对应一个真实员工，
    //    防止 HR 借本函数为任意邮箱开通与系统无关的账号。
    let target: { id: string; email: string; role: string; auth_user_id: string | null } | null = null;
    if (emp_id) {
      const { data } = await admin.from("employees").select("id,email,role,auth_user_id").eq("id", emp_id).maybeSingle();
      target = data as typeof target;
    }
    if (!target && mail) {
      const { data } = await admin.from("employees").select("id,email,role,auth_user_id").eq("email", mail).maybeSingle();
      target = data as typeof target;
    }
    if (!target) return json({ error: "No employee record matches this email — add the employee first." }, 400);
    // 3) 越权防线：HR 不能动 Owner / Super Admin 的登录（重置密码=接管账号），只有 Owner 能。
    if (target.role === "admin" && !isAdmin) {
      return json({ error: "Only the Owner / Super Admin can manage an Owner account's login." }, 403);
    }

    // ===== 移除登录（off-board / 彻底删除时调用）=====
    if (action === "remove") {
      if (!target.auth_user_id) return json({ ok: true, removed: false, note: "No login to remove." });
      const { error: dErr } = await admin.auth.admin.deleteUser(target.auth_user_id);
      if (dErr) return json({ error: dErr.message }, 400);
      // 外键 on delete set null 已自动清空 employees.auth_user_id
      return json({ ok: true, removed: true });
    }

    // ===== 重置密码为默认值（Edit → Reset password 时调用）=====
    if (action === "reset") {
      if (!target.auth_user_id) return json({ error: "This person has no login yet — use ‘Create login’ first." }, 400);
      const { error: uErr } = await admin.auth.admin.updateUserById(target.auth_user_id, { password: DEFAULT_PASSWORD });
      if (uErr) return json({ error: uErr.message }, 400);
      // 告知本人密码被改过。失败绝不能影响重设本身 —— 因为一封邮件发不出去
      // 就把人锁在门外，比少一封通知糟糕得多。
      try {
        await admin.functions.invoke("send-notification", {
          body: { kind: "password_changed", to: target.email, by: "HR", at: new Date().toISOString() },
        });
      } catch (_e) { /* fire and forget */ }
      return json({ ok: true, reset: true, email: target.email, password: DEFAULT_PASSWORD });
    }

    // ===== 改登录邮箱（HR 在应用里改了员工 email 时调用）=====
    // 为什么需要：档案和登录是靠 auth_user_id 关联的，不是靠邮箱字符串。
    // 只改 employees.email 的话，本人仍然只能用**旧邮箱**登录，
    // 自助重设密码时用新邮箱收不到码、用旧邮箱码发去了可能已停用的信箱。
    if (action === "change-email") {
      if (!target.auth_user_id) return json({ ok: true, changed: false, note: "No login to update." });
      const newMail = mail || String(target.email || "").trim().toLowerCase();
      if (!newMail) return json({ error: "Email is required." }, 400);
      const { error: eErr } = await admin.auth.admin.updateUserById(target.auth_user_id, {
        email: newMail, email_confirm: true,
      });
      if (eErr) return json({ error: eErr.message }, 400);
      return json({ ok: true, changed: true, email: newMail });
    }

    // ===== 创建登录 =====
    const loginMail = mail || String(target.email || "").trim().toLowerCase();
    if (!loginMail) return json({ error: "Email is required." }, 400);
    const pw = (typeof password === "string" && password.length >= 6) ? password : DEFAULT_PASSWORD;

    // 建 auth 用户（邮箱预确认，员工可立即用密码登录）
    const { data: created, error: cErr } = await admin.auth.admin.createUser({
      email: loginMail, password: pw, email_confirm: true,
    });
    if (cErr) return json({ error: cErr.message }, 400); // 常见：邮箱已存在（已建过登录）

    // 关联到员工档案
    const { error: lErr } = await admin.from("employees")
      .update({ auth_user_id: created.user.id }).eq("id", target.id);
    if (lErr) return json({ error: "Login created but linking failed: " + lErr.message }, 400);

    return json({ ok: true, email: loginMail, password: pw });
  } catch (e) {
    return json({ error: (e as Error)?.message || String(e) }, 500);
  }
});
