# LeaveDesk SG — Leave Management System

员工申请 → 自动 email 审批人 → 批准 / 拒绝 / 退回（审批路线由 HR 按员工设定）→
自动 email 通知员工 → 批准后记入假期账本、进入 HR 记录。
员工随时可查各类假期（Annual / Sick / Hospitalisation / Maternity / Off-in-Lieu 等
新加坡全部法定假期）的剩余天数。**界面为全英文**。

## 📖 先看这些（按你的身份挑一份）

| 你是谁 / 要做什么 | 看这份 |
|---|---|
| **要在新账号上从零搭一遍**（新 Supabase、新 GitHub、新监控） | **[`MIGRATION_GUIDE.md`](MIGRATION_GUIDE.md)** ← 一步步点，最详细 |
| **HR / Owner 日常操作**（加人、审批、离职、改假期类型） | [`GUIDE_HR.md`](GUIDE_HR.md) |
| **发给普通员工看的** | [`GUIDE_EMPLOYEE.md`](GUIDE_EMPLOYEE.md) |
| **每年 1 月例行检查**（含「自动同步万一没跑成怎么办」） | [`YEARLY_CHECKLIST.md`](YEARLY_CHECKLIST.md) |
| 交接给下一个开发者 / AI | [`HANDOVER.md`](HANDOVER.md) |
| 换公司 / 全量重置 SOP | [`NEW_COMPANY_SETUP.md`](NEW_COMPANY_SETUP.md) |

## 文件说明

| 文件 | 用途 |
|---|---|
| `MIGRATION_GUIDE.md` | **新账号从零部署总指南**：要注册哪些网站、建哪些仓库、跑哪些 SQL、部署哪些函数、防休眠与监控怎么配、最后逐条验收。 |
| `GUIDE_HR.md` / `GUIDE_EMPLOYEE.md` | HR 操作手册 / 员工使用手册（英文，与界面一致）。 |
| `year-start-flowchart.html` | 「Start a new year」按钮到底做了什么 —— 逐步流程图 + 实例，双击即可打开。 |
| `YEARLY_CHECKLIST.md` | 每年例行检查。重点是**不要盲信自动化**：公共假期同步、年度入账、防休眠、报警通道，逐项验证「结果」而不是「有没有排程」。 |
| `app.html` | **生产版应用**（部署在 https://fluffyland.github.io/hrleavesystem/ ）。真实登录 + Supabase 数据库,持续维护更新。 |
| `index.html` | 演示版（单文件、免安装,数据存浏览器）。**已冻结**,新功能只进 app.html。 |
| `supabase/schema.sql` | 正式版数据库底座：7 张表、余额视图、状态机存储过程、RLS 权限、年度入账函数。在 Supabase SQL Editor 执行一次即可。 |
| `supabase/functions/send-notification/index.ts` | 邮件 Edge Function：监听状态转移事件，用 Resend 发真实邮件。 |
| `SETUP.md` | 正式版部署指南（一步步照做）。 |
| `DESIGN.md` | 第一性原则设计文档（账本 / 状态机 / 通知 / 权限四大支柱）。 |

## 组织与审批路线（来自公司组织架构图，已内置为演示数据）

- **Doris**（Managing Director）：无审批人，请假自动记录备案（HR 收通知）；系统管理员权限
- **直通 Doris**：Michelle、Alice、Usam、Burak、Lin、文斌
- **Michelle** 审批：Tam、Phyllis（Bookshop）、Amanda、Paulin、Daisy（School Account）
- **Alice**（Retail Head & **HR**）审批：Yukong；并拥有 HR Console 全部权限
- **Usam**（Warehouse Dept Head）审批：文翰
- **Belinda**（Merchandising Dept Head）审批：Barry
- **Maggie**、**Annie**（Finance）：直接向 Doris 汇报，无部门主管
- 全员默认一级审批；HR 可在 HR Console → Employees 给任何人改成两级；
  共 18 人，每位审批人（Michelle / Doris / Alice / Usam / Belinda）手上都留了至少一条
  待审批申请，方便你直接登录试点批准/拒绝/退回

## 与隐私相关（重要）

演示版"点头像登录"只是为了一个人能切换体验所有角色。
**正式版一人一账号**（公司邮箱 + 密码），数据库行级权限（RLS）强制：
员工只能看自己的数据，审批人只能看链上下属的申请，只有 HR/Admin 能看全部——
这些已在 `supabase/schema.sql` 内实现，前端即使被篡改也无法越权。

## 建议演示路径

1. **Tam** 提交年假 → **Michelle** 在 Approvals 退回（必须填原因）→ Tam 修改重交 →
   Michelle 批准 → Tam 余额减少，📧 里每一步都有模拟邮件
2. **Michelle** 的 Approvals 页有 **Decision history**：她批过/退回过的所有记录
3. **文斌** 的申请直通 **Doris**（Lin 看不到）；**Doris** 自己请假则自动备案
4. **Alice**（HR）：HR Console 看全公司记录、改审批路线、给补休入账、看邮件外发记录

## 可复用性（任何小公司都能用）

系统里没有任何写死的公司信息 —— 全部是**数据**，HR Console 里直接改：

- **Company settings**：公司名、邮箱域名、公共假期列表（增删）
- **Teams / departments**：团队是统一管理的下拉列表（杜绝 "Operation" vs
  "Operations" 手打拼写分裂）；改名自动同步到每个成员；空团队可删除
- **Employees**：搜索（姓名/邮箱/职位）+ 按团队筛选；新增/编辑员工时团队用
  下拉选择，也可当场 "＋ New team…"；职位（job title）自由填写
- **Leave types**：假期种类和天数全部可配置

## Security & operations（2026-07 审计后）

**第一性原理:信任锚点 = 登录账号 ↔ 在职员工档案。**"已登录"不构成边界
（anon key 是公开的），所以一切权限判断都建立在 `current_emp_id()`
（=调用者作为在职员工的身份）之上，由数据库强制。

已落实：
- Dashboard 关闭自助注册（第一道门）+ 全部只读策略要求 `is_staff()`（第二道门）
- `leave_balances` 视图 `security_invoker`（修复视图绕过 RLS 的余额泄漏）
- 离职员工：`current_emp_id()` 要求 `active` → 服务器层自动登出；前端同步提示
- 防休眠：**cron-job.org**（外部定时服务）每天 POST 一次
  `/rest/v1/rpc/keepalive_ping`，真正**写入**一行心跳
  （函数见 `supabase/keepalive_ping_v2.sql`，需在 SQL Editor 手动跑一次）。
  - ⚠️ 2026-07 事故：旧版只做「读」，每次都 HTTP 200，项目照样被暂停，
    HR 系统停摆两周。**纯读不算活动，必须写。**
  - ⚠️ 已**弃用 GitHub Actions** 做这件事：仓库 60 天无提交，GitHub 会自动停用
    定时任务，而「没在跑」不触发任何失败通知 —— 沉默和成功长得一样。
  - 写入是推断，不是官方保证。若再次被暂停，就升级 Pro（US$25/月）——那是唯一有保证的方案。
  - 冗余：**两个**互不相干的定时器，时间错开 12 小时 ——
    ① cron-job.org（早上）；② 私有仓库 `fluffyland/leavedesk-keepalive`（21:17 SGT）。
    ② **必须保持 private**：GitHub 的「60 天无活动自动停用定时任务」只针对 public 仓库。
    也**不要**把它塞进 `hrleavesystem`：那个仓库必须是 public，否则免费版 Pages
    会下线，整个 HR 网站打不开。
  - 报警：UptimeRobot 5 分钟一次监控**数据库**（不是网站 —— 停摆那两周网站一直是好的），
    并且**开手机推送**。当年 8 封失败邮件没人看见，报警发到没人看的地方等于没有报警。

HR 日常手册：
- **员工忘记密码**：Supabase Dashboard → Authentication → Users → 该员工 →
  Generate link（recovery）→ 把链接用 WhatsApp 发给员工，点开即可设新密码
- **办离职**：系统里 Edit → Offboard 结清假期后，再到 Authentication → Users
  把该员工的登录 **Delete**
- **新员工**：系统里 Add employee（自动入账年假）→ Authentication → Users →
  Add user（同一邮箱 + 临时密码 + 勾 Auto Confirm）

待办（按时间）：
- **2026 年 12 月前**：年末结转/清零策略（`carry_over_cap` 字段已备好未启用）
- 病假 3 个月等待期（MOM 规定，系统暂不强制）
- 审批人休假时的代理审批

## 核心设计（详见 DESIGN.md）

1. **假期是账本**：不存可变余额，余额 = 交易之和，天然可审计
2. **审批是状态机**：pending → approved / rejected / returned / withdrawn；批准后可销假返还
3. **邮件是状态转移的副作用**：挂在事件流上，永不漏发；Decision history 也由事件流生成
4. **权限来自组织关系**：员工看自己、审批人批下属、HR 管全部（数据库层 RLS 强制）
