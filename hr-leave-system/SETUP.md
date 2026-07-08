# LeaveDesk SG — 正式版部署指南

演示版（`index.html`）开箱即用，数据存在浏览器里。要变成全公司真实可用的系统
（真实登录、真实邮件、数据集中在云端数据库），按下面步骤搭 Supabase 后端。
全程免费额度足够 20–100 人公司使用。

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

## 每年例行维护（HR）

- 1 月 1 日：SQL 执行 `select grant_annual_entitlements(<年份>);` 完成全员入账
- 更新 `public_holidays` 表为当年 MOM 公布的公共假期
- 政策变化（如 2026-04 Shared Parental Leave 增至 10 周）：改 `leave_types.default_days` 即可
