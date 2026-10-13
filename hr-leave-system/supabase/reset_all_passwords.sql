-- LeaveDesk SG — 一次性：把所有登录用户的密码重置为 Ssu123@
-- 用法：Supabase Dashboard → SQL Editor → 粘贴执行。执行后每个人都用 Ssu123@ 登录，
--       让他们首次登录后自行改密（应用右上角 🔑 Password）。
--
-- 原理：Supabase Auth 的密码以 bcrypt 存于 auth.users.encrypted_password。
--       直接用 pgcrypto 的 crypt()+gen_salt('bf') 写入 bcrypt 哈希即可，GoTrue 登录时可正常校验。
--       这条路径绕过 API 的密码策略（最小长度/泄露密码检查），但 Ssu123@ 本身已满足复杂度。

create extension if not exists pgcrypto with schema extensions;

update auth.users
set encrypted_password = extensions.crypt('Ssu123@', extensions.gen_salt('bf')),
    updated_at = now()
where deleted_at is null;

-- 只想重置某一个人时（把邮箱换掉）：
-- update auth.users
-- set encrypted_password = extensions.crypt('Ssu123@', extensions.gen_salt('bf')), updated_at = now()
-- where email = 'someone@yourcompany.sg';
