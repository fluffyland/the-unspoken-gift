-- ============================================================================
-- undo_year_start.sql — 把某一次「Start a new year」原样退回去
--
-- 为什么可以退：账本是**只追加**的。那一次运行只是写了新行，没有改写、没有删除
-- 任何旧行。year_start_log 又记下了它处理过哪些人、什么时候跑的（run_at）。
-- 所以那一批行是**可以精确圈出来**的：时间在 run_at 之后 + 人在名单里 +
-- 措辞是那次运行会写的那几种。三个条件同时满足才删。
--
-- ⚠️ 时间这一条不能省。用户 7 月发过 2026 年度配额，措辞正好也是
--    '2026 年度配额' —— 只按措辞删，会把 7 月那笔正常的发放一起删掉。
--    加上 created_at >= run_at，7 月那笔就永远碰不到。
--
-- 用法（先看，再做）：
--   select undo_year_start(2026);              -- 预览：只算不写
--   select undo_year_start(2026, false);       -- 确认无误后才真的退
--
-- 幂等：退过一次之后再跑，year_start_log 里已经没有那一年了，直接返回「无事可做」。
-- ============================================================================

create or replace function undo_year_start(p_year int, p_preview boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_run_at timestamptz;
  v_people int;
  v_rows   jsonb := '[]'::jsonb;
  v_ledger int := 0;
  v_carry  int := 0;
  v_days   numeric := 0;
  v_ids    bigint[];
  r record;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can undo a year start';
  end if;

  select min(run_at), count(*) into v_run_at, v_people
    from year_start_log where year = p_year;

  if v_run_at is null then
    return jsonb_build_object('year', p_year, 'found', false,
      'message', 'Nothing to undo — no year-start run is recorded for ' || p_year || '.');
  end if;

  -- 圈出那一次写的账本行。三个条件缺一不可。
  -- 用数组不用临时表：临时表在同一条语句里被调用两次会打出
  -- "relation _undo_rows already exists" 的 NOTICE —— 对不写代码的人来说，
  -- 那看着就像出错了。诊断信息必须只在真的出事时出现。
  select coalesce(array_agg(l.id), '{}')
    into v_ids
    from leave_ledger l
   where l.emp_id in (select emp_id from year_start_log where year = p_year)
     and l.created_at >= v_run_at - interval '5 seconds'   -- ← 保住 7 月那笔
     and (
          l.reason like (p_year - 1) || '%expired (unused)%'                       -- 其它假别清零
       or l.reason like (p_year - 1) || ' annual leave above the carry-over cap%'  -- 超上限作废
       or l.reason like '%carry-over expired (unused)%'                            -- 结转到期核销
       or l.reason in (p_year || ' annual allowance', p_year || ' 年度配额')        -- 新年度发放
     );

  select count(*), coalesce(sum(delta_days), 0) into v_ledger, v_days
    from leave_ledger where id = any(v_ids);
  select count(*) into v_carry
    from annual_carry ac
   where ac.year = p_year
     and ac.granted_at >= v_run_at - interval '5 seconds'
     and ac.emp_id in (select emp_id from year_start_log where year = p_year);

  -- 每个人：删哪些行、余额从多少回到多少
  for r in
    select l.emp_id, e.name as emp_name,
           jsonb_agg(jsonb_build_object('type', l.leave_type, 'days', l.delta_days,
                                        'reason', l.reason) order by l.id) as rows,
           sum(l.delta_days) as net
      from leave_ledger l join employees e on e.id = l.emp_id
     where l.id = any(v_ids)
     group by l.emp_id, e.name order by e.name
  loop
    v_rows := v_rows || jsonb_build_object(
      'name', r.emp_name, 'removes', r.rows, 'net_change', -r.net);
  end loop;

  if p_preview then
    return jsonb_build_object(
      'year', p_year, 'found', true, 'preview', true,
      'run_at', v_run_at, 'people', v_people,
      'ledger_rows', v_ledger, 'carry_rows', v_carry, 'net_days_removed', v_days,
      'detail', v_rows,
      'message', 'PREVIEW ONLY — nothing has changed. Check the numbers, then run '
                 || 'select undo_year_start(' || p_year || ', false);');
  end if;

  delete from leave_ledger where id = any(v_ids);
  delete from annual_carry ac
   where ac.year = p_year
     and ac.granted_at >= v_run_at - interval '5 seconds'
     and ac.emp_id in (select emp_id from year_start_log where year = p_year);
  -- 日志最后删：万一上面出错，这一年还能再预览一次
  delete from year_start_log where year = p_year;

  return jsonb_build_object(
    'year', p_year, 'found', true, 'preview', false,
    'people', v_people, 'ledger_rows', v_ledger, 'carry_rows', v_carry,
    'net_days_removed', v_days, 'detail', v_rows,
    'message', 'Undone. ' || v_ledger || ' ledger row(s) and ' || v_carry
               || ' carry-forward record(s) removed; ' || p_year || ' is no longer started.');
end $$;

revoke execute on function undo_year_start(int, boolean) from anon, public;
grant  execute on function undo_year_start(int, boolean) to authenticated;

comment on function undo_year_start(int, boolean) is
  'Reverses one Start-a-new-year run. Previews by default. Only removes rows written at or after that run''s run_at, by the employees it logged, with the wordings it produces — so an ordinary allowance granted earlier in the same year is never touched.';

do $$
begin
  raise notice ' ';
  raise notice 'undo_year_start installed. To see what a run did, without changing anything:';
  raise notice '    select jsonb_pretty(undo_year_start(2026));';
  raise notice ' ';
end $$;
