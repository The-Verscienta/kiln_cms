# Secrets rotation runbook

How to replace each secret a KilnCMS deployment depends on, and what breaks
while you do it. Written to be followed
during an incident, against a *running* deployment — so every step below is
what the code actually does, not what would be reasonable.

Pairs with [`backups.md`](backups.md) (the env snapshot is part of the backup)
and closes residual risk 13 in [`threat-model.md`](threat-model.md). The
canonical list of every variable is
[`environment-variables.md`](environment-variables.md); this document is only
about the ones that are *secret*, and only about replacing them.

---

## The three facts that shape every procedure here

**1. There is no hot reload.** Every secret below is read from the environment
in [`config/runtime.exs`](../config/runtime.exs), which a release evaluates
**once, at boot**, before the supervision tree starts. Changing a variable on a
running container changes nothing. Every rotation in this document therefore
ends in a restart, and on the reference deployment (a single Coolify app on one
VPS — see [`deploy.md`](deploy.md)) a restart is a brief full outage, not a
rolling one. Plan the window.

**2. Almost nothing here supports two keys at once.** Not the session cookie,
not the auth tokens, not the object store. Where a graceful transition exists,
it is usually because the *provider* (Postgres, S3) can hold two credentials,
not because Kiln can. The one exception is data at rest: `KilnCMS.Keys.Vault`
reads under `PREVIOUS_SECRET_KEY_BASE` too while a `SECRET_KEY_BASE` rotation
is in progress (#1487). Sections that say "hard cutover" mean it.

**3. Two secrets are not interchangeable, even though both sign things.**

| | `SECRET_KEY_BASE` | `TOKEN_SIGNING_SECRET` |
|---|---|---|
| Signs/encrypts | the session cookie, every `Phoenix.Token` (preview links, content-password grants, the collab socket token, the 2FA pending blob) | the AshAuthentication JWTs (session token, bearer tokens, remember-me, magic links, password resets, email confirmations) |
| Also **encrypts data at rest** | **yes** — `KilnCMS.Keys.Vault` | no |
| Rotation loses data | **only if done out of order**: the old value must stay readable until the re-encryption task has run (see below) | no |
| Blast radius | everyone signed out, **plus** silent loss of database-stored key material if the old value is retired too early | everyone signed out |

Rotating `SECRET_KEY_BASE` is the one operation in this document where the
*order* of the steps decides whether data survives. Read its section in full
before you run it.

## Preconditions for any rotation

- [ ] A **verified** backup exists and is off-site
      ([`backups.md`](backups.md)). A rotation that goes
      wrong is recovered by restoring, and a `SECRET_KEY_BASE` restore needs
      the *old* value too.
- [ ] The current env snapshot is in your password manager, and you can still
      read the **old** value of whatever you are about to replace. Several
      procedures below need it.
- [ ] You know which of the two questions you are answering. They have
      different answers:
      - *"A secret leaked and I must invalidate it"* → rotate, accept the
        breakage, follow the section.
      - *"I want every user signed out"* → you probably do **not** need a
        rotation. See [Signing everyone out without rotating
        anything](#signing-everyone-out-without-rotating-anything).

---

## Signing everyone out without rotating anything

Worth stating first, because it is the request that most often arrives dressed
as "rotate the secrets", and it is far cheaper.

`KilnCMS.Accounts.User` sets both `store_all_tokens?` and
`require_token_presence_for_authentication?`
([`lib/kiln_cms/accounts/user.ex`](../lib/kiln_cms/accounts/user.ex)), so every
minted JWT has a row in the `tokens` table and the browser session stores the
**token**, not just a subject. Authentication therefore checks the database on
every request, and the database is a lever you can pull without restarting
anything:

```sql
-- Kills every browser session and every API bearer JWT, immediately.
-- Does NOT touch remember-me cookies — see below.
DELETE FROM tokens WHERE purpose = 'user';
```

Session and bearer verification both require a live row with
`purpose = 'user'`, so the next request from every signed-in browser fails and
redirects to sign-in.

**The remember-me cookie is the exception.** Its sign-in path verifies the JWT
signature, the `"purpose": "remember_me"` claim and the *absence* of a
revocation — it never requires the token's own row to be present. Deleting the
row does nothing; the 30-day cookie keeps working. To kill those too, convert
every stored token into a revocation instead of deleting it:

```sql
-- Kills sessions, bearer tokens AND remember-me cookies.
UPDATE tokens SET purpose = 'revocation' WHERE purpose <> 'revocation';
```

A revocation row is looked up by `jti`, so this invalidates each token
individually and expires with it on the nightly `:expunge_expired` sweep
(`KilnCMS.Accounts.Token`).

Neither statement touches API keys — those are SHA-256 hashes in `api_keys`
(`KilnCMS.Accounts.ApiKey`), independent of both secrets. Revoke or delete
those rows separately.

Only if the *signing secret itself* is what leaked do you need the next
section.

---

## `TOKEN_SIGNING_SECRET`

**What it signs.** Every AshAuthentication JWT, through `KilnCMS.Secrets`,
which resolves it from application config at each sign and each verify. That
is: the session token stored in the session cookie, `Authorization: Bearer`
JWTs on the API and the GraphQL socket, the 30-day remember-me cookie, magic
links, password-reset links, and new-user email confirmations.

**Dual-key transition: not possible.** Verification builds exactly one signer
from exactly one secret and tries it once. There is no second-secret fallback,
no key id in the header to select on, and `KilnCMS.Secrets` returns a single
value. A rotation is a hard cutover at the moment the new process accepts its
first request.

**What breaks, precisely:**

| Credential | Effect | User-visible recovery |
|---|---|---|
| Browser sessions | Invalid immediately; next request redirects to sign-in | Sign in again |
| Remember-me cookies (30 days) | Invalid immediately | Sign in again |
| API bearer JWTs | 401 immediately | Re-authenticate |
| **API keys** (`kiln_…`) | **Unaffected** — hashed in the database, not signed | — |
| Password-reset links in flight (3-day lifetime) | Dead | Request a new reset |
| Magic links in flight (10-minute lifetime) | Dead | Request a new link |
| New-user confirmation links (3-day lifetime) | Dead | Admin re-triggers, or the user re-registers |
| Two-factor pending blobs | Unaffected by this secret — they are `Phoenix.Token`, keyed off `SECRET_KEY_BASE` | — |
| Rows in `tokens` | Left behind, unusable; swept by `:expunge_expired` at their natural expiry | — |

**Nothing stored in the database is encrypted with this secret**, so a
rotation loses no data. That is what makes it the *safe* one of the two.

### Procedure

1. **Pick the window.** Password resets and magic links in flight die. If you
   can, rotate outside business hours, or accept that anyone mid-reset must
   start over. There is no way to honour them across the cutover.
2. **Generate the new secret:**
   ```bash
   mix phx.gen.secret
   ```
   (64 bytes, base64 — the same generator `.env.example` points at.)
3. **Set `TOKEN_SIGNING_SECRET`** to the new value in the platform's
   environment (Coolify application settings; `.env.prod` on the reference
   compose stack) and record it in the password manager **before** deploying —
   a half-applied rotation you cannot reproduce is the worst state to be in.
4. **Restart the application.** Coolify: *Redeploy*. Compose:
   `docker compose -f docker-compose.prod.yml --env-file .env.prod up -d`.
   Boot `raise`s if the variable is **unset**. Note the gap: the guard is
   `System.get_env("TOKEN_SIGNING_SECRET") || raise(...)`, and
   `System.get_env/1` returns `""` for a `VAR=` entry, which is truthy in
   Elixir — so a *blank* value passes the guard and the app comes up signing
   with an empty secret. The same holds for `SECRET_KEY_BASE` and
   `DATABASE_URL`. Delete the variable rather than blanking it, and never
   leave one half-typed.
5. **Optional but tidy:** clear the now-unusable rows, so the console and the
   expunge job are not carrying dead weight:
   ```sql
   DELETE FROM tokens WHERE purpose <> 'revocation';
   ```
6. **Verify:** sign in with a fresh browser session; confirm an old tab gets
   bounced to sign-in; request a password reset and complete it end to end.

### If the old secret leaked

Do steps 2–4 immediately; the invalidation is instantaneous and complete once
the new process is serving. Then audit the `tokens` table for the window in
which the leak was live — `subject` names the user, `created_at` the mint.

---

## `SECRET_KEY_BASE`

**What it signs and encrypts.** Three distinct things, and the third is why
this section is long:

1. **The session cookie.** Signed *and* encrypted, via
   `KilnCMSWeb.SessionCookie`. Both keys derive from `secret_key_base` through
   `Plug.Crypto.KeyGenerator`, combined with per-purpose salts.
2. **Every `Phoenix.Token` in the app.** Preview tokens
   (`KilnCMS.CMS.PreviewToken`), release-preview tokens
   (`KilnCMS.CMS.ReleasePreview`), content-password grants
   (`KilnCMS.CMS.ContentPassword`), the collaborative-editing socket token, the
   form anti-replay stamp (`KilnCMS.Forms`), the editor's content lock
   (`KilnCMSWeb.ContentLock`), and the two-factor pending sign-in blob
   (`KilnCMS.Accounts.PendingSignIn`, which additionally *encrypts* with it).
   The LiveView session is signed with it too.
3. **Data at rest.** `KilnCMS.Keys.Vault` derives an AES-256-GCM key from
   `secret_key_base` and encrypts database-stored key material with it. This is
   the part that can lose data if the steps below are done out of order.

### Data at rest: re-encrypt before you retire the old value

These columns hold ciphertext under the current `secret_key_base`. Every one
has type `KilnCMS.Keys.Vault.Ciphertext`, and that type is how the
re-encryption task finds them. A test fails the build if a new binary column
is neither that type nor explained, so the list cannot fall behind the code.

| Encrypted column | Resource | What stops working if it cannot be opened | In-app recovery if the old secret is gone |
|---|---|---|---|
| `dkim_private_key_encrypted` | `KilnCMS.Mail.Settings` | Outbound mail is no longer DKIM-signed (direct-delivery mode) | `/editor/mail` → *Rotate key*, then publish the new DNS TXT record |
| `credential_encrypted` | `KilnCMS.Social.Account` | Scheduled social posts stop being published | `/editor/social`: reconnect each account and enter its credential again |
| `secret_key_encrypted`, `webhook_secret_encrypted` | `KilnCMS.Billing.Settings` | Payments and inbound payment webhooks stop | `/editor/billing`: paste the provider API key and the `whsec_…` from the provider dashboard again |
| `password_encrypted` | `KilnCMS.CMS.SiteMailRelay` (one per site that set its own relay) | That site's mail is **held**: the delivery jobs retry for ~16 hours and then give up. It is never sent through the operator's relay instead | `/editor/site-mail` on each such site: enter the relay password again |
| `private_key_encrypted` | `KilnCMS.CMS.SiteVapidKey` (one per site that generated its own push key) | That site's push notifications are **held**, and its settings page stops offering a key to new devices. They are never signed with the deployment's `KILN_VAPID_*` key instead | `/editor/site-push` on each such site: *Rotate key*. Every device subscribed with the old key has to turn notifications on again |
| `api_key_encrypted` | `KilnCMS.CMS.SiteMeilisearch` (one per site that set its own search instance) | That site's indexing is **held**: the jobs retry for ~16 hours and then give up, and its search falls back to the built-in Postgres search. Its content is never sent to the operator's instance instead | `/editor/site-search` on each such site: enter the API key again (the save reindexes the site) |
| `secret_encrypted` | `KilnCMS.CMS.WebhookEndpoint` (one per endpoint) | Outbound webhook deliveries are refused — the ledger says `"delivery failed: signing secret unreadable"` and the endpoint row reports the secret unreadable | `/editor/webhooks`: delete and re-create each endpoint, then give its receiver the new secret |
| `private_key_encrypted` | `KilnCMS.Federation.SiteFederation` | The site can no longer sign ActivityPub deliveries | `/editor/federation` → *Re-key*, or `mix kiln.federation rekey`. See [Re-keying the ActivityPub actor](#re-keying-the-activitypub-actor) |

**You should never need the last column.** Two pieces make the rotation
lossless:

- **A read window.** Set `PREVIOUS_SECRET_KEY_BASE` to the *old* value next to
  the new `SECRET_KEY_BASE`. `KilnCMS.Keys.Vault.decrypt/1` tries the current
  secret and then the previous one. `encrypt/1` writes only under the current
  secret. While both are set, everything above keeps working, and anything
  written during the window is already under the new key.
- **A re-encryption task.** `mix kiln.vault.reencrypt` (in a release:
  `bin/kiln_cms eval 'KilnCMS.Release.reencrypt_vault()'`) walks every column
  above in one transaction per table, with rows locked. It decrypts each value
  with the old secret and writes it back under the current one. It sorts each
  value into one of three groups:
  - *already current*: skipped, so a second run is a no-op.
  - *re-encrypted*: moved from the old secret to the current one.
  - *unreadable*: opens under neither secret. It is reported by table, column
    and id, and **never overwritten**.

  If anything is unreadable, it exits non-zero. By default the old secret is
  `PREVIOUS_SECRET_KEY_BASE`. To name a different variable, pass
  `--old-secret-key-base-env VAR`. The secret itself is never an argument, so
  it stays out of shell history and `ps`. `--dry-run` reports without writing.
  With no old secret at all, the task still runs, as a check that everything
  opens under the current secret.

**If it goes wrong, the failure is quiet.** The decrypt helpers deliberately
return `nil` instead of raising, so that a rotated or restored deployment stops
*doing* the thing instead of crashing every request that touches it. Nothing
fails at boot and nothing sends an alert:

- **DKIM**: `KilnCMS.Mail.dkim_config/0` logs
  `"DKIM key configured but unresolvable, sending unsigned"` at `warning` and
  **sends the mail anyway**, on the explicit reasoning that losing a signature
  hurts deliverability while losing the mail loses a password reset. So mail
  keeps flowing, unsigned, and deliverability decays. `/editor/mail` still
  renders the selector, the public key and the DNS record, because
  `dkim_public_key` is a **plaintext** column. The page looks completely
  healthy. **The log line is the only signal.**
- **Social**: the provider adapter turns the `nil` into a recorded post
  failure, `"no usable access token stored"`, on every attempt.
- **Federation**: `/editor/federation` and `mix kiln.federation status` show
  the signing key as **unreadable**, and each delivery in the ledger fails with
  *"this site's signing key is unreadable"*. Before #1487 it failed with
  *"federation is not enabled"*.
- **Billing**: the provider call fails at the point of use.
- **A site's own mail relay** (#1322): the one that does announce itself.
  `/editor/site-mail` shows *"The saved password can't be read"*, and every
  held delivery logs `"Holding mail for site …: … its password could not be
  decrypted"`. The mail is held, not sent through the operator's relay — but
  only a site admin who opens that page sees the banner, so on a multi-site
  deployment tell each site that set a relay.
- **A site's own push key** (#1560): `/editor/site-push` shows *"The saved
  private key can't be read"*, and each held delivery logs `"Cannot send push
  notifications: :key_unreadable"`. The subscriptions are kept, so restoring
  the old secret brings them back; rotating the key instead drops them.
- **A site's own Meilisearch instance** (#1558): `/editor/site-search` shows
  *"The saved API key can't be read"*, and every held job logs
  `"Holding Meilisearch indexing for site …: its API key could not be
  decrypted"`. Indexing is held and search falls back to the built-in
  search; nothing goes to the operator's instance. As with the relay, only a
  site admin who opens the page sees the banner.

`mix kiln.vault.reencrypt --dry-run` with no old secret is the one check that
covers all of them at once. It should report `0 unreadable` for every column.

> Using the `:env` or `:file` key providers
> (`KilnCMS.Keys.Providers.Env`, `KilnCMS.Keys.Providers.File`) instead of the
> `:database` one takes the DKIM and billing keys out of the vault entirely and
> makes them immune to this. The federation actor key has no such option: it
> is vault-only.

### Dual-key transition: the vault only

`KilnCMS.Keys.Vault` has the read window described above. **Nothing else in
this section does.** `Plug.Session`'s cookie store derives its keys from the
single `conn.secret_key_base` and has no notion of an old key. `Phoenix.Token`
reads one `secret_key_base` from the endpoint's config.
`PREVIOUS_SECRET_KEY_BASE` is read by the vault and by nothing else. For
everyone signed in, the rotation is still a hard cutover.

PR #1445 made the session cookie's two salts configurable
(`:session_signing_salt` / `:session_encryption_salt`) instead of literals in
`KilnCMSWeb.SessionCookie`. **It does not change this answer.** The salts are
`Application.compile_env/3` reads, compile-time because the endpoint's
`@session_options` is a module attribute. So they are set in a downstream
`config/prod.exs` and take a **rebuild**, not an env change, and they still
derive a single key from a single `secret_key_base`. What that PR gives you is
a deployment-specific salt instead of one shared by every clone of this
open-source tree. It does not give you a grace period. Changing a salt
invalidates sessions exactly as changing `secret_key_base` does, without the
vault consequences, because the vault uses its own fixed salt.

### What breaks

| | Effect |
|---|---|
| Browser sessions | Cookie undecryptable → treated as absent → everyone signed out |
| Open LiveView tabs | Socket fails to re-establish; the page redirects to sign-in |
| API bearer JWTs and API keys | **Unaffected** (signed by `TOKEN_SIGNING_SECRET` / hashed) |
| Remember-me cookies | Unaffected by this secret; still valid, so a "remembered" browser signs straight back in |
| Shared preview links, release-preview links | Dead. Re-issue from the editor |
| Content-password grants | Dead; visitors re-enter the password |
| Two-factor sign-ins in flight | The pending blob is undecryptable, so the user restarts sign-in |
| Editor content locks | Unreadable locks are treated as absent, which is the intended fallback |
| DKIM / social / billing / federation key material | **Kept**, if you follow the procedure: readable through the window, then re-encrypted. Lost only if the old value is retired first |

### Procedure

1. **Decide whether you actually need this.** If the goal is "sign everyone
   out", use the SQL above instead. If the goal is "the session cookie's key
   leaked", you need this. If the goal is "a backup was exfiltrated", read
   [If the old value leaked](#if-the-old-value-leaked) first: re-encrypting
   does not protect a copy that has already been taken.
2. **Take a fresh, verified backup** and record the **old** `SECRET_KEY_BASE`
   alongside it, labelled. Without it, that dump is only a partial backup
   ([`backups.md`](backups.md#what-must-be-backed-up)).
3. **Check the starting point.** Everything should open under the current
   secret before you change anything:
   ```bash
   mix kiln.vault.reencrypt --dry-run
   # in a release:
   bin/kiln_cms rpc 'KilnCMS.Release.reencrypt_vault(dry_run: true)'
   ```
   Every column should say `0 unreadable`. If one does not, that value is
   already lost to the current secret. Recover it in the app (the last column
   of the table above) before you rotate, so you are not fixing two things at
   once.
4. **Generate the new value:**
   ```bash
   mix phx.gen.secret
   ```
5. **Set both variables:** `SECRET_KEY_BASE` to the **new** value, and
   `PREVIOUS_SECRET_KEY_BASE` to the **old** one. Record both in the password
   manager, and update the env snapshot that backups depend on.
6. **Restart.** Boot `raise`s on an *unset* `SECRET_KEY_BASE`, but not on a
   blank one; see the note under `TOKEN_SIGNING_SECRET` step 4. Everyone is
   signed out (see [What breaks](#what-breaks)). Mail, social, billing and
   federation keep working, because the vault reads through the window.
7. **Re-encrypt:**
   ```bash
   mix kiln.vault.reencrypt --dry-run   # expect "N would re-encrypt, 0 unreadable"
   mix kiln.vault.reencrypt
   # in a release:
   bin/kiln_cms eval 'KilnCMS.Release.reencrypt_vault()'
   ```
   It is safe to run against the live deployment and safe to run twice. A
   non-zero exit means some value opened under neither secret. Those values
   are listed by id and left untouched. Stop and find out why before going on.
8. **Confirm nothing is left:** run the dry run once more. Every column should
   report `0 would re-encrypt, 0 unreadable`.
9. **Close the window.** Remove `PREVIOUS_SECRET_KEY_BASE` and restart. From
   now on the old value opens nothing the application stores. Keep it with the
   backups taken before step 7, which still need it.
10. **Verify** with the checklist at the end of this document.

### If the old value leaked

Re-encryption protects the data you keep. **It does not un-leak anything.**
Anyone holding the old `SECRET_KEY_BASE` and a copy of the database from before
step 7 (a backup, a staging clone, a stolen dump) can still decrypt every value
in the table above. So after the procedure, rotate the secrets themselves, not
just their encryption:

1. `/editor/mail` → *Rotate key*, then publish the new DNS TXT record.
2. Roll the billing provider's API key and webhook secret in the provider
   dashboard, then paste the new ones into `/editor/billing`.
3. Revoke and reissue each social credential at the provider, then reconnect
   it in `/editor/social`.
4. Re-key the ActivityPub actor, as described in
   [Re-keying the ActivityPub actor](#re-keying-the-activitypub-actor).

---

## `DATABASE_URL`

Rotating the database credential is the one procedure here that **can** be done
without downtime, because Postgres can hold two valid roles at once even though
Kiln can hold one connection string.

**How Kiln uses it.** `runtime.exs` passes the URL straight to `KilnCMS.Repo`
as `url:`, together with `pool_size` (`POOL_SIZE`, default 10), the IPv6 socket
option and the TLS settings. Ecto's repo supervisor parses the URL **once at
boot** and pops it — `KilnCMS.Repo.config/0` never contains `:url` afterwards,
which is also why `KilnCMS.Backups.database_url/0` consults the environment
before rebuilding one from the Repo.

**Why you must not simply `ALTER ROLE … PASSWORD` in place.** The pool's
connections are already authenticated and keep working, so nothing appears to
break — until a connection drops. DBConnection then reconnects with the *old*
password from the already-parsed config, fails, and retries on its backoff
forever. You get a deployment that is healthy right up to the first network
blip and then degrades with no obvious cause. Same trap for the backup cron:
`scripts/backup.sh` reads its own `DATABASE_URL` from the crontab entry, so an
in-place password change breaks nightly backups silently at the next run.

**Note also:** the application's role runs migrations at boot (`bin/migrate`),
so whatever role you cut over to must be able to perform DDL on the existing
objects — not merely read and write them.

### Procedure (no outage on a multi-instance deployment; one restart on a single one)

1. **Create a second role** with the new password, as a member of the current
   one so it inherits ownership-level rights on existing objects:
   ```sql
   CREATE ROLE kiln_app_2 LOGIN PASSWORD '<new-password>';
   GRANT kiln_app TO kiln_app_2;
   ```
   Role membership is what makes the new role able to migrate objects the old
   role owns. Verify before cutting over:
   ```sql
   -- as kiln_app_2
   SELECT 1 FROM pages LIMIT 1;
   CREATE TABLE _rotation_probe (id int); DROP TABLE _rotation_probe;
   ```
2. **Update `DATABASE_URL`** to the new role in the platform environment.
   Keep the old value recorded until step 6.
3. **Update every *other* consumer of the same credential**, in the same
   change:
   - the backup crontab (`/etc/cron.d/kiln-backup`) — see
     the restore runbook in [`backups.md`](backups.md);
   - `BACKUP_DATABASE_URL`, if this deployment sets it;
   - any staging/drill tooling that points at production for a dump
     (`PROD_DATABASE_URL` in [`staging-environments.md`](staging-environments.md)).
4. **Restart the application** so `runtime.exs` re-evaluates. With more than
   one instance behind the proxy, restart them one at a time — the old role is
   still valid, so instances on either side of the cutover both work, and this
   is genuinely zero-downtime. On the single-instance reference deployment it
   is one Coolify *Redeploy* and a brief outage.
5. **Drain the old role's connections** once every instance is on the new one:
   ```sql
   SELECT count(*) FROM pg_stat_activity
    WHERE usename = 'kiln_app' AND datname = 'kiln_prod';
   ```
   It should reach zero on its own after the restart. If a stray session
   lingers (a psql shell, a forgotten drill), close it properly rather than
   reaching for `pg_terminate_backend` — the app's own connections are gone by
   now, so anything left is something you should identify first.
6. **Retire the old credential**, once a backup has run successfully under the
   new role. Take away its ability to log in rather than dropping it:
   ```sql
   ALTER ROLE kiln_app NOLOGIN;
   ```
   The leaked password is now useless, `kiln_app` stays the owner of every
   object, and `kiln_app_2` keeps its rights through the membership granted in
   step 1. That is the end state to aim for: an owner role that never logs in,
   and a login role you can replace again with another
   `CREATE ROLE … ; GRANT kiln_app TO …`. **Do not** `DROP ROLE kiln_app` —
   that requires reassigning every object it owns (`REASSIGN OWNED BY`), which
   is a far larger change than a credential rotation needs to be, and it takes
   the membership `kiln_app_2` depends on with it.

### If the credential leaked and you cannot wait

`ALTER ROLE kiln_app PASSWORD '<new>'` closes the leak for *new* connections
immediately, and existing pool connections keep serving. Set `DATABASE_URL` and
restart within the same maintenance action — do not leave the deployment in
that state, for the reconnect reason above. Also rotate the backup crontab's
copy in the same breath.

---

## S3 credentials (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`)

One credential pair serves **three** consumers in this application, and all
three break together:

- **Media storage** — `KilnCMS.Storage.S3`, when `S3_BUCKET` is set. These two
  are the exception to the blank-value gap above: `runtime.exs` reads them with
  `System.fetch_env!/1`, so an **unset** variable is a boot failure rather than
  a degraded start. A blank one still gets through — as an empty credential
  that fails at the first S3 call.
- **The private bucket** for gated documents (`S3_PRIVATE_BUCKET`), read
  server-side by the same credentials.
- **The governance witness store**, when `KILN_GOVERNANCE_WITNESS_BUCKET` is
  configured.

**Off-site backups do *not* use these keys.** `BACKUP_RCLONE_REMOTE` is an
rclone remote, and its credentials live in `rclone.conf` on the host, outside
the application entirely. Rotating the bucket credentials there is a separate
change to a separate file — see step 5.

**How the credentials are read.** ExAws rebuilds its config from application
environment on **every request** — there is no cached client and no long-lived
session to invalidate. So the moment the new process serves, every subsequent
S3 call uses the new key. The only reason a restart is needed is that
`runtime.exs` is the sole writer of that application environment.

**In-flight uploads.** A media upload is browser → LiveView → server temp file
→ a single server-side `PUT` at `consume_uploaded_entries` time. It is not a
browser-direct presigned upload and not a resumable multipart session, so
there is no upload that can straddle a credential change: an upload either
completes its `PUT` under the old credential before the restart, or the
LiveView is torn down by the restart and the editor re-selects the file. No
partial objects, no orphaned multipart uploads.

**Objects already stored are unaffected.** Keys are write-once UUIDs and
public objects are served from `S3_PUBLIC_BASE_URL` (a CDN or the bucket's
public endpoint), not through the application's credentials.

### Procedure (no data loss; one restart)

1. **Create a second access key** on the same identity in the provider console
   (AWS IAM: a second access key on the user; R2/B2/Wasabi: a second
   application key with the same bucket scope). Both keys are now valid — this
   is the overlap that makes the rotation safe.
2. **Confirm the new key's scope matches the old one** — at minimum
   read/write on the public bucket, plus the private bucket and the witness
   bucket if configured. A key that is narrower than the old one produces
   failures that look like application bugs.
3. **Set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`** and restart the
   application.
4. **Verify before retiring the old key** (details in the checklist below):
   upload an image in the media library; open a gated document if
   `S3_PRIVATE_BUCKET` is set; check the governance witness wrote its next
   checkpoint if that is configured.
5. **Rotate the backup remote separately, if it points at the same account.**
   `rclone config update <remote> …` on the host, then run
   `./scripts/backup.sh all` once by hand and confirm the off-site copy
   succeeds — the script fails the run when the off-site copy fails, so a
   successful manual run is the proof.
6. **Delete the old access key** in the provider console. Do this only after
   step 4 and step 5 both pass; until you do, the leaked credential is still
   live.

### If the key leaked

Reverse the order: delete the compromised key in the provider console
**first**, accept that media uploads and gated-document reads fail until step 3
completes, then create the replacement and restart. A public bucket keeps
serving existing objects throughout, because that path uses no credentials.

---

## Every other secret `runtime.exs` reads

None of these is a boot-time `raise`, so a wrong value degrades a feature
rather than stopping the app — which also means a botched rotation here is
quiet. All of them are plain environment reads: set the new value, restart,
verify the feature.

| Secret | Rotation | Grace period | What to check afterwards |
|---|---|---|---|
| `SMTP_PASSWORD` (with `SMTP_USERNAME`) | Set and restart | Relay-side: create the second credential before removing the first | Send a test mail from `/editor/mail` |
| `OIDC_CLIENT_SECRET` | Set and restart | Most IdPs allow two active secrets — add the new one at the IdP first | Complete one SSO sign-in |
| `MEILI_MASTER_KEY` | Must match the running Meilisearch instance's key — rotate both together | None; search degrades between the two restarts | A search returns results; run `mix kiln.meili.reindex` if the index was rebuilt |
| `KILN_VAPID_PRIVATE_KEY` / `KILN_VAPID_PUBLIC_KEY` | `mix kiln.vapid.gen`, set **both** halves, restart | **None** — rotation invalidates every live push subscription; the push service answers 403 and the row is pruned | Subscribers must re-enable notifications; expect the subscription count to drop to zero |
| `KILN_PROVENANCE_PRIVATE_KEY` (or `KILN_PROVENANCE_KEY_FILE`) | Set the new key; **add the old key's public half** to `KILN_PROVENANCE_RETIRED_KEY_FILES` so previously signed anchors still verify | **Yes** — this is the one secret in the whole system with a real retired-key mechanism | `mix kiln.audit.verify` still verifies anchors signed under the old key; if it starts reporting them unsigned, the retired-key list is wrong |
| `KILN_GOVERNANCE_WITNESS_TOKEN` | Set and restart; rotate at the witness endpoint in the same window | Endpoint-dependent | The next checkpoint posts successfully |
| `UNSPLASH_ACCESS_KEY` | Set and restart | None needed — read-only, no stored state | The Unsplash tab in the media library returns results |
| `ADMIN_PASSWORD` / `EDITOR_PASSWORD` | Seed-only; change the password in the app, not the variable | — | — |
| Webhook endpoint secrets (`KilnCMS.CMS.WebhookEndpoint`) | Per-endpoint, in the database, vault-encrypted — so they move with the rest of the vault when you re-encrypt (*Data at rest*, under `SECRET_KEY_BASE` above). Re-create the endpoint only to mint a *new* secret | Consumer-dependent — a consumer verifying signatures will reject deliveries until it has the new secret | A delivery succeeds; `consecutive_failures` stays at 0 |
| API keys (`kiln_…`) | Mint a new key, hand it to the consumer, then destroy the old row | Overlap is under your control — both keys work until you delete one | The consumer's requests still succeed |

---

## Re-keying the ActivityPub actor

**The federation actor key** is the RSA keypair
`KilnCMS.Federation.SiteFederation` mints on `:enable`. The private half is
vault-encrypted. You do **not** need to re-key for a `SECRET_KEY_BASE`
rotation: the procedure above carries the key across unchanged, and followers
never notice. Re-key when the key itself is compromised, or when it was lost
(a rotation done without the window, or a restore without the old secret).

```bash
mix kiln.federation rekey [--org-id UUID]
```

In the app, use `/editor/federation` → *Re-key*. Both are admin-only.

**What stays and what changes.** The handle, the actor id and the `keyId`
(`<origin>/actor#main-key`) stay the same. Only the PEM behind them changes.
Remote servers store the actor id and deduplicate on it, so keeping it is what
keeps your followers.

**How followers find out.** Re-keying queues an actor `Update` to every
deliverable follower (`KilnCMS.Federation.ActorUpdateWorker`). The update
carries the whole actor document with the new `publicKeyPem`. It is queued
inside the re-key transaction, so it cannot go out before `/actor` serves the
new key. It is signed with the new key, like every delivery after it.

**What followers actually do with it depends on their software:**

- A server that processes actor `Update`s replaces the key straight away.
- A server that behaves like Mastodon first fails to verify the `Update`
  against its cached key. It then re-fetches the actor document, finds the new
  key, and accepts the update. Mastodon rate-limits that re-fetch, so expect a
  short run of failed deliveries in the ledger, which clears on retry.
- A server that does neither keeps the old key. Deliveries to it keep failing
  until it re-fetches the actor for some other reason, and some never will.
  The confirmation on the button says so.

**If the key leaked**, re-key immediately, but do not assume it is contained.
Until each peer has the new key, the old one still signs traffic those peers
accept as yours. Treat it as the incident it is, and tell your followers out of
band if what the old key could sign matters.

---

## Verification checklist

Run this after **any** rotation. The items marked ● are the vault-backed ones:
they cannot be checked by looking at a settings page, because every one of
those pages renders from plaintext columns and keeps looking healthy. Each has
to be exercised.

- [ ] `GET /up` returns 200 (the app booted; no `raise` from `runtime.exs`).
- [ ] Sign in with email + password in a fresh private window.
- [ ] A published page serves publicly, and an image on it renders.
- [ ] Upload a new image in the media library (proves S3 write credentials).
- [ ] ● `mix kiln.vault.reencrypt --dry-run` (in a release,
      `bin/kiln_cms rpc 'KilnCMS.Release.reencrypt_vault(dry_run: true)'`)
      reports `0 unreadable` for every column, and, once a `SECRET_KEY_BASE`
      rotation is finished, `0 would re-encrypt`. This one check covers every
      item below at the storage level. The items below prove that each feature
      actually uses what is stored.
- [ ] ● Send a test mail and check the application log for
      `"DKIM key configured but unresolvable"`. Its **absence** is the pass —
      the mail is delivered either way, so receiving it proves nothing.
      Better still, inspect the received message for a `DKIM-Signature`
      header that verifies.
- [ ] ● Publish a post to each connected social account. "Connected" on
      `/editor/social` is not evidence; a successful post is.
- [ ] ● Exercise billing against the provider (a test call, or whatever the
      settings page offers), rather than reading the page's status.
- [ ] ● If the site federates: `/editor/federation` shows the signing key as
      readable, and a delivery is **accepted** by a remote instance, not
      merely queued.
- [ ] A password reset completes end to end (proves `TOKEN_SIGNING_SECRET`).
- [ ] Oban queues are draining in the console dashboards.
- [ ] A backup runs successfully — by hand, `./scripts/backup.sh all` — and the
      off-site copy lands. This exercises `DATABASE_URL` and the rclone remote
      together.
- [ ] The env snapshot in the password manager matches what is deployed.

## Where the values live

| Deployment | Where to set it | How to apply |
|---|---|---|
| Coolify (this project's production) | Application → Environment variables | *Redeploy* |
| `docker-compose.prod.yml` reference stack | `.env.prod` | `docker compose -f docker-compose.prod.yml --env-file .env.prod up -d` |
| Kubernetes / other orchestrator | Secret → env | Roll the deployment; instances restart one at a time |
| Backup cron | `/etc/cron.d/kiln-backup` (`DATABASE_URL`, `BACKUP_RCLONE_REMOTE`) | Next scheduled run — test it by hand first |
| rclone off-site remote | `rclone.conf` on the host | Next run — test with `./scripts/backup.sh all` |

Keep the password-manager snapshot as the source of truth for all of them:
without it, a restored database is only a partial backup
([`backups.md`](backups.md#what-must-be-backed-up)).
