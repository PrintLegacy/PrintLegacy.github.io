# Supabase lockdown — same project, real data preserved

Decision: reuse the existing project (`szpjpytpciptplqjfwyd`) rather than starting fresh, so the
real client data already collected through `order.html` isn't lost.

The code side is already done:
- `index.html`'s admin modal is now a real login **and register** form — `sb.auth.signInWithPassword`
  to log in, `sb.auth.signUp` to create a new account. A brand-new account can't reach the dashboard
  until an existing admin approves it.
- `dashboard/index.html` guards on `sb.auth.getSession()` **and** on an `admins.approved` check, and
  the whole dashboard UI is now hidden until both pass — no more flash of the dashboard shell before
  the redirect. It also has a new **Administrateurs** page for approving/revoking accounts.
- All 5 live pages (`index.html`, `order.html`, `dashboard/index.html`, `profile/index.html`,
  `printlegacy-profile.html`) use the new `sb_publishable_...` API key you sent.

## What you still need to do in the Supabase dashboard

### 1. Rotate the compromised admin credential
Go to **Authentication → Users** in project `szpjpytpciptplqjfwyd`.
- If a user for `printlegacy2@gmail.com` already exists: reset its password to something new and
  strong. The old password (`esaie4110`) was a plaintext string in public JS and git history —
  anyone who viewed the page source or the repo history has it, so it must be changed regardless of
  whether the login flow using it has changed.
- If no such user exists yet: **Add user → Create new user**, email `printlegacy2@gmail.com`, a new
  strong password, toggle **Auto Confirm User** on.

### 2. Run the schema script
1. **SQL Editor** → New query.
2. Paste in [`SUPABASE_SCHEMA.sql`](./SUPABASE_SCHEMA.sql) and run it.

This does **not** touch your existing client-data tables or data — it enables Row Level Security on
them, and it creates one new table, `admins`, for the registration/approval feature:
- anyone can sign up via the "Créer un compte" link on `index.html`'s admin modal — this creates a
  Supabase Auth user and, automatically (via a trigger), a row in `admins` with `approved = false`;
- only rows in `admins` with `approved = true` can read/write client data — the script also bootstraps
  `printlegacy2@gmail.com` as approved, so you're not locked out;
- from the dashboard's new **Administrateurs** page, an approved admin can approve or revoke other
  accounts.

The script starts with a diagnostic query — read its output before the rest runs, in case policies
from an earlier attempt already exist under different names (drop those first so you don't end up
with duplicate/conflicting rules).

### 3. Confirm the storage bucket exists
**Storage** → check a bucket named exactly `printlegacy` exists, and is set **Public**. (It almost
certainly already does, since `order.html` has presumably been uploading to it — this is just a
check, not a new step.)

### 4. Check email confirmation settings
**Authentication → Providers → Email**: if "Confirm email" is enabled, someone who registers via
`index.html` will need to click a confirmation link before they can log in (on top of needing admin
approval). That's fine either way — just know both gates exist if a fresh registration doesn't log
in immediately.

## Verify

- [ ] Incognito window: submit a test order via `order.html` — should still succeed.
- [ ] Incognito window: view an existing active profile via `profile/index.html?slug=...` — should still load.
- [ ] Log into the admin modal on `index.html` with the **rotated** `printlegacy2@gmail.com` password — redirects to `/dashboard` with real data visible.
- [ ] Incognito: visit `/dashboard` directly with no session — should redirect back to `/` (no flash of the dashboard shell first).
- [ ] Incognito: on `index.html`, click "Créer un compte", register a throwaway test account — should show the "en attente de validation" message, not log in.
- [ ] From an approved admin session, open the dashboard's **Administrateurs** page — the test account should show as pending; approve it, then confirm that account can now log in.
- [ ] Click "Déconnexion" in the dashboard, then revisit `/dashboard` — should redirect to `/` again (session actually cleared).
- [ ] Test an existing `modifier.html?slug=...&token=...` link (printlegacy-platform.vercel.app) — if it breaks, `update_client_by_token`'s column list in `SUPABASE_SCHEMA.sql` needs extending to match what that page actually sends.

## Why this matters

Before this change, `dashboard/index.html` queried Supabase directly using the public API key with
no session check at all, and the password gate on `index.html` was a plaintext string comparison
readable via view-source, tied to one hardcoded email. The current setup adds real multi-admin
support without opening the door wide: registration is self-service, but a new account is inert
until someone who's already trusted approves it, and every "admin" RLS policy checks that approval
status rather than just "is logged in" — because once anyone can create an authenticated session,
"authenticated" alone stops being a meaningful gate.
