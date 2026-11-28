defmodule KilnCMS.Keys.ClientDigest do
  @moduledoc """
  The digest a client key is stored under (#3501): an HMAC-SHA256 under a key
  derived from the endpoint's `secret_key_base` with a label of its own.

  A client key is small and guessable: `"inet:203.0.113.5"`, `"<org>|1.2.3.4/32"`,
  a raw address, or `KilnCMS.Accounts.AccountThrottle.digest/1` (an unsalted
  SHA-256 of a lowercased email). A plain SHA-256 of one is reversed by
  hashing every IPv4 address, or a list of known emails, in minutes. Keyed
  with a secret that is not in the database, a row taken from a `pg_dump`, a
  backup or an unscrubbed staging clone names nobody.

  Two tables store their keys through here, and nothing else does:

    * `throttle_counters.key_hash` (`KilnCMS.Accounts.ThrottleStore.key_hash/1`)
    * `crawler_sightings.key_hash` (`KilnCMS.Security.CrawlerSightingStore.key_hash/1`)

  ## Why this secret

  `SECRET_KEY_BASE` is the same on every node, so every node lands a key on the
  same row (a per-node or per-boot key would give an attacker one budget per
  node, which is what #1619 removed). It is never written to the database, so
  a dump does not carry it (`docs/backups.md`), and a staging clone runs its
  own. And it needs no database: the node-local fallback
  (`ThrottleStore.Local`, keyed by this digest) needs the digest exactly when
  the database cannot answer. `Plug.Crypto.KeyGenerator` derives the key once
  per node (`Plug.Crypto.Keys` caches it), and the label keeps it apart from
  every other key derived from the same secret, as `KilnCMS.Keys.Vault` and
  `KilnCMS.Accounts.SignInUnlock.address_digest/1` do.

  Without the secret a digest is not reversible, and with it only by guessing
  the key again; it is a pseudonym, not an encryption.

  ## Rotating `secret_key_base`

  A hard cutover. `PREVIOUS_SECRET_KEY_BASE` is not read here: after a
  rotation every budget, tally and sighting lands on a new row and starts again
  in its current window, and the old rows lapse through `expires_at`. That
  resets active sign-in pauses too. A rolling rotation, with nodes on both
  secrets at once, splits each key over two rows exactly as the rolling deploy
  that introduced this digest does (below). Changing the label is a rotation.

  ## The rolling deploy that introduced it

  While nodes on the release before this one (plain SHA-256) and nodes on this
  one run side by side, one key is counted on two rows. Every
  `AccountThrottle` bucket splits: sign-in and second-factor budgets, the mail
  budgets (an hour's window), the alert windows (one duplicate alert mail is
  possible), passkey registration. So do the `KilnCMSWeb.RateLimit` credential
  buckets, the challenge gate, the scanner guard and the failed-sign-in alert
  tally (an alert can fire late, or not at all, for one window). The effect is
  bounded at twice a budget per window, for each window the mixed period
  covers (a fixed window already admits twice its budget across a boundary),
  and an attacker collects it by retrying through denials, no deploy detection
  needed. It ends one window of the longest budget after the last old node
  stops. A single node stopped and started again resets each budget once
  rather than splitting it.
  """

  alias KilnCMS.Keys.Vault

  @label "kiln client key digest v1"

  @doc "The digest of `client_key` under the configured `secret_key_base`."
  @spec digest(String.t()) :: <<_::256>>
  def digest(client_key) when is_binary(client_key),
    do: digest(client_key, Vault.secret_key_base())

  @doc "The digest of `client_key` under an explicit `secret_key_base`."
  @spec digest(String.t(), String.t()) :: <<_::256>>
  def digest(client_key, secret_key_base)
      when is_binary(client_key) and is_binary(secret_key_base) do
    key =
      Plug.Crypto.KeyGenerator.generate(secret_key_base, @label,
        length: 32,
        cache: Plug.Crypto.Keys
      )

    :crypto.mac(:hmac, :sha256, key, client_key)
  end
end
