-- =============================================================
-- LeaveDesk SG — keep-alive ping function
--
-- 为什么需要：免费版 Supabase 项目 7 天没有数据库请求就会自动暂停。
-- GitHub Actions（.github/workflows/keepalive.yml）每天调用一次本函数，
-- 保证产生一次真实的数据库查询，把「闲置计时」清零。
--
-- 为什么不直接读表：所有业务表都开了 RLS 且只对 authenticated 放行，
-- 匿名 anon 读表只会拿到空数组，行为不直观、也不好排查。
-- 这个函数只回一个时间戳，不暴露任何业务数据。
--
-- 执行方式：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run（跑一次即可）
-- =============================================================

create or replace function public.keepalive_ping()
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select now();
$$;

comment on function public.keepalive_ping() is
  'Health ping for the free-tier keep-alive workflow. Returns the server time and nothing else.';

-- 允许未登录（anon）调用：它不返回任何业务数据，安全。
grant execute on function public.keepalive_ping() to anon, authenticated;

-- 验证：应当返回当前时间
select public.keepalive_ping();
