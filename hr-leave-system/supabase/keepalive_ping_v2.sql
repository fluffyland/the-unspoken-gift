-- =============================================================
-- LeaveDesk SG — keep-alive ping v2 (WRITE-based)
--
-- 背景（2026-08 事故）：
--   v1 的 keepalive_ping() 是 `stable` 函数，只跑 `select now()` —— 纯读。
--   定时任务每 2 天成功 ping 一次（7/13、15、17、19、21 全部 HTTP 200），
--   但项目仍然在 7/21–7/23 之间被自动暂停，HR 系统停摆约两周（7/23 → 8/5）。
--   Supabase 官方回信只说「7 天无活动即暂停」。
--   结论：**纯读请求不会重置 Supabase 的闲置计时器。**
--
-- v2 的做法：每次 ping 真正 **写入** 一行数据（UPDATE 一张单行心跳表）。
--   写操作会产生 WAL、改变数据库状态，是比读强得多的「活动」信号。
--
-- ⚠️ 诚实提醒：Supabase 没有公开「什么才算活动」的准确定义。
--   写入是目前最合理的推断，但**不是官方保证**。唯一有保证的方案是升级 Pro（US$25/月）。
--   如果两周内又被暂停，就说明免费版没有可靠的自救办法，只能升级。
--
-- 执行方式：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run（跑一次即可）
-- 幂等：可以重复执行，不会重复建表或丢数据。
--
-- 谁来定时调用它：**cron-job.org**（外部免费定时服务），每天一次：
--
--   POST https://<项目ref>.supabase.co/rest/v1/rpc/keepalive_ping?apikey=<anon key>
--   不需要任何 header，body 留空即可。
--
--   ⚠️ 把 apikey 放进 URL，不要放 header：很多定时服务的自定义 header 填不进去，
--      会报 {"message":"No API key found in request"}。PostgREST 同时接受
--      url param，实测无 header 也返回 200。
--      （anon key 本来就是公开的 —— 网站源码里就有 —— 放 URL 不增加任何暴露。）
--   ⚠️ 必须 POST：本函数是 volatile（会写），GET 会返回
--      405 "cannot execute UPDATE in a read-only transaction"。
--   ⚠️ 不要改用 GitHub Actions：仓库 60 天无提交就会被自动停用定时任务，
--      而「没在跑」不产生任何失败通知 —— 沉默和成功长得一模一样。
-- =============================================================

-- 1) 心跳表：永远只有一行（id = 1）。不含任何业务数据。
create table if not exists public.keepalive_heartbeat (
  id           smallint    primary key default 1,
  last_ping_at timestamptz not null default now(),
  ping_count   bigint      not null default 0,
  constraint keepalive_heartbeat_single_row check (id = 1)
);

comment on table public.keepalive_heartbeat is
  'Single-row heartbeat for the free-tier keep-alive workflow. Written once a day by keepalive_ping(). Contains no business data.';

-- 播种那唯一一行（已存在则不动）
insert into public.keepalive_heartbeat (id) values (1)
on conflict (id) do nothing;

-- 2) 锁死直接访问：开 RLS 且不建任何 policy ⇒ anon / authenticated 都碰不到这张表。
--    只有下面的 security definer 函数能写它。
alter table public.keepalive_heartbeat enable row level security;
revoke all on table public.keepalive_heartbeat from anon, authenticated;

-- 3) 把 keepalive_ping() 从「只读」换成「真写」。
--
--    返回值从 timestamptz 改成 bigint（累计 ping 次数）。这是刻意的：
--    v1 返回 now()，而两次独立的 HTTP 请求 = 两个事务 = 两个不同的时间戳，
--    所以「时间戳变了」根本证明不了写入发生过。
--    改成返回**持久化的计数器**后，连调两次必然是 N、N+1 —— 只有真的写进磁盘
--    才会递增。想确认心跳真的通了，就看这个数字有没有在涨：
--      select last_ping_at, ping_count from public.keepalive_heartbeat;
--
--    改返回类型必须先 drop（create or replace 不允许改返回类型）。
drop function if exists public.keepalive_ping();

create function public.keepalive_ping()
returns bigint
language plpgsql
volatile              -- 关键：v1 是 stable(只读)，v2 必须是 volatile(会写)
security definer
set search_path = public
as $$
declare
  v_count bigint;
begin
  update public.keepalive_heartbeat
     set last_ping_at = now(),
         ping_count   = ping_count + 1
   where id = 1
  returning ping_count into v_count;

  -- 万一那一行被人删了，自愈补回来
  if v_count is null then
    insert into public.keepalive_heartbeat (id, last_ping_at, ping_count)
    values (1, now(), 1)
    on conflict (id) do update
      set last_ping_at = now(),
          ping_count   = public.keepalive_heartbeat.ping_count + 1
    returning ping_count into v_count;
  end if;

  return v_count;
end;
$$;

comment on function public.keepalive_ping() is
  'Keep-alive heartbeat. Performs a real WRITE (updates keepalive_heartbeat) and returns the persisted ping counter. Exposes no business data.';

-- 允许未登录（anon）调用：它只写心跳表、只回一个计数，不碰任何业务数据。
grant execute on function public.keepalive_ping() to anon, authenticated;

-- =============================================================
-- 验证
--
-- ⚠️ Supabase SQL Editor 一次跑多条语句时，**只显示最后一条的结果**。
--    所以下面前两行的返回值你是看不到的 —— 这是正常的，不是出错。
--
-- ✅ 通过标准：最后一行显示 ping_count = 2（首次安装时）。
--    计数器能到 2，就说明两次调用各自都真的写进了磁盘并保留了下来 ——
--    只读的 v1 永远只会是 0，因为它根本没有表可写。
--
-- 想单独看返回值，就只选中这一行单独 Run（每跑一次数字 +1）：
--    select public.keepalive_ping();
-- =============================================================
select public.keepalive_ping() as ping_1;   -- 结果不会显示（见上）
select public.keepalive_ping() as ping_2;   -- 结果不会显示（见上）
select last_ping_at, ping_count from public.keepalive_heartbeat where id = 1;
