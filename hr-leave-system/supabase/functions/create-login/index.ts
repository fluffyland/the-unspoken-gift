// LeaveDesk SG — 一键为员工创建登录账号 Edge Function
// HR 在应用里「Add employee」后自动调用（或点「Create login」），无需再去 Supabase Auth 手动建号。
// 原理：用调用者的 JWT 校验其为 HR/admin → 用 service_role 建 auth 用户（邮箱预确认）→
//       回填 employees.auth_user_id 完成关联 → 把临时密码返回给 HR 转交员工。
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

// 易读的临时密码：去掉易混字符（0/O/1/l/I），长度 10。
function genPassword(): string {
  const cs = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  const a = new Uint32Array(10);
  crypto.getRandomValues(a);
  return Array.from(a, (n) => cs[n % cs.length]).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const authHeader = req.headers.get("Authorization") || "";
    if (!authHeader.startsWith("Bearer ")) return json({ error: "Not signed in." }, 401);

    // 1) 用调用者身份校验是否 HR/admin（is_hr() 依 auth.uid()）
    const asUser = createClient(URL, ANON, { global: { headers: { Authorization: authHeader } } });
    const { data: isHr, error: hrErr } = await asUser.rpc("is_hr");
    if (hrErr) return json({ error: "Could not verify permissions: " + hrErr.message }, 400);
    if (!isHr) return json({ error: "Only HR can create logins." }, 403);

    const { email, emp_id, password } = await req.json().catch(() => ({}));
    const mail = String(email || "").trim().toLowerCase();
    if (!mail) return json({ error: "Email is required." }, 400);

    const admin = createClient(URL, SERVICE);
    const pw = (typeof password === "string" && password.length >= 8) ? password : genPassword();

    // 2) 建 auth 用户（邮箱预确认，员工可立即用密码登录）
    const { data: created, error: cErr } = await admin.auth.admin.createUser({
      email: mail, password: pw, email_confirm: true,
    });
    if (cErr) return json({ error: cErr.message }, 400); // 常见：邮箱已存在（已建过登录）

    // 3) 关联到员工档案（按 emp_id 优先，否则按邮箱）
    const linkCol = emp_id ? "id" : "email";
    const linkVal = emp_id ? emp_id : mail;
    const { error: lErr } = await admin.from("employees")
      .update({ auth_user_id: created.user.id }).eq(linkCol, linkVal);
    if (lErr) return json({ error: "Login created but linking failed: " + lErr.message }, 400);

    return json({ ok: true, email: mail, password: pw });
  } catch (e) {
    return json({ error: (e as Error)?.message || String(e) }, 500);
  }
});
