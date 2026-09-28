# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Security

<a id="mint-1110-closes-three-advisories-http1-response-smuggling-and-two-http2"></a>

- **`mint` 1.11.0 closes three advisories: HTTP/1 response smuggling and two
  HTTP/2 client memory exhaustions (EEF-CVE-2026-91043 HIGH, -92103, -94194).**
  All three were published against `mint` 1.10.1 on 2026-09-28 and fixed in
  1.11.0. A malicious HTTP/2 server could make the client decode HPACK-indexed
  `cookie` fields far past `max_header_list_size`, which is enforced only on
  the compressed block (EEF-CVE-2026-91043, HIGH). It could also hold up to
  about 16 MiB per connection in a frame larger than `max_frame_size`, which is
  checked only once the whole payload has arrived (EEF-CVE-2026-92103). A
  malicious HTTP/1 server could send `Transfer-Encoding: chunked, gzip`, which
  Mint framed as chunked although RFC 9112 reads such a body to connection
  close. That desynchronizes Mint from a strict intermediary on a pooled
  connection (EEF-CVE-2026-94194). Kiln reaches Mint through Req and Finch on
  every outbound HTTP path, and webhooks, ActivityPub federation and media URL
  import aim at hosts an operator or editor supplies, so a hostile origin is
  reachable. `mint` is transitive only, so this is a one-line `mix.lock`
  change.
