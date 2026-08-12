# Supabase Auth + RLS setup (run this yourself, I can't run SQL for you)

The code changes (Supabase Auth login on the site, session guard on the dashboard) are already
deployed. They are **not fully effective until you complete the two steps below** in your Supabase
project. Until then, the site will still *work* (dashboard queries currently succeed because RLS
either isn't enabled or is permissive), but the anon key embedded in `dashboard/index.html` could
still be used to hit the database directly, bypassing the login screen.

## Step 1 — create your admin login

1. Go to the [Supabase Dashboard](https://supabase.com/dashboard) → project `szpjpytpciptplqjfwyd` → **Authentication → Users**.
2. Click **Add user → Create new user**.
3. Email: `printlegacy2@gmail.com` (already hardcoded into `index.html`'s admin form as the login
   identity — if you'd rather use a different email, update the `ADMIN_EMAIL` constant near the top
   of the `<script>` block in `index.html` to match).
4. Password: pick a **new, strong password**. The old one (`esaie4110`) is permanently compromised —
   it lived in plaintext in the site's public JavaScript and in git history — never reuse it anywhere.
5. Toggle **Auto Confirm User** on, so you can log in immediately without an email confirmation step.

Test it: go to `https://printlegacy.github.io/`, click "⚙ Admin" in the footer, enter the new
password. It should redirect you to `/dashboard` with your data visible.

## Step 2 — lock down the database with Row Level Security (RLS)

Open the **SQL Editor** in your Supabase project and run the diagnostic query first:

```sql
select relname, relrowsecurity from pg_class
where relname in ('clients','card_views','creations','impressions');

select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies where tablename in ('clients','card_views','creations','impressions');
```

This tells you whether RLS is already on and what policies (if any) already exist. If you see
existing policy names in the second query that aren't in the script below, you may want to drop
them first (`drop policy if exists "<name>" on public.<table>;`) so you don't end up with
conflicting/duplicate rules.

Then run:

```sql
-- ============================================================
-- clients — public can INSERT a pending order and SELECT only
-- active profiles; admin (authenticated) has full access.
-- ============================================================
alter table public.clients enable row level security;

create policy "clients_public_select_active"
  on public.clients for select to anon
  using (status = 'active');

create policy "clients_public_insert_pending"
  on public.clients for insert to anon
  with check (status = 'pending');

create policy "clients_admin_select_all"
  on public.clients for select to authenticated using (true);
create policy "clients_admin_update"
  on public.clients for update to authenticated using (true) with check (true);
create policy "clients_admin_delete"
  on public.clients for delete to authenticated using (true);

-- Token-scoped self-edit for the external "modifier.html" client-edit page
-- (printlegacy-platform.vercel.app). This works whether or not that page
-- currently does anon UPDATE — it's the safe way to support client
-- self-editing without a broad public UPDATE policy.
--
-- IMPORTANT: the column list below is a placeholder (firstname/lastname).
-- Before relying on this, check what fields modifier.html actually sends
-- and update the SET clause to match — otherwise self-edit may silently
-- not update the fields clients expect.
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

-- ============================================================
-- card_views — public can INSERT (anonymous view tracking);
-- only admin can read the analytics.
-- ============================================================
alter table public.card_views enable row level security;

create policy "card_views_public_insert"
  on public.card_views for insert to anon with check (true);
create policy "card_views_admin_select"
  on public.card_views for select to authenticated using (true);

-- ============================================================
-- creations — no evidence anywhere in this repo of a public
-- reference to this table; admin-only by default. If the
-- Vercel front-end shows a public portfolio/gallery reading
-- from `creations`, you'll need to add a scoped anon SELECT
-- policy here (e.g. `using (published = true)`).
-- ============================================================
alter table public.creations enable row level security;
create policy "creations_admin_all"
  on public.creations for all to authenticated using (true) with check (true);

-- ============================================================
-- impressions — admin-only, no public reference found anywhere.
-- ============================================================
alter table public.impressions enable row level security;
create policy "impressions_admin_all"
  on public.impressions for all to authenticated using (true) with check (true);

-- ============================================================
-- storage.objects (bucket 'printlegacy') — public read (so
-- getPublicUrl() links load in browsers on public profile
-- pages), anon upload (order.html uploads files before the
-- client row exists), admin full write/delete.
-- ============================================================
create policy "printlegacy_public_read"
  on storage.objects for select to public
  using (bucket_id = 'printlegacy');
create policy "printlegacy_anon_upload"
  on storage.objects for insert to anon
  with check (bucket_id = 'printlegacy');
create policy "printlegacy_admin_update"
  on storage.objects for update to authenticated
  using (bucket_id = 'printlegacy') with check (bucket_id = 'printlegacy');
create policy "printlegacy_admin_delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'printlegacy');
```

## Step 3 — verify nothing broke

Work through this checklist after Steps 1 and 2:

- [ ] Incognito window: submit a test order via `order.html` — must still succeed.
- [ ] Incognito window: view an existing active profile via `profile/index.html?slug=...` — must still load.
- [ ] Log into the admin modal on `index.html` with your new email/password — redirects to `/dashboard`, shows real data.
- [ ] Visit `/dashboard` directly with no session (fresh incognito) — redirects back to `/`.
- [ ] From the dashboard: toggle a client's status, delete a test client, upload a creation, edit an impression — all should still work.
- [ ] Click "Déconnexion" in the dashboard — then try visiting `/dashboard` again — should redirect to `/` (session actually cleared).
- [ ] Test a `modifier.html?slug=...&token=...` link generated from the dashboard — if it breaks, the `update_client_by_token` function's column list needs adjusting to match what that page actually sends.

If anything in this checklist fails, the specific policy to revisit is named next to it above — this
is meant to be debugged incrementally, not re-run blind.

## Why this matters

Before this change, `dashboard/index.html` queried the `clients` table directly using the public
anon key, with no session check — the password modal on `index.html` was the *only* thing standing
between a visitor and your client data, and that password was a literal string comparison sitting in
plaintext, readable JavaScript. Anyone who viewed the page source could extract it, and even without
the password, the anon key itself (also public, by necessity, since it's used client-side) could hit
your Supabase REST API directly if RLS wasn't already restricting it. This setup closes both gaps:
real authentication for the admin panel, and database-level policies that enforce it regardless of
what any given page's JavaScript does.
