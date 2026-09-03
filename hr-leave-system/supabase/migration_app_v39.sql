-- ============================================================================
-- migration_app_v39.sql — 结转的两半必须对得上，对不上要能查出来、能补回来
--
-- 用户原话：「why lee jian wei carried foward is 2 days? i told you to credit 5 days」
--
-- 我上一次的解释是**错的**。我说他把到期日设成了过去的日子 —— 可他自己贴出来的那一行
-- 写着「Expiry Date: 31 Dec 2026」，那是将来。到期日不是原因。
--
-- 复现出来的真相（两种情形，数字分得清清楚楚）：
--   账本里有 carry_in 那一行 + 到期日在将来  →  Available 16、屏幕显示结转 2  （对）
--   只有 annual_carry 那一行、账本里没有      →  Available 11、屏幕显示结转 2  （他看到的）
--
-- 也就是说：**结转只写了一半。**
--   annual_carry 那一行  = 到期作业读的东西、屏幕上那个「Carry Forward」数字
--   账本 carry_in 那一行 = 真正能拿去请假的天数
-- 写了前者没写后者，屏幕就会广告一个余额里根本不存在的数字 —— 正是 2 的来历。
--
-- 这个迁移不猜是谁写坏的，它做两件事：
--   1. carry_health_check()  —— 把两半对不上的人全部列出来
--   2. repair_carry_ledger() —— 把缺的那一半补上，先预览，确认了才写
--
-- 幂等：重复执行没有副作用。
-- ============================================================================

-- ---------- 1. 查：两半对不对得上 ----------
create or replace function carry_health_check()
returns table ("Employee" text, "Year" int, "annual_carry says" numeric,
               "ledger says" numeric, "Difference" numeric, "Verdict" text)
language sql stable security definer set search_path = public as $$
  select e.name,
         ac.year,
         ac.carry_in,
         coalesce((select sum(l.delta_days) from leave_ledger l
                    where l.emp_id = ac.emp_id and l.leave_type = 'annual'
                      and l.leave_year = ac.year and l.kind = 'carry_in'), 0),
         ac.carry_in - coalesce((select sum(l.delta_days) from leave_ledger l
                    where l.emp_id = ac.emp_id and l.leave_type = 'annual'
                      and l.leave_year = ac.year and l.kind = 'carry_in'), 0),
         case when ac.carry_in = coalesce((select sum(l.delta_days) from leave_ledger l
                    where l.emp_id = ac.emp_id and l.leave_type = 'annual'
                      and l.leave_year = ac.year and l.kind = 'carry_in'), 0)
              then 'ok'
              else '⚠ the screen shows these days but the balance does not have them — run repair_carry_ledger(false)'
         end
    from annual_carry ac join employees e on e.id = ac.emp_id
   where e.active
   order by (ac.carry_in = coalesce((select sum(l.delta_days) from leave_ledger l
                    where l.emp_id = ac.emp_id and l.leave_type = 'annual'
                      and l.leave_year = ac.year and l.kind = 'carry_in'), 0)),
            e.name;
$$;
revoke execute on function carry_health_check() from anon, public;
grant  execute on function carry_health_check() to authenticated;
comment on function carry_health_check() is
  'Compares the two halves of every carry-forward: the annual_carry row (what the screen and the expiry job read) against the ledger carry_in entries (the days you can actually book). They must be equal. Read-only.';

-- ---------- 2. 补：把缺的那一半写回去 ----------
-- 只补**账本少于 annual_carry** 的方向。反过来（账本多）不动：那可能是有人手工
-- 加过结转，凭空扣掉就是从人家余额里拿走天数，那种事必须有人看着做。
create or replace function repair_carry_ledger(p_preview boolean default true)
returns table ("Employee" text, "Year" int, "Days added back" numeric, "Done" boolean)
language plpgsql security definer set search_path = public as $$
declare r record; gap numeric; v_exp date;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can repair carry-forward records';
  end if;
  for r in
    select ac.emp_id, ac.year, ac.carry_in, ac.expires_on, e.name
      from annual_carry ac join employees e on e.id = ac.emp_id
     where e.active
     order by e.name
  loop
    gap := r.carry_in - coalesce((select sum(l.delta_days) from leave_ledger l
             where l.emp_id = r.emp_id and l.leave_type = 'annual'
               and l.leave_year = r.year and l.kind = 'carry_in'), 0);
    if gap > 0 then
      if not p_preview then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by,
                                  leave_year, kind)
        values (r.emp_id, 'annual', gap,
                'Carried forward from ' || (r.year - 1)
                  || case when r.expires_on is not null
                          then ' (expires ' || to_char(r.expires_on, 'DD Mon YYYY') || ')' else '' end,
                current_emp_id(), r.year, 'carry_in');
        perform log_amendment(r.emp_id, r.name, 'annual', 'carry_credit',
                              r.carry_in - gap, r.carry_in, gap, 1,
                              'Carry-forward repaired — ' || trim_scale(gap)
                                || ' day(s) were recorded on the Carry Forward line but were '
                                || 'missing from the balance');
      end if;
      "Employee" := r.name; "Year" := r.year; "Days added back" := gap; "Done" := not p_preview;
      return next;
    end if;
  end loop;
end $$;
revoke execute on function repair_carry_ledger(boolean) from anon, public;
grant  execute on function repair_carry_ledger(boolean) to authenticated;
comment on function repair_carry_ledger(boolean) is
  'Writes the missing ledger half of a carry-forward, where annual_carry records more than the ledger holds. Previews by default. Only ever ADDS days that were already promised on screen — it never removes any, because the opposite direction could be a deliberate manual credit and taking days away needs a person to decide.';

do $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'repair_carry_ledger'
                and pg_get_functiondef(p.oid) like '%delete from leave_ledger%') then
    raise exception 'v39 FAILED: the repair must never delete ledger entries';
  end if;
  raise notice 'v39 installed: run  select * from carry_health_check();  to see whether any carry-forward is half-written.';
end $$;

select * from carry_health_check();
