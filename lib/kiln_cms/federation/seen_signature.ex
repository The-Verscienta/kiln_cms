defmodule KilnCMS.Federation.SeenSignature do
  @moduledoc """
  The replay nonce store for inbound HTTP signatures (#967).

  `KilnCMS.Federation.HttpSignature` bounds replay with a 300-second `Date`
  window — what Mastodon enforces, and the documented phase-1 position. Inside
  that window a byte-identical signed request replayed freely. This closes it:
  after a signature verifies, its SHA-256 is **inserted** here, and the insert
  is the check — the primary key is the hash, so the second arrival of the same
  signature fails the unique constraint and is refused as a replay. Same
  design as `KilnCMS.Accounts.Token`'s `:spend_jti` (#743), for the same
  reason: a node-local store fails *open* across nodes, and a replay landing
  on a node that never saw the original would be accepted. A row in Postgres is
  the same answer on every node.

  Rows expire `expires_at` — twice the date window, so a signature is held for
  the whole time its `Date` could still verify — and are swept hourly by
  `KilnCMS.Federation.SeenSignatureSweeper`. Not tenant-scoped: a signature is
  bound to one request against one origin already (the signing string covers
  `host`), so there is nothing per-org about "seen before".

  Recorded **after** verification, never before: an unverified signature is
  refused anyway, and recording it would let a caller fill the table with
  garbage.
  """
  use Ash.Resource,
    domain: KilnCMS.Federation,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "federation_seen_signatures"
    repo KilnCMS.Repo

    custom_indexes do
      # The sweep's scan.
      index [:expires_at], name: "federation_seen_signatures_expires_at_index"
    end
  end

  actions do
    defaults [:read]

    # The INSERT is the check. Not an upsert — a conflict is the answer.
    create :record do
      accept [:signature_hash, :expires_at]
    end

    destroy :destroy do
      primary? true
    end

    # Rows whose window has passed. Bulk-destroyed by the sweeper.
    read :expired do
      filter expr(expires_at < now())
    end
  end

  policies do
    # System-only in every direction: the inbox writes and the sweeper deletes,
    # both with `authorize?: false`; nothing user-facing reads a nonce table.
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    # SHA-256 of the raw `signature` parameter, hex. The primary key so the
    # uniqueness IS the replay check.
    attribute :signature_hash, :string do
      primary_key? true
      allow_nil? false
      public? false
      constraints max_length: 64
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? false
    end

    create_timestamp :inserted_at
  end
end
