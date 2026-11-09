# Security posture

**Configure → Organization → Security posture** (`/editor/security-posture`)
lists the security settings that matter most, says which are on, and puts
what to fix first at the top (#2252). The page changes nothing: each line
links to the screen that changes the setting, or names the environment
variable that does.

Nothing is stored. The checks run each time the page opens, so the page
shows the settings as they are at that moment.

## Who sees what

- **Site administrators** see **This site**: the lines about their own site.
  These cover which of the site's administrators and editors have two-step
  sign-in, the idle sign-out, the admin allowlist and the breached-password
  policy.
- **Platform administrators** see **This site** for the site they are on,
  and also **This installation**: lines about the whole deployment. These
  cover HTTPS, exposed endpoints, API keys, human verification, the Kiln
  version, and the platform administrators' own two-step sign-in. Most of
  these are set with environment variables, not in the console, so a site
  administrator could not fix them anyway.

Editors and viewers can't open the page, and an administrator of another
site is turned away. The page is gated twice, like the security log: by the
console's administrator check when the page opens, and by the policy on the
report itself (`KilnCMS.Security.PostureReport`). **Run checks again** checks
again that you are still an administrator, because an open page can outlive
a change of role.

## Check your site's settings

You need to be an administrator of the site.

1. In the console, open **Configure**, then **Security posture** under
   **Organization**. You can also type "security posture" or "2fa" in the
   command palette (⌘K).
   You see "Running the checks…" for a moment, then a summary box and the
   **This site** list. A platform administrator also sees **This
   installation** below it.
2. Read the summary box. Its badge is the worst line on the page, followed by
   a sentence ("Something needs fixing.", "Some settings are worth a look." or
   "Every check passed.") and a count of each kind of line, such as
   "1 to fix · 2 to review · 5 OK".
3. Start with the lines marked **Fix now**. They are listed first, then
   **Review**, **Could not run**, **Unknown**, **OK** and **Not applicable**.
4. Open **Details** on a line to see why it matters and, where the check
   names them, who or what it is about: up to ten names, or nine and
   "and N more" when there are more.
5. Select **Fix** to go to the screen that changes the setting. Lines about
   the installation often have no **Fix** link, because the setting is an
   environment variable. Use **Learn more** to open the section of this guide
   that describes the check.
6. After changing a setting, come back and select **Run checks again**. The
   line should move to **OK**.

## Reading the page

Each line has one of these labels:

| Label | Status | Meaning |
| --- | --- | --- |
| Fix now | `fail` | Something is exposed. Fix these first. |
| Review | `warn` | Worth changing, but nothing is exposed. |
| Could not run | `error` | The check crashed, took too long, gave an answer the page can't show, or the server had no room to run it. The line says which. |
| Unknown | `unknown` | The check couldn't read the setting (a database error, say), or is still waiting for an answer. |
| OK | `pass` | The setting is on. |
| Not applicable | `n_a` | The check doesn't apply here: a production-only setting on a development build, or an optional feature that isn't in use. |

There is no score. The badge at the top is the worst line on the page:

- **Fix now** if any line is `fail`;
- otherwise **Review** if any line is `warn`, `unknown` or `error`;
- otherwise **OK**. A page of only **Not applicable** lines is **OK** too.

### Unknown and "could not run" are not OK

A check that could not tell answers **Unknown**, and a check that broke is
**Could not run**. Both count as a warning in the summary, never as a pass.
A page that turns green because a check failed to run would be worse than no
page, so a setting the page cannot see is reported as unseen.

The site's settings are read through the same functions that enforce them,
so the page cannot say a setting is on when enforcement ignores it. Where
enforcement treats an unreadable setting as "off" (the idle timeout) or as
"warn" (the breached-password policy) so that sign-in keeps working, the check
uses a version of the same read that can say "I could not read it", and shows
**Unknown** instead.

## The checks

Each check has an id, used in logs, telemetry and by plugins. A check with no
**Fix** link is set in the environment.

| Check (id) | Shown in | Reads | Fix now | Review | Unknown, Not applicable | Fix |
| --- | --- | --- | --- | --- | --- | --- |
| Two-step sign-in for administrators and editors (`core.second_factor`) | This site | The site's administrators and editors, not counting platform administrators, and whether each has an authenticator app | An administrator has none | Only editors have none | N/A: the site has no administrators or editors of its own | **Your settings** (`/editor/settings`), by each person |
| Idle sign-out (`core.idle_timeout`) | This site | The site's session policy | | Neither timeout is set | Unknown: the policy can't be read | **Sign-in & access → Sessions** (`/editor/sessions`) |
| Admin allowlist (`core.admin_allowlist`) | This site | The site's allowlist, and `KILN_ADMIN_ALLOWLIST_DISABLED` | A list is saved, but the switch turns it off | | N/A: no list. Unknown: the list can't be read | **Sign-in & access → Admin allowlist** (`/editor/admin-allowlist`) |
| Breached passwords (`core.breached_passwords`) | This site | The policy for administrators: the site's choice, else `BREACHED_PASSWORD_POLICY`, and `BREACHED_PASSWORD_CHECK` | Off, or `BREACHED_PASSWORD_CHECK=false` | Warn | Unknown: the site's policy can't be read | **Sign-in & access → Password policy** (`/editor/password-policy`) |
| Two-step sign-in for platform administrators (`core.operator_second_factor`) | This installation | Every platform administrator and whether each has an authenticator app | A platform administrator has none | | N/A: no platform administrators | **Your settings** (`/editor/settings`), by each person |
| HTTPS and secure cookies (`core.transport`) | This installation | What the running release was built with: `force_ssl`, HSTS, the public URL's scheme, the session cookie's `Secure` flag | Any of the four is off | | N/A: not a production build | Environment |
| Exposed endpoints (`core.exposed_endpoints`) | This installation | The metrics listener's settings, `API_DOCS_ENABLED`, `GRAPHQL_INTROSPECTION_ENABLED` | Metrics on every interface with no token | The API explorer or GraphQL introspection is on | | Environment |
| API keys (`core.api_keys`) | This installation | Every valid API key on the installation and its owner | A read-write key owned by an administrator | A key over 180 days old, or expiring more than a year from now | N/A: no valid keys | **Operations → API keys** (`/editor/api-keys`) |
| Human verification (`core.human_verification`) | This installation | The human-verification settings | | No usable provider, both checks off, or `KILN_CHALLENGE_DISABLED` | | Environment |
| Kiln version (`core.release`) | This installation | The cached answer of the update check | | A newer release exists | Unknown: no answer yet, or the update check failed. N/A: `KILN_UPDATE_CHECK=false` | **Operations → System** (`/editor/system`) |

Every check is **OK** when none of its other conditions hold. A check that
reads people or keys from the database (the two two-step sign-in checks and
API keys) shows **Could not run** rather than **Unknown** if that read fails.

<!-- The headings below are linked from each check's "Learn more"
     (`KilnCMS.Security.Posture.docs_url/1`). Renaming one breaks that link. -->

### Two-step sign-in

Two lines: one per site, for that site's administrators and editors, and one
for the platform administrators, under **This installation**.

- **On a site.** Any administrator without an authenticator app is **Fix
  now**; editors without one are **Review**. People are counted by the role
  they have on the site now: someone who is a viewer globally but an
  administrator of this site counts as an administrator. Erased accounts and
  registrations that are waiting or rejected are not counted.
- **Platform administrators** are counted once, under **This installation**,
  and never on a site's list, even though they can administer every site.
  Someone with a temporary administrator grant is counted while the grant
  lasts. Any platform administrator without an authenticator app is **Fix
  now**.

A passkey doesn't count. It is another way to sign in, and it does not
protect the same account's password sign-in: someone with the password can
still sign in without the passkey. The fix is for each person to turn on
**Two-factor authentication** under **Your settings**
([how it works](two-factor-auth.md)). Open **Details** to see who is missing
it, by email address.

### Idle sign-out

Whether the site signs idle browsers out (**Sign-in & access → Sessions**,
[guide](account-administration.md#sign-people-out-when-idle)). A general or an
administrators-only timeout is **OK**; neither, or no saved setting, is
**Review**.

### Admin allowlist

Whether only listed networks can reach the console and sign-in (**Sign-in &
access → Admin allowlist**, [guide](admin-allowlist.md)). The list is
optional, so no list is **Not applicable**, not a warning.

A saved list is **Fix now** while `KILN_ADMIN_ALLOWLIST_DISABLED` is on: the
console is open to every network, though the list is still saved. The check
reads the switch on the server that runs the report, so on a deployment
where the nodes disagree, the line can differ from one page load to the next.

### Breached passwords

What happens when an administrator picks a password that has been in a breach
(**Sign-in & access → Password policy**,
[guide](account-administration.md#breached-passwords)). The check reads the
policy the way it is enforced for an administrator: the site's own choice, or
the operator's default (`BREACHED_PASSWORD_POLICY`) when the site has made
none. Only **Block** is **OK**; **Warn** is **Review**; **Off**, or
`BREACHED_PASSWORD_CHECK=false` for the installation, is **Fix now**.

### HTTPS and secure cookies

On a production build, all four must hold, or the line is **Fix now**:

- plain HTTP is redirected to HTTPS (`force_ssl`);
- browsers are told to insist on HTTPS (HSTS, on with `force_ssl` unless set
  to `false`);
- the public URL is `https`;
- the session cookie is marked `Secure`.

Open **Details** to see which one is off. The check reads what the running
release was built with, not the config files. On any other build the line is
**Not applicable**, because development and test serve plain HTTP on purpose.

### Exposed endpoints

- The metrics listener on every interface (`KILN_METRICS_BIND=all`) with no
  `KILN_METRICS_TOKEN` (a blank token counts as none) is **Fix now**: anyone
  who can reach the port can read it.
- The API explorer and spec (`API_DOCS_ENABLED`) or GraphQL introspection
  (`GRAPHQL_INTROSPECTION_ENABLED`) being on is **Review**. Both are off by
  default in production; turn them on only for a deployment that publishes
  its API ([variables](environment-variables.md#api-documentation-567)).

### API keys

Every key on the installation that is valid now (not revoked, not expired):

- A **read-write** key whose owner is an administrator anywhere (a platform
  administrator, including by a temporary grant, or an active administrator
  of any site) is **Fix now**. Such a key can write anything its owner can,
  with no password or second factor.
- A key created more than 180 days ago, or expiring more than 365 days from
  now, is **Review**. Keys don't record when they were last used yet, so age
  stands in for "unused".

**Details** names each key and its owner's email address. Revoke or replace
keys under **Operations → API keys**.

### Human verification

Whether suspicious sign-ins and registrations can be asked to prove they're
human ([guide](human-verification.md)). A usable provider with a check on for
sign-in or registration is **OK**. Everything else is **Review**: no provider
(`CHALLENGE_PROVIDER` unset), a provider named but not usable (an unknown id
or a missing key), both checks switched off, or the kill switch
`KILN_CHALLENGE_DISABLED`. This check never shows **Fix now**: human
verification is optional.

### Kiln version

Whether a newer Kiln release exists, from the same check as **Operations →
System**. A newer release is **Review**; the newest is **OK**;
`KILN_UPDATE_CHECK=false` is **Not applicable**; a failed check is
**Unknown** ("Could not tell whether a newer release exists. Open System to
check.").

The check never waits on the network. It reads only the answer the update
check has cached. When nothing is cached (after a restart, a day after the
last answer, or 15 minutes after a failed check), it starts one update check in the background and shows
**Unknown**: "Checking for updates; reopen this page in a minute." Reopen the
page or select **Run checks again** after a minute to see the answer.

This makes Security posture the second place, after **System**, that can
send the update request: the same unauthenticated request to kilncms.dev,
falling back to GitHub, carrying nothing that identifies the installation
([what is sent](data-flows.md)). It is sent only when a platform
administrator opens the page, and at most one runs at a time on each server.
`KILN_UPDATE_CHECK=false` turns it off on both pages.

## How the checks are run

All the checks run at once, each in its own process with its own deadline,
so the page waits at most as long as the slowest deadline.

- **Each check has a deadline.** It is one second unless the check asks for
  more, and never less than 0.1 seconds or more than five. The core's
  second-factor and API key checks take three. A check still running at its
  deadline is stopped and shows "This check could not run: it took too
  long."
- **A broken check is one line, not a broken page.** A check that raises,
  throws or exits shows "This check could not run: it failed."; one that
  answers something that isn't a result shows "...it gave an answer the page
  can't show." The error is written to the server log ("Security posture
  check `<id>` (`<module>`) failed with ..."), never shown on the page.
- **The deadline holds without the page.** Each check's process stops itself
  at its deadline, even if the page that started it has been closed.
- **Work a check hands off is not stopped.** If a check starts another
  process or calls a long-running server, that work is not part of the
  check's process and is not stopped at the deadline.
- **Room is limited.** Checks run under their own task supervisor, at most 50
  at once on each server, so slow checks cannot crowd out the rest of Kiln.
  A check that finds no room shows "This check could not run: the server was
  busy."

Each check emits `[:kiln_cms, :security_posture, :check, :stop]` (measurement
`duration` in native units; metadata `id`, `status`, `error`), and a check
that crashed also emits `[:kiln_cms, :security_posture, :check, :exception]`
(metadata `id`, `kind`). No metric is defined for them by default.

## Running the checks again

**Run checks again** reruns every check. It is limited, because each run
starts one process per check:

- **On one page**, it is refused while the checks are still running ("The
  checks are already running.") and for five seconds after the last time you
  selected it ("The checks just ran. Try again in a few seconds.").
- **For one site**, at most three reports run at once on each server, counting
  every open page and every reload. A fourth shows "The checks are already
  running for this site. Try again in a moment." Other sites are not affected.

## What it does not check yet

- Whether two-factor sign-in is *required* for administrators.
- Plugins with advisories or integrity problems, and security notices that
  apply to the installed versions.
- When an API key was last used.

There is no machine-readable (JSON) output yet: the page is the only way to
see the report.

## When something goes wrong

| What you see | What it means |
| --- | --- |
| "You don't have permission to see this site's security posture." | You are not an administrator of this site, or no longer are. Ask an administrator of the site. |
| "The checks could not be run. Try again in a moment." | The report as a whole failed. The server log has the reason. |
| "The checks are already running for this site. Try again in a moment." | Three reports of this site are already running on this server. Wait for one to finish. |
| A line says "This check could not run: ..." | That one check failed; the rest of the page is current. See [How the checks are run](#how-the-checks-are-run). |
| Kiln version says "Checking for updates; reopen this page in a minute." | Nothing was cached yet, and the update check has started in the background. |
| A plugin's line is missing | The plugin's check doesn't meet the contract, or uses an id already taken. The server log says "Security posture: ... is not a usable check and is skipped", "... takes the reserved id ...", or "... repeats the id ..."; `mix kiln.plugins.doctor` reports the same before deploy. |

## Add a check from a plugin

A plugin can add its own lines to the page with `security_checks/0` and the
`Kiln.Security.Check` contract, new in `kiln_plugin` 1.4. It works from a
plugin shipped as a Mix dependency as well as from an overlay. The lines show
"From the *plugin name* plugin" under their summary.

1. Require the SDK version that has the contract, in the plugin's `mix.exs`:

   ```elixir
   {:kiln_plugin, "~> 1.4"}
   ```

2. Write the check. A check that reads the plugin's own configuration:

   ```elixir
   defmodule MyPlugin.WebhookSecretCheck do
     use Kiln.Security.Check

     @impl Kiln.Security.Check
     def id, do: "my_plugin.webhook_secret"

     @impl Kiln.Security.Check
     def title, do: "Webhook signing secret"

     @impl Kiln.Security.Check
     def description, do: "An unsigned webhook can be sent by anyone who knows its URL."

     @impl Kiln.Security.Check
     def scope, do: :deployment

     @impl Kiln.Security.Check
     def run(_context) do
       if Application.get_env(:my_plugin, :webhook_secret) in [nil, ""],
         do: fail("Incoming webhooks are not signed.", facts: %{signed: false}),
         else: pass("Incoming webhooks are signed.", facts: %{signed: true})
     end
   end
   ```

3. List it in the plugin's entry module:

   ```elixir
   @impl Kiln.Plugin
   def security_checks, do: [MyPlugin.WebhookSecretCheck]
   ```

4. Test it in the plugin. `conformance/1` checks every callback except
   `run/1`, and `run/1` can be called with a context you build:

   ```elixir
   assert Kiln.Security.Check.conformance(MyPlugin.WebhookSecretCheck) == :ok

   context = %Kiln.Security.Check.Context{build_env: :prod, now: DateTime.utc_now()}

   assert %Kiln.Security.Check.Result{status: :fail} =
            MyPlugin.WebhookSecretCheck.run(context)
   ```

5. In the site, run `mix kiln.plugins.doctor`. It reports a check that fails
   `conformance/1`, an id under `core.`, and an id that two modules share.
   `mix kiln.plugins.list` counts each plugin's security checks.
6. Deploy, and open **Security posture**. A `:deployment` check appears under
   **This installation**, for platform administrators; a `:site` check under
   **This site**.

### The rules a check follows

**Callbacks.** `id/0`, `title/0`, `scope/0` and `run/1` are required;
`description/0` and `timeout/0` are optional. The core calls `id/0`,
`title/0`, `scope/0`, `description/0` and `timeout/0` every time the page
runs its checks, before any check starts and outside every deadline, so a
slow one holds up the whole page. They must return constants and must not
block. Only `run/1` runs under the
deadline.

**Ids.** Lowercase, dotted, at most 64 characters: a letter, then letters,
digits or `_`, then at least one `.segment` (`my_plugin.webhook_secret`). Use
the plugin's name as the first segment. Ids that start with `core.` belong to
Kiln, and a plugin check that uses one is never shown. If two plugins'
checks share an id, the one from the plugin registered first is shown and
the other is skipped.

**Scope.** `:site` when the answer depends on the site being looked at (its
settings, its people). The check gets the site's id in `context.org_id` and
is shown to that site's administrators. `:deployment` when it is about the
whole installation. `context.org_id` is then `nil`, and the line is shown
only to platform administrators. If the answer would tell one site's
administrators about another site, it is a `:deployment` check.

**No actor.** The context carries the site, the build environment
(`build_env`), the time the report started (`now`; use it instead of the
clock, so tests can move it) and the reader's locale. It does not carry the
person reading the page. A check is not run as anyone: it reads what it needs
itself, and must reveal no more than its summary, details and facts say.

**Answers.** Build the result with `pass/2`, `warn/2`, `fail/2`, `unknown/2`
or `n_a/2`. Answer `unknown/2` when the check cannot tell, never `pass/2`.
Each takes a one-sentence summary and these options. The core trims a result
to these limits rather than refusing it:

| Field | Limit | What the core does past it |
| --- | --- | --- |
| summary | 300 characters | Cut, with "…" |
| `:details` | 10 strings of up to 300 characters each, shown only on the page | Strings past ten dropped, long ones cut, non-strings dropped |
| `:fix_path` | A console path: starts with `/editor/`, with no `//`, backslash, whitespace or control characters, at most 300 characters | Dropped: no **Fix** link |
| `:docs_url` | An `https://` URL with a host, no user or password, none of `"`, `'`, `<`, `>`, `\` or whitespace, at most 500 characters | Dropped: no **Learn more** link |
| `:facts` | 20 entries; keys are strings or atoms of up to 64 characters; values are `nil`, a boolean, a number or a string of up to 300 characters | Other values dropped; long strings cut; the first 20 by key kept |

A `title/0` of up to 120 characters and a `description/0` of up to 1000 are
checked by `conformance/1`; longer ones make the check unusable.

**Facts never carry a secret.** No token, key, password or person's address
in `facts`. They are machine-readable values, and a later release may
publish them to monitoring tools. Names and addresses belong in `details`,
which only the page shows, and only when the reader needs them to act.

**Locale.** The page shows the summary and details exactly as written. To
translate them, use `context.locale` with the plugin's own Gettext backend.
The core sets the locale only for its own backend:

```elixir
def run(%Kiln.Security.Check.Context{locale: locale}) do
  Gettext.with_locale(MyPlugin.Gettext, locale, fn ->
    pass(gettext("Incoming webhooks are signed."))
  end)
end
```

**Deadline.** `timeout/0` is in milliseconds: 1000 if the check does not
define it, and held to 100–5000. Keep the work inside `run/1`, and give any
call it makes its own timeout shorter than the deadline. A `Task` it starts,
or a message it sends to a `GenServer`, is not stopped when the check is.

**Compatibility.** A plugin built against `kiln_plugin` older than 1.4 has no
`security_checks/0` and adds no lines. `use Kiln.Plugin` defines it as `[]`.
Within 1.x the contract's rules only loosen: a check that conforms now keeps
conforming.
