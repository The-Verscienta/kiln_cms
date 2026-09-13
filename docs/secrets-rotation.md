# Secrets rotation runbook

How to replace each secret a KilnCMS deployment depends on, what breaks while
you do it, and what cannot be rotated gracefully today. Written to be followed
during an incident, against a *running* deployment — so every step below is
what the code actually does, not what would be reasonable.

Pairs with [`backups.md`](backups.md) (the env snapshot is part of the backup)
and closes residual risk 12 in [`threat-model.md`](threat-model.md). The
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

**2. Nothing here supports two keys at once.** Not the session cookie, not the
auth tokens, not the object store. Where a graceful transition exists it is
because the *provider* (Postgres, S3) can hold two credentials, never because
Kiln can. Sections that say "hard cutover" mean it.

**3. Two secrets are not interchangeable, even though both sign things.**

| | `SECRET_KEY_BASE` | `TOKEN_SIGNING_SECRET` |
|---|---|---|
| Signs/encrypts | the session cookie, every `Phoenix.Token` (preview links, content-password grants, the collab socket token, the 2FA pending blob) | the AshAuthentication JWTs (session token, bearer tokens, remember-me, magic links, password resets, email confirmations) |
| Also **encrypts data at rest** | **yes** — `KilnCMS.Keys.Vault` | no |
| Rotation is reversible | **no** (see below) | yes |
| Blast radius | everyone signed out **plus** silent, permanent loss of database-stored key material | everyone signed out |

Rotating `SECRET_KEY_BASE` is the single most destructive operation in this
document. Read its section in full before you run it.

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
   the irreversible part.

### The part that is not recoverable

Four things live in the database encrypted under the old `secret_key_base`, and
**there is no re-encryption path in the application** — no mix task, no admin
action, no migration. Rotate the secret and the ciphertext is permanently
unreadable:

| Encrypted column | Resource | What stops working | Recovery |
|---|---|---|---|
| `dkim_private_key_encrypted` | `KilnCMS.Mail.Settings` | Outbound mail is no longer DKIM-signed (direct-delivery mode) | **Supported**: `/editor/mail` → *Rotate key*, then publish the new DNS TXT record |
| `credential_encrypted` | `KilnCMS.Social.Account` | Scheduled social posts stop being published | `/editor/social` — re-connect each account and re-enter its credential |
| `secret_key_encrypted`, `webhook_secret_encrypted` | `KilnCMS.Billing.Settings` | Payments and inbound payment webhooks stop | `/editor/billing` — re-paste the provider API key and the `whsec_…` from the provider dashboard |
| `private_key_encrypted` | `KilnCMS.Federation.SiteFederation` | The site can no longer sign ActivityPub deliveries | **None in-app.** See [What cannot be rotated safely today](#what-cannot-be-rotated-safely-today) |

**None of these announces itself.** The decrypt helpers deliberately return
`nil` rather than raising, so that a rotated or restored deployment stops
*doing* the thing instead of crashing every request that touches it. Nothing
fails at boot and nothing alerts; each one surfaces only at the moment
something tries to use it, and only where you would have to be looking:

- **DKIM** — `KilnCMS.Mail.dkim_config/0` logs
  `"DKIM key configured but unresolvable, sending unsigned"` at `warning` and
  **sends the mail anyway**, on the explicit reasoning that losing a signature
  hurts deliverability while losing the mail loses a password reset. So mail
  keeps flowing, unsigned, and deliverability decays. Worse for your
  purposes: `/editor/mail` still renders the selector, the public key and the
  DNS record, because `dkim_public_key` is a **plaintext** column — the page
  looks completely healthy. **The log line is the only signal.**
- **Social** — the provider adapter turns the `nil` into a recorded post
  failure, `"no usable access token stored"`, per attempt.
- **Federation** — signing fails, and `KilnCMS.Federation.DeliveryWorker`
  records a failed delivery per attempt rather than a signed one.
- **Billing** — the provider call fails at the point of use.

If you rotate this secret, go and check each of the four yourself — see the
verification checklist below.

> Using the `:env` or `:file` key providers
> (`KilnCMS.Keys.Providers.Env`, `KilnCMS.Keys.Providers.File`) instead of the
> `:database` one takes the DKIM and billing keys out of the vault entirely and
> makes them immune to this. If your deployment rotates `SECRET_KEY_BASE` on a
> schedule, move them off the database provider *first*, permanently. The
> federation actor key has no such option — it is vault-only.

### Dual-key transition: not possible

`Plug.Session`'s cookie store derives its keys from the single
`conn.secret_key_base` and has no notion of an old key. `Phoenix.Token` reads
one `secret_key_base` from the endpoint's config. `KilnCMS.Keys.Vault` derives
one AES key. There is nowhere to put a second value.

PR #1445 (open at the time of writing) makes the session cookie's two salts
configurable (`:session_signing_salt` / `:session_encryption_salt`) rather than
literals in `KilnCMSWeb.SessionCookie`. **It does not change this answer.**
The salts are `Application.compile_env/3` reads — compile-time, because the
endpoint's `@session_options` is a module attribute — so they are set in a
downstream `config/prod.exs` and take a **rebuild**, not an env change, and
they still derive a single key from a single `secret_key_base`. What that PR
gives you is a deployment-specific salt instead of one shared by every clone of
this open-source tree; what it does not give you is a grace period. Changing a
salt has exactly the session-invalidating effect that changing
`secret_key_base` has — with none of the vault consequences, since the vault
uses its own fixed salt.

### What breaks

| | Effect |
|---|---|
| Browser sessions | Cookie undecryptable → treated as absent → everyone signed out |
| Open LiveView tabs | Socket fails to re-establish; the page redirects to sign-in |
| API bearer JWTs and API keys | **Unaffected** (signed by `TOKEN_SIGNING_SECRET` / hashed) |
| Remember-me cookies | Unaffected by this secret; still valid, so a "remembered" browser signs straight back in |
| Shared preview links, release-preview links | Dead. Re-issue from the editor |
| Content-password grants | Dead; visitors re-enter the password |
| Two-factor sign-ins in flight | The pending blob is undecryptable — the user restarts sign-in |
| Editor content locks | Unreadable locks are treated as absent, which is the intended fallback |
| DKIM / social / billing / federation key material | **Permanently lost** — see above |

### Procedure

1. **Decide whether you actually need this.** If the goal is "sign everyone
   out", use the SQL above instead. If the goal is "the session cookie's key
   leaked", you need this. If the goal is "a backup was exfiltrated", note
   that the vault ciphertext in that backup is readable only with the *old*
   `SECRET_KEY_BASE` — so rotation here protects the data in a stolen dump,
   at the cost of the live copy.
2. **Take a fresh, verified backup** and record the **old** `SECRET_KEY_BASE`
   alongside it, labelled. Without it that dump is only a partial backup
   ([`backups.md`](backups.md#what-must-be-backed-up)).
3. **Harvest what you are about to lose**, while the old secret is still live:
   - `/editor/mail` — note the current DKIM selector and TXT record.
   - `/editor/social` — note which accounts are connected. The page will keep
     showing them afterwards; the credential behind each is what is lost.
   - `/editor/billing` — have the provider API key and webhook secret to hand
     from the provider's dashboard; you will re-paste both.
   - If the site federates, read [What cannot be rotated safely
     today](#what-cannot-be-rotated-safely-today) **before continuing**.
4. **Generate and set the new value:**
   ```bash
   mix phx.gen.secret
   ```
   Set `SECRET_KEY_BASE`, record it in the password manager, and update the
   env snapshot that backups depend on.
5. **Restart.** Boot `raise`s on an *unset* variable — but not on a blank
   one; see the note under `TOKEN_SIGNING_SECRET` step 4.
6. **Re-establish each vault-backed secret**, in this order:
   1. `/editor/mail` → *Rotate key* → publish the new DNS TXT record. The UI
      says the old record can stay up while signed mail is in transit; leave
      it for a day, then remove it.
   2. Billing settings → re-enter the API key and the webhook signing secret.
   3. Social accounts → re-connect each one.
   4. Federation → see below.
7. **Verify** with the checklist at the end of this document. Do not skip it:
   nothing in step 6's list announces its own failure, and two of the four
   render a healthy-looking settings page either way.

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
| Webhook endpoint secrets (`KilnCMS.CMS.WebhookEndpoint`) | Per-endpoint, in the database, **not** vault-encrypted and **not** affected by any secret above. Re-create the endpoint to mint a new secret | Consumer-dependent — a consumer verifying signatures will reject deliveries until it has the new secret | A delivery succeeds; `consecutive_failures` stays at 0 |
| API keys (`kiln_…`) | Mint a new key, hand it to the consumer, then destroy the old row | Overlap is under your control — both keys work until you delete one | The consumer's requests still succeed |

---

## What cannot be rotated safely today

**The ActivityPub actor key, when federation is enabled.**

`KilnCMS.Federation.SiteFederation` mints the site's RSA keypair exactly once,
in the `:enable` action, and stores the private half vault-encrypted. The
action is an upsert whose `upsert_fields` list is `[:enabled]` and nothing
else, *deliberately* — re-enabling a site that was switched off must keep the
actor its remote followers already cached. The consequence is that there is no
action, no admin UI and no mix task that can give a site a new keypair.

So if `SECRET_KEY_BASE` is rotated on a federating deployment:

- `private_key_pem/1` returns `nil`, the site stops signing, and every outbound
  delivery is refused. It shows up as a run of failed deliveries in
  `KilnCMS.Federation.DeliveryWorker`, not as anything that announces a cause.
- The only way back is a manual database intervention — delete the
  `site_federation` row and re-run `:enable` — which mints a **new** public key
  under the same actor id.
- Remote servers cache an actor's public key. Whether they refetch on a
  signature failure is entirely up to each remote implementation; the source
  comment on `MintIdentity` is explicit that "there is no mechanism for a
  remote server to learn it happened". Expect some followers never to recover.

**Treat federation as a reason not to rotate `SECRET_KEY_BASE`** unless the
leak makes it unavoidable. If you must: disable federation, rotate, re-enable
with a fresh identity, and tell your followers out of band that the actor was
re-keyed.

Closing this gap is a follow-up worth filing: a re-key action for the actor,
and a vault re-encryption task that walks the four encrypted columns with the
old and new `SECRET_KEY_BASE` in hand. Together they would make
`SECRET_KEY_BASE` rotation recoverable rather than destructive, and would let
this section be deleted.

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
- [ ] ● Send a test mail and check the application log for
      `"DKIM key configured but unresolvable"`. Its **absence** is the pass —
      the mail is delivered either way, so receiving it proves nothing.
      Better still, inspect the received message for a `DKIM-Signature`
      header that verifies.
- [ ] ● Publish a post to each connected social account. "Connected" on
      `/editor/social` is not evidence; a successful post is.
- [ ] ● Exercise billing against the provider (a test call, or whatever the
      settings page offers), rather than reading the page's status.
- [ ] ● If the site federates: confirm a delivery is **accepted** by a remote
      instance, not merely queued.
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
