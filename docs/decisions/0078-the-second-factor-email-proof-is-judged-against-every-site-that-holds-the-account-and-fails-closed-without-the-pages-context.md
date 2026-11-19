# 0078. The second-factor email proof is judged against every site that holds the account, and fails closed without the page's context

- **Status** — accepted (2026-11-19). Builds on
  [ADR 0030](0030-the-second-factor-requirement-fails-open-and-only-a-freshly-verified-admin-changes-it.md),
  which makes the requirement itself fail open. This record is about the
  step inside it, the emailed proof, which fails the other way. ADR 0030 is
  not revised.
- **References** — [#2872](https://github.com/The-Verscienta/kiln_cms/issues/2872)
  (this record); [#2247](https://github.com/The-Verscienta/kiln_cms/issues/2247)
  (the requirement and the proof, owner decision 1b);
  [#2899](https://github.com/The-Verscienta/kiln_cms/pull/2899) (the in-app
  help the same follow-up asked for).
- **Changelog** — the 1.10.0 entry
  [Second-factor help follows the host](../changelog/v1.10.0.md#second-factor-help-follows-the-host).

## The problem

A site that requires a second factor holds an account, past the deadline,
until it has one. The set-up page is the one thing a held account can reach,
so a person who has only the password reaches it too, and could add their own
authenticator app or passkey. The account would then be "enrolled" with a
factor its owner does not hold. To close that, a session that signed in with
only a password must first show it can read the account's email:
`KilnCMS.Accounts.EnrolmentProof` mails six digits, and the enrolment actions
accept the signed proof that follows.

Two questions had obvious answers that are wrong.

- **Which site's rules apply?** A factor belongs to the account, not to a
  site: once added it satisfies every site that holds the account. The set-up
  page is served on the main host, where the page's site is the default one,
  and the default site need not hold the account or have a mail relay. The
  page's site is not the only one the decision rests on.
- **What happens when it cannot be judged?** The proof is skipped when there
  is no working mail relay (owner decision 1b), because a held admin with no
  way to receive mail would otherwise be locked out for good. A relay that
  cannot be read right now looks, to a careless check, the same as no relay.

## Decision

- **The proof is judged against every site that holds the account.**
  `EnrolmentProof.decide/4` asks for the proof when the page's site holds the
  account or any site does (`TwoFactorRequirement.enforced_deadlines/2`), and
  judges "signed in before the deadline" against the earliest of those
  deadlines, the strictest site. The mail relay is judged the same way:
  `EnrolmentProof.relay_orgs/3` is the page's site followed by every site
  that holds the account (`TwoFactorRequirement.holding_orgs/2`).
  `send_code/4` mails the code through the first of them whose relay takes
  it, and the skip (`"email_skipped_no_relay"`) is taken only when none of
  them has one: `Mail.relay_available?/1` is checked per site.
- **Without the page's context, it fails closed.** The action does not trust
  the page. `Changes.RequireEnrolmentProof`, on `User.:confirm_totp` and
  `Passkey.:register`, calls `EnrolmentProof.accept/4`, which runs `decide/4`
  again from the account and the session and refuses without a valid proof.
  A page that supplies no context (`EnrolmentProof.context/3` with no proof,
  as `SettingsLive` does: it has no proof step and says where to go instead),
  a forged event, or a claimed `:no_relay` that any holding site contradicts
  gets `{:error, :proof_required}`. `Mail.relay_available?/1` is `true` for
  anything but a relay retrying will not fix, so one site whose relay can't
  be read just now keeps the proof rather than lifting it. Likewise
  `send_code/4` reports a transient failure on any site as
  `{:error, :send_failed}` ahead of `{:skip, :no_relay}`.

## Rejected

- **Judge only the current page's site.** It is the simpler rule, and it is
  wrong in the case the page makes likely: on the main host the page's site
  is the default one. If the default site has no relay, the proof is skipped,
  and someone with only the password adds a factor that then satisfies a
  site that does hold the account and does have a relay. The owner is
  locked out of an account whose protection was the point. The same applies
  to asking the proof at all: a password-only session on a host whose site
  does not cover the account would add a factor that counts on a site that
  does. Judging every holding site costs a few extra relay lookups on a page
  that is used once per factor.
- **Fail open when the page's context is missing or a relay can't be
  read.** This is ADR 0030's direction for the requirement, and it is right
  there: a requirement that can't be read must not hold every account. It
  is wrong here, because the failure is something an attacker can cause or
  wait for (a relay's settings unreadable for a moment, a page that sends no
  proof), and the proof is the control that stands between a stolen password
  and a factor the owner never held. The cost of failing closed is bounded
  and recoverable: the person retries, or signs in with a passkey or a magic
  link, which already proves the mailbox or is not asked. The cost of failing
  open is an account takeover that persists. Only a relay that retrying will
  not fix (`Mail.no_relay?/1`: no outgoing mail server, or a site relay whose
  password can't be decrypted) counts as "no relay".

## Consequences

- A held account on a site with no relay can still get in through the
  requirement being unreadable (open, ADR 0030), a site that has a relay, or
  a session that already proved the mailbox. It can't through a transient
  mail failure.
- `/account/two-factor` (`TwoFactorSetupLive`) is the page that mails and
  checks the code, and is on the main host. `/account` and the settings
  forms refuse a factor that needs the proof and link to it, saying so when
  it is on another host, so the failing-closed refusal always has a way
  forward.
- A new place that adds a second factor must pass `EnrolmentProof.context/3`
  and rely on `accept/4`; checking in the page alone is the bug this record
  exists to prevent.
