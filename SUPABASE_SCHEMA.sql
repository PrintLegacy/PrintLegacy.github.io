-- ============================================================
-- Print Legacy — RLS lockdown for the EXISTING project
-- (szpjpytpciptplqjfwyd). Tables and data already exist —
-- this script does NOT create or touch any client-data table
-- structure, it only enables Row Level Security, adds policies,
-- and creates a new `admins` table for multi-admin self-service
-- registration with admin-approval.
-- Run in: Supabase Dashboard → SQL Editor → New query.
-- ============================================================

-- ── STEP 1 — run this first and read the results ──
-- Tells you whether RLS is already on, and whether any policies
-- already exist (e.g. from a prior partial attempt). If the second
-- query returns rows with names NOT listed below, drop them first:
--   drop policy if exists "<name>" on public.<table>;
-- so you don't end up with duplicate/conflicting rules.

select relname, relrowsecurity from pg_class
where relname in ('clients','card_views','creations','impressions');

select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies where tablename in ('clients','card_views','creations','impressions');

-- ============================================================
-- STEP 2 — admins table: self-service registration, gated by
-- approval from an already-approved admin. Anyone can sign up
-- via Supabase Auth (sb.auth.signUp on index.html), but a new
-- account can't see any client data until an existing admin
-- flips `approved` to true from the dashboard's "Administrateurs"
-- page.
-- ============================================================
create table if not exists public.admins (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  approved    boolean not null default false,
  created_at  timestamptz not null default now()
);

alter table public.admins enable row level security;

-- security definer so it can read `admins` without recursing through
-- this table's own RLS policies — the standard pattern for a
-- self-referencing role/permissions table.
create or replace function public.is_approved_admin() returns boolean
language sql stable security definer as $$
  select exists(select 1 from public.admins where id = auth.uid() and approved = true);
$$;

drop policy if exists "admins_self_or_approved_select" on public.admins;
create policy "admins_self_or_approved_select"
  on public.admins for select to authenticated
  using (id = auth.uid() or public.is_approved_admin());

drop policy if exists "admins_approved_update" on public.admins;
create policy "admins_approved_update"
  on public.admins for update to authenticated
  using (public.is_approved_admin()) with check (public.is_approved_admin());

drop policy if exists "admins_approved_delete" on public.admins;
create policy "admins_approved_delete"
  on public.admins for delete to authenticated
  using (public.is_approved_admin());

-- Auto-create a pending admins row whenever anyone signs up via
-- Supabase Auth, regardless of email-confirmation settings (this
-- runs on the auth.users insert itself, not on first sign-in).
create or replace function public.handle_new_admin_signup() returns trigger
language plpgsql security definer as $$
begin
  insert into public.admins (id, email, approved) values (new.id, new.email, false)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_admin_signup();

-- Bootstrap: mark the existing admin account approved so you're not
-- locked out. Safe to re-run. If no auth user exists yet for this
-- email, this does nothing — create the user first (Authentication →
-- Users → Add user), then re-run just this statement.
insert into public.admins (id, email, approved)
select id, email, true from auth.users where email = 'printlegacy2@gmail.com'
on conflict (id) do update set approved = true;

-- ============================================================
-- STEP 3 — RLS on the actual client-data tables. "Admin" access
-- is now gated by is_approved_admin(), not just any authenticated
-- session — this matters because ANYONE can now create an
-- authenticated session via self-registration.
-- ============================================================

-- clients — public can INSERT a pending order and SELECT only
-- active profiles; approved admin has full access.
alter table public.clients enable row level security;

drop policy if exists "clients_public_select_active" on public.clients;
create policy "clients_public_select_active"
  on public.clients for select to anon
  using (status = 'active');

drop policy if exists "clients_public_insert_pending" on public.clients;
create policy "clients_public_insert_pending"
  on public.clients for insert to anon
  with check (status = 'pending');

drop policy if exists "clients_admin_select_all" on public.clients;
create policy "clients_admin_select_all"
  on public.clients for select to authenticated using (public.is_approved_admin());

drop policy if exists "clients_admin_update" on public.clients;
create policy "clients_admin_update"
  on public.clients for update to authenticated
  using (public.is_approved_admin()) with check (public.is_approved_admin());

drop policy if exists "clients_admin_delete" on public.clients;
create policy "clients_admin_delete"
  on public.clients for delete to authenticated using (public.is_approved_admin());

-- Token-scoped self-edit for the external "modifier.html" client-edit
-- page (printlegacy-platform.vercel.app). Works whether or not that
-- page currently does anon UPDATE directly.
--
-- IMPORTANT: the column list below is a placeholder (firstname/lastname
-- only). Before relying on this, check what fields modifier.html
-- actually sends and extend the SET clause — otherwise self-edit will
-- silently not update the fields clients expect.
create or replace function public.update_client_by_token(
  p_slug text, p_token text, p_updates jsonb
) returns void
language plpgsql security definer as $$
begin
  update public.clients
  set firstname = coalesce(p_updates->>'firstname', firstname),
      lastname  = coalesce(p_updates->>'lastname', lastname)
      -- add other self-editable columns here as needed
  where slug = p_slug and edit_token = p_token;
end;
$$;
grant execute on function public.update_client_by_token to anon;

-- card_views — public can INSERT (anonymous view tracking);
-- only an approved admin can read the analytics.
alter table public.card_views enable row level security;

drop policy if exists "card_views_public_insert" on public.card_views;
create policy "card_views_public_insert"
  on public.card_views for insert to anon with check (true);

drop policy if exists "card_views_admin_select" on public.card_views;
create policy "card_views_admin_select"
  on public.card_views for select to authenticated using (public.is_approved_admin());

-- creations — admin-only. No public reference found anywhere in
-- this repo; if a public portfolio page reads from this table
-- elsewhere, add a scoped anon SELECT policy (e.g. using (published = true)).
alter table public.creations enable row level security;

drop policy if exists "creations_admin_all" on public.creations;
create policy "creations_admin_all"
  on public.creations for all to authenticated
  using (public.is_approved_admin()) with check (public.is_approved_admin());

-- impressions — admin-only, no public reference found anywhere.
alter table public.impressions enable row level security;

drop policy if exists "impressions_admin_all" on public.impressions;
create policy "impressions_admin_all"
  on public.impressions for all to authenticated
  using (public.is_approved_admin()) with check (public.is_approved_admin());

-- storage.objects (bucket 'printlegacy') — public read (so
-- getPublicUrl() links load in browsers), anon upload (order.html
-- uploads files before the client row exists), approved-admin full
-- write/delete.
drop policy if exists "printlegacy_public_read" on storage.objects;
create policy "printlegacy_public_read"
  on storage.objects for select to public
  using (bucket_id = 'printlegacy');

drop policy if exists "printlegacy_anon_upload" on storage.objects;
create policy "printlegacy_anon_upload"
  on storage.objects for insert to anon
  with check (bucket_id = 'printlegacy');

drop policy if exists "printlegacy_admin_update" on storage.objects;
create policy "printlegacy_admin_update"
  on storage.objects for update to authenticated
  using (bucket_id = 'printlegacy' and public.is_approved_admin())
  with check (bucket_id = 'printlegacy' and public.is_approved_admin());

drop policy if exists "printlegacy_admin_delete" on storage.objects;
create policy "printlegacy_admin_delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'printlegacy' and public.is_approved_admin());
