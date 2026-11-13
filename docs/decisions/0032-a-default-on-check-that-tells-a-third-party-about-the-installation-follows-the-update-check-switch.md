# 0032. A default-on check that tells a third party about the installation follows the update-check switch

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2244 in 1.9.0. It records that choice and the conditions it was made under;
  the general rule for future checks is **not** decided here (see the last
  section).
- **References** — [#2244](https://github.com/The-Verscienta/kiln_cms/issues/2244)
  and [#2562](https://github.com/The-Verscienta/kiln_cms/pull/2562), the plugin
  health check; [#2568](https://github.com/The-Verscienta/kiln_cms/issues/2568),
  which asked for this record;
  [ADR 0031](0031-the-breached-password-check-calls-a-third-party-by-default-and-fails-open.md)
  for the other default-on call that sends something beyond a fixed query.
- **Changelog** — [1.9.0, Upgrade notes](../changelog/v1.9.0.md#plugin-health-egress-upgrade)
  and [Added](../changelog/v1.9.0.md#plugin-health-checks).

## The problem

Before 1.9.0, every outbound request a default install made about Kiln
itself carried nothing about the installation: the kilncms.dev release feed,
the GitHub fallback and the security notices feed send a bare `KilnCMS`
user-agent and a fixed query, so each service sees only the server's IP
([data flows](../data-flows.md#optional-subprocessors)).

The plugin health check (#2244) cannot work that way. To say whether an
installed plugin's package changed on Hex since the build, whether Hex has an
advisory for it, or whether it was retired, `Kiln.Plugins.Health` has to ask
hex.pm about that package and that version:
`GET https://hex.pm/api/packages/<name>` and
`GET https://hex.pm/api/packages/<name>/releases/<version>`. hex.pm then
knows which plugins, at which versions, this server runs. That is the first
default-on request that tells a third party something about the
installation, and the question was whether it may be on by default at all,
and on what terms.

## The decision

**It is on by default, on these terms, all of which shipped in #2562:**

1. **It follows the update-check switch.** `KILN_PLUGIN_HEALTH_CHECK` unset
   takes the value of `KILN_UPDATE_CHECK` (`config/runtime/updates.exs`), so an
   operator who set `KILN_UPDATE_CHECK=false` for "no outbound requests about
   Kiln" before 1.9.0 gets no new request without doing anything.
2. **It has its own switch.** `KILN_PLUGIN_HEALTH_CHECK=false` stops the hex.pm
   requests while the update check stays on; `KILN_PLUGIN_HEALTH_CHECK=true`
   keeps them with the update check off.
3. **It sends the minimum, only to the party the data concerns.** The package
   name and the locked version, in the URL path, to hex.pm, which already
   serves that package. No checksum, no Kiln version, no host name, no
   identifier, and nothing for a plugin that does not come from hex.pm (git,
   path, private-repo and `projects/` plugins send nothing).
4. **A person asks for it.** The request is made only when a platform admin
   opens **Operations → System** or **Security posture**, calls
   `GET /api/security/posture`, or selects **Check plugins now**, and only when
   no answer is cached (24 hours per node, 15 minutes after a failure; a forced
   check at most once a minute). There is no Oban job and no request at boot.
5. **It is documented as a disclosure, where operators look.** Its row in
   [data flows](../data-flows.md#optional-subprocessors) puts what it discloses
   in bold, and the release that turned it on carried an entry under **Upgrade
   notes**, not only under Added, naming `KILN_PLUGIN_HEALTH_CHECK=false` as
   the thing to set *before* deploying. `mix kiln.update` shows upgrade notes;
   it does not show Added.

Why on by default rather than opt-in: a plugin whose package was changed on
Hex after the build, or that has an advisory against it, is exactly what an
operator who never looks at an opt-in setting needs to hear about. The
disclosure (that this server runs a public package that hex.pm itself
serves) is small against that, and the switches above let any deployment
refuse it.

## Rejected

- **Opt-in.** The check would be off on most installs, which are the ones it
  is for.
- **A request on a schedule or at boot.** It would tell hex.pm about the
  installation on a timetable, with nobody having asked. The admin-triggered,
  cached request answers the same question when someone is looking.
- **Its own switch only, ignoring `KILN_UPDATE_CHECK`.** An operator who had
  already opted out of outbound requests about Kiln would have been opted back
  in by an upgrade.
- **Sending more to get a better answer** (the lockfile checksum, the Kiln
  version). hex.pm publishes the checksum; the comparison is made locally.

## How this applies to calls already made by default

Not every default-on call meets terms 1 and 2 as written, and this record
does not change them:

- The **GitHub fallback** of the update check and the core's **security
  notices** reader have no switch of their own; `KILN_UPDATE_CHECK=false`
  stops them. They disclose nothing about the installation, so the terms
  above do not apply to them.
- The **breached-password check** sends a fragment of a password's hash, not
  something about the installation, and has its own switch
  (`BREACHED_PASSWORD_CHECK`), not `KILN_UPDATE_CHECK`. Its reasoning is
  [ADR 0031](0031-the-breached-password-check-calls-a-third-party-by-default-and-fails-open.md).
- **Crawler verification** sends a visitor's IP address to the node's DNS
  resolver, on visitor traffic, by default (`KILN_CRAWLER_VERIFICATION`). No
  record argues that choice yet; it is outside this one.

## Not decided here

#2568 asked for the rule for *future* default-on checks. What #2562 decided
is the case above. These questions are still open, and the next check that
raises one should settle it with the project owner and record it:

- Whether every future check that discloses installation details must meet
  all five terms above, or whether some (a request on a schedule, a request
  not prompted by a person) can be allowed with other safeguards.
- Whether sending anything about the installation to a party that is *not*
  the source of what is being checked (usage telemetry, install counts) is
  always opt-in, and whether that includes kilncms.dev itself, which today
  keeps no client address for the published-entries route both feeds read,
  as an operational promise rather than a rule.
- Whether a call that sends data about people (a password fragment, a
  visitor's address) needs a rule of its own, and where crawler
  verification's default sits under it.
- Whether there should be one switch that turns off every default-on
  outbound call. There is none today: [data flows](../data-flows.md#optional-subprocessors)
  lists the variables a deployment with no egress has to set.
