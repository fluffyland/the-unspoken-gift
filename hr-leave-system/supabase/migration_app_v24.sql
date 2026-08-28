-- =============================================================
-- LeaveDesk migration v24 —— 结转到期「日期」取代「月数」
--
-- 起因：Company settings 里那一栏是 "Carry Forward AL expire after (months)"，
-- 填 6，系统自己算出 6 月 30 日。用户要的是**直接选日期**：设 12 月 31 日，
-- 到那天还没用掉的结转年假就作废清账。
--
-- 关键事实（决定了这个改动很小）：annual_carry.expires_on **本来就是 date**。
-- 下游全部读它 —— 余额视图扣掉 due_unwritten_carry、expire_due_carry 落账、
-- 员工看到的 "use them by"。月数只在 run_year_start 里用过**一次**，
-- 就是为了算出这个日期。所以这里换掉的是那次计算的输入，不是任何下游逻辑。
--
--   1. org_settings.carry_expiry_month / carry_expiry_day：**每年重复**的日月。
--      设一次 12-31，2027 结转的到 2027-12-31 过期，2028 的到 2028-12-31，永远。
--      两列同时为 NULL = 永不过期（等于旧的「留空」）。
--   2. 回填自 carry_expiry_months，**上线当天任何日期都不变**：12 → 12-31，
--      6 → 06-30，NULL → NULL。carry_expiry_months **保留不动** ——
--      前端的 db.orgV16 是靠它探测的，删掉会让没迁移的库瞎掉。
--   3. carry_expiry_for(year)：唯一一处算日期的地方，run_year_start 和
--      set_carry_expiry 都调它，两边不可能算出不同的日子。
--      2 月 29 日在平年自动收到 2 月 28 日 —— 设置永远不会产生非法日期。
--   4. set_carry_expiry(month, day, preview)：**一个函数同时负责预览和执行**，
--      v16 的 run_year_start 立的规矩。同一段算术，preview 只是不写，
--      所以确认框上的人数和真正被改的行数不可能对不上。
--      执行时：改设置 → 重盖当年 annual_carry.expires_on → 调 expire_due_carry()
--      把已经过期的立刻清账（用户原话「and clear off in system」）。
--
-- 依赖 v16（annual_carry.expires_on、expire_due_carry、annual_used_between）。
-- 幂等，可重复执行。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

-- ---------- 1. 字段 ----------
alter table org_settings add column if not exists carry_expiry_month int;
alter table org_settings add column if not exists carry_expiry_day   int;

comment on column org_settings.carry_expiry_month is
  'Month (1-12) that carried annual leave expires on, repeating every year. NULL (with carry_expiry_day) = never expires.';
comment on column org_settings.carry_expiry_day is
  'Day of carry_expiry_month. 29 February is clamped to 28 February in a non-leap year.';

-- ---------- 2. 回填：上线当天任何日期都不许变 ----------
-- 旧算法是 make_date(Y,1,1) + N 个月 - 1 天。用闰年 2000 反推日月，
-- N=2（2 月底）会得到 02-29，再由下面的收敛规则在平年收到 02-28 ——
-- 和旧算法逐年的结果完全一致。
update org_settings
   set carry_expiry_month = extract(month from d)::int,
       carry_expiry_day   = extract(day   from d)::int
  from (select ((make_date(2000, 1, 1) + (carry_expiry_months || ' months')::interval)::date - 1) as d
          from org_settings where id = 1 and carry_expiry_months is not null) s(d)
 where org_settings.id = 1
   and org_settings.carry_expiry_month is null
   and org_settings.carry_expiry_day is null;

-- ---------- 3. 唯一一处算日期的地方 ----------
create or replace function carry_expiry_for(p_year int)
returns date language sql stable set search_path = public as $$
  select case
           when o.carry_expiry_month is null or o.carry_expiry_day is null then null
           else make_date(p_year, o.carry_expiry_month,
                  least(o.carry_expiry_day,
                        extract(day from (make_date(p_year, o.carry_expiry_month, 1)
                                          + interval '1 month' - interval '1 day'))::int))
         end
  from org_settings o where o.id = 1;
$$;
grant execute on function carry_expiry_for(int) to authenticated;

-- ---------- 4. 改日期：预览 + 执行是同一个函数 ----------
-- 往前挪日期会**立刻作废别人手上正拿着的天数**，所以这里必须先能算出
-- 「几个人、几天会当场没」，让界面在写任何东西之前把话说清楚。
create or replace function set_carry_expiry(p_month int, p_day int, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_year int := extract(year from current_date)::int;
  v_new date; v_dying numeric;
  v_people int := 0; v_days_lost numeric := 0; v_dying_people int := 0;
  v_already int := 0;
  v_rows jsonb := '[]'::jsonb;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can change the carry-forward expiry date';
  end if;
  -- 两个都空 = 永不过期；否则两个都要有，且必须是真日子。
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
    v_new := make_date(v_year, p_month,
               least(p_day, extract(day from (make_date(v_year, p_month, 1)
                                              + interval '1 month' - interval '1 day'))::int));
  end if;

  -- 已经落账作废的那些行不再动 —— 天数已经没了，把日期往后挪也换不回来。
  select count(*) into v_already from annual_carry
   where year = v_year and expired_at is not null;

  for r in
    select ac.emp_id, ac.year, ac.carry_in, ac.expires_on, e.name
      from annual_carry ac join employees e on e.id = ac.emp_id
     where ac.year = v_year and ac.expired_at is null
       and ac.expires_on is distinct from v_new
     order by e.name
  loop
    v_people := v_people + 1;
    -- 只有新日期已经过去了，天数才会当场没。日期在将来 ⇒ 现在什么都不掉。
    v_dying := case when v_new is not null and v_new < current_date
                 then greatest(0, r.carry_in - annual_used_between(r.emp_id, make_date(r.year, 1, 1), v_new))
                 else 0 end;
    if v_dying > 0 then
      v_dying_people := v_dying_people + 1;
      v_days_lost := v_days_lost + v_dying;
    end if;
    v_rows := v_rows || jsonb_build_object(
      'name', r.name, 'from', r.expires_on, 'to', v_new, 'dying', v_dying);
  end loop;

  if not p_preview then
    update org_settings set carry_expiry_month = p_month, carry_expiry_day = p_day where id = 1;
    update annual_carry set expires_on = v_new
     where year = v_year and expired_at is null and expires_on is distinct from v_new;
    -- 「and clear off in system」：新日期已经过去的，现在就落账，不用等明天的定时任务。
    perform expire_due_carry();
  end if;

  return jsonb_build_object(
    'preview', p_preview, 'year', v_year, 'month', p_month, 'day', p_day,
    'new_date', v_new, 'people', v_people,
    'dying_people', v_dying_people, 'days_lost', v_days_lost,
    'already_expired', v_already, 'rows', v_rows);
end $$;
revoke execute on function set_carry_expiry(int, int, boolean) from anon, public;
grant  execute on function set_carry_expiry(int, int, boolean) to authenticated;

-- ---------- 5. run_year_start 改读日期 ----------
-- 整个函数只有 v_expires 这一处变了，其余逐字保持 v18 的样子。
create or replace function run_year_start(p_year int, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r record; t record;
  v_mode text; v_expires date;
  v_bal numeric; v_cap numeric; v_carry numeric; v_excess numeric;
  v_taken numeric; v_exp numeric; v_tb numeric;
  v_resets jsonb; v_reset_days numeric;
  v_rows jsonb := '[]'::jsonb;
  v_people int := 0; v_carry_people int := 0; v_carry_days numeric := 0;
  v_forfeit_people int := 0; v_forfeit_days numeric := 0;
  v_expired_people int := 0; v_expired_days numeric := 0;
  v_reset_people int := 0; v_granted int := 0;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can start a new year';
  end if;
  if p_year < 2000 or p_year > 2500 then raise exception 'Year out of range'; end if;

  select accrual_mode into v_mode from org_settings where id = 1;
  v_expires := carry_expiry_for(p_year);          -- v24：日期直接来自设置，不再由月数推算

  -- 步骤 1：把已经到期的结转落成账本条目（预览不写）
  if not p_preview then perform expire_due_carry(); end if;

  for r in select e.id, e.name, coalesce(e.carry_cap, 0) as cap
           from employees e where e.active order by e.name loop

    -- 已经处理过这一年的人直接跳过 ⇒ 按第二次只会报 0，不会重复扣
    if exists (select 1 from year_start_log y where y.year = p_year and y.emp_id = r.id) then
      continue;
    end if;
    v_people := v_people + 1;
    v_cap := r.cap;

    -- 去年结转的到期情况（预览时按「将会作废多少」算，执行后按已落账的算 —— 同一个数）
    select coalesce(case
             when ac.expires_on is null then 0
             when ac.expired_at is not null then ac.expired_days
             else greatest(0, ac.carry_in - annual_used_between(r.id, make_date(ac.year,1,1), ac.expires_on))
           end, 0)
      into v_exp
      from annual_carry ac where ac.emp_id = r.id and ac.year = p_year - 1;
    v_exp := coalesce(v_exp, 0);
    if v_exp > 0 then v_expired_people := v_expired_people + 1; v_expired_days := v_expired_days + v_exp; end if;

    -- 步骤 2：年假结转。先减掉「本年度配额」——即使有人先跑了发放，结转也只按去年剩余算。
    v_bal := coalesce((select balance from leave_balances where emp_id = r.id and leave_type = 'annual'), 0);
    v_bal := v_bal - coalesce((select sum(delta_days) from leave_ledger
                               where emp_id = r.id and leave_type = 'annual'
                                 and reason in (p_year || ' 年度配额', p_year || ' annual allowance')), 0);
    -- 预览时上面那 expire 还没写账，视图已经替我们扣掉了 due_unwritten_carry，所以两条路数字一致
    v_carry  := least(v_cap, greatest(0, v_bal));
    v_excess := greatest(0, v_bal - v_cap);
    v_taken  := annual_used_in_year(r.id, p_year - 1);
    if v_carry  > 0 then v_carry_people := v_carry_people + 1; v_carry_days := v_carry_days + v_carry; end if;
    if v_excess > 0 then v_forfeit_people := v_forfeit_people + 1; v_forfeit_days := v_forfeit_days + v_excess; end if;

    -- 步骤 3：其余假别清零。清多少读余额，发多少读 leave_types.default_days —— 都不硬编码。
    v_resets := '[]'::jsonb; v_reset_days := 0;
    for t in select code, name_en, default_days from leave_types
             where resets_yearly and not no_deduct order by sort loop
      select coalesce(balance, 0) into v_tb from leave_balances
        where emp_id = r.id and leave_type = t.code;
      v_tb := coalesce(v_tb, 0);
      if v_tb <> 0 then
        v_resets := v_resets || jsonb_build_object(
          'code', t.code, 'name', t.name_en, 'cleared', v_tb, 'credits', t.default_days);
        v_reset_days := v_reset_days + v_tb;
        if not p_preview then
          insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
          values (r.id, t.code, -v_tb,
                  (p_year - 1) || ' ' || t.name_en || ' expired (unused)', current_emp_id());
        end if;
      end if;
    end loop;
    if jsonb_array_length(v_resets) > 0 then v_reset_people := v_reset_people + 1; end if;

    if not p_preview then
      if v_excess > 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', -v_excess,
                (p_year - 1) || ' annual leave above the carry-over cap (' || v_cap || ') — forfeited',
                current_emp_id());
      end if;
      insert into annual_carry (emp_id, year, carry_in, expires_on)
      values (r.id, p_year, v_carry, v_expires)
      on conflict (emp_id, year) do nothing;
      insert into year_start_log (year, emp_id, emp_name, annual_taken_prev, annual_left,
                                  cap_applied, carried, forfeited, expired, expires_on,
                                  resets, reset_days, run_by)
      values (p_year, r.id, r.name, v_taken, v_bal, v_cap, v_carry, v_excess, v_exp, v_expires,
              v_resets, v_reset_days, current_emp_id());
    end if;

    v_rows := v_rows || jsonb_build_object(
      'name', r.name, 'taken_prev', v_taken, 'left', v_bal, 'cap', v_cap,
      'carried', v_carry, 'forfeited', v_excess, 'expired', v_exp,
      'expires_on', v_expires, 'reset_days', v_reset_days, 'resets', v_resets);
  end loop;

  -- 步骤 4：发放新一年的配额。**必须在清零之后**，否则刚发的立刻被抹掉。
  if v_mode = 'monthly' then
    v_granted := 0;
  elsif p_preview then
    -- 别名不能叫 t：上面声明了 record t，PL/pgSQL 会把它当变量替换进查询，
    -- 报 "record t is not assigned yet"。这类冲突不会在编译期发现，只在跑到时才炸。
    v_granted := (select count(distinct e.id) from employees e cross join leave_types lt
                  where e.active and (lt.default_days > 0 or lt.code = 'annual')
                    and (lt.gender_eligibility is null or lt.gender_eligibility = e.gender)
                    and not exists (select 1 from leave_ledger l
                                    where l.emp_id = e.id and l.leave_type = lt.code
                                      and l.reason in (p_year || ' 年度配额', p_year || ' annual allowance')));
  else
    v_granted := grant_annual_entitlements(p_year);
  end if;

  return jsonb_build_object(
    'year', p_year, 'preview', p_preview, 'people', v_people,
    'accrual_mode', v_mode, 'expires_on', v_expires,
    'carried_people', v_carry_people, 'carried_days', v_carry_days,
    'forfeited_people', v_forfeit_people, 'forfeited_days', v_forfeit_days,
    'expired_people', v_expired_people, 'expired_days', v_expired_days,
    'reset_people', v_reset_people, 'granted', v_granted,
    'rows', v_rows);
end $$;
revoke execute on function run_year_start(int, boolean) from anon, public;
grant  execute on function run_year_start(int, boolean) to authenticated;
