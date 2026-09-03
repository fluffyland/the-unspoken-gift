-- Minimal stand-in for what Supabase provides, so schema.sql loads unchanged.
create extension if not exists pgcrypto;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;
create schema if not exists auth;
create schema if not exists storage;
create table if not exists auth.users (id uuid primary key, email text, raw_user_meta_data jsonb);
-- who "is" logged in, for tests
create table if not exists auth._whoami (id uuid);
create or replace function auth.uid() returns uuid language sql stable as $$ select id from auth._whoami limit 1 $$;
create or replace function auth.role() returns text language sql stable as $$ select 'authenticated'::text $$;
create or replace function auth.email() returns text language sql stable as $$ select null::text $$;
-- Supabase provides these; a bare Postgres does not. Minimal stand-ins so schema.sql's
-- attachment policies can be created exactly as they are on a real project.
create table if not exists storage.buckets (
  id text primary key, name text, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[]);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(), bucket_id text, name text,
  owner uuid, created_at timestamptz default now(), metadata jsonb);
-- Supabase ships this; it splits an object path into its folder parts.
create or replace function storage.foldername(name text) returns text[]
language sql immutable as $$ select string_to_array(name, '/') $$;
create schema if not exists net;
create table if not exists net._calls (id serial, url text, body jsonb, headers jsonb, timeout_ms int);
create or replace function net.http_post(url text, body jsonb default '{}', params jsonb default '{}',
  headers jsonb default '{}', timeout_milliseconds int default 5000) returns bigint
language sql as $$ insert into net._calls (url, body, headers, timeout_ms)
  values (url, body, headers, timeout_milliseconds) returning 1::bigint $$;
