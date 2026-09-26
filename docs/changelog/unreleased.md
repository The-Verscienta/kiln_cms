# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.


## Added

<a id="a-site-on-its-own-smtp-relay-keeps-its-own-bounce-list"></a>

- **A site on its own SMTP relay keeps its own bounce list.** When a site's own
  relay (`/editor/site-mail`) rejects a recipient as dead (`5.1.1`, `5.2.1` and
  the like, in the mail transaction), the address goes on that site's own
  suppression list (`KilnCMS.Mail.SiteSuppressedRecipient`, keyed by site and
  address), and that site's newsletters and other queued mail skip it (#1562).
  Before, a site relay's hard reject cancelled that one message and nothing
  more, so a site on its own relay kept mailing dead addresses on every
  newsletter, which hurts its standing with its provider.

  The list stops only that site's mail. The relay is a server the site chose,
  and it may answer 550 to any address, so its word never reaches the
  instance-wide list, another site's mail, or account mail (sign-in links,
  password resets), which carries no site and never consults a site's list.
  The worst a hostile relay can do with it is stop mail its own site sends. The
  instance-wide list stays the operator's relay's alone, and it still applies
  to every site's mail. Only a reject naming the recipient suppresses: a relay
  refusing our AUTH, TLS or sender, and a reject that doesn't say whose fault
  it is, suppress nobody, as on the operator's relay.

  `/editor/site-mail` gains the **Delivery health** panel `/editor/mail` has,
  scoped to the site: its recent hard bounces and give-ups by recipient domain
  (newsletter jobs included), and its suppressed addresses, each with
  **Remove**. The list is read and cleared by the site's admins only, and
  written by nothing but the delivery pipeline. One new table,
  `site_suppressed_recipients`.

## Fixed

<a id="a-sites-relay-refusing-its-password-no-longer-pages-the-operator"></a>

- **A site's relay refusing its password no longer pages the operator.** A
  site's own relay refusing AUTH, TLS or the sender raised the operator's
  "relay refused" alert (log error, Sentry message, telemetry) as if the
  deployment's relay were broken, and spent that alert's 15-minute cooldown, so
  the operator's own relay failing in that window went unreported. It now
  alerts only for the operator's relay, as the relay-unreachable alert already
  did (#1562).
