# 0029. Security-alert email stays English until accounts store a locale

- **Status** — accepted (2026-11-12).
- **References** — [#2642](https://github.com/The-Verscienta/kiln_cms/issues/2642)
  (closed by PR #2793), [#2796](https://github.com/The-Verscienta/kiln_cms/issues/2796),
  [#2245](https://github.com/The-Verscienta/kiln_cms/issues/2245).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md)
  (#2793).

## The problem

The console is translated (es, fr), and #2642 asked for security alerts to be
too. An alert is said in four places: the bell and inbox, the email, a
Slack-format webhook, and the Kiln-format webhook payload (data, not prose).
The inbox has a reader with a locale. The other two prose channels do not:

- **An account stores no preferred language.** Nothing on
  `KilnCMS.Accounts.User` says which language a person reads.
- **One admin can hold several sites in different locales**, and a platform
  alert is about no site at all.
- **The email is sent by a worker**, not a request
  (`KilnCMS.Security.Changes.DeliverAlert`), so there is no console locale to
  borrow. Borrowing the locale of whoever triggered the event would mail an
  admin in the language of the person who locked themselves out.

## Decision

**The inbox is translated; the email and the Slack message are English.**

- **The inbox** renders a security row from its structured
  `Notification.details` (`KilnCMS.Security.AlertText.details/1`) in the
  reader's locale, through `KilnCMSWeb.NotificationText.excerpt/1`. The
  English line stays in `excerpt`, which is what a release before `details`
  reads.
- **The email** (`KilnCMS.Security.AlertMail`) is English, like the other
  account mail (`KilnCMS.Accounts.User.Senders.SendRegistrationPending`,
  `KilnCMS.Accounts.ApiKeyReuse`). The labels it shares with the inbox come
  from `AlertText`, which is gettext'd, so `AlertMail` renders them under
  `Gettext.with_locale(KilnCMSWeb.Gettext, "en", …)`. The prose only the
  email has (subject, body, footer) is plain English strings, deliberately
  not gettext, so the catalogs carry no es or fr text that no reader would
  ever see.
- **The Slack message** (`KilnCMS.Webhooks.SlackFormat`) pins English the
  same way, and stays English even if accounts gain a locale: it is posted to
  a channel, not to a person, and a channel has no locale.

## Rejected

- **Translate the email in the locale of the site the alert is about.** A
  site's locale is its readers' language, not its admins'. Platform alerts
  have no site, and an admin of an es site and an fr site would get mail in
  two languages.
- **Translate it in the locale of the request that raised the event.** That
  is the actor's language (often an attacker's), not the recipient's, and
  most alerts are delivered by a job a minute later in any case.
- **Put the email's prose through gettext now, to be ready.** It would fill
  the catalogs with es and fr strings that nothing renders, which translators
  would maintain for no reader, and which would drift unnoticed.

## Consequences

- An admin who reads the console in es or fr gets English alert email.
- Giving the email a per-user locale is more than changing `AlertMail`'s
  locale call. It needs a locale stored on the account and a way to set it;
  `AlertMail`'s `english/1` call taking that locale instead of `"en"`; and the
  subject, body and footer moved into gettext with es and fr translations.
  The other account mail would want the same.
- The Slack format would not follow; it would still be English.
- The inbox, the email and Slack say the same headline because they share
  `AlertText`; only the language differs.
