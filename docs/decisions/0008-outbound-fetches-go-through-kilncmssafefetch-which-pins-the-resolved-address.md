# 0008. Outbound fetches go through `KilnCMS.SafeFetch`, which pins the resolved address

- **Status** — accepted, shipped in
  [0.5.0](../changelog/v0.5.0.md) (Security).
- **References** — [#753](https://github.com/The-Verscienta/kiln_cms/issues/753).
- **Changelog** — [0.5.0 → Security](../../CHANGELOG.md#050---2026-08-09).

## Decision

**Webhook delivery now goes through `KilnCMS.SafeFetch`** (#753). The address
pinning that closes the DNS-rebinding window — resolve once, connect to the
literal, keep SNI and certificate hostname verification aimed at the real
name, restore the `Host` header, follow no redirects — existed twice: once in
`SafeFetch` and once in the `Webhooks.DeliveryWorker` it was extracted from.
Fifteen lines of TLS options that fail *open* when mistyped, in two places,
with `SafeFetch`'s own moduledoc claiming there should be one. There is now
one, and the worker also picks up the streaming byte cap it never had — with
truncation, so a receiver that answers 200 with a large body stays a delivered
200 rather than becoming a permanent failure the cap invented.

The ledger's `last_error` vocabulary is unchanged. `SafeFetch` writes for its
own callers and prefixes differently, so each of its shapes is *translated*
rather than wrapped — wrapping read `delivery failed: request failed:
%Req.TransportError{…}`, the documented wording with somebody else's inside
it.

**An IPv6 endpoint could never be delivered to.** The pinned host was
bracketed by hand *and* by `URI.to_string/1`, producing
`https://[[2606:2800::1]]/x` — so a webhook to any endpoint whose DNS answer
is IPv6 failed with a transport error that named nothing. It affected oEmbed,
link checking, federation and social posting too, since all of them share this
path. Found by writing the pinning test #753 asked for; the round-trip is now
asserted. The `Host` header for an IPv6 *literal* URL keeps its brackets as
well, so `[2606:2800::1]:8443` is no longer sent as an ambiguous
`2606:2800::1:8443`.

`SafeFetch` gained the test suite the issue names — the refusal of private and
link-local addresses, the pinned connection's TLS options asserted as values
(a `Req.Test` round trip cannot see them; the plug adapter never opens a
socket), the byte cap holding against a lying `content-length`, and
`decode_body: false` meaning the caller always gets bytes.
