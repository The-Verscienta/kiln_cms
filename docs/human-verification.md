# Human verification (CAPTCHA) at sign-in, registration and on forms

Kiln can ask for a human-verification check (Cloudflare Turnstile) before a
password sign-in or a registration goes through (#2249). It is **adaptive**:
the check appears only when an attempt looks like part of a guessing run, so
most people never see it. It slows down password guessing and scripted
sign-ups without locking the real owner of an account out.

A site admin can also ask for the check on each public form, so scripted
submissions stop reaching the inbox. See [Public forms](#public-forms).

It is **off** until the operator configures a provider. Per-site keys come
later.

## Who sees a check, and when

With the defaults, a check is shown on:

- **Password sign-in**, once either of these is true:
  - the same email address has been tried **3** times in the last 15 minutes
    (a successful sign-in resets this), or
  - the visitor's IP address has had **5** failed password sign-ins in the
    last 15 minutes (successful sign-ins do not count).

  The next attempt then needs the check. The address counts what was typed,
  whether or not an account exists for it, so the check never tells anyone
  which addresses have accounts.
- **Registration**, once the visitor's IP address has made **2** registration
  attempts in the last hour. The operator can also make registration ask
  **always**, or never.

A check is **never** asked for on these ways in, which stay open as the
accessible alternative for anyone who cannot complete one:

- passkeys,
- a sign-in link by email (magic link),
- password reset,
- the two-factor code prompt (`/sign-in/verify`),
- single sign-on, a site's own or the operator's,
- accepting an invitation.

The headless `POST /api/auth/sign_in` is **not** challenged unless the operator
turns it on with `CHALLENGE_API_SIGN_IN` (see [For API clients](#for-api-clients)).

The setting is the operator's and applies to the whole deployment. A site
admin cannot turn it off or change the thresholds for one site, because an
account is global: the same person signs in on every site they belong to, so a
site with the check off would be the door every other site's accounts are
guessed through. See
[ADR 0020](decisions/0020-human-verification-is-deployment-wide-and-fails-open-only-within-the-sign-in-budget.md).

## What people see

On `/sign-in`, after an attempt that needed a check, the form shows the
widget above the **Sign in** button with one of these lines:

| Line | Meaning |
|---|---|
| Complete the human-verification check below, then sign in again. | The attempt needed a check and had none. The password was not checked. |
| Complete the human-verification check below, then register again. | The same, on `/register`. |
| The human-verification check didn't pass. Complete it again. | The provider refused the token: wrong, expired, already used, or solved on another site. |
| The human-verification check is unavailable right now. Try again in a moment. | The provider could not be reached and this attempt is past the point where Kiln lets sign-ins through without one (see [When the provider is down](#when-the-provider-is-down)). |

None of them says the password was wrong, because it was not checked.

Under the widget, a status line reads "Loading the human-verification check…",
then "Check complete." once it is solved, or "The check expired. Complete it
again." if it sat too long. If the widget cannot load (blocked by a browser
extension or a network filter), it reads "The human-verification check could
not load." and offers another way in. That line names only the ways this site
offers:

- on sign-in, a passkey (always), a sign-in link by email (when magic links are
  enabled), and the site's single sign-on (when it has one), for example "Can't
  complete the check? Use a passkey or email yourself a sign-in link.";
- on registration, "Can't complete the check? Ask a site administrator to
  invite you instead."

Every submit uses up the token, so after any refused attempt the widget is
drawn fresh.

The widget is also shown from the moment the page loads when Kiln already
knows it will be needed: the visitor's address is past its threshold,
registration is set to **always**, or a form submitted without JavaScript was
refused (the page then opens at `/sign-in?challenge=1` or
`/register?challenge=1` with the reason as a message at the top).

The check needs JavaScript. Without it the page shows "This check needs
JavaScript." and the same fallback line.

## Turn on human verification

You need access to the deployment's environment variables and a Cloudflare
account (Turnstile is free). Before you start, list every host your sign-in
pages are served on: `PHX_HOST` (or `TENANT_BASE_HOST` if you set it), each
site's subdomain and custom domain, and, if you set `KILN_CONSOLE_HOST`, that
host and `<slug>.<console host>` for each site.

1. In the Cloudflare dashboard, open **Turnstile** and add a widget. Add every
   host from your list to its hostnames. A host that is missing from the list
   makes the widget fail to load on that host.
2. Copy the widget's **site key** and **secret key**.
3. Set these on every node, then restart:

   ```sh
   CHALLENGE_PROVIDER=turnstile
   CHALLENGE_SITE_KEY=0x4AAAAAAA...
   CHALLENGE_SECRET_KEY=0x4AAAAAAA...
   ```

   To keep the secret out of the environment, mount it as a file and set
   `CHALLENGE_SECRET_KEY_FILE=/run/secrets/challenge_secret` instead. The file
   wins when both are set.
4. Check that the sign-in page now allows Cloudflare's script:

   ```sh
   curl -sI https://cms.example.com/sign-in | grep -i content-security-policy
   ```

   The header's `script-src` and `frame-src` now end with
   `https://challenges.cloudflare.com`. Before step 3 they did not mention it.
5. Sign in with a wrong password four times in a row with the same email
   address. The fourth attempt is refused with "Complete the
   human-verification check below, then sign in again." and the widget
   appears. Solve it and sign in with the right password.

Sign-in and registration are both `adaptive` once all three of provider, site
key and secret are set. To change that:

```sh
CHALLENGE_SIGN_IN=off            # off | adaptive
CHALLENGE_REGISTRATION=always    # off | adaptive | always
```

To switch everything off at once without removing the keys (for example while
Cloudflare has an incident), set `KILN_CHALLENGE_DISABLED=1` and restart:
nothing is required anywhere, no widget is drawn and the page policy goes back
to what it was.

Every variable is listed in
[Environment variables](environment-variables.md#human-verification-2249).

### Thresholds and timeouts

These are not environment variables. Set them in your project's Elixir config
if the defaults do not suit you:

```elixir
config :kiln_cms, KilnCMS.Challenge,
  account_threshold: 3,                  # attempts on one email address
  ip_threshold: 5,                       # failed sign-ins from one IP address
  ip_window: :timer.minutes(15),
  ip_closed_after: 20,                   # see "When the provider is down"; ip_threshold * 4 when unset
  registration_threshold: 2,             # registrations from one IP address
  registration_window: :timer.hours(1),
  deadline: 3_000,                       # ms for the whole verification call
  connect_timeout: 1_000,
  receive_timeout: 2_000,
  outage_window: :timer.seconds(60),
  send_remote_ip: false,                 # send the visitor's IP to Cloudflare
  verify_hostname: true
```

The window for `account_threshold` is the account sign-in budget's window (15
minutes), not `ip_window`.

## When the provider is down

A token Cloudflare **refused** never gets through. A token Cloudflare **could
not check** is different: a timeout (the whole call is given 3 seconds), a
network error, a `5xx` or `429` answer, an answer that is not the expected
JSON, an unreadable secret file, or a secret Cloudflare rejects. Refusing every
sign-in then would let a Cloudflare outage lock everyone out, so Kiln lets the
attempt through to the password check, within two limits:

- **The account's own sign-in budget** (20 attempts per 15 minutes on one
  address) still applies, as it always does.
- **An IP address with 20 failed sign-ins in 15 minutes** (`ip_closed_after`)
  is refused instead, with "The human-verification check is unavailable right
  now." This is the line an attacker cannot ride an outage past.

Registration is let through the same way, bounded by the registration rate
limit (5 a minute per address).

When the widget's own script cannot load, the browser has no token to send. A
missing token is normally a refusal. But for 60 seconds after a node has seen
Cloudflare fail (`outage_window`), that node treats a missing token as the
provider being down too, with the same limits. Otherwise a real visitor whose
widget would not load would be refused, while an attacker sending a junk token
(which also comes back "unavailable") would get through. Each node keeps its
own memory of the outage.

## Privacy

When the widget is shown, the visitor's browser loads a script and an iframe
from `https://challenges.cloudflare.com`, which sees their IP address and
browser details. The script is loaded only when the widget is actually on
screen: a visitor who never crosses a threshold never contacts Cloudflare.
With registration set to `always`, every visitor who opens the registration
form does.

Kiln's server sends Cloudflare the secret key and the token, and the visitor's
IP address only if you set `send_remote_ip: true`.

Name Cloudflare as a processor in your privacy policy, and check whether your
cookie or consent notice needs to mention it. Turnstile is a security measure
on a page the visitor asked for, but whether that needs consent where you
operate is a question for your own advice.

On a form that asks for a check, every visitor who scrolls to the form loads
Cloudflare's script, not only the ones that look suspicious.

Tokens are never logged: `challenge_token`, `cf-turnstile-response` and a
form's `_kiln_challenge` are filtered from request logs and scrubbed from
error reports.

## For API clients

`POST /api/auth/sign_in` is **unchanged** unless the operator sets
`CHALLENGE_API_SIGN_IN=true`. With it off, the endpoint is never challenged,
whatever its counters say. Turn it on only when every client that signs in
through the API can draw a Turnstile widget and send its token. A server-side
integration should use an API key instead.

With it on, a sign-in that needs a check answers `401`:

```json
{
  "errors": [
    {
      "status": "401",
      "code": "challenge_required",
      "detail": "Complete a human-verification challenge.",
      "meta": {
        "provider": "turnstile",
        "site_key": "0x4AAAAAAA...",
        "script_url": "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit",
        "action": "sign_in"
      }
    }
  ]
}
```

Draw the widget with `site_key` and `action`, then send the same request again
with the token:

```sh
curl -s -X POST https://cms.example.com/api/auth/sign_in \
  -H 'content-type: application/json' \
  -d '{"email": "editor@example.com", "password": "…", "challenge_token": "<token>"}'
```

The widget must be drawn on a host the deployment serves (or one listed in
`CHALLENGE_HOSTNAMES`), or Kiln refuses the token. A native app that draws the
widget in a web view needs that view's host added to the Turnstile widget and
to `CHALLENGE_HOSTNAMES`.

The other answers are `401` `challenge_failed` (the token was refused; same
`meta`) and `503` `challenge_unavailable` with `retry-after: 30`. See
[the API guide](api.md#human-verification).

## Public forms

A site admin can make a public form ask every visitor for a check before the
submission is acted on. It is set **per form** and is **off** by default. It
works only on a deployment where the operator has configured a provider (see
[Turn on human verification](#turn-on-human-verification)); sign-in and
registration do not have to be on for it.

Unlike sign-in, the check on a form never turns a visitor away for want of
a token. A submission without a passing check is **held**: it is stored in
**Spam** for an admin to review, and nothing is done with it. The visitor
sees the form's usual success message either way. So a real visitor whose
widget could not load still reaches the inbox, and a script that never ran
the widget gets nothing mailed, forwarded or counted. See
[ADR 0021](decisions/0021-a-form-opts-in-to-human-verification-and-an-unverified-submission-is-held-not-refused.md).

### Ask for a check on a form

You need the **admin** role: the Forms pages are admin-only.

1. Open **Forms** (`/editor/forms`) and click the form's name. The builder
   opens on its **Fields** tab.
2. Click the **General** tab.
3. Tick **Ask visitors to complete a human-verification check**. The line
   under it explains what happens to submissions without a check.

   If the box is greyed out and the line under it reads "Human verification
   isn't available on this deployment. Ask the operator to configure it.",
   no form can ask on this deployment yet: the operator has not set a
   provider, a site key and a secret, has set `CHALLENGE_FORMS=false`, or has
   the kill switch on.
4. Click **Save**. The builder says **Saved.**
5. Open the form in a private browser window, at `/forms/<slug>` on the
   site's host or on a published page that has the form block. Above the
   submit button, a status line reads "Loading the human-verification
   check…", then the widget appears, and "Check complete." once it is solved
   (Turnstile often solves it without a click).
6. Send the form. Back in the builder, open the **Entries** tab: the new
   entry carries a **Verified** badge.

To switch it off, untick the box on the **General** tab and click **Save**.
That works even while verification is unavailable on the deployment, so a
form is never stuck asking.

The widget is drawn wherever the form is: on a delivered page (inside a
columns block or an experiment variant too), on the form's own page
`/forms/<slug>`, and inside the embed iframe (`embed.js`). An embedded form
needs no extra host configuration: the iframe is served from the site's own
host. Previews render no form, and fired artifacts keep their
`data-kiln-form` placeholder, so neither changes.

### What visitors see

The widget sits above the submit button with a status line under it, the
same lines as on sign-in: "Loading the human-verification check…", "Check
complete.", "The check expired. Complete it again." If the visitor clicks
submit before the check has finished, the line reads "Finishing the
human-verification check…" and the form waits up to 8 seconds for it, then
sends anyway.

If the widget cannot load (a script blocker, a network that blocks
`challenges.cloudflare.com`), the line reads "The human-verification check
could not load." and under it: "If the check doesn't load, you can still
send this form — it will be reviewed before it's acted on." Without
JavaScript the form shows "This check needs JavaScript." and the same
sentence.

Cloudflare's script loads only when the widget scrolls into view, so a
visitor who never reaches the form never contacts Cloudflare.

### What happens to each submission

The check runs only after the form's own fields are valid, so a visitor who
mistyped an email address keeps their token for the next try. A submission
that trips the honeypot is discarded before the check, as before.

| The check | What happens | Badge on the **Entries** tab |
|---|---|---|
| Passed | Accepted as usual: notification email, autoresponder, `form.submitted` webhook, experiment conversion | **Verified** |
| No token: the widget did not load, JavaScript was off, or a script never ran it | **Held**: stored in **Spam**; the visitor sees the success message | **Held** ("Held: sent without completing the check.") |
| Solved on a host this deployment does not serve | **Held**, and the log names the host (see [Headless sites](#headless-sites)) | **Held** ("Held: the check was completed on a site this deployment doesn't serve.") |
| Cloudflare could not be asked: a timeout, a network error, a `5xx` or `429` | **Held** | **Held** ("Held: the verification service couldn't be reached.") |
| Refused: wrong, expired, already used, malformed, or drawn for another action | **Not stored.** The form comes back (`422`) with the visitor's values and a fresh widget, and "The human-verification check didn't pass. Complete it again, then send the form." | — |

A held submission is never mailed to `notify_email`, never autoresponded
to, never sent to webhooks and never counted as an experiment conversion.
Hover a badge to see its reason.

There is no grace period when you switch the check on: a visitor who loaded
the page before, in a tab left open or from a cache (a delivered page may be
served for up to six minutes), sends without a token and lands in Spam.

### Review held submissions

1. Open the form's **Entries** tab and click **Spam**. Held entries carry a
   **Held** badge.
2. Read the entry. If it is genuine, click **Mark as reviewed** on it (or
   tick several and use **Mark as reviewed** in the bar above the list).

Marking an entry reviewed does not send its notification or webhook after
the fact: that only ever happens when the submission arrives. Act on it by
hand. Spam, held entries included, is deleted after `spam_retention_days`
(30 days by default), so review it before then.

### Headless sites

A front end that renders a form from `GET /api/forms/<slug>` has to draw the
widget itself. Without a token, everything it sends is held.

1. Ask the operator to add the front end's hostnames to the Turnstile widget
   in Cloudflare and to `CHALLENGE_HOSTNAMES` (see
   [Turn on human verification](#turn-on-human-verification)). Kiln accepts
   a token only when Cloudflare reports a host this deployment serves or one
   listed there.
2. Read the form's schema. Its `challenge` is `null` for a form that does not
   ask, or this:

   ```sh
   curl -s https://cms.example.com/api/forms/contact
   ```

   ```json
   {
     "slug": "contact",
     "name": "Contact",
     "honeypot_field": "website",
     "submit_url": "/forms/contact",
     "challenge": {
       "required": true,
       "provider": "turnstile",
       "site_key": "0x4AAAAAAA...",
       "script_url": "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit",
       "action": "form",
       "field": "_kiln_challenge",
       "without_token": "held"
     },
     "fields": ["…"]
   }
   ```

3. Load `script_url` and render the widget with `site_key` and `action`
   (Cloudflare refuses a token drawn for another action).
4. Send the token as a string under `field`, beside the form's values:

   ```sh
   curl -s -X POST https://cms.example.com/api/forms/contact \
     -H 'content-type: application/json' \
     -d '{"email": "visitor@example.com", "message": "Hello", "_kiln_challenge": "<token>"}'
   ```

   ```json
   {"ok": true, "message": "Thanks, we'll be in touch.", "challenge": "verified"}
   ```

   `cf-turnstile-response`, the name Turnstile's own markup posts, is
   accepted when `_kiln_challenge` is absent or empty.

`challenge` in the answer is `"verified"`, or `"held"` when the submission
was kept for review. A refused token is a `422`:

```json
{
  "ok": false,
  "errors": {"_kiln_challenge": "did not pass the human-verification check"},
  "challenge": "failed"
}
```

Draw a fresh widget and send again: a token is good for one request. A form
that does not ask answers exactly as it did before, with no `challenge`
key. Full reference: [the API guide](api.md#human-verification-on-forms).

If the operator turned `send_remote_ip` on, Kiln sends Cloudflare the
address of whoever made the request, which for a server relaying a browser's
submission is the server's own address.

### Turn forms off for the whole deployment

The operator can stop every form asking without touching any form's
setting:

```sh
CHALLENGE_FORMS=false
```

Restart every node. Every form then renders and submits as if its check
were off, and the **General** tab greys the box out for forms that do not
have it on. Each form's setting is kept, so unsetting the variable and
restarting puts them back. `KILN_CHALLENGE_DISABLED=1`, or a provider that
is not fully configured, has the same effect on forms.

### What can go wrong with forms

| You see | Meaning |
|---|---|
| The **General** tab's box is greyed out with "Human verification isn't available on this deployment." | No provider, site key or secret, `CHALLENGE_FORMS=false`, or the kill switch. Ask the operator. |
| Saving is refused with a message that the check can't be turned on because human verification isn't available on this deployment | The deployment lost its provider (or turned forms off) between loading the tab and saving. Reload the page. |
| Every entry from a headless site is **Held**, and the log says "A form submission's human-verification token was solved on "www.example.org", which this deployment does not serve; it was held as spam. If that is your own site, add it to CHALLENGE_HOSTNAMES." | That host is not in `CHALLENGE_HOSTNAMES`. Logged at most once a minute per node. |
| Every entry from a headless site is **Held** as "sent without completing the check", and nothing is logged | The front end is not sending `_kiln_challenge`. |
| Entries are **Held** as "couldn't be reached" | Kiln could not reach Cloudflare, or the secret is wrong: check `kiln_cms.challenge.verify.stop.count` by `result` ([Observability](observability.md#human-verification)). |
| An embedded form draws no widget, and its entries are all **Held** | The embed's script `/assets/js/challenge_static.js` is missing: a custom asset build that skipped the `kiln_challenge_embed` esbuild profile. |
| A burst of **Held** entries right after switching the check on | Pages loaded (or cached) before the switch; see above. |

## What can go wrong

| You see | Meaning |
|---|---|
| No widget ever appears, and the log says "Human verification is configured (CHALLENGE_PROVIDER=...) but has no site key (CHALLENGE_SITE_KEY); no challenge will be required until it is fixed." | A key is missing. The other version of this line names the secret (`CHALLENGE_SECRET_KEY or CHALLENGE_SECRET_KEY_FILE`). Logged at most once a minute per node. |
| No widget ever appears, and the boot log says "CHALLENGE_PROVIDER is set to an unrecognized value" | `turnstile` is the only accepted value. |
| The widget says "The human-verification check could not load." | The browser could not load Cloudflare's script: an ad or script blocker, a network that blocks `challenges.cloudflare.com`, or this host missing from the Turnstile widget's hostnames. |
| Every solved check is refused with "didn't pass" | Kiln refused the hostname Cloudflare reported. Sign-in pages served on a host Kiln does not know as one of its own (behind a proxy that rewrites the host) need it in `CHALLENGE_HOSTNAMES`. |
| The widget appears, but sign-ins go through whether or not it was solved, and the `fail_open` decision count climbs | Kiln cannot verify tokens, so it is treating Cloudflare as down (see [When the provider is down](#when-the-provider-is-down)). Either the server cannot reach Cloudflare (egress firewall, DNS), or the secret is wrong or unreadable: a wrong secret is not caught at boot. Check `kiln_cms.challenge.verify.stop.count` by `result`: `not_configured` is the secret, `timeout` or `transport` the network. |
| "The human-verification check is unavailable right now." on sign-in | Cloudflare is down and this IP address has 20 or more failed sign-ins in 15 minutes. A passkey or a sign-in link still works. The log says "Human verification is unavailable (...); refusing password sign-ins from client addresses past the failure threshold until the provider answers." at most once a minute per node. |
| An office or school gets the check on every sign-in | Everyone behind one shared IP address (NAT) shares the address count: more than 5 failed sign-ins among them in 15 minutes and everyone there gets the check. See [Things to know](#things-to-know). |

### Trying it on a development machine

Cloudflare publishes test keys that work on any host, including `localhost`.
They are useful for the refusal paths but **cannot produce a passing check in
Kiln**: Cloudflare's test answers report the hostname `example.com` and no
action, and Kiln refuses a token whose action is not the one the widget was
drawn for. To see a check pass end to end, use a real widget on a staging host.

| Site key | Secret key | What you see |
|---|---|---|
| `1x00000000000000000000AA` (passes) | `2x0000000000000000000000000000000AA` | "The human-verification check didn't pass." (Cloudflare refuses the token) |
| `1x00000000000000000000AA` | `3x0000000000000000000000000000000AA` | "didn't pass" (Cloudflare reports the token already spent) |
| `2x00000000000000000000AB` (always blocks) | any | The widget fails and produces no token. Submitting gives "Complete the human-verification check below, then sign in again." |

Set them in your shell before `mix phx.server`; the variables are read in
development (and skipped by the test suite).

## Things to know

- **Shared addresses.** The IP count is per address, so an office, school or
  mobile network behind one address shares it. More than 5 failed sign-ins
  from there in 15 minutes and everyone there sees the check for the rest of
  the window. During a Cloudflare outage, 20 failures from there refuse
  password sign-in for that address; passkeys and sign-in links keep working.
- **API failures count toward the outage limit.** Failed sign-ins on
  `POST /api/auth/sign_in` count toward the 20-failure limit for their IP
  address even when `CHALLENGE_API_SIGN_IN` is off. They do not make the
  browser form ask for a check.
- **A refused attempt costs nothing.** An attempt refused for want of a check
  does not use up the account's sign-in budget, so an attacker who never
  solves one cannot lock the owner out with it.
- **Security log.** A token that did not pass is a **Failed sign-in**
  (`sign_in_failed`) with reason `challenge_failed`; a refusal because the
  provider was down is reason `challenge_unavailable`. Both are sampled like
  wrong passwords. A check merely being asked for records nothing. See
  [The security log](security-events.md).
- **Metrics.** `kiln_cms.challenge.decision.count` and
  `kiln_cms.challenge.verify.stop.*`; see
  [Observability](observability.md#human-verification).
- **Upgrading and rolling back.** Sign-in and registration need no
  migration. The form setting adds a `challenge` column to `forms` and to
  `form_submissions` (`mix ash.migrate`). Nothing changes until a provider is
  configured, and rolling the pin back simply stops asking, on forms too:
  a form that asked for a check acts on every submission again.

See also the [threat model](threat-model.md#human-verification-2249).
