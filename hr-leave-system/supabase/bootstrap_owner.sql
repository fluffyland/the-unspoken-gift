-- LeaveDesk SG — 引导第一个 Owner / Super Admin（新公司首个账号）
-- 背景：应用里的「一键创建登录」需要调用者本身是 HR，所以“第一个人”只能手工建。
-- 之后这位 Owner 就能在应用里创建其余所有员工与登录，无需再碰 SQL / Auth。
--
-- 步骤：
--   1. 先执行 schema.sql（建好所有表 / 权限 / 函数）。
--   2. Supabase → Authentication → Users → Add user：
--        Email = 下面的邮箱；Password = Ssu123@；勾选 Auto Confirm User。
--   3. 把下面两处改成真实姓名 / 邮箱，然后在 SQL Editor 执行本文件。
--   4. 用该邮箱 + Ssu123@ 登录应用，即是 Owner / Super Admin（可管理一切）。

insert into employees (name, email, join_date, role, active, auth_user_id)
select
  'Owner Name',                       -- ← 改成真实姓名
  lower('owner@newco.com'),           -- ← 改成真实邮箱（与上面 Add user 的邮箱一致）
  current_date, 'admin', true, u.id
from auth.users u
where lower(u.email) = lower('owner@newco.com')   -- ← 同上邮箱
on conflict (email) do update
  set role = 'admin', active = true, auth_user_id = excluded.auth_user_id;

-- 校验：应返回一行，role = admin，auth_user_id 非空
select name, email, role, auth_user_id from employees where role = 'admin';
