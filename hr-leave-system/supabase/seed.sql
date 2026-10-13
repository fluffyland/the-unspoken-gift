-- =============================================================
-- LeaveDesk SG — 员工种子数据（在 schema.sql 之后执行一次）
-- 18 名员工，邮箱 名字@shanghai-uniforms.com
-- 审批路线：直通 Doris = Michelle / Alice / Usam / Burak / Lin / 文斌
-- Doris（MD）无审批人 → 请假自动批准备案
-- =============================================================

-- 0) 部门（团队）列表 —— 员工的 dept 引用这里，必须先建
insert into departments (name) values
  ('Management'), ('Sales Operation'), ('Bookshop Operation'), ('Retail Operation'),
  ('School Account Operations'), ('Warehouse'), ('Logistics'), ('Operation Team'),
  ('Merchandising Team'), ('Finance')
on conflict (name) do nothing;

-- 1) 先插入 Doris（无审批人）
insert into employees (name, email, join_date, dept, gender, role, approver1, annual_base)
values ('Doris', 'doris@shanghai-uniforms.com', '2015-01-01', 'Management', 'F', 'admin', null, 21)
on conflict (email) do nothing;

-- 2) 其余员工（approver1 按邮箱查找；执行前可按需修改入职日期 join_date 与年假基数 annual_base）
with a as (select id from employees where email = 'doris@shanghai-uniforms.com')
insert into employees (name, email, join_date, dept, gender, role, approver1, annual_base)
select v.name, v.email, v.join_date::date, v.dept, v.gender, v.role, a.id, v.base from a, (values
  ('Michelle', 'michelle@shanghai-uniforms.com', '2018-01-01', 'Sales Operation',           'F', 'approver', 16),
  ('Alice',    'alice@shanghai-uniforms.com',    '2019-01-01', 'Retail Operation',          'F', 'hr',       14),
  ('Usam',     'usam@shanghai-uniforms.com',     '2019-01-01', 'Warehouse',                 'M', 'approver', 14),
  ('Burak',    'burak@shanghai-uniforms.com',    '2021-01-01', 'Logistics',                 'M', 'employee', 14),
  ('Lin',      'lin@shanghai-uniforms.com',      '2020-01-01', 'Operation Team',            'M', 'approver', 14),
  ('文斌',     'wenbin@shanghai-uniforms.com',   '2022-01-01', 'Operation Team',            'M', 'employee', 14)
) as v(name, email, join_date, dept, gender, role, base)
on conflict (email) do nothing;

with m as (select id from employees where email = 'michelle@shanghai-uniforms.com')
insert into employees (name, email, join_date, dept, gender, role, approver1, annual_base)
select v.name, v.email, v.join_date::date, v.dept, v.gender, v.role, m.id, 14 from m, (values
  ('Tam',     'tam@shanghai-uniforms.com',     '2021-01-01', 'Bookshop Operation',        'M', 'employee'),
  ('Phyllis', 'phyllis@shanghai-uniforms.com', '2021-01-01', 'Bookshop Operation',        'F', 'employee'),
  ('Amanda',  'amanda@shanghai-uniforms.com',  '2022-01-01', 'School Account Operations', 'F', 'employee'),
  ('Paulin',  'paulin@shanghai-uniforms.com',  '2022-01-01', 'School Account Operations', 'F', 'employee'),
  ('Daisy',   'daisy@shanghai-uniforms.com',   '2022-01-01', 'School Account Operations', 'F', 'employee')
) as v(name, email, join_date, dept, gender, role)
on conflict (email) do nothing;

with x as (select id from employees where email = 'alice@shanghai-uniforms.com')
insert into employees (name, email, join_date, dept, gender, role, approver1, annual_base)
select 'Yukong', 'yukong@shanghai-uniforms.com', '2022-01-01', 'Retail Operation', 'M', 'employee', x.id, 14 from x
on conflict (email) do nothing;

with x as (select id from employees where email = 'usam@shanghai-uniforms.com')
insert into employees (name, email, join_date, dept, gender, role, approver1, annual_base)
select '文翰', 'wenhan@shanghai-uniforms.com', '2022-01-01', 'Warehouse', 'M', 'employee', x.id, 14 from x
on conflict (email) do nothing;

with d as (select id from employees where email = 'doris@shanghai-uniforms.com')
insert into employees (name, email, join_date, dept, gender, role, approver1, annual_base)
select 'Belinda', 'belinda@shanghai-uniforms.com', '2020-01-01', 'Merchandising Team', 'F', 'approver', d.id, 14 from d
on conflict (email) do nothing;

with b as (select id from employees where email = 'belinda@shanghai-uniforms.com')
insert into employees (name, email, join_date, dept, gender, role, approver1, annual_base)
select 'Barry', 'barry@shanghai-uniforms.com', '2022-01-01', 'Merchandising Team', 'M', 'employee', b.id, 14 from b
on conflict (email) do nothing;

with d as (select id from employees where email = 'doris@shanghai-uniforms.com')
insert into employees (name, email, join_date, dept, gender, role, approver1, annual_base)
select v.name, v.email, '2023-01-01'::date, 'Finance', 'F', 'employee', d.id, 14 from d, (values
  ('Maggie', 'maggie@shanghai-uniforms.com'),
  ('Annie',  'annie@shanghai-uniforms.com')
) as v(name, email)
on conflict (email) do nothing;

-- 3) 全员年度配额入账（年假按 annual_base + 年资；病假/住院/育儿等按标准）
select grant_annual_entitlements(extract(year from current_date)::int);

-- 4) 核对
select e.name, e.dept, coalesce(a.name, '(auto-approve)') as approver, e.annual_base
from employees e left join employees a on a.id = e.approver1
order by e.dept, e.name;
