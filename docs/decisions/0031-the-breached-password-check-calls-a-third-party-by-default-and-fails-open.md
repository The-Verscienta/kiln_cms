# 0031. The breached-password check calls a third party by default, and fails open

- **Status** — accepted (2026-11-13), recording the choice that shipped with
  #2240 in 1.9.0.
- **References** — [#2240](https://github.com/The-Verscienta/kiln_cms/issues/2240)
  and [#2403](https://github.com/The-Verscienta/kiln_cms/pull/2403), which
  built it; [#2409](https://github.com/The-Verscienta/kiln_cms/issues/2409),
  which asked for this record;
  [ADR 0008](0008-outbound-fetches-go-through-kilncmssafefetch-which-pins-the-resolved-address.md)
  for the fetch path it uses;
  [ADR 0032](0032-a-default-on-check-that-tells-a-third-party-about-the-installation-follows-the-update-check-switch.md)
  for the other default-on call that discloses something, and
  [ADR 0018](0018-a-site-may-only-lower-a-deployment-ceiling-refused-on-write-clamped-on-read.md)
  for why a site's saved policy wins over the operator's default.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#breached-password-check).

## The problem

When someone sets a password (registers, changes it, resets it with a token,
creates the first admin in `/setup`, or accepts an invitation with a
password), `KilnCMS.Accounts.Changes.CheckBreachedPassword` asks whether that
password has appeared in a public data breach. The only practical source of
that answer is a corpus Kiln does not hold: Have I Been Pwned's.

So three choices had to be made, and each outlives the release:

- **Does a default install ask a third party at all?** The call carries a
  derivative of something a person typed, and it happens on unauthenticated
  paths (self-registration, password reset).
- **What happens when the third party can't answer?** A timeout, an error
  status, a blocked address or a malformed body.
- **Who can turn it off?** A site admin, the operator, or both.

## The decision

**The check is on by default, with the `warn` policy, and every failure to get
an answer accepts the password.**

### What leaves the server

`KilnCMS.Accounts.BreachedPassword` hashes the password with SHA-1 on the node
and sends **the first five hex characters** of that hash, as the path of
`GET https://api.pwnedpasswords.com/range/<prefix>` (the k-anonymity range
API), with `Add-Padding: true`. The service answers with every known suffix
under that prefix, padded with fake suffixes to a uniform size, and the match
is made locally. The suffix, the full hash, the password, the account and the
site never leave the node. What the provider learns: that *someone* behind this
server's IP set a password whose hash starts with that prefix, one of about a
million possible prefixes.

The request goes through `KilnCMS.SafeFetch` (ADR 0008): no redirects, no
retries, a 128 KB cap and a 3-second deadline that covers the DNS lookup too.
Nothing is cached, and no log line or telemetry event carries the password,
the hash, the prefix or the URL.

### On by default

The check needs no credential, so there is no unset secret to stand in for
consent, and the disclosure is the smallest one the protocol allows. A
deployment that must not make the call says so explicitly.

### Fails open, and says so

`BreachedPassword.check/1` returns `{:error, class}` for a timeout, a non-200,
a transport failure, a blocked address or a malformed body, and the caller
accepts the password. An outage at a third party, or an attacker who can block
the server's egress, must never decide whether anyone can set a password. The
check is advisory: even `block` refuses only an administrator's password, and
editors and viewers are only warned.

The cost is that the same attacker can switch the check off. They already
hold a network position from which they can do worse, and the failure is not
silent: every lookup emits `[:kiln_cms, :password, :breach_check]` with
`result: :error` and the error class as `reason`, and
[observability](../observability.md#breached-password-checks) says to alert
on the error share.

### Who can turn it off

- **The operator: `BREACHED_PASSWORD_CHECK=false`.** No outbound call is ever
  made, whatever any site has saved. Only an explicit off-spelling writes
  anything (`config/runtime/console.exs`); unset or unreadable leaves it on.
  This is the egress switch for the call.
- **A site admin: the policy Off.** `CheckBreachedPassword` makes no request
  for a site whose policy is `:off`.
- **`BREACHED_PASSWORD_POLICY=off` is not an egress switch.** It is the
  operator's default for sites that have saved no choice, and a site's saved
  choice wins over it, so a site admin can turn the call back on under it.

The check is **not** governed by `KILN_UPDATE_CHECK`. That variable switches
off the calls that ask about Kiln and its plugins; this one is part of
setting a password, and has its own switch. A deployment that must make no
third-party request at all has to set both, plus the crawler-verification
switches: [data flows](../data-flows.md#optional-subprocessors) lists every
call made by default and the variable that stops it.

## Rejected

- **Opt-in.** Few installs would turn it on, and the ones most exposed to
  credential stuffing (small sites with no security staff) least of all.
  The disclosure is a five-character prefix; the protection is real.
- **Fail closed.** A third-party outage, or a firewall rule nobody connected
  to it, would stop every registration and password reset on every site.
- **A local copy of the corpus** (a downloaded hash list or a Bloom filter
  built from it). Tens of gigabytes to download and refresh on every node, a
  scheduled job to keep it current, and storage that most installs would carry
  for an advisory control. It is the right answer for a deployment that needs
  the check fully offline, and it can be added behind the same
  `BreachedPassword.check/1` contract.
- **A private mirror.** The host is configuration
  (`config :kiln_cms, KilnCMS.Accounts.BreachedPassword, host: …`), so a mirror
  on a public address works today. A mirror on a private or link-local address
  is refused by `SafeFetch`'s address pinning, like any other outbound call;
  supporting one would mean an explicit allowance for that host, which was not
  built. There is no environment variable for the host.
- **Checking at sign-in too.** It would send a prefix on every password
  sign-in, not only when a password is set, and turn an advisory note into a
  sign-in dependency. Not built; recorded as a follow-up in the threat model.

## When to revisit

- Have I Been Pwned changes its terms, its rate limits, or starts requiring a
  key for the range API.
- A deployment needs the check with no egress (the local-copy alternative).
- `block` is widened beyond administrators, or the check moves to sign-in:
  either makes the fail-open trade-off heavier and should be argued again.
