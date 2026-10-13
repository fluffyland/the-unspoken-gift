-- =============================================================
-- LeaveDesk migration v28 —— 邮件通知的开关
--
-- 邮件本身在 Edge Function 里（supabase/functions/send-notification）。
-- 数据库这边只需要一样东西：**测试期间只发给谁**。
--
-- 用户原话：「the email sending please only send to user Amanda for testing」。
-- 做成一个设置而不是把名字写死在代码里 —— 他可以随时指向别人，也可以自己关掉，
-- 不用等我改代码。
--
-- 语义：填了人 = 只有**发给这个人**的邮件会真的发出去，公司里其他人一封都收不到。
--       留空 = 正常发给所有相关的人（试完之后就留空）。
--
-- 这一列还兼着「测试邮件寄到哪里」：Edge Function 的测试发送**不接受**外部传入的
-- 收件地址，只会寄给这里指定的员工。所以就算有人拿到公开的 anon key，
-- 也没办法借它往任意邮箱发信。
--
-- 幂等，可重复执行。不影响任何现有功能：邮件从头到尾都不是任何流程的前置条件，
-- 没配置 / 函数没部署 / Resend 挂了，请假和审批照常。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

alter table org_settings add column if not exists notify_only_emp uuid references employees (id);

comment on column org_settings.notify_only_emp is
  'Test mode for notification emails: while this names an employee, only mail addressed to THEM is sent and nobody else in the company receives anything. NULL = notify everyone normally. Also the destination for the Send test email button.';
