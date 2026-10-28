# Cryptographically signed / provenance-verified content

Prove that a piece of content **came from us, unaltered, at version N, disclosed
as human/AI** — a novel trust story for the AI-slop era and for regulated
content ([#340](https://github.com/The-Verscienta/kiln_cms/issues/340); part of
the differentiator cluster, see `docs/differentiator-opportunities.md` #4).

Kiln already fires each published document into **immutable, pre-serialized
artifacts** and already ships an **RSA signing key** (the DKIM key). Provenance
combines the two: a signed hash of the fired artifact bound to a claim about who
signed it and how it was produced.

## C2PA-*style*, not literal C2PA

[C2PA / Content Credentials](https://c2pa.org) is designed for **media assets**
(images/video) with embedded or side-car manifests. Kiln adapts the *model* — a
detached manifest + a signed artifact hash + a signer claim — to HTML/JSON
**content** artifacts. It is genuinely provenance, but it is **not** drop-in
C2PA compliance for a webpage; the manifest shape below is Kiln's own.

## On by default

Since 1.7, every fire signs. Each fired artifact is stored with its signed manifest
(#1929), so a reader can ask whether what it is served is still what was
signed, and a fresh install does that from its first publish:

- **A new install** gets a signing key at `/setup`, generated and stored
  encrypted in the database (`KilnCMS.Provenance.Settings`, AES-256-GCM under
  `secret_key_base`, re-encrypted by `mix kiln.vault.reencrypt` like every
  other stored key). Nothing to configure.
- **A mounted key wins.** `KILN_PROVENANCE_KEY_FILE`, or the
  `KILN_PROVENANCE_PRIVATE_KEY` variable the compiled config names, is used
  whenever it is set, generated key or not. A mounted file that cannot be read
  is an error, never a quiet fall back to the generated key.
- **An install with no key keeps working.** An install upgraded to 1.7 without
  a key, or one whose `/setup` could not make one, serves its artifacts
  `unsigned`. Nothing is refused. A platform admin sees a strip on the console
  overview naming `KILN_PROVENANCE_KEY_FILE`, with a button that generates the
  key `/setup` would have.
- **Off is still available.** `KILN_PROVENANCE_ENABLED=false` produces no
  manifest and every `/api/provenance/*` endpoint returns `404`, as before 1.7.

Artifacts fired before a key existed stay `unsigned` until they are fired
again. `mix kiln.refire_all` (or `KilnCMS.Firing.Sweep.run()` over `rpc`) signs
them all.

On a released image, the knobs are environment variables (see
[environment-variables.md](environment-variables.md)):

```bash
KILN_PROVENANCE_KEY_FILE=/run/secrets/kiln-provenance.pem   # optional: a key of your own
KILN_PROVENANCE_RETIRED_KEY_FILES=/etc/kiln/keys/2025.pub.pem
KILN_PROVENANCE_ENABLED=false                               # only to switch it all off
```

From source, the same knobs plus the claim fields:

```elixir
# config/runtime.exs (production)
config :kiln_cms, KilnCMS.Provenance,
  enabled: true,
  signer: "Example Editorial",
  origin: "https://example.com",
  ai_disclosure: :human,
  # Reuse the DKIM key (:dkim), or point at a dedicated content-signing key:
  signing_key: {:env, %{"var" => "KILN_PROVENANCE_PRIVATE_KEY"}}
```

`signer`, `origin` and `ai_disclosure` are still source-only; they default to
`:site_name`, `:public_base_url` and `:human`, which is a reasonable deployment
on its own.

`signing_key` is resolved through `KilnCMS.Keys` (the same provider mechanism as
DKIM): `:dkim` reuses the mail signing key; `{:env, %{"var" => …}}` and
`{:file, %{"path" => …}}` point at a PKCS#1 RSA PEM (Docker/K8s secret-friendly).

## Using it

Every delivery response advertises its manifest when provenance is on:

```
GET /api/content/post/my-post
→ x-kiln-provenance: /api/provenance/post/my-post?surface=json
```

**The detached manifest** — a consumer fetches this alongside the artifact:

```
GET /api/provenance/post/my-post?surface=json
```

```json
{
  "kiln_provenance": "1.0",
  "artifact": {
    "type": "post", "slug": "my-post", "surface": "json",
    "hash": { "alg": "sha-256", "canonicalization": "kiln-jcs-v1", "value": "…base64…" }
  },
  "claim": {
    "signer": "Example Editorial",
    "origin": "https://example.com",
    "version": "…source version uuid…",
    "ai_disclosure": "human",
    "fired_at": "2026-07-17T…Z",
    "signed_at": "2026-07-17T…Z"
  },
  "signature": { "alg": "rsa-sha256", "key_id": "sha256:…", "value": "…base64…" }
}
```

**The public key** — for offline verification (PEM + base64 SPKI DER + fingerprint):

```
GET /api/provenance/public-key
→ {
    "alg": "rsa-sha256", "key_id": "sha256:…",       ← the ACTIVE key
    "public_key_pem": "…", "public_key_b64": "…",
    "keys": [                                         ← everything that still verifies
      { "key_id": "sha256:…", "status": "active",  "public_key_pem": "…", … },
      { "key_id": "sha256:…", "status": "retired", "public_key_pem": "…", … }
    ]
  }
```

Match a manifest's `signature.key_id` against `keys[]` — that is what keeps
manifests published before a key rotation verifiable (see
[Key rotation](#key-rotation)).

**Is this what was signed?** — the question a reader actually has, answered
for every published document whether it was signed or not:

```
GET /api/provenance/verify/post/my-post?surface=json
→ {
    "status": "verified",            ← or "tampered", "unsigned", "unverifiable"
    "type": "post", "slug": "my-post", "locale": "en", "surface": "json",
    "version": "…", "fired_at": "…", "key_id": "sha256:…",
    "unaltered": true, "authentic": true,
    "claim": { … }
  }
```

The served body is checked against the manifest **stored when it was
fired**:

| `status` | Meaning |
|---|---|
| `verified` | The body hashes to the manifest's hash, and the signature verifies against the key it names |
| `tampered` | Either check fails against a key this instance holds: the body was changed after it was signed, or the manifest was |
| `unsigned` | No manifest was stored: fired before 1.7, or while no key resolved. Fire it again to sign it |
| `unverifiable` | Signed with a key this instance no longer holds. Register the key's public half as retired ([Key rotation](#key-rotation)); this is never reported as tampering |

Anonymous, `Cache-Control: public, max-age=60`, and covered by the 1.0 API
contract ([overlay-contract.md](overlay-contract.md)).

**Server-side verify** — the older convenience verdict, which re-derives the
manifest from the live body and so cannot report tampering:

```
GET /api/provenance/post/my-post/verify
→ { "verified": true, "unaltered": true, "authentic": true, "claim": { … } }
```

## Verifying independently

A consumer (browser, edge cache, air-gapped mirror — see #341/#353) with a copy
of the artifact bytes verifies without trusting our server:

1. Recompute the artifact's canonical hash (`kiln-jcs-v1`: JSON with object keys
   sorted lexicographically, no insignificant whitespace, SHA-256, Base64) and
   check it equals `artifact.hash.value` → **unaltered**.
2. Rebuild the manifest without its `signature`, canonical-encode it, and verify
   `signature.value` (RSASSA-PKCS1-v1_5 / SHA-256) against the public key whose
   `key_id` the manifest names → **authentic**.

Both passing proves the content is exactly what we signed, at the stated version,
with the stated AI disclosure.

## Key rotation

Signatures name the key that made them, and verification resolves *that* key —
never "whatever is signing today". Rotating the signing key would otherwise
blind everything signed before the rotation, which is the opposite of what an
audit trail is for.

**Moving off the generated key needs no step.** Mount a key of your own and
it signs from then on; the key `/setup` generated stays in the database and
`KeyRegistry` lists it as retired, so everything it signed keeps verifying.
The generated key itself has no rotate action: replacing it in place would
blind what it signed.

Rotating a key you mounted is the case below. Register the outgoing key's
**public half** — from the environment:

```bash
KILN_PROVENANCE_RETIRED_KEY_FILES=/etc/kiln/keys/2025-provenance.pub.pem,/etc/kiln/keys/2024.pub.pem
```

or, from source, with the full provider vocabulary:

```elixir
config :kiln_cms, KilnCMS.Provenance,
  signing_key: {:env, %{"var" => "KILN_PROVENANCE_PRIVATE_KEY"}},
  retired_keys: [
    {:file, %{"path" => "/etc/kiln/keys/2025-provenance.pub.pem"}},
    {:env, %{"var" => "KILN_PROVENANCE_RETIRED_2024"}}
  ]
```

`retired_keys` entries are `KilnCMS.Keys` provider tuples (`:env` / `:file`) or
a raw PEM. The env var is paths only, because a PEM is multi-line and `.env`
parsers generally are not; it lands in a separate `retired_key_files` key that
`KeyRegistry.retired/0` **unions** with `retired_keys`, so setting it can only
add verification keys — never silently drop one configured in source.

The public half is all verification needs, so once it is registered **the
retired private key can be destroyed** — that is the point of registering the
public one. Register first, destroy second: until the public half is registered
those old signatures resolve to `{:error, {:unknown_key_id, …}}`, and with the
private half already gone there is nothing left to derive it from. A private key
PEM is accepted too (public half derived), but publishing the public half is
the better habit. Get the public half of a key you still hold with:

```bash
openssl rsa -in provenance.pem -pubout -out provenance.pub.pem
```

An entry that can't be read is logged and skipped, so one bad path can't take
down verification for the keys that do resolve. A `key_id` matching nothing is
reported as *unverifiable* — never as a failed signature: not holding a key
says nothing about the content, and conflating the two would slander your own
archive. `KilnCMS.Provenance.KeyRegistry` owns this resolution, and the
tamper-evident history anchors (#356) verify through the same registry.

## AI-generation disclosure

`claim.ai_disclosure` is one of `human` | `ai_assisted` | `ai_generated`. It
defaults to `KilnCMS.Provenance` config, but an editor can set it per-document
by defining an `ai_disclosure` custom field on the content type — its value is
read from `custom_fields` (invalid values normalize to `human`).

## How it works

Each surface's manifest is made as it is fired (`KilnCMS.Provenance.sign_fired/4`)
and stored on the artifact row (`published_artifacts.manifest`). Signing costs
one RSA signature per surface, with the key resolved once per fire. The
manifest endpoint serves the stored manifest; an artifact fired before 1.7 has
none and gets one derived from its body, as before
(`KilnCMS.Provenance.manifest_for/2`, deterministic: PKCS#1-v1_5 signing over
an immutable body). Signing reuses the DKIM RSA helpers in `KilnCMS.Keys`.

## How much is signed

The share of published artifacts carrying a verifiable manifest — one per
published document, counted on the `json` surface — is
`KilnCMS.Provenance.coverage/1`:

```bash
mix kiln.provenance.coverage
/app/bin/kiln_cms rpc "IO.inspect(KilnCMS.Provenance.coverage())"
```

It is also emitted every five minutes as `kiln_cms.provenance.coverage.share`
(with `.verifiable` and `.total`) telemetry, and exported with the other
metrics when `KILN_METRICS_ENABLED` is on. A manifest whose key this instance
no longer holds counts as signed but not verifiable.

- `KilnCMS.Provenance` — config + manifest build/verify.
- `KilnCMS.Provenance.Canonical` — deterministic JSON + SHA-256 digest.
- `KilnCMS.Provenance.Signer` — RSA sign/verify + public-key info via `KilnCMS.Keys`.
- `KilnCMS.Provenance.KeyRegistry` — resolves which key verifies a given `key_id`.
- `KilnCMSWeb.ProvenanceController` — the public endpoints.

## Scope & Phase 2

Multi-key verification shipped (see [Key rotation](#key-rotation)). Still open:

- **Signer identity** is a configured string. Tying it to the authenticated
  publisher (per-user keys) is future work.
