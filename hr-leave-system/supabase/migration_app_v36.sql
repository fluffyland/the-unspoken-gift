-- ============================================================================
-- migration_app_v36.sql — 补休（Off-in-Lieu）到期日
--
-- 用户原话：
--   「I need another function for Off in lieu expired date. same as the carry foward
--     AL function just create one for off in lieu, and put it together with the
--     Carry Forward AL expiry date under company setting. the funciton is related to
--     Off in lieu expired, so once the date reaches it will be forfeited. same as AL.」
--
-- 规则（用户当场选定，与年假结转**不同**，这一点要记牢）：
--   到了那个日子，**整个补休余额**清零 —— 不分是哪一年攒的。
--   年假结转是「去年剩下的，今年这个日子作废，今年新发的不受影响」；
--   补休是「这个日子一到，手上还剩多少就作废多少」。
--   例：到期日设 3 月 31 日。2026 年 11 月攒了 2 天，2027 年 2 月又攒了 1 天，
--       2027-03-31 那天，**3 天全部作废**。
--
-- 默认**不到期**（两列都是 NULL）。装上这个迁移不会有任何人少一天；
-- 一直到 HR 自己去 Company settings 选一个月份，才开始生效。
--
-- 幂等：重复执行没有副作用。
-- ============================================================================

-- ---------- 0. 前置 ----------
alter table org_settings add column if not exists oil_expiry_month int;
alter table org_settings add column if not exists oil_expiry_day   int;

comment on column org_settings.oil_expiry_month is
  'Month (1-12) that off-in-lieu expires on, every year. NULL (with oil_expiry_day) = off-in-lieu never expires, which is the default and what every existing company keeps until HR chooses otherwise.';
comment on column org_settings.oil_expiry_day is
  'Day of oil_expiry_month that off-in-lieu expires on. Clamped to the length of the month, so 31 in a 30-day month means the 30th rather than an error.';

-- ---------- 1. 那个日子是哪一天 ----------
-- 和 carry_expiry_for 一个模子，包括「31 号遇到只有 30 天的月份就取 30」那一下。
create or replace function oil_expiry_for(p_year int)
returns date language sql stable security definer set search_path = public as $$
  select case
           when o.oil_expiry_month is null or o.oil_expiry_day is null then null
           else make_date(p_year, o.oil_expiry_month,
                  least(o.oil_expiry_day,
                        extract(day from (make_date(p_year, o.oil_expiry_month, 1)
                                          + interval '1 month' - interval '1 day'))::int))
         end
  from org_settings o where o.id = 1;
$$;
comment on function oil_expiry_for(int) is
  'The date off-in-lieu expires in a given year. SECURITY DEFINER for the same reason as carry_expiry_for: as an invoker it returns NULL wherever org_settings is unreadable, and NULL here means "never expires" — a silent failure instead of an error.';
revoke execute on function oil_expiry_for(int) from anon, public;
grant  execute on function oil_expiry_for(int) to authenticated;

-- 任意「几月几号」最近一次**已经过去**的那一天。设置界面要在保存前就能算，
-- 所以月份和日子是参数，不是从设置里读。
create or replace function oil_cutoff_of(p_month int, p_day int)
returns date language sql immutable as $$
  select case when p_month is null or p_day is null then null
         when make_date(y, p_month, least(p_day, extract(day from (make_date(y, p_month, 1)
                + interval '1 month' - interval '1 day'))::int)) <= current_date
           then make_date(y, p_month, least(p_day, extract(day from (make_date(y, p_month, 1)
                + interval '1 month' - interval '1 day'))::int))
         else make_date(y - 1, p_month, least(p_day, extract(day from (make_date(y - 1, p_month, 1)
                + interval '1 month' - interval '1 day'))::int))
         end
  from (select extract(year from current_date)::int as y) _;
$$;

create or replace function oil_last_cutoff()
returns date language sql stable security definer set search_path = public as $$
  select oil_cutoff_of(o.oil_expiry_month, o.oil_expiry_day) from org_settings o where o.id = 1;
$$;
revoke execute on function oil_last_cutoff() from anon, public;
grant  execute on function oil_last_cutoff() to authenticated;

-- ---------- 2. 那一天为止，手上还有多少补休 ----------
-- **这里用 created_at 是对的**，别「顺手改成 leave_year」。
-- v35 禁止的是「拿写入日期当假期年度」；这里问的是另一回事：
-- 「到那一天为止，这一天到底攒到手没有」—— 那正是 created_at 回答的问题。
-- 但请假／销假两种要看**假期日期**：十二月休的补休一月才补录，
-- 若按补录日期算，就会把一个人已经用掉的天数再作废一次。
create or replace function oil_balance_asof(p_emp uuid, p_on date)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(l.delta_days), 0)
    from leave_ledger l
   where l.emp_id = p_emp and l.leave_type = 'oil'
     and (case when l.kind in ('taken', 'refund')
               then coalesce((select a.start_date from applications a where a.id = l.ref_application),
                             l.created_at::date)
               else l.created_at::date end) <= p_on;
$$;
revoke execute on function oil_balance_asof(uuid, date) from anon, public;
grant  execute on function oil_balance_asof(uuid, date) to authenticated;

-- ---------- 3. 作废记录 ----------
-- 和 annual_carry.expired_at 一个作用：证明这一次到期已经落过账，不会作废两次。
create table if not exists oil_expiry_log (
  emp_id       uuid not null references employees (id),
  expires_on   date not null,
  expired_days numeric(6,1) not null,
  expired_at   timestamptz not null default now(),
  primary key (emp_id, expires_on)
);
comment on table oil_expiry_log is
  'One row per employee per off-in-lieu expiry date, written when that date is processed. A row with expired_days = 0 still counts as processed — it is what stops the same date being looked at again every day.';
alter table oil_expiry_log enable row level security;
drop policy if exists oilexp_read on oil_expiry_log;
create policy oilexp_read on oil_expiry_log for select to authenticated
  using (emp_id = current_emp_id() or is_hr());

-- ---------- 4. 安全网：过期了但还没落账 ----------
-- 和 due_unwritten_carry 一样，余额视图里直接扣掉。
-- 这样就算每一个定时任务都死了，也没有人能用到已经作废的补休。
create or replace function due_unwritten_oil(p_emp uuid, p_code text)
returns numeric language sql stable security definer set search_path = public as $$
  select case when p_code <> 'oil' then 0 else coalesce((
    select greatest(0, oil_balance_asof(p_emp, c.d))
      from (select oil_last_cutoff() as d) c
     where c.d is not null
       and exists (select 1 from employees e where e.id = p_emp and e.active)  -- v27：离职即冻结
       and not exists (select 1 from oil_expiry_log g
                        where g.emp_id = p_emp and g.expires_on = c.d)
  ), 0) end;
$$;
revoke execute on function due_unwritten_oil(uuid, text) from anon;
grant  execute on function due_unwritten_oil(uuid, text) to authenticated;

-- ---------- 5. 余额视图：把它扣掉 ----------
create or replace view leave_balances as
select l.emp_id, l.leave_type,
       sum(l.delta_days) filter (where l.delta_days > 0)  as granted,
       -sum(l.delta_days) filter (where l.delta_days < 0) as used,
       sum(l.delta_days) - due_unwritten_carry(l.emp_id, l.leave_type)
                         - due_unwritten_oil(l.emp_id, l.leave_type)   as balance,
       coalesce((select sum(a.days) from applications a
                 where a.emp_id = l.emp_id and a.leave_type = l.leave_type
                   and a.status = 'pending'), 0)          as pending,
       sum(l.delta_days) - due_unwritten_carry(l.emp_id, l.leave_type)
                         - due_unwritten_oil(l.emp_id, l.leave_type)
         - coalesce((select sum(a.days) from applications a
                     where a.emp_id = l.emp_id and a.leave_type = l.leave_type
                       and a.status = 'pending'), 0)      as available
from leave_ledger l
group by l.emp_id, l.leave_type;

-- ---------- 6. 到期落账 ----------
create or replace function expire_due_oil(p_emp uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; d date := oil_last_cutoff(); rem numeric; n int := 0;
begin
  if d is null then return 0; end if;            -- 没设到期日 = 永不过期
  for r in
    select e.id from employees e
     where e.active                               -- 离职的人账已经冻结，不动
       and (p_emp is null or e.id = p_emp)
       and not exists (select 1 from oil_expiry_log g
                        where g.emp_id = e.id and g.expires_on = d)
    order by e.id
  loop
    rem := greatest(0, oil_balance_asof(r.id, d));
    if rem > 0 then
      -- **created_at is the cut-off date, not now.** oil_balance_asof asks "what was in
      -- hand on that day", so a write-off stamped with today's date is invisible to it —
      -- and the next cut-off then forfeits the very same days a second time, driving the
      -- balance negative. Dating it on the day it happened is both truthful and the thing
      -- that makes the arithmetic close.
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by,
                                leave_year, kind, created_at)
      values (r.id, 'oil', -rem,
              to_char(d, 'YYYY') || ' off-in-lieu expired (unused)', current_emp_id(),
              extract(year from d)::int, 'writeoff', d);
    end if;
    -- 即使是 0 天也要记一笔：这条记录才是「这一次到期处理过了」的凭据。
    insert into oil_expiry_log (emp_id, expires_on, expired_days) values (r.id, d, rem);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function expire_due_oil(uuid) from anon, public;
grant  execute on function expire_due_oil(uuid) to authenticated;

-- ---------- 7. HR 设定这个日子 ----------
-- 和 set_carry_expiry 一样：**先预览**。把日子往前挪会当场烧掉别人手上的天数，
-- 那句话必须是真的，不能是这边猜的。
create or replace function set_oil_expiry(p_month int, p_day int, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_cut date; v_people int := 0; v_days numeric := 0; v_dying_people int := 0;
  v_already int; v_holding int; r record;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can change the off-in-lieu expiry date';
  end if;
  if (p_month is null) <> (p_day is null) then
    raise exception 'Pick both a month and a day, or neither';
  end if;
  if p_month is not null then
    if p_month < 1 or p_month > 12 then raise exception 'Month must be 1-12'; end if;
    if p_day   < 1 or p_day   > 31 then raise exception 'Day must be 1-31'; end if;
    if p_day > extract(day from (make_date(2000, p_month, 1)
                                 + interval '1 month' - interval '1 day'))::int then
      raise exception 'That month does not have % days', p_day;
    end if;
  end if;

  v_cut := oil_cutoff_of(p_month, p_day);
  select count(*) into v_already from oil_expiry_log;
  select count(*) into v_holding from employees e
   where e.active and coalesce((select balance from leave_balances
                                where emp_id = e.id and leave_type = 'oil'), 0) > 0;

  -- 这个日子最近一次已经过去了 ⇒ 一保存，那些天数立刻没。先数清楚。
  if v_cut is not null then
    for r in
      select e.id, greatest(0, oil_balance_asof(e.id, v_cut)) as dying
        from employees e
       where e.active
         and not exists (select 1 from oil_expiry_log g
                          where g.emp_id = e.id and g.expires_on = v_cut)
    loop
      v_people := v_people + 1;
      if r.dying > 0 then
        v_dying_people := v_dying_people + 1;
        v_days := v_days + r.dying;
      end if;
    end loop;
  end if;

  if not p_preview then
    update org_settings set oil_expiry_month = p_month, oil_expiry_day = p_day where id = 1;
    -- 立刻落账，这样屏幕上看到的和预览说的是同一件事。
    if p_month is not null then perform expire_due_oil(); end if;
  end if;

  return jsonb_build_object(
    'preview', p_preview, 'new_date', v_cut,
    'month', p_month, 'day', p_day,
    'holding', v_holding, 'people', v_people,
    'days_lost', v_days, 'dying_people', v_dying_people,
    'already_expired', v_already);
end $$;
revoke execute on function set_oil_expiry(int, int, boolean) from anon, public;
grant  execute on function set_oil_expiry(int, int, boolean) to authenticated;

-- ---------- 8. 每天的心跳也带上它 ----------
-- **不要重写这个函数的签名。** keepalive_ping 返回 bigint，而且维护着一个持久计数器
-- （keepalive_heartbeat.ping_count）—— 那个计数器就是「心跳真的写进磁盘了」的唯一证据。
-- 把它改成返回 text，或者忘了那段 update，等于把保活功能悄悄弄坏，
-- 而这种坏法要等 Supabase 把项目睡掉才会有人发现。
-- 所以这里连原来的函数体一起照抄，只多加一段补休到期。
create or replace function public.keepalive_ping()
returns bigint
language plpgsql
volatile
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

  -- v3：把「已经过了到期日」的结转年假落成账本条目。
  begin
    perform public.expire_due_carry();
  exception when undefined_function then null;
  end;

  -- v36：补休到期，同样落账。单独包一层 —— 一个坏掉不该把另一个也带下去，
  -- 更不该把保活本身带下去。
  begin
    perform public.expire_due_oil();
  exception when undefined_function then null;
  end;

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
revoke execute on function public.keepalive_ping() from anon, public;
grant  execute on function public.keepalive_ping() to authenticated;

-- ---------- 9. 自检 ----------
do $$
declare d date;
begin
  if not exists (select 1 from information_schema.columns
                  where table_name = 'org_settings' and column_name = 'oil_expiry_month') then
    raise exception 'v36 FAILED: org_settings.oil_expiry_month is missing';
  end if;
  -- 装上之后必须是「永不过期」：不能有任何人因为升级少一天。
  select oil_expiry_for(extract(year from current_date)::int) into d;
  if d is not null and not exists (select 1 from oil_expiry_log) then
    raise warning 'v36: an off-in-lieu expiry date is already set (%). Nothing has expired yet — it will on the next daily run.', d;
  end if;
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname = 'keepalive_ping'
                and pg_get_functiondef(p.oid) not like '%expire_due_oil%') then
    raise exception 'v36 FAILED: the daily heartbeat does not expire off-in-lieu';
  end if;
  raise notice 'v36 installed: off-in-lieu can be given an expiry date, next to the carry-forward one.';
end $$;

select 'v36 installed — Off-in-Lieu expiry' as status,
       coalesce(to_char(oil_expiry_for(extract(year from current_date)::int), 'DD Mon YYYY'),
                'never expires (nothing changes until you pick a month)') as "Off-in-lieu expires",
       coalesce(to_char(carry_expiry_for(extract(year from current_date)::int), 'DD Mon YYYY'),
                'never expires') as "Carried annual leave expires";
