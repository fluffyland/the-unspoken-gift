-- ============================================================================
-- migration_app_v32.sql — 邮件通知的地址由**应用自己填**，不再让人手抄一遍
--
-- 用户原话：
--   「if for a new company i should be editing the project thing inside the website
--     instead of supabase, why you still ask me to paste the project refernce???」
--
-- 他说得对。项目地址和 anon key 本来就必须写进 app.html（网站那两行），
-- 再让人往 SQL 里抄一遍，就是同一份东西输两次 —— 而输两次，迟早会不一致。
--
-- 改法：数据库里留两个空格子；HR/Owner 一登录，应用就把自己正在用的地址和 key
-- 写进去（不一样才写）。人一个字都不用抄。
--
-- 触发器在此之前就存在，只是**静默**：地址是空的就直接放行，什么都不做。
-- 请假永远不会因为邮件而失败。
-- ============================================================================

alter table org_settings add column if not exists notify_url text;
alter table org_settings add column if not exists notify_key text;

comment on column org_settings.notify_url is
  'Where leave-notification events are POSTed. Written by the app itself when an HR/Owner signs in — never typed by hand. Empty = notifications off, and nothing fails.';
comment on column org_settings.notify_key is
  'The project anon key, so the Edge Function gateway accepts the call. Public by design.';

-- ---------- 触发器：读格子，不写死 ----------
-- v33 之前是用 execute format() 把地址烤进函数体，所以换项目就得重建函数。
-- 现在函数体是固定的，地址是数据 —— 换项目只要改那一行数据。
create or replace function leavedesk_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare u text; k text;
begin
  select notify_url, notify_key into u, k from org_settings where id = 1;
  if coalesce(u, '') = '' then
    return new;                      -- 还没接上邮件：静悄悄放行
  end if;
  -- 邮件**绝不能**挡住请假。这里出任何事都吞掉：假条已经记下了，邮件只是礼貌。
  begin
    perform net.http_post(
      url     := u,
      headers := jsonb_build_object('Content-Type', 'application/json',
                                    'Authorization', 'Bearer ' || coalesce(k, '')),
      body    := jsonb_build_object('type', 'INSERT', 'table', 'application_events',
                                    'schema', 'public', 'record', to_jsonb(new)),
      timeout_milliseconds := 15000);   -- 面板默认 1000ms，比函数实际耗时还短
  exception when others then
    null;
  end;
  return new;
end $$;

drop trigger if exists trg_leavedesk_notify on application_events;
create trigger trg_leavedesk_notify after insert on application_events
  for each row execute function leavedesk_notify();

-- ---------- 应用用来自报地址的入口 ----------
-- 只有 HR/Owner 能调；值相同就什么都不做（避免每次登录都写一次）。
create or replace function set_notify_endpoint(p_url text, p_key text)
returns boolean language plpgsql security definer set search_path = public as $$
declare changed boolean := false;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can change the notification endpoint';
  end if;
  update org_settings
     set notify_url = p_url, notify_key = p_key
   where id = 1
     and (coalesce(notify_url, '') is distinct from coalesce(p_url, '')
       or coalesce(notify_key, '') is distinct from coalesce(p_key, ''));
  changed := found;
  return changed;
end $$;
revoke execute on function set_notify_endpoint(text, text) from anon, public;
grant  execute on function set_notify_endpoint(text, text) to authenticated;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_leavedesk_notify') then
    raise exception 'v32 FAILED: the notification trigger was not created';
  end if;
  raise notice 'v32 installed: the app now reports its own address — nothing to copy by hand.';
end $$;
