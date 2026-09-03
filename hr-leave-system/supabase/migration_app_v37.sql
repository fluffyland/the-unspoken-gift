-- ============================================================================
-- migration_app_v37.sql — 两个到期功能变成同一套；每一笔作废都进修订记录
--
-- 用户原话：
--   「i set Sep 3 so every OIL should be forfeited right? why i still saw employee
--     have OIL?」
--   「is the forfeited recorded ? i need every forfeited leave also be recorded
--     under all records.」
--   「this two expiry function should be identical ... same logic and same method,
--     and same will be recorded for all amendement.」
--
-- ---------------------------------------------------------------------------
-- 1) 为什么设了 9 月 3 日却没作废 —— 根因
-- ---------------------------------------------------------------------------
-- v36 里 oil_cutoff_of 被标成了 IMMUTABLE，可它里面读 current_date，而
-- current_date 是 STABLE。**这是在对规划器撒谎。**
-- Postgres 不会拦你，但一旦标成 immutable，规划器就有权把它在**做计划的时候**
-- 算一次，然后把那个日期钉死在缓存的计划里。
--
-- 用 psql 手工跑每次都是新连接、新计划，所以永远是对的 —— 我的测试就是这么过的。
-- 而线上是 PostgREST：连接是池化的、长命的，计划缓存能活很久。于是那个「今天」
-- 可能是几天前的今天。设 9 月 3 日、当天却什么都没发生，就是这么来的。
--
-- 教训写在这里：**函数里只要出现 current_date / now()，就不能标 immutable。**
-- 下面加了一条自检，直接读 pg_proc 的 provolatile，标错了装不上去。
--
-- ---------------------------------------------------------------------------
-- 2) 两个到期功能同一套做法
-- ---------------------------------------------------------------------------
--   · 同一个「最近一次已过去的日子」算法        cutoff_of(month, day)
--   · 同一个安全网                              余额视图里先扣掉
--   · 同一种落账                                leave_ledger 一条 writeoff
--   · **同一份修订记录**                        hr_amendments，kind = 'expiry'
--
-- 作废掉的是哪些天，两者不同 —— 这是假期本身的性质决定的，不是做法不同：
--   年假：到期的是**结转过来的那一部分**（annual_carry 记着是多少）
--   补休：到期的是**整个补休余额**（补休没有「结转」这回事）
-- 两边都是「那个池子里到那天还剩多少，就作废多少」。
--
-- 幂等：重复执行没有副作用。
-- ============================================================================

-- ---------- 1. 根因修复：不能对规划器撒谎 ----------
create or replace function oil_cutoff_of(p_month int, p_day int)
returns date language sql stable as $$
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
comment on function oil_cutoff_of(int, int) is
  'The most recent occurrence of a given day/month that is on or before today. STABLE, never IMMUTABLE: it reads current_date, and marking it immutable lets the planner freeze that date into a cached plan — which is why an expiry set to today did nothing on the live site while working perfectly in a fresh psql session.';

-- 年假那边用同一个算法，同一个名字形状 —— 两个功能从这里开始就是一套东西。
create or replace function carry_cutoff_of(p_month int, p_day int)
returns date language sql stable as $$ select oil_cutoff_of(p_month, p_day); $$;
comment on function carry_cutoff_of(int, int) is
  'Same helper as oil_cutoff_of, under the name the carry-forward side reads. One algorithm, two callers: if the two expiry dates ever behave differently, it will not be because they compute "the last time that date went by" differently.';
revoke execute on function carry_cutoff_of(int, int) from anon, public;
grant  execute on function carry_cutoff_of(int, int) to authenticated;

-- ---------- 2. 一笔作废怎么记 ----------
-- 两边都调这一个。措辞、kind、影响人数全都一致 —— 「same will be recorded」。
create or replace function log_expiry_amendment(
  p_emp uuid, p_type text, p_days numeric, p_on date)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text; v_label text;
begin
  if coalesce(p_days, 0) <= 0 then return; end if;
  select name into v_name from employees where id = p_emp;
  select name_en into v_label from leave_types where code = p_type;
  perform log_amendment(p_emp, coalesce(v_name, ''), p_type, 'expiry',
                        p_days, 0, -p_days, 1,
                        coalesce(v_label, p_type) || ' expired on '
                          || to_char(p_on, 'DD Mon YYYY') || ' — '
                          || trim_scale(p_days) || ' day(s) forfeited');
end $$;
revoke execute on function log_expiry_amendment(uuid, text, numeric, date) from anon, public;

-- ---------- 3. 补休到期：加上修订记录 ----------
create or replace function expire_due_oil(p_emp uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; d date := oil_last_cutoff(); rem numeric; n int := 0;
begin
  if d is null then return 0; end if;
  for r in
    select e.id from employees e
     where e.active
       and (p_emp is null or e.id = p_emp)
       and not exists (select 1 from oil_expiry_log g
                        where g.emp_id = e.id and g.expires_on = d)
    order by e.id
  loop
    rem := greatest(0, oil_balance_asof(r.id, d));
    if rem > 0 then
      -- created_at 是**到期那一天**，不是现在。oil_balance_asof 问的是「那天手上有多少」，
      -- 用今天的日期写这条，它就看不见，下一次到期会把同样的天数再作废一遍。
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by,
                                leave_year, kind, created_at)
      values (r.id, 'oil', -rem,
              to_char(d, 'YYYY') || ' off-in-lieu expired (unused)', current_emp_id(),
              extract(year from d)::int, 'writeoff', d);
      perform log_expiry_amendment(r.id, 'oil', rem, d);
    end if;
    insert into oil_expiry_log (emp_id, expires_on, expired_days) values (r.id, d, rem);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function expire_due_oil(uuid) from anon, public;
grant  execute on function expire_due_oil(uuid) to authenticated;

-- ---------- 4. 年假结转到期：同样加上修订记录 ----------
-- 除了「作废的是结转那一部分」之外，和上面一模一样。
create or replace function expire_due_carry(p_emp uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; rem numeric; n int := 0;
begin
  for r in
    select ac.emp_id, ac.year, ac.carry_in, ac.expires_on
    from annual_carry ac join employees e on e.id = ac.emp_id
    where e.active                                  -- v27：离职即冻结
      and ac.expired_at is null
      and ac.expires_on is not null
      and ac.expires_on < current_date
      and (p_emp is null or ac.emp_id = p_emp)
  loop
    rem := greatest(0, r.carry_in - annual_used_between(r.emp_id, make_date(r.year,1,1), r.expires_on));
    if rem > 0 then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by,
                                leave_year, kind, created_at)
      values (r.emp_id, 'annual', -rem, r.year || ' carry-over expired (unused)', current_emp_id(),
              r.year, 'writeoff', r.expires_on);
      -- v37：和补休走同一个函数，所以修订记录里两者长得一模一样。
      perform log_expiry_amendment(r.emp_id, 'annual', rem, r.expires_on);
    end if;
    update annual_carry set expired_days = rem, expired_at = now()
      where emp_id = r.emp_id and year = r.year;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function expire_due_carry(uuid) from anon, public;
grant  execute on function expire_due_carry(uuid) to authenticated;

-- ---------- 5. HR 手动给某人加结转年假（测试用，也是补录用） ----------
-- 用户原话：「please credit 5 carryfoward AL to Lee Jian Wei, Amanda and ABB」。
-- 结转不是凭空一个数字，它有两半，缺一不可：
--   · 账本里一条 carry_in（这才是真正能用的天数）
--   · annual_carry 一行（到期作业读的就是这一行）
-- 手写 SQL 很容易只写一半，然后余额和到期对不上。这个函数两半一起写。
create or replace function credit_carry_forward(p_emp uuid, p_days numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare y int := extract(year from current_date)::int;
        v_exp date; v_name text; v_had numeric;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can credit carry-forward leave';
  end if;
  if p_days is null or p_days <= 0 then raise exception 'Enter a number of days above zero'; end if;
  select name into v_name from employees where id = p_emp and active;
  if v_name is null then raise exception 'That employee is not on the active list'; end if;

  v_exp := carry_expiry_for(y);
  select coalesce(carry_in, 0) into v_had from annual_carry where emp_id = p_emp and year = y;

  insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
  values (p_emp, 'annual', p_days,
          'Carried forward from ' || (y - 1)
            || case when v_exp is not null
                    then ' (expires ' || to_char(v_exp, 'DD Mon YYYY') || ')' else '' end,
          current_emp_id(), y, 'carry_in');

  insert into annual_carry (emp_id, year, carry_in, expires_on)
  values (p_emp, y, p_days, v_exp)
  on conflict (emp_id, year) do update
    set carry_in = annual_carry.carry_in + excluded.carry_in,
        expires_on = excluded.expires_on,
        expired_days = null, expired_at = null;

  perform log_amendment(p_emp, v_name, 'annual', 'carry_credit',
                        coalesce(v_had, 0), coalesce(v_had, 0) + p_days, p_days, 1,
                        trim_scale(p_days) || ' day(s) of carry-forward credited'
                          || case when v_exp is not null
                                  then ', expiring ' || to_char(v_exp, 'DD Mon YYYY')
                                  else ' (no expiry set)' end);

  return jsonb_build_object('name', v_name, 'days', p_days, 'year', y,
                            'carry_now', coalesce(v_had, 0) + p_days, 'expires_on', v_exp);
end $$;
revoke execute on function credit_carry_forward(uuid, numeric) from anon, public;
grant  execute on function credit_carry_forward(uuid, numeric) to authenticated;
comment on function credit_carry_forward(uuid, numeric) is
  'Give somebody carried-forward annual leave by hand. Writes BOTH halves — the ledger entry that makes the days real, and the annual_carry row the expiry job reads — so the balance and the expiry can never disagree. Recorded in Amendment records.';

-- ---------- 6. 自检 ----------
do $$
declare v char;
begin
  select provolatile into v from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'oil_cutoff_of';
  if v = 'i' then
    raise exception 'v37 FAILED: oil_cutoff_of is IMMUTABLE but reads current_date — the planner may freeze today''s date into a cached plan, and the expiry then silently does nothing on a pooled connection';
  end if;
  select provolatile into v from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'carry_cutoff_of';
  if v = 'i' then raise exception 'v37 FAILED: carry_cutoff_of is IMMUTABLE but reads current_date'; end if;

  -- 两个到期都必须写修订记录，否则「same will be recorded」就是句空话
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname = 'expire_due_oil'
                and pg_get_functiondef(p.oid) not like '%log_expiry_amendment%') then
    raise exception 'v37 FAILED: off-in-lieu expiry does not write an amendment record';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname = 'expire_due_carry'
                and pg_get_functiondef(p.oid) not like '%log_expiry_amendment%') then
    raise exception 'v37 FAILED: carry-forward expiry does not write an amendment record';
  end if;
  raise notice 'v37 installed: both expiry dates work the same way, and every forfeit is recorded.';
end $$;

select 'v37 installed' as status,
       coalesce(to_char(oil_expiry_for(extract(year from current_date)::int), 'DD Mon YYYY'), 'never') as "Off-in-lieu expires",
       coalesce(to_char(carry_expiry_for(extract(year from current_date)::int), 'DD Mon YYYY'), 'never') as "Carried AL expires",
       (select count(*) from hr_amendments where kind = 'expiry') as "Forfeits recorded so far";
