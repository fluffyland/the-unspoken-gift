# LeaveDesk SG — 正式版部署指南

演示版（`index.html`）开箱即用，数据存在浏览器里。要变成全公司真实可用的系统
（真实登录、真实邮件、数据集中在云端数据库），按下面步骤搭 Supabase 后端。
全程免费额度足够 20–100 人公司使用。

## 本项目的连接信息（已创建，2026-07）

- Project URL: `https://aypyolzkdupkpefpxius.supabase.co`
- anon public key（前端连接用，公开安全 —— 权限全部由数据库 RLS 强制）:
  `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF5cHlvbHprZHVwa3BlZnB4aXVzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM1MDM0MTMsImV4cCI6MjA5OTA3OTQxM30.hoRS_j8yBTJkcQBG_IZRuVgDD06ZGCRam8lqz923f6s`
- ⏳ 待办：`schema.sql` 与 `seed.sql` 还未在 SQL Editor 执行（执行后表才会存在）

## 第 1 步：创建 Supabase 项目（约 5 分钟）

1. 打开 https://supabase.com → 用 GitHub 或 Google 账号注册 → **New project**
2. 项目名随意（如 `leavedesk`），Region 选 **Southeast Asia (Singapore)**，设置数据库密码并保存好
3. 项目建好后，记下两样东西（Settings → API）：
   - `Project URL`（形如 `https://xxxx.supabase.co`）
   - `anon public` key（前端用）

## 第 2 步：建表 + 权限（复制粘贴一次）

1. Dashboard 左侧 **SQL Editor** → New query
2. 把 `supabase/schema.sql` 整个文件内容粘贴进去 → **Run**
3. 完成后自动拥有：7 张表、余额视图、工作日折算函数、
   全部状态机存储过程（提交/审批/退回/撤回/销假）、RLS 行级权限、年度入账函数

## 第 3 步：录入员工

1. Dashboard → **Authentication** → Users → 逐个 **Invite user**（输入员工公司邮箱）
2. **Table Editor** → `employees` 表 → 为每个员工插入一行：
   姓名、email（与登录邮箱一致）、入职日期、部门、性别、角色、
   `approver1`（直属上司的 id）、需要两级审批的员工勾 `two_level` 并填 `approver2`
3. 把每行的 `auth_user_id` 填成 Authentication 里对应用户的 UUID（关联登录身份）
4. SQL Editor 执行一次年度入账：`select grant_annual_entitlements(2026);`

## 第 4 步：自动邮件（Resend）

1. https://resend.com 注册（免费每天 100 封，足够），验证你的发件域名，拿到 API Key
2. 安装 Supabase CLI 后在 `hr-leave-system/` 目录执行：
   ```bash
   supabase login
   supabase link --project-ref <你的项目ref>
   supabase secrets set RESEND_API_KEY=re_xxx MAIL_FROM="LeaveDesk <hr@yourcompany.sg>" APP_URL=https://<你的前端网址>
   supabase functions deploy send-notification --no-verify-jwt
   ```
3. Dashboard → **Database → Webhooks** → Create：
   - Table: `application_events`，Events: **INSERT**
   - Type: HTTP Request → URL 填 `send-notification` 函数的 URL
   
   之后每一次状态转移（提交/批准/拒绝/退回/撤回/销假）都会自动发对应邮件，一封不漏。

## 第 5 步：附件存储（MC / 证明）

1. Dashboard → **Storage** → New bucket：`attachments`（Private）
2. 加两条 Storage policy：登录用户可上传到 `attachments/{自己emp_id}/...`；
   本人、链上审批人、HR 可读（参照 applications 的 RLS 写法）

## 第 6 步：前端接线并上线

演示版 `index.html` 里所有数据操作都集中在「数据层」区（文件顶部有标注），
接线就是把 localStorage 的读写换成 supabase-js 调用，一一对应：

| 演示版函数 | 正式版调用 |
|---|---|
| `submitApp(...)` | `supabase.rpc('submit_application', {...})` |
| `actOnStep(...)` | `supabase.rpc('act_on_step', {...})` |
| `withdrawApp(...)` | `supabase.rpc('withdraw_application', {...})` |
| `requestCancel / confirmCancel` | `supabase.rpc('request_cancel' / 'confirm_cancel', {...})` |
| `bal(...)` | `select * from leave_balances`（视图） |
| 登录页演示账号 | `supabase.auth.signInWithPassword` 或 magic link |
| 模拟邮件 outbox | 删除（真实邮件由 Edge Function 发送） |

前端托管任选：Netlify / Vercel / GitHub Pages（纯静态即可，密钥只用 anon key，
安全由数据库端 RLS + 存储过程保证——前端即使被改，也做不了越权的事）。

## 第 7 步：公共假期自动同步 + 站内公告 + 年假结转（v7）

本步让系统**自动**去新加坡官方开放数据（data.gov.sg，MOM 维护的公共假期数据集）
核对假期：每月检查本年是否有改动/临时假日（如大选日），并在次年假期公布后自动载入
「次年日历」（只可查看，1 月 1 日前不能申请）。有任何变更会**给全员发站内公告**
（下次登录即见）。同时把年假结转做成**上限 5 天、先用结转、次年 12/31 未用作废**。

1. **跑数据库迁移**：SQL Editor 粘贴执行 `supabase/migration_app_v7.sql`（幂等，可重复）。
2. **部署同步函数**（在 `hr-leave-system/` 目录，已登录/link 过项目）：
   ```bash
   supabase functions deploy sync-holidays --no-verify-jwt
   ```
   > 无需任何用户密钥：函数运行时由 Supabase 平台自动注入 service_role，
   > **不是**被吊销的那把 secret。可先手动跑一次验证：
   > `curl -X POST https://<项目ref>.functions.supabase.co/sync-holidays`
   > 返回 `{"ok":true,...}` 即成功；随后在 `holiday_sync_log` 表能看到一条记录。
3. **定时**（SQL Editor 执行一次，用 pg_cron 每月自动调用同步函数）：
   ```sql
   create extension if not exists pg_cron;
   create extension if not exists pg_net;
   -- 每月 1 号自动同步一次（想更勤可改成每周 0 19 * * 0）
   select cron.schedule('sync-holidays-monthly', '0 19 1 * *', $$
     select net.http_post(url := 'https://<项目ref>.functions.supabase.co/sync-holidays');
   $$);
   ```
4. **上传新前端**：把更新后的 `app.html` 复制成 `index.html` 部署（本仓库脚本已自动做，
   见 auto-deploy）。前端会在登录后展示未读公告、仪表盘显示「本年结转 X 天，X 前用完」，
   申请页对次年日期只读、必填项标红 `*`。

## 一键创建员工登录（create-login Edge Function）

让「Add employee」直接建好登录账号，HR 不用再去 Supabase Authentication 手动开号。
一次性部署，之后永久一键。

1. **部署函数**（二选一）：
   - **Dashboard（免 CLI）**：Supabase → **Edge Functions** → **Create a new function** →
     命名 `create-login` → 把 `supabase/functions/create-login/index.ts` 全文粘贴 → **Deploy**。
   - **CLI**：`supabase functions deploy create-login`
   > 无需任何密钥：`SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY` 平台自动注入。
2. **关自助注册**（保持）：Authentication → Providers/Settings 里「Enable email signups」可关；
   本函数用 service_role 建号并预确认邮箱，员工可立即用「邮箱 + 临时密码」登录。
3. 用法：应用里 **Add employee** 保存后会自动建登录，所有新账号统一使用默认密码
   **`Ssu123@`**（弹窗会显示，转交员工，让其首次登录后改密）。给老员工补登录：
   打开其 **Edit** → **Create login**。
   > `Ssu123@` 含大小写字母、数字、符号，满足常见复杂度要求；一般不会被最小长度或
   > 泄露密码检查拦下。改动此默认密码只需改函数里的 `DEFAULT_PASSWORD` 再重新部署。

## 每年例行维护（HR）—— v7 后已自动化

- **公共假期**：无需再手工维护——系统每月自动核对、次年公布后自动载入并公告全员。
  （HR 仍可在「Company settings」手工增删临时假日；自动同步只动 `source='data.gov.sg'` 的行，
   不会覆盖手工录入。出问题时看 `holiday_sync_log` 表。）
- **年度切换（每年 1 月 1 日，结转 + 入账）**：可 SQL 手动跑，或用 pg_cron 自动：
  ```sql
  -- 先结转（上限 5、先用结转、上一年未用作废），再发放新年度额度；两者幂等
  select cron.schedule('annual-rollover', '0 17 31 12 *', $$
    select rollover_annual_leave(extract(year from (now() at time zone 'Asia/Singapore'))::int);
  $$);
  select cron.schedule('annual-grant', '30 17 31 12 *', $$
    select grant_annual_entitlements(extract(year from (now() at time zone 'Asia/Singapore'))::int);
  $$);
  ```
  > 手动等价写法（任意时间，幂等）：`select rollover_annual_leave(2027); select grant_annual_entitlements(2027);`
- 政策变化（如 Shared Parental Leave 增至 10 周）：改 `leave_types.default_days` 即可。
