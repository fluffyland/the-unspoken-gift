-- =============================================================
-- LeaveDesk — v6 半天假重做 + 公司名
-- 在 Supabase Dashboard → SQL Editor 整段执行一次；幂等，可重复执行。
--   · 半天假改为逐日可选（全天/上午/下午）：新增 half_days 列 + working_days_hd()，
--     重建 submit_application（p_sh/p_eh 保留为可选尾参 → 前后端部署顺序无关）
--   · 公司名更新为 Shanghai School Uniforms Pte Ltd
-- =============================================================

-- ---------- 1. 半天假明细列 ----------
alter table applications add column if not exists half_days jsonb not null default '[]'::jsonb;

-- ---------- 2. 逐日半天的工作日折算 ----------
-- 整工作日数 − 0.5 ×（落在工作日内、被标为 am/pm 的日期数）；下限 0.5。
create or replace function working_days_hd(p_start date, p_end date, p_half jsonb)
returns numeric language plpgsql stable as $$
declare d date; n numeric := 0;
begin
  if p_end < p_start then return 0; end if;
  d := p_start;
  while d <= p_end loop
    if extract(isodow from d) < 6 and not exists (select 1 from public_holidays where holiday = d) then
      n := n + 1;
      if exists (select 1 from jsonb_array_elements(coalesce(p_half,'[]'::jsonb)) e
                 where (e->>'d')::date = d and lower(e->>'part') in ('am','pm')) then
        n := n - 0.5;
      end if;
    end if;
    d := d + 1;
  end loop;
  if n <= 0 then n := 0.5; end if;
  return n;
end $$;

-- ---------- 3. 重建 submit_application（新增 p_half_days；p_sh/p_eh 变可选尾参） ----------
drop function if exists submit_application(text,date,date,boolean,boolean,text,text,uuid);
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

-- ---------- 4. 公司名 ----------
update org_settings set company_name = 'Shanghai School Uniforms Pte Ltd' where id = 1;
