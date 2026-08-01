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
Configuring a signing key does **not** turn it on: the key by itself signs
history anchors (#356), and the provenance endpoints stay `404` until `enabled`
is set. That surprise is why the switch is reachable from the environment.

On a released image, set the environment (see
[environment-variables.md](environment-variables.md)):

```bash
KILN_PROVENANCE_ENABLED=true
KILN_PROVENANCE_KEY_FILE=/run/secrets/kiln-provenance.pem
KILN_PROVENANCE_RETIRED_KEY_FILES=/etc/kiln/keys/2025.pub.pem
```

From source, the same knobs plus the claim fields:

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
   `signature.value` (RSASSA-PKCS1-v1_5 / SHA-256) against the public key whose
   `key_id` the manifest names → **authentic**.

Both passing proves the content is exactly what we signed, at the stated version,
with the stated AI disclosure.

## Key rotation

Signatures name the key that made them, and verification resolves *that* key —
never "whatever is signing today". Rotating the signing key would otherwise
blind everything signed before the rotation, which is the opposite of what an
audit trail is for.

So when you rotate, register the outgoing key's **public half** — from the
environment:

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

Manifests are derived **statelessly** from the immutable artifact
(`KilnCMS.Provenance.manifest_for/2`): the firing hot path is untouched, and
re-deriving a manifest for the same artifact yields the same bytes (the artifact
is immutable per publish and PKCS#1-v1_5 signing is deterministic). Signing
reuses the DKIM RSA helpers in `KilnCMS.Keys`.

- `KilnCMS.Provenance` — config + manifest build/verify.
- `KilnCMS.Provenance.Canonical` — deterministic JSON + SHA-256 digest.
- `KilnCMS.Provenance.Signer` — RSA sign/verify + public-key info via `KilnCMS.Keys`.
- `KilnCMS.Provenance.KeyRegistry` — resolves which key verifies a given `key_id`.
- `KilnCMSWeb.ProvenanceController` — the public endpoints.

## Scope & Phase 2

Multi-key verification shipped (see [Key rotation](#key-rotation)). Still open:

- **Stateless derivation.** Persisting the manifest at fire-time would pin the
  signer/key/disclosure *as of publish* (audit-grade, survives config changes)
  and let `/verify` detect server-side drift — a natural Phase-2 upgrade that
  slots behind the same API.
- **Signer identity** is a configured string. Tying it to the authenticated
  publisher (per-user keys) is future work.
