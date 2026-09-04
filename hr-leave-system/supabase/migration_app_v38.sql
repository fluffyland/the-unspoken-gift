-- ============================================================================
-- migration_app_v38.sql — 屏幕上的「Carry Forward」必须是**真的还能用**的天数
--
-- 用户原话：
--   「why lee jian wei carried foward is 2 days? i told you to credit 5 days」
--   「this year 14 and carry foward 5 total AL should be 19 ... why after i apply
--     the Annual leave will change from Annual Leave: 9 · Carry Forward: 2 to
--     Annual Leave: 10 · Carry Forward: 1?」
--
-- 复现出来的真相（一模一样：Available 11 / 屏幕显示结转 2 / 实际被扣住 5）：
--   他为了测试，把 Carry Forward AL 到期日设成了**已经过去**的日子。
--   于是那 5 天确实已经作废了 —— 余额视图里 due_unwritten_carry 把 5 天全扣住，
--   Available = 14 + 5 − 3 − 5 = 11。**这一半是对的，那 5 天本来就不该还能用。**
--
--   错的是屏幕：my_annual_carry.remaining 只算 carry_in − 今年已休，
--   **完全不看到期没到期**，于是还在广告「你还有 2 天结转」。
--   同一批天数，余额一套算法，屏幕另一套算法 —— 这就是那个 2 的来历。
--
--   而「Annual Leave」那个数字是**减出来的**（Available − 屏幕上的结转）。
--   所以那个假的结转数一变小，「Annual Leave」就跟着变大 ——
--   请了一天假，Annual Leave 从 9 跳到 10，就是这么来的。
--
-- 修法只有一条：**结转只有一个算法**。屏幕上写的，就是真的还能拿去请假的。
-- 修好之后，用户预期的那套数就自然成立了：
--   14 + 5 = 19，休 3 天先扣结转 ⇒ Annual Leave 14 · Carry Forward 2 = 16
--   再休 1 天              ⇒ Annual Leave 14 · Carry Forward 1 = 15
--   「Annual Leave」在结转用完之前不会动 —— 正是「先用结转」的意思。
--
-- 幂等：重复执行没有副作用。不改任何人的天数，只改屏幕读到的那个数。
-- ============================================================================

create or replace view my_annual_carry as
select ac.year,
       ac.carry_in,
       -- 还能用的结转 = 结转 − 今年已休 − 已经过期但还没落账的部分。
       -- 第三项是关键：没有它，过期的天数还在屏幕上招手。
       greatest(0, ac.carry_in
                   - annual_used_in_year(ac.emp_id, ac.year)
                   - due_unwritten_carry(ac.emp_id, 'annual')) as remaining,
       ac.expires_on,
       -- 让屏幕能说清楚「为什么是 0」：是没结转，还是已经过期了。
       (ac.expired_at is not null
        or (ac.expires_on is not null and ac.expires_on < current_date)) as expired,
       ac.expired_at
from annual_carry ac
where ac.emp_id = current_emp_id() and ac.year = extract(year from current_date)::int;
alter view my_annual_carry set (security_invoker = true);
grant select on my_annual_carry to authenticated;
revoke select on my_annual_carry from anon;
comment on view my_annual_carry is
  'This year''s carried annual leave for whoever is asking. remaining is what can ACTUALLY still be booked — it subtracts days already past their expiry date, which the balance withholds too. Before v38 it did not, so the screen advertised carried days the balance had already refused, and the "Annual Leave" figure beside it (computed as available minus this) moved in the wrong direction when leave was taken.';

do $$
declare bad int;
begin
  if exists (select 1 from pg_views where viewname = 'my_annual_carry'
              and definition not like '%due_unwritten_carry%') then
    raise exception 'v38 FAILED: my_annual_carry still ignores the expiry date';
  end if;
  raise notice 'v38 installed: the carry-forward figure on screen is now the one you can actually book.';
end $$;

select 'v38 installed' as status,
       coalesce(to_char(carry_expiry_for(extract(year from current_date)::int), 'DD Mon YYYY'),
                'never expires') as "Carried AL expires",
       (select count(*) from annual_carry
         where year = extract(year from current_date)::int
           and expires_on is not null and expires_on < current_date
           and expired_at is null) as "Carry past its date, not yet written off";
