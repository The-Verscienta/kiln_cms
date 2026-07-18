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

## Off by default

With `enabled: false` (the default) no manifest is produced and every
`/api/provenance/*` endpoint returns `404` — the lean install pays nothing.

```elixir
# config/runtime.exs (production)
config :kiln_cms, KilnCMS.Provenance,
  enabled: true,
  signer: "Verscienta Editorial",
  origin: "https://example.com",
  ai_disclosure: :human,
  # Reuse the DKIM key (:dkim), or point at a dedicated content-signing key:
  signing_key: {:env, %{"var" => "KILN_PROVENANCE_PRIVATE_KEY"}}
```

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
    "signer": "Verscienta Editorial",
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
```

**Server-side verify** — a convenience verdict for the live artifact:

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
   `signature.value` (RSASSA-PKCS1-v1_5 / SHA-256) against the published public
   key → **authentic**.

Both passing proves the content is exactly what we signed, at the stated version,
with the stated AI disclosure.

## AI-generation disclosure

`claim.ai_disclosure` is one of `human` | `ai_assisted` | `ai_generated`. It
defaults to `KilnCMS.Provenance` config, but an editor can set it per-document
by defining an `ai_disclosure` custom field on the content type — its value is
read from `custom_fields` (invalid values normalize to `human`).

## How it works

Manifests are derived **statelessly** from the immutable artifact
(`KilnCMS.Provenance.manifest_for/2`): the firing hot path is untouched, and
re-deriving a manifest for the same artifact yields the same bytes (the artifact
is immutable per publish and PKCS#1-v1_5 signing is deterministic). Signing
reuses the DKIM RSA helpers in `KilnCMS.Keys`.

- `KilnCMS.Provenance` — config + manifest build/verify.
- `KilnCMS.Provenance.Canonical` — deterministic JSON + SHA-256 digest.
- `KilnCMS.Provenance.Signer` — RSA sign/verify + public-key info via `KilnCMS.Keys`.
- `KilnCMSWeb.ProvenanceController` — the public endpoints.

## Scope & Phase 2

This is a Phase-1 slice:

- **Single active signing key.** Rotation changes `key_id`; old cached manifests
  verify only against the key that is current. A key registry (verify against
  any of N historical public keys) is a follow-on.
- **Stateless derivation.** Persisting the manifest at fire-time would pin the
  signer/key/disclosure *as of publish* (audit-grade, survives config changes)
  and let `/verify` detect server-side drift — a natural Phase-2 upgrade that
  slots behind the same API.
- **Signer identity** is a configured string. Tying it to the authenticated
  publisher (per-user keys) is future work.
