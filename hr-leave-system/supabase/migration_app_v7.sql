-- =============================================================
-- LeaveDesk — v7 公共假期自动同步 + 站内公告 + 次年日历只读 + 年假结转(上限5天,逾期作废)
-- 在 Supabase Dashboard → SQL Editor 整段执行一次；幂等，可重复执行。
-- 需要一起部署：sync-holidays Edge Function（拉取 data.gov.sg）+ 前端 index.html。
--
-- 本迁移新增/变更：
--   1. public_holidays 增加来源/同步时间列（区分手工录入 vs 自动同步）
--   2. holiday_sync_log     每次同步的审计日志（HR 可见，供监控/排错）
--   3. announcements / announcement_reads  站内公告（假期变更时通知全员，登录即见）
--   4. apply_holiday_sync() 供 Edge Function（service_role）调用：对账 + 记日志 + 发公告
--   5. submit_application  加「次年日历只读」：跨年/次年日期在 1 月 1 日前不可申请
--   6. 年假结转：annual_carry 表 + rollover_annual_leave()（上限 5 天，先用结转、年底作废）
--      并把 annual 的 carry_over_cap 设为 5
-- =============================================================


-- =============================================================
-- 1. 公共假期来源标记
-- =============================================================
alter table public_holidays add column if not exists source    text not null default 'manual';
alter table public_holidays add column if not exists synced_at  timestamptz;
comment on column public_holidays.source is 'manual = HR 手工录入; data.gov.sg = 自动同步（对账时只会动自动来源的行，不覆盖手工录入）';


-- =============================================================
-- 2. 同步审计日志
-- =============================================================
create table if not exists holiday_sync_log (
  id         bigint generated always as identity primary key,
  ran_at     timestamptz not null default now(),
  source     text not null,
  years      int[]  not null default '{}',
  added      jsonb  not null default '[]'::jsonb,
  removed    jsonb  not null default '[]'::jsonb,
  renamed    jsonb  not null default '[]'::jsonb,
  total_seen int    not null default 0,
  status     text   not null default 'ok',
  message    text
);
create index if not exists idx_hsl_ran on holiday_sync_log (ran_at desc);
alter table holiday_sync_log enable row level security;
drop policy if exists hsl_read on holiday_sync_log;
create policy hsl_read on holiday_sync_log for select to authenticated using (is_hr());


-- =============================================================
-- 3. 站内公告（假期变更 → 全员登录即见的通知）
-- =============================================================
create table if not exists announcements (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  kind       text not null default 'system',      -- 'holiday' | 'system'
  title      text not null,
  body       text not null,
  active     boolean not null default true
);
-- 受众：'all' 全员可见；'hr' 只给 HR/admin（假期变更时额外发一条可操作提醒）
alter table announcements add column if not exists audience text not null default 'all';
alter table announcements enable row level security;
drop policy if exists ann_read  on announcements;
drop policy if exists ann_write on announcements;
create policy ann_read  on announcements for select to authenticated
  using (is_staff() and active and (audience = 'all' or is_hr()));
create policy ann_write on announcements for all    to authenticated using (is_hr()) with check (is_hr());

create table if not exists announcement_reads (
  announcement_id bigint not null references announcements (id) on delete cascade,
  emp_id          uuid   not null references employees (id),
  read_at         timestamptz not null default now(),
  primary key (announcement_id, emp_id)
);
alter table announcement_reads enable row level security;
drop policy if exists ar_rw on announcement_reads;
create policy ar_rw on announcement_reads for all to authenticated
  using (emp_id = current_emp_id()) with check (emp_id = current_emp_id());

-- 当前用户「未读」公告视图（前端登录后读这里，逐条弹/挂横幅）
create or replace view my_announcements as
select a.id, a.created_at, a.kind, a.title, a.body, a.audience,
       (r.emp_id is not null) as read
from announcements a
left join announcement_reads r
  on r.announcement_id = a.id and r.emp_id = current_emp_id()
where a.active and is_staff() and (a.audience = 'all' or is_hr());
alter view my_announcements set (security_invoker = true);
grant select on my_announcements to authenticated;
revoke select on my_announcements from anon;

-- 标记已读（幂等）
create or replace function mark_announcement_read(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := current_emp_id();
begin
  if me is null then return; end if;
  insert into announcement_reads (announcement_id, emp_id) values (p_id, me)
  on conflict do nothing;
end $$;
revoke execute on function mark_announcement_read(bigint) from anon, public;
grant  execute on function mark_announcement_read(bigint) to authenticated;


-- =============================================================
-- 4. 假期对账 RPC（Edge Function 以 service_role 调用）
--    入参 p_holidays: [{"holiday":"2027-01-01","name":"New Year's Day"}, ...]
--         p_years:    该批数据「权威覆盖」的年份，如 {2026,2027}；只在这些年份内对账，
--                     绝不动其它年份，也绝不删除 source='manual' 的手工录入
-- =============================================================
create or replace function apply_holiday_sync(
  p_holidays jsonb, p_years int[], p_source text default 'data.gov.sg'
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_added   jsonb := '[]'::jsonb;
  v_removed jsonb := '[]'::jsonb;
  v_renamed jsonb := '[]'::jsonb;
  r record; changed boolean := false;
  add_txt text; rem_txt text; ann_body text;
begin
  -- 仅系统任务可调用：PostgREST 用 service_role key → current_user='service_role'；
  -- 或在 SQL Editor（postgres）里手动测试。普通登录用户/anon 一律拒绝。
  if current_user <> 'service_role' and session_user <> 'postgres' then
    raise exception 'apply_holiday_sync 仅限系统同步任务调用';
  end if;
  if p_years is null or array_length(p_years, 1) is null then
    raise exception 'p_years 不能为空'; end if;

  -- (a) 新增 / 改名：逐条 upsert，落在覆盖年份内的才对账
  for r in
    select (e->>'holiday')::date as d, e->>'name' as nm
    from jsonb_array_elements(coalesce(p_holidays, '[]'::jsonb)) e
    where extract(year from (e->>'holiday')::date)::int = any(p_years)
  loop
    if not exists (select 1 from public_holidays where holiday = r.d) then
      v_added := v_added || jsonb_build_object('holiday', r.d, 'name', r.nm);
      changed := true;
    elsif (select name from public_holidays where holiday = r.d) is distinct from r.nm then
      v_renamed := v_renamed || jsonb_build_object('holiday', r.d, 'name', r.nm);
      changed := true;
    end if;
    insert into public_holidays (holiday, name, source, synced_at)
    values (r.d, r.nm, p_source, now())
    on conflict (holiday) do update
      set name = excluded.name, source = excluded.source, synced_at = now();
  end loop;

  -- (b) 删除：覆盖年份内、由本来源自动同步过、但这批数据里已不存在的日期
  --     （只删 source=p_source 的行；手工录入的临时假日不会被误删）
  for r in
    select ph.holiday as d, ph.name as nm from public_holidays ph
    where extract(year from ph.holiday)::int = any(p_years)
      and ph.source = p_source
      and not exists (select 1 from jsonb_array_elements(coalesce(p_holidays, '[]'::jsonb)) e
                      where (e->>'holiday')::date = ph.holiday)
  loop
    v_removed := v_removed || jsonb_build_object('holiday', r.d, 'name', r.nm);
    delete from public_holidays where holiday = r.d;
    changed := true;
  end loop;

  insert into holiday_sync_log (source, years, added, removed, renamed, total_seen, status)
  values (p_source, p_years, v_added, v_removed, v_renamed,
          jsonb_array_length(coalesce(p_holidays, '[]'::jsonb)), 'ok');

  -- (c) 有变更 → 发全员站内公告
  if changed then
    add_txt := (select string_agg(to_char((e->>'holiday')::date, 'YYYY-MM-DD (Dy)') || '  ' || (e->>'name'), E'\n')
                from jsonb_array_elements(v_added || v_renamed) e);
    rem_txt := (select string_agg(to_char((e->>'holiday')::date, 'YYYY-MM-DD (Dy)') || '  ' || (e->>'name'), E'\n')
                from jsonb_array_elements(v_removed) e);
    ann_body := 'The public-holiday calendar was updated from the official MOM source (data.gov.sg). 系统已按 MOM 官方数据更新公共假期。';
    if add_txt is not null then ann_body := ann_body || E'\n\n➕ Added / updated 新增或更新:\n' || add_txt; end if;
    if rem_txt is not null then ann_body := ann_body || E'\n\n➖ Removed 移除:\n' || rem_txt; end if;
    -- 全员通知（informational）
    insert into announcements (kind, title, body, audience)
    values ('holiday', '📅 Public holidays updated 公共假期已更新', ann_body, 'all');
    -- 额外给 HR / admin 一条可操作提醒：可在 HR 控制台复核 / 增删改
    insert into announcements (kind, title, body, audience)
    values ('holiday', '🛠️ HR: public holidays changed — please review 公共假期已变更（请复核）',
            'The automatic sync updated the public-holiday calendar. Review or adjust it in HR Console → Company settings — you can add, edit or remove any date.'
            || E'\n\n' || ann_body, 'hr');
  end if;

  return jsonb_build_object('changed', changed, 'added', v_added, 'removed', v_removed, 'renamed', v_renamed);
end $$;
revoke execute on function apply_holiday_sync(jsonb, int[], text) from anon, public, authenticated;
grant  execute on function apply_holiday_sync(jsonb, int[], text) to service_role;


-- =============================================================
-- 5. 次年日历「只读」 + 半天假仅对适用假期开放
--    （重建 submit_application；签名与 v6 完全一致，仅新增两处校验，前端无需改调用）
-- =============================================================
-- 5.0 半天假开关：默认仅年假 / 补休可请半天；其余（病假/住院假等）整天。HR 可在控制台改。
alter table leave_types add column if not exists allow_half_day boolean not null default false;
update leave_types set allow_half_day = (code in ('annual','oil'));

create or replace function submit_application(
  p_type text, p_start date, p_end date, p_reason text,
  p_attachment text default null, p_resubmit_id uuid default null,
  p_half_days jsonb default '[]'::jsonb, p_sh boolean default false, p_eh boolean default false
) returns uuid language plpgsql security definer set search_path = public as $$
declare me employees%rowtype; t leave_types%rowtype; d numeric; app_id uuid; avail numeric;
        hd jsonb := coalesce(p_half_days, '[]'::jsonb);
begin
  select * into me from employees where auth_user_id = auth.uid() and active;
  if me.id is null then raise exception '未找到员工档案'; end if;
  perform pg_advisory_xact_lock(hashtext(me.id::text));
  select * into t from leave_types where code = p_type;
  if t.code is null then raise exception '假期类型不存在'; end if;
  if t.gender_eligibility is not null and t.gender_eligibility <> me.gender then
    raise exception '不符合该假期的资格条件'; end if;
  if t.requires_attachment and p_attachment is null then
    raise exception '该假期类型必须上传证明（MC）'; end if;
  if p_end < p_start or p_end - p_start > 366 then
    raise exception '请假区间无效或过长（最多约一年）'; end if;
  -- 次年日历只读：次年额度要到 1 月 1 日才发放，此前不能申请落在次年的假
  if extract(year from p_start)::int > extract(year from current_date)::int
     or extract(year from p_end)::int > extract(year from current_date)::int then
    raise exception '次年假期要到 1 月 1 日才开放申请（次年日历现在仅供查看） / Next year''s leave opens on 1 Jan';
  end if;
  -- 半天假仅对允许的假期类型生效；其余类型忽略半天明细，一律按整天计
  if not coalesce(t.allow_half_day, false) then hd := '[]'::jsonb; end if;
  d := case when jsonb_array_length(hd) > 0
            then working_days_hd(p_start, p_end, hd)
            else working_days(p_start, p_end, p_sh, p_eh) end;
  if d <= 0 then raise exception '所选日期不含工作日'; end if;
  if not t.no_deduct then
    select available into avail from leave_balances where emp_id = me.id and leave_type = p_type;
    if coalesce(avail, 0) < d then raise exception '余额不足：需 % 天，可用 % 天', d, coalesce(avail,0); end if;
  end if;
  if exists (select 1 from applications a where a.emp_id = me.id
             and a.id is distinct from p_resubmit_id
             and a.status in ('pending','approved','cancel_requested')
             and not (a.end_date < p_start or a.start_date > p_end)) then
    raise exception '所选日期与已有申请重叠';
  end if;

  if p_resubmit_id is not null then
    update applications set leave_type=p_type, start_date=p_start, end_date=p_end,
      start_half=p_sh, end_half=p_eh, half_days=hd, days=d, reason=p_reason,
      attachment_path=coalesce(p_attachment, attachment_path),
      status='pending', current_step=1, backdated=(p_start<current_date), updated_at=now()
      where id=p_resubmit_id and emp_id=me.id and status='returned'
      returning id into app_id;
    if app_id is null then raise exception '只能重新提交被退回的申请'; end if;
    delete from approval_steps where application_id = app_id;
  else
    insert into applications (emp_id,leave_type,start_date,end_date,start_half,end_half,half_days,days,reason,attachment_path,backdated)
    values (me.id,p_type,p_start,p_end,p_sh,p_eh,hd,d,p_reason,p_attachment,p_start<current_date)
    returning id into app_id;
  end if;

  insert into application_events (application_id, actor, action)
  values (app_id, me.id, case when p_resubmit_id is null then 'submitted' else 'resubmitted' end);

  if me.approver1 is null then
    update applications set status='approved', updated_at=now() where id=app_id;
    if not t.no_deduct then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_by)
      values (me.id, p_type, -d, '请假扣减', app_id, me.id);
    end if;
    insert into application_events (application_id, actor, action, comment)
    values (app_id, me.id, 'auto_approved', 'No approver required (Managing Director)');
  else
    insert into approval_steps (application_id, step_order, approver_id, status)
    values (app_id, 1, me.approver1, 'pending');
    if me.two_level and me.approver2 is not null then
      insert into approval_steps (application_id, step_order, approver_id, status)
      values (app_id, 2, me.approver2, 'waiting');
    end if;
  end if;
  return app_id;
end $$;


-- =============================================================
-- 6. 年假结转（上限 5 天，先用结转、次年 12/31 未用作废）
-- =============================================================
-- 6.0 年假结转上限设为 5（原为 7）
update leave_types set carry_over_cap = 5 where code = 'annual';

-- 6.1 结转记账表：记录「某员工在某年可用的结转天数」，供次年到期核销 + 前端展示
create table if not exists annual_carry (
  emp_id       uuid    not null references employees (id),
  year         int     not null,          -- 该结转在「这一年」内可用（次年 1/1 从上一年结转而来）
  carry_in     numeric(5,1) not null,     -- 结转进来的天数（已 ≤ 上限）
  granted_at   timestamptz not null default now(),
  expired_days numeric(5,1),              -- 年末未用、被作废的天数（核销后回填）
  expired_at   timestamptz,
  primary key (emp_id, year)
);
alter table annual_carry enable row level security;
drop policy if exists acarry_read on annual_carry;
create policy acarry_read on annual_carry for select to authenticated
  using (emp_id = current_emp_id() or is_hr());

-- 6.2 某员工某年「实际休掉的年假」（用于判断结转是否用完）。
--     因次年日历只读 → 每张年假申请都落在单一自然年，用 start_date 归年即准确。
create or replace function annual_used_in_year(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select coalesce(sum(a.days), 0) from applications a
  where a.emp_id = p_emp and a.leave_type = 'annual' and a.status = 'approved'
    and extract(year from a.start_date)::int = p_year;
$$;

-- 6.3 年度切换：处理「转入 p_year」这一刻的结转与作废。建议每年 1/1 由 pg_cron 或 HR 执行；
--     必须在 grant_annual_entitlements(p_year) 发放新年度额度之前调用。幂等。
--     规则：① 先核销上一年（p_year-1）结转里没用完的部分（先用结转 → 未用即过期）；
--          ② 再看上一年剩余年假余额：≤5 全部结转、>5 的部分作废；把结转额记入 annual_carry。
create or replace function rollover_annual_leave(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare r record; cap numeric; used numeric; rem numeric; bal numeric; carry numeric; excess numeric; n int := 0;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception '只有 HR 能执行年度结转'; end if;
  cap := coalesce((select carry_over_cap from leave_types where code = 'annual'), 0);

  for r in select id from employees where active loop
    -- ① 上一年结转未用部分作废（先用结转的口径：作废 = max(0, 结转进来 − 上一年实际休掉)）
    perform 1 from annual_carry where emp_id = r.id and year = p_year - 1 and expired_at is null;
    if found then
      select carry_in into carry from annual_carry where emp_id = r.id and year = p_year - 1;
      used := annual_used_in_year(r.id, p_year - 1);
      rem  := greatest(0, carry - used);
      if rem > 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', -rem, (p_year - 1) || ' 结转年假到期作废 (expired carry-over)', null);
      end if;
      update annual_carry set expired_days = rem, expired_at = now()
        where emp_id = r.id and year = p_year - 1;
    end if;

    -- ② 建立转入 p_year 的结转额度（上限 cap；超额部分作废）
    if not exists (select 1 from annual_carry where emp_id = r.id and year = p_year) then
      bal    := coalesce((select balance from leave_balances where emp_id = r.id and leave_type = 'annual'), 0);
      -- 若本年度额度已发放，剔除它 → 只按「上一年遗留」算结转，避免 rollover/grant 执行顺序出错
      bal    := bal - coalesce((select sum(delta_days) from leave_ledger
                                where emp_id = r.id and leave_type = 'annual'
                                  and reason = p_year || ' 年度配额'), 0);
      carry  := least(cap, greatest(0, bal));
      excess := greatest(0, bal - cap);
      if excess > 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', -excess, (p_year - 1) || ' 年假超出结转上限(' || cap || ')作废 (excess forfeited)', null);
      end if;
      -- 结转天数本就在余额里（去年遗留），无需再入账；仅登记以便展示与次年核销
      insert into annual_carry (emp_id, year, carry_in) values (r.id, p_year, carry);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function rollover_annual_leave(int) from anon, public;
grant  execute on function rollover_annual_leave(int) to authenticated;

-- 6.4 当前用户「本年结转」视图（前端在仪表盘展示：还剩几天结转、几时到期）
create or replace view my_annual_carry as
select ac.year,
       ac.carry_in,
       greatest(0, ac.carry_in - annual_used_in_year(ac.emp_id, ac.year)) as remaining,
       (ac.year || '-12-31')::date as expires_on
from annual_carry ac
where ac.expired_at is null
  and ac.emp_id = current_emp_id()
  and ac.year  = extract(year from current_date)::int;
alter view my_annual_carry set (security_invoker = true);
grant select on my_annual_carry to authenticated;
revoke select on my_annual_carry from anon;

-- =============================================================
-- 完。部署顺序见 SETUP.md「v7 部署」：① 跑本 SQL ② 部署 sync-holidays Edge Function
--   ③ 建 cron（每月同步 + 每年 1/1 结转&发放）④ 上传新 index.html
-- =============================================================
