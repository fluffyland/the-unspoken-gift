-- Same people, but NOTHING has ever been granted — a company that has just been set up.
insert into departments (name) values ('Ops') on conflict do nothing;
insert into auth.users (id, email) values
 ('11111111-0000-0000-0000-000000000001','barry@x.com'),
 ('11111111-0000-0000-0000-000000000002','bel@x.com'),
 ('11111111-0000-0000-0000-000000000003','barbie@x.com'),
 ('11111111-0000-0000-0000-000000000009','hr@x.com');
insert into employees (id,name,email,dept,gender,role,join_date,annual_base,carry_cap,active,two_level,auth_user_id,approver1) values
 ('a0000000-0000-0000-0000-000000000009','Hilda HR','hr@x.com','Ops','F','hr','2020-01-01',14,5,true,false,'11111111-0000-0000-0000-000000000009',null),
 ('a0000000-0000-0000-0000-000000000001','Barry','barry@x.com','Ops','M','employee','2022-01-01',17.5,5,true,false,'11111111-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000009'),
 ('a0000000-0000-0000-0000-000000000002','Belinda','bel@x.com','Ops','F','employee','2022-01-01',19,5,true,false,'11111111-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000009'),
 ('a0000000-0000-0000-0000-000000000003','Barbie','barbie@x.com','Ops','F','employee','2024-01-01',14,5,true,false,'11111111-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000009');
update org_settings set annual_cap = 30 where id = 1;
