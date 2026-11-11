# 0021. A form opts in to human verification, and an unverified submission is held, not refused

- **Status** — accepted (2026-11-09).
- **References** — [#2249](https://github.com/The-Verscienta/kiln_cms/issues/2249)
  (the second of three parts), following
  [ADR 0020](0020-human-verification-is-deployment-wide-and-fails-open-only-within-the-sign-in-budget.md)
  (sign-in and registration) and
  [ADR 0018](0018-a-site-may-only-lower-a-deployment-ceiling-refused-on-write-clamped-on-read.md)
  (a site may only lower a deployment ceiling).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

Public forms are anonymous and deliberately CSRF-free, so they can be posted
from a fired artifact or another site. Until now their only defences were a
honeypot, a per-address rate limit and a spam score after the fact. #2249
asks for a CAPTCHA on them too. Sign-in already has one (ADR 0020), but
three things are different about a form:

- **Who bears the cost.** A sign-in check protects accounts shared across
  sites. A form's submissions go to one site's inbox, webhooks and
  autoresponder, and nowhere else.
- **What a refusal costs.** A refused sign-in can be retried, or the person
  can use a passkey or a sign-in link. A refused form submission is lost:
  there is no other way to send it, and a visitor whose widget was blocked by
  an extension or a network filter cannot solve the check at all.
- **Who sends without a token.** Headless front ends render forms from
  `GET /api/forms/:slug` and relay submissions. Until they are updated to
  draw the widget, every submission they send has no token. So does every
  page loaded before an admin switched the check on.

## Decision

- **Per form, and off by default.** `KilnCMS.CMS.Form` carries
  `challenge: :off | :always`, set by a site admin in the form builder. By
  ADR 0018's test, a looser setting may be the site's when it costs only that
  site, and a form with the check off exposes only its own inbox. Off by
  default, because switching it on changes what every headless consumer of
  that form must send.
- **The operator keeps the ceiling.** `CHALLENGE_FORMS` (on by default), the
  kill switch and a usable provider decide whether any form may ask. As in
  ADR 0018, the setting is refused on write while forms cannot ask
  (`KilnCMS.CMS.Validations.ChallengeAvailable`) and clamped on every read
  (`KilnCMS.Challenge.form_required?/2`), so turning forms off takes effect
  everywhere at once without rewriting a row. The refusal applies only to a
  write that changes `challenge`: a form already on can still be renamed and
  switched off while the operator has forms off.
- **Held, not refused.** A submission without a pass is stored and scored as
  spam, so it lands in Spam with no notification, autoresponder, webhook or
  experiment conversion, and an admin can review it. That covers three
  cases: no token, a token solved on a host this deployment does not serve,
  and a token the provider could not check. A visitor who could not solve the
  check still reaches the site; a script reaches nothing that acts. Only a
  token the provider refused (invalid, expired, malformed, drawn for another
  action) is refused, and the visitor gets the form back with their values
  to try again: that visitor has a working widget.
- **No outage bypass.** Sign-in fails open within a budget because refusing
  everyone during an outage would lock people out (ADR 0020). Holding locks
  nobody out, so a form need not fail open at all. A missing token is held
  even during an outage, and so is a token the provider could not check: an
  attacker who can make the provider answer `429` gets nothing acted on. A
  form check never arms sign-in's outage memory either, so that same burst
  cannot open sign-in's fail-open window.
- **Holding is in the scorer, not a spam check.**
  `KilnCMS.CMS.Changes.ScoreFormSubmission` adds the threshold for every
  outcome but `:passed`. A `Kiln.Forms.SpamCheck` would be unregistrable and
  reweighable by a plugin; the outcome is offered to checks as the
  `:challenge` fact instead.
- **The check runs last.** Inactive form, honeypot, field validation, then
  the provider. A typo never spends the visitor's single-use token, and a
  tripped honeypot never costs a provider call (it answers in the shape a
  real submission with a valid token would).
- **One hostname rule, and a mismatch is held.** Both endpoints use sign-in's
  rule: a host this deployment serves or one in `CHALLENGE_HOSTNAMES`, never
  the request's `Host`. A mismatch is almost always configuration (a headless
  site the operator has not listed), so it is held and logged with the host
  to add, rather than refused in a way the visitor cannot fix.
- **The page policy widens only where the widget is drawn.** The delivered
  page, `/forms/:slug`, a refused re-render and the embed gain the provider's
  origins only when the form they render asks; every other response is
  byte-identical.

## Considered and rejected

- **Refusing a submission without a token.** Loses every submission from a
  visitor whose widget could not load, from a headless site not yet updated,
  and from a page loaded before the switch, with nothing for the admin to
  recover.
- **Failing open during an outage, as sign-in does.** The bound that makes
  it safe for sign-in (the account budget) does not exist for an anonymous
  form, and holding already keeps the data.
- **A deployment-wide forms mode only.** A form's spam is its own site's
  problem; one site's need would switch the check on for every site's
  headless consumers at once.
- **A grace window for pages rendered before the switch.** Held submissions
  keep their data, and a grace keyed on the page's render time would admit
  token-less posts for as long as an old render stamp stays valid.
- **Trusting the request's host, or the form's embed origins, for the
  hostname.** The request's host is the caller's to choose. An embedded
  form's widget runs inside the iframe, on the site's own host, so the
  parent's origin never reaches the token.
- **A hard `422` on a hostname mismatch.** Correct but unfixable by the
  visitor, and it would break a covered API for every headless site the
  moment its admin ticked the box.
- **Drawing the widget in fired artifacts.** Fired output is
  settings-independent and shared; a headless site draws the widget from the
  schema instead.
- **Challenging the newsletter sign-up now.** Its abuse is re-sending
  confirmation mail to one address, which a per-address cooldown answers
  better (#2500).

## Follow-ups

1. Per-site keys and a settings page (sign-in stays deployment-wide),
   reCAPTCHA v2, and a plugin SDK callback for providers once the shape is
   proven: the third part of #2249.
2. The CSV export does not carry the outcome; the Entries tab does.
