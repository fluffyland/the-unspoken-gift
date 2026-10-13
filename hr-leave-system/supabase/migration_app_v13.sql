-- =============================================================
-- LeaveDesk SG — migration v13：公共假期的「来源 + 时间」与手工录入保护
--
-- 可以在 v12 之前或之后执行，两者互不依赖。幂等，可重复执行。
--
-- 解决三件事：
--   1) 手工录入的假期，系统里**没有任何时间戳** —— 界面想显示「什么时候加的」
--      根本无从取数（manual 编辑时还会把 synced_at 置空）。
--   2) 同步会**悄悄接管**手工录入的行：source 被改成 data.gov.sg，
--      于是名称被 MOM 覆盖，而且这行从此可以被下一次同步删掉 —— 保护凭空消失。
--      若名称恰好相同，连公告都不会发，完全无声。
--   3) 冲突（你手工加的日期，MOM 后来也发布了）没有任何记录。
-- =============================================================

-- ---------- 1. 一个「最后改动时间」列，同步和手工都写 ----------
alter table public_holidays add column if not exists updated_at timestamptz not null default now();
comment on column public_holidays.updated_at is
  'Last change to this row from ANY source. synced_at answers a different question: when MOM last confirmed the date. Manual rows have synced_at null but a real updated_at.';

-- 已有行回填：优先用同步时间，没有就用当前时间
update public_holidays set updated_at = coalesce(synced_at, now()) where updated_at is null;

-- ---------- 2. 同步日志记下「冲突」 ----------
alter table holiday_sync_log add column if not exists conflicts jsonb not null default '[]'::jsonb;
comment on column holiday_sync_log.conflicts is
  'Dates that existed as manual entries and also appeared in the official feed. Kept as manual; recorded so the takeover is never silent.';

-- ---------- 3. 重建对账函数（保护手工录入 + 记录冲突 + 写 updated_at） ----------
create or replace function apply_holiday_sync(
  p_holidays jsonb, p_years int[], p_source text default 'data.gov.sg'
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_added   jsonb := '[]'::jsonb;
  v_removed jsonb := '[]'::jsonb;
  v_renamed jsonb := '[]'::jsonb;
  v_conflicts jsonb := '[]'::jsonb;   -- MOM 也发布了、但本来是手工录入的日期
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
    else
      -- 手工录入的日期被 MOM 也收录了：记下来并告知 HR，不再是「静默接管」
      if (select source from public_holidays where holiday = r.d) = 'manual' then
        v_conflicts := v_conflicts || jsonb_build_object('holiday', r.d, 'name', r.nm);
        changed := true;
      end if;
    end if;
    if exists (select 1 from public_holidays where holiday = r.d)
       and (select name from public_holidays where holiday = r.d) is distinct from r.nm then
      v_renamed := v_renamed || jsonb_build_object('holiday', r.d, 'name', r.nm);
      changed := true;
    end if;
    -- 冲突处理：**绝不接管手工录入的行**。
    -- 原写法 set source = excluded.source 会把 HR 手工加的日期悄悄改成自动来源，
    -- 于是 (a) 名称被 MOM 覆盖，(b) 该行从此可被下一次同步删除 —— 保护凭空消失，
    -- 而且名称若刚好相同，连公告都不会发。
    insert into public_holidays (holiday, name, source, synced_at, updated_at)
    values (r.d, r.nm, p_source, now(), now())
    on conflict (holiday) do update
      set name      = excluded.name,
          synced_at = now(),
          updated_at = now(),
          source    = case when public_holidays.source = 'manual' then 'manual'
                           else excluded.source end;
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

  insert into holiday_sync_log (source, years, added, removed, renamed, conflicts, total_seen, status)
  values (p_source, p_years, v_added, v_removed, v_renamed, v_conflicts,
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
            || case when jsonb_array_length(v_conflicts) > 0 then
                 E'\n\n📌 ' || jsonb_array_length(v_conflicts) ||
                 ' date(s) you added by hand also appear in MOM''s list. They have been KEPT AS YOURS — the sync will never rename or delete them.'
               else '' end
            || E'\n\n' || ann_body, 'hr');
  end if;

  return jsonb_build_object('changed', changed, 'added', v_added, 'removed', v_removed, 'renamed', v_renamed, 'conflicts', v_conflicts);
end $$;
revoke execute on function apply_holiday_sync(jsonb, int[], text) from anon, public, authenticated;
grant  execute on function apply_holiday_sync(jsonb, int[], text) to service_role;

-- ---------- 验证 ----------
select 'columns' as check,
  (select count(*) from information_schema.columns
    where table_name='public_holidays' and column_name='updated_at')  as ph_updated_at,
  (select count(*) from information_schema.columns
    where table_name='holiday_sync_log' and column_name='conflicts')  as log_conflicts;
select 'no null updated_at' as check, count(*) as should_be_zero
  from public_holidays where updated_at is null;
