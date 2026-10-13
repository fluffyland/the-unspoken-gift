-- =============================================================
-- LeaveDesk migration v25 —— carry_expiry_for 改为 security definer
--
-- 起因：v24 上线后从外部探测 carry_expiry_for(2027)，返回的是 null 而不是日期。
-- 查下来那是探测本身的局限 —— org_settings 上有 RLS
-- （org_read … to authenticated using (is_staff())），匿名调用读不到任何行。
-- 真正的两个调用方 run_year_start / set_carry_expiry 都是 security definer，
-- 函数内部 current_user 是属主，属主绕过 RLS，所以线上一切正常，没有坏掉。
--
-- **但这里藏着一个不会报错的陷阱。**
-- carry_expiry_for 是 language sql stable —— security **invoker**。
-- 它读不到 org_settings 时不会失败，而是返回 null；
-- 而 null 在这套系统里的含义是「结转年假永不过期」。
-- 一个「失败时会静默地把过期规则关掉」的函数，正是这个项目反复栽过的那一类：
-- 按符号分类的 bal()、被吃掉的负号、拿存储值去比的 entitlement ——
-- 都是没有任何人报错，屏幕却说得理直气壮。
-- 今天没有这样的调用路径。问题在于没有任何东西拦着以后加一条。
--
-- 改动只有一处：加 security definer + 收回 anon。
-- 它读的是 org_settings 的一行，而这张表本来就对所有在职员工可读，
-- 所以这没有多授予任何权限 —— 只是让这个函数不再依赖「碰巧是谁在调用它」
-- 才能给出正确答案。
--
-- 不动任何列、任何数据、任何日期。幂等，可重复执行。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

create or replace function carry_expiry_for(p_year int)
returns date language sql stable security definer set search_path = public as $$
  select case
           when o.carry_expiry_month is null or o.carry_expiry_day is null then null
           else make_date(p_year, o.carry_expiry_month,
                  least(o.carry_expiry_day,
                        extract(day from (make_date(p_year, o.carry_expiry_month, 1)
                                          + interval '1 month' - interval '1 day'))::int))
         end
  from org_settings o where o.id = 1;
$$;
comment on function carry_expiry_for(int) is
  'The date carried annual leave expires in a given year. SECURITY DEFINER on purpose: as an invoker it returned NULL wherever org_settings was unreadable, and NULL here means "never expires" — a silent failure rather than an error.';
revoke execute on function carry_expiry_for(int) from anon, public;
grant  execute on function carry_expiry_for(int) to authenticated;
