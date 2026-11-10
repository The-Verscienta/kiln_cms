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
  version, the installed plugins, and the platform administrators' own
  two-step sign-in. Most of
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

## Check your installed plugins

**Operations → System** shows each plugin built into this release with a
badge saying whether it still checks out against hex.pm and the security
notices feed (#2244). The **Installed plugins** line on this page is the
summary of the same check. You need to be a platform administrator.

1. In the console, open **Operations**, then **System**
   (`/editor/system`), and scroll to **Plugins**.
   Under the introduction you see "Checking plugins..." the first time the
   page asks, then "Checked 2026-11-09 14:02 UTC." (the time of the answer,
   in UTC). Each plugin's name now has a badge.
2. Read each badge:

   | Badge | Meaning | What to do |
   | --- | --- | --- |
   | **OK** | Hex publishes the checksum this build recorded, no security notice covers the installed version, Hex hasn't retired it, it had a release on Hex in the last 24 months, and its `kiln_plugin` requirement accepts this Kiln's SDK. | Nothing. |
   | **Changed on Hex since this build** (red) | The checksum hex.pm publishes for this version differs from the one in the lockfile this release was built from. The plugin row shows both, shortened: "Locked …, Hex has …". | Find out which cause applies before you rebuild: the release was replaced on Hex (or Hex's record was tampered with), your build fetched from a Hex mirror or an offline cache, or someone edited the lockfile by hand. Check the package's page on hex.pm. The running code is the code you built; this says Hex's record no longer matches it. |
   | **Security notice** (red for high, critical or unrated; amber for low or medium) | A notice covers the installed version. Each one is listed as an **Advisory *id*** link. | Read the advisory, update the plugin to a fixed version (`mix deps.update <package>`), rebuild and redeploy. |
   | **Not on Hex** (amber) | Hex has no such package or version. | Check whether it was removed from Hex, or whether the lockfile names a version that was never published there. |
   | **Retired** (red if retired for security, otherwise amber) | Hex marks the installed release as retired, and the reason is given ("security", "deprecated", "invalid", "renamed" or "other"). | Move to a release Hex hasn't retired, or to the plugin that replaced it. |
   | **No recent release** (amber) | The package has had no release on Hex for 24 months (`KILN_PLUGIN_STALE_MONTHS`). The newest release counts, not the installed one. | Decide whether you still trust an unmaintained plugin. Nothing here is broken yet. |
   | **Incompatible with this Kiln** (amber) | The plugin's `kiln_plugin` requirement doesn't accept the SDK this Kiln bundles, or can't be read. | Update the plugin. `mix kiln.plugins.doctor` reports the same problem before a deploy. |
   | **Can't verify** | A git or path plugin, or one from a private Hex repository. Hex has no checksum to compare. Its `kiln_plugin` requirement, and the notices feed when it is on, were checked and found nothing. | Nothing to fix. Review the plugin's source yourself, as for any code you build in. |
   | **Built from this project** | A plugin in `projects/`, compiled with the core. Nothing upstream to compare with. | Nothing. |
   | **Unknown** | Hex or the notices feed did not answer, or plugin checks are turned off (a Hex plugin can't be compared then). Unknown is never OK. | See the line under the introduction, and the table below. |

   Under the badge, each problem has its own line, in the same words as the
   **Installed plugins** line here. A Hex plugin also shows "Latest on Hex:
   *version*".
3. To ask again, select **Check plugins now**. The badges show nothing
   while it runs, then the new answer. The button is there only when the
   checks are on and some plugin comes from Hex, git or a path. Hex and the
   notices feed are asked at most once a minute: a second press within the
   minute shows the answer already cached.

The answer is cached on each server for 24 hours (15 minutes after a request
failed) and is lost when the server restarts, so a new deploy asks again the
first time a platform administrator opens System or this page.

### From the command line

`mix kiln.plugins.list --health` runs the same check from the project and
prints each plugin's status under its line. Without `--health` the list
makes no request. With it, the task asks hex.pm and the notices feed even
when the server's check is turned off, and says so first. It always asks
afresh and doesn't touch a server's cache. `KILN_SECURITY_NOTICES_URL=false`
keeps the notices feed out of it, as on the server.

For a project with two Hex plugins, one of them unmaintained:

```console
$ mix kiln.plugins.list --health
2 plugin(s) installed:

* ratings v0.3.1 — Ratings.Plugin
    contributes: 1 block
    health: ok
* legacy_embeds v1.0.2 — LegacyEmbeds.Plugin
    contributes: 1 block
    health: warning
      - no release on Hex since 2023-05-02

Checked against hex.pm and the security notices feed.
```

The other statuses print as `FAIL`, `unknown (not ok: a source did not
answer)`, `can't verify (git or path: no registry checksum)` and `built from
this project`.

### Turn the check off, or keep it off kilncms.dev

The check asks hex.pm about each Hex plugin, which tells hex.pm that plugin's
package name and version from your server's address. To make no request at
all:

```bash
KILN_PLUGIN_HEALTH_CHECK=false
```

`KILN_UPDATE_CHECK=false` turns it off too, unless `KILN_PLUGIN_HEALTH_CHECK`
is set. To keep the Hex comparison but not ask kilncms.dev for notices, set
`KILN_SECURITY_NOTICES_URL=false`. A fork or mirror (`KILN_UPDATE_REPO`,
`KILN_UPDATE_RELEASES_URL`, or `KILN_UPDATE_FEED_URL=false`) doesn't ask
kilncms.dev unless `KILN_SECURITY_NOTICES_URL` names it. See
[the variables](environment-variables.md#plugin-health-check-2244).

`KILN_PLUGIN_HEALTH_CHECK=false` stops the hex.pm requests, but not the
notices feed: [Security notices for Kiln](#security-notices-for-kiln) reads
the same feed for the core while `KILN_UPDATE_CHECK` is on. To ask no feed
at all, set `KILN_SECURITY_NOTICES_URL=false` or `KILN_UPDATE_CHECK=false`
(with `KILN_PLUGIN_HEALTH_CHECK` unset).

### When the plugin check goes wrong

| What you see | What it means |
| --- | --- |
| "Hex or the notices feed could not be reached; these results are unknown, not OK." | A request failed or the check did not finish in 90 seconds. The plugins it concerns show **Unknown**. Kiln asks again on the first visit after 15 minutes, or when you select **Check plugins now**. A server that can't reach `hex.pm` or `kilncms.dev` through its firewall always ends here. |
| "Plugin checks are off." | `KILN_PLUGIN_HEALTH_CHECK=false`, or `KILN_UPDATE_CHECK=false` with `KILN_PLUGIN_HEALTH_CHECK` unset. Hex plugins show **Unknown**; there is no **Check plugins now**. |
| "No dependency plugins to check." | Every plugin is built from this project. No request is made. |
| "The security notices feed is turned off; only Hex's own advisories were checked." | `KILN_SECURITY_NOTICES_URL=false`, or a fork or mirror that doesn't name a notices feed. |
| "You need admin access to do that." | You selected **Check plugins now** after losing platform administrator rights (a temporary grant that expired, say). Nothing was asked. |
| Every Hex, git and path plugin is **Unknown**, and the log says "KILN_SECURITY_NOTICES_URL is not an absolute http(s) URL; security notices are unknown." | Fix the value: it must be `http://` or `https://` with a host. The same value makes [Security notices for Kiln](#security-notices-for-kiln) **Unknown** too. |
| Every plugin is **Unknown** with `KILN_SECURITY_NOTICES_URL` pointing at an internal mirror | Requests go through Kiln's outbound guard, which refuses private and loopback addresses. Serve the mirror on a public address, or set `KILN_SECURITY_NOTICES_URL=false`. |
| The log says "Plugin health check failed for: *name* (*reason*)" | A check that just asked Hex found a plugin that fails. Open System for the details. Kiln sends no alert for it. |

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
| Security notices for Kiln (`core.security_notices`) | This installation | The cached security notices feed, against the running Kiln's version | A notice of any severity covers this version | | Unknown: no answer yet, the feed didn't answer or its URL is invalid, a notice names Kiln but can't be matched, or this build's version can't be read. N/A: `KILN_UPDATE_CHECK=false`, or the notices feed is off | **Operations → System** (`/editor/system`) |
| Installed plugins (`core.plugin_health`) | This installation | The cached answer of the plugin health check: each plugin against hex.pm and the security notices feed | A plugin's package changed on Hex since this build, a high, critical or unrated security notice covers it, or Hex retired it for security | A low or medium notice, not on Hex, retired for another reason, no release on Hex for 24 months, or a `kiln_plugin` requirement this Kiln doesn't meet | Unknown: no answer yet, or Hex or the notices feed didn't answer. N/A: no plugin from Hex, git or a path, or plugin checks are off | **Operations → System** (`/editor/system`) |

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

### Security notices for Kiln

Whether a security notice kilncms.dev publishes covers the Kiln version this
server runs (#2522). **Kiln version** above only says a newer release exists,
which is **Review**; this line is **Fix now** when the release you run has a
known hole.

| Line | When |
| --- | --- |
| **Fix now** | A notice covers this version, at any severity: "A security notice covers Kiln 1.8.0." **Details** lists each one: "GHSA-xxxx-xxxx-xxxx (high): fixed in 1.8.1.", or "... no fixed release is listed yet." |
| **Unknown** | A notice names Kiln but can't be placed against this version (see below), the feed didn't answer ("Could not reach the security notices feed. Open System to check."), `KILN_SECURITY_NOTICES_URL` isn't a usable URL, or nothing is cached yet ("Checking security notices; reopen this page in a minute."). |
| **OK** | "No published security notice covers Kiln 1.8.0." |
| **Not applicable** | `KILN_UPDATE_CHECK=false` ("Security notice checks are turned off (KILN_UPDATE_CHECK=false)."), even if the plugin check has the feed cached; or the feed is off: `KILN_SECURITY_NOTICES_URL=false`, or a fork or mirror of the update feed that names no notices feed. |

Plugin notices work differently: a low or medium notice on a plugin is
**Review**. A notice on the running core is a known way into the whole
installation, whatever its rating, so here every severity is **Fix now**.

**How a notice is matched.** A notice concerns Kiln when one of its packages
is `kiln_cms`. The publishing script writes that name for every advisory
vulnerability that names no package, including one listed beside a named
plugin. Then:

- **Only the affected range decides.** A notice covers this version when the
  version falls inside its `affected_versions`, release candidates included.
  `patched_versions` is shown ("fixed in 1.8.1") and never consulted: the
  publisher leaves out a line that has no fix yet, so reading it as a verdict
  would clear an unfixed newer line, or a version inside a range that
  reopened after a fix. Plugin notices follow the same rule.
- **An unreadable range is Unknown**: empty, malformed, or the word
  `unknown`. Details: "*id*: its affected versions can't be read."
- **A notice naming several packages is Unknown when this version is inside
  its ranges.** The ranges of all its packages are published joined, with no
  record of whose is whose, so the one that matched may be a plugin's.
  Details: "*id* names several packages; whether it covers Kiln can't be
  told." Outside every range, the notice doesn't concern this version.
- **A version that can't be read is Unknown** ("Could not read this Kiln's
  version."), but only while some notice names Kiln. A build without a
  version reports `0.0.0`, which counts as unreadable.

**What it can't tell you.**

- **A build from `main` between releases can read as affected after the fix
  merged.** Kiln's version is raised to the next release only when that
  release is cut, so a build from `main` that already has the fix still
  reports the affected version. Run a tagged release, or check the advisory
  against your commit.
- **Notices that name `kiln_plugin` match nothing.** The plugin SDK is built
  into Kiln, but neither this line nor **Installed plugins** reads its
  version.
- **A loose range errs on the strict side.** A notice whose affected range
  was never narrowed to exclude the fixed releases flags them as covered.

**What is sent, and when.** One request (up to five pages) to the security
notices feed, which carries nothing about this installation. It is the same
fetch and the same cache as the [Installed plugins](#installed-plugins)
line, so the two lines make at most one request between them, and the feed
is now asked even when no plugin is installed. Like the Kiln version line,
this one never waits on the network: on a cold cache (after a restart, a day
after the last answer, or 15 minutes after a failed request) it starts one
background request and shows **Unknown**. System asks too, when a platform
administrator opens it with nothing cached, and when they select **Check
now** ([data flows](data-flows.md)).

When a fresh answer shows the running Kiln covered, the server log says, once
per request: "Kiln 1.8.0 is covered by security notice(s) GHSA-xxxx-xxxx-xxxx;
update it (System, Updates)." It names only the notice ids, and it is
written only while `KILN_UPDATE_CHECK` is on.

#### Check whether a notice covers your Kiln

You need to be a platform administrator.

1. In the console, open **Operations**, then **System** (`/editor/system`).
   The **Updates** card has a **Security notices** line under the update
   status. It says "Checking security notices..." the first time, then the
   same sentence the Security posture line shows. The line is missing when
   `KILN_UPDATE_CHECK=false`.
2. Read it. A covered version has a red **Security notice** badge, one line
   per notice with the release that fixes it, and an **Advisory *id*** link
   to each notice. A notice that can't be matched has an **Unknown** badge.
   A clean version has no badge.
3. To ask past the cache, select **Check now**. It checks for updates and
   asks the notices feed again; a second press within a minute shows the
   answer already cached.
4. If a notice covers you, read the advisory and update Kiln to the fixed
   release ([Updating a project to a release](releasing.md#updating-a-project-to-a-release)).
   After the deploy, the line reads "No published security notice covers
   Kiln *version*."

| What you see | What it means |
| --- | --- |
| "Couldn't reach the security notices feed. This says nothing about whether a notice covers this version." | The request failed or took longer than a minute. The failure is kept for 15 minutes; select **Check now** to ask sooner. A server that can't reach `kilncms.dev` through its firewall always ends here. |
| "KILN_SECURITY_NOTICES_URL is not an absolute http(s) URL, so no notice was checked." | Fix the value: it must be `http://` or `https://` with a host. |
| "The security notices feed is turned off (KILN_SECURITY_NOTICES_URL=false, or a fork or mirror of the update feed)." | Nothing is asked. A fork that publishes its own notices sets `KILN_SECURITY_NOTICES_URL` to its site. |
| "You need admin access to do that." | You selected **Check now** after losing platform administrator rights. Nothing was asked. |

### Installed plugins

Whether each plugin built into this release still checks out (#2244), from
the same check as **Operations → System → Plugins**. A plugin is checked when
it comes from Hex, git or a path; a plugin built from this project
(`projects/`) has nothing upstream to compare with and is left out.

| Line | When |
| --- | --- |
| **Fix now** | Any plugin fails: its package changed on Hex since this build, a security notice of high, critical or unrated severity covers the installed version, or Hex retired the release for security. |
| **Review** | Any plugin warns: a low or medium notice, the version is not published on Hex, Hex retired it for another reason, no release on Hex for 24 months (`KILN_PLUGIN_STALE_MONTHS`), or its `kiln_plugin` requirement doesn't accept the SDK this Kiln bundles. |
| **Unknown** | "Checking plugins; reopen this page in a minute." (nothing cached yet), or "Could not reach Hex or the security notices feed. Open System to check." |
| **OK** | "Every plugin matches Hex and has no known security notice." With a git or path plugin installed, the line reads "No installed plugin has a known security notice or SDK problem." and a detail says those plugins were checked for security notices and SDK support only. |
| **Not applicable** | "No plugins are installed from Hex, git or a path.", or plugin checks are turned off. With checks off, a plugin whose `kiln_plugin` requirement this Kiln doesn't meet is still **Review**: that part needs no request. |

**Details** lists up to ten reasons, one sentence each, the same sentences
System shows under each plugin. **Fix** opens System, where each plugin has
its own badge; see [Check your installed plugins](#check-your-installed-plugins).

Like the Kiln version line, this one never waits on the network. On a cold
cache (after a restart, a day after the last answer, or 15 minutes after a
check that failed) it starts one check in the background and shows
**Unknown**; reopen the page after a minute.

**What is sent, and where.** For each plugin locked from hex.pm, two
requests to hex.pm, which tell hex.pm the plugin's package name and version.
And one request (up to five pages) to the security notices feed on
kilncms.dev, which carries nothing about this installation, shared with
[Security notices for Kiln](#security-notices-for-kiln). A deployment with
no plugin from Hex, git or a path sends nothing for this line, though the
Kiln line still asks the notices feed. Turn the check
off with `KILN_PLUGIN_HEALTH_CHECK=false`; `KILN_UPDATE_CHECK=false` turns it
off too unless `KILN_PLUGIN_HEALTH_CHECK` is set
([variables](environment-variables.md#plugin-health-check-2244),
[data flows](data-flows.md)).

**What it can and can't tell you.**

- **"Changed on Hex" is about Hex, not about your server.** The check
  compares the checksum this build's lockfile recorded with the one hex.pm
  publishes for that version now. `mix deps.get` already refuses a lockfile
  whose checksum differs from Hex's, so a difference after the build means
  Hex's record changed (the release was replaced, or the registry was
  tampered with), the build used a mirror or an offline cache, or the
  lockfile was edited by hand. The check does not re-hash the compiled code
  in the running release.
- **Git and path plugins can't be verified.** Hex has no checksum for them.
  They are still checked against the notices feed and for their
  `kiln_plugin` requirement, which is why they can pass here while System shows **Can't
  verify**. A plugin from a private Hex repository is treated the same way.
- **The kilncms.dev feed lists first-party notices only**: Kiln and the
  Kiln project's own plugins. For a third-party plugin, the only notices
  checked are the ones Hex lists on the installed release.
- **A notice naming several packages** carries one set of version ranges
  for all of them, so the check can tell that a plugin is outside every
  range, but not that a range is its own. Inside one, the plugin reads
  **Unknown** rather than matched. That includes a notice that covers both
  Kiln and a plugin: the publisher names the core `kiln_cms` beside the
  plugin, so the plugin reads **Unknown** rather than **Security notice**
  (#2566 tracks publishing ranges per package).
- **Only the affected range decides.** A notice's fixed-in versions are
  shown, never used to clear a plugin; see
  [how a notice is matched](#security-notices-for-kiln).

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
- Security notices for `kiln_plugin`, the plugin SDK built into Kiln:
  neither notices line reads its version.
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
| Security notices for Kiln says "Checking security notices; reopen this page in a minute." | Nothing was cached yet, and the notices feed is being asked in the background. |
| Security notices for Kiln says "Could not reach the security notices feed. Open System to check." | The request failed. The answer is kept for 15 minutes, then the next visit asks again. See [Security notices for Kiln](#security-notices-for-kiln). |
| Installed plugins says "Checking plugins; reopen this page in a minute." | Nothing was cached yet, and the plugin check has started in the background. |
| Installed plugins says "Could not reach Hex or the security notices feed. Open System to check." | A request failed. The answer is kept for 15 minutes, then the next visit asks again. **Details** names each plugin that could not be checked. See the System table in [Check your installed plugins](#check-your-installed-plugins). |
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
