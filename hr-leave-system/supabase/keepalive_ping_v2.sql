-- =============================================================
-- LeaveDesk SG — keep-alive ping v2 (WRITE-based)
--
-- 背景（2026-08 事故）：
--   v1 的 keepalive_ping() 是 `stable` 函数，只跑 `select now()` —— 纯读。
--   GitHub Actions 每 2 天成功 ping 一次（7/13、15、17、19、21 全部 HTTP 200），
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
--    返回值仍是 timestamptz，所以可以直接 create or replace 覆盖 v1。
create or replace function public.keepalive_ping()
returns timestamptz
language plpgsql
volatile              -- 关键：v1 是 stable(只读)，v2 必须是 volatile(会写)
security definer
set search_path = public
as $$
declare
  v_now timestamptz;
begin
  update public.keepalive_heartbeat
     set last_ping_at = now(),
         ping_count   = ping_count + 1
   where id = 1
  returning last_ping_at into v_now;

  -- 万一那一行被人删了，自愈补回来
  if v_now is null then
    insert into public.keepalive_heartbeat (id, last_ping_at, ping_count)
    values (1, now(), 1)
    on conflict (id) do update
      set last_ping_at = now(),
          ping_count   = public.keepalive_heartbeat.ping_count + 1
    returning last_ping_at into v_now;
  end if;

  return v_now;
end;
$$;

comment on function public.keepalive_ping() is
  'Keep-alive heartbeat. Performs a real WRITE (updates keepalive_heartbeat) and returns the write timestamp. Exposes no business data.';

-- 允许未登录（anon）调用：它只写心跳表、只回一个时间戳，不碰任何业务数据。
grant execute on function public.keepalive_ping() to anon, authenticated;

-- =============================================================
-- 验证：连跑两次，两个时间戳必须不同，且 ping_count 递增 2。
-- 如果时间戳一样 → 说明还在跑 v1 的只读版本，函数没覆盖成功。
-- =============================================================
select public.keepalive_ping() as ping_1;
select public.keepalive_ping() as ping_2;
select last_ping_at, ping_count from public.keepalive_heartbeat where id = 1;
