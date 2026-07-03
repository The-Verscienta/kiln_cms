defmodule KilnCMS.Mail.Settings do
  @moduledoc """
  Singleton instance-wide mail settings: the DKIM key reference and the
  operator-facing direct-delivery state (server IP, last DNS verification).

  Key material follows the provider model (`KilnCMS.Keys`): this row stores
  *which* provider and its config, plus the non-secret public key — always in
  the database regardless of provider, so the DNS TXT record display and
  verification work the same for env/file/database keys. Only the database
  provider persists the private key here, encrypted (`KilnCMS.Keys.Vault`).

  The row is created lazily (`KilnCMS.Mail.ensure_settings!/0`) and unique by
  the constant `singleton` column.
  """
  use Ash.Resource,
    domain: KilnCMS.Mail,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "mail_settings"
    repo KilnCMS.Repo

    # The provider set is enforced in the Ash layer (`one_of` below), but Ash
    # casts this column to an atom on *read*, so an out-of-band write of any
    # other string would crash every read of the singleton — taking down the
    # whole outbound-mail pipeline. A DB-level CHECK makes the bad write
    # impossible in the first place.
    check_constraints do
      check_constraint :dkim_key_provider, "dkim_key_provider_must_be_known",
        check: "dkim_key_provider IN ('database', 'env', 'file')"
    end
  end

  actions do
    defaults [:read]

    # Lazy get-or-create; all real state arrives via the update actions.
    create :init do
      accept []
    end

    # Generate a database-provider key. From the env/file providers this
    # switches back to :database (with fresh material); with a database key
    # already present it refuses — use :rotate_dkim, which is the same
    # operation minus the guard, so the intent is explicit in the audit trail.
    update :generate_dkim do
      accept []
      require_atomic? false
      change KilnCMS.Mail.Settings.Changes.GenerateDkim
    end

    update :rotate_dkim do
      accept []
      require_atomic? false
      change {KilnCMS.Mail.Settings.Changes.GenerateDkim, rotate: true}
    end

    # Point the DKIM key at an env var or file. Checks the source, derives
    # the public key from what it finds, and rotates the selector only when
    # the key material actually changed.
    update :configure_key_source do
      accept []
      require_atomic? false

      argument :provider, :atom do
        allow_nil? false
        constraints one_of: [:env, :file]
      end

      argument :config, :map, default: %{}

      change KilnCMS.Mail.Settings.Changes.ConfigureKeySource
    end

    update :set_server_ip do
      accept [:server_ip]
      require_atomic? false
      validate KilnCMS.Mail.Settings.Validations.ServerIp
    end

    update :record_verification do
      accept [:verification_results]
      require_atomic? false
      change set_attribute(:last_verified_at, &DateTime.utc_now/0)
    end
  end

  policies do
    # Mail settings are admin-only. The delivery pipeline reads them with
    # `authorize?: false` as a system job (KilnCMS.Mail.dkim_config/0).
    policy always() do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id

    # Constant column backing the unique "there is one row" identity.
    attribute :singleton, :integer do
      allow_nil? false
      default 0
      writable? false
    end

    attribute :dkim_selector, :string, public?: true

    attribute :dkim_key_provider, :atom do
      allow_nil? false
      default :database
      constraints one_of: [:database, :env, :file]
      public? true
    end

    # Provider-specific pointer (%{"var" => ...} / %{"path" => ...}); never
    # key material. Empty for the database provider.
    attribute :dkim_key_provider_config, :map, allow_nil?: false, default: %{}, public?: true

    attribute :dkim_private_key_encrypted, :binary do
      sensitive? true
      writable? false
    end

    # The DKIM TXT record's p= value (base64 SubjectPublicKeyInfo DER).
    attribute :dkim_public_key, :string, public?: true

    # Operator-entered public IP; drives the SPF suggestion and PTR check.
    attribute :server_ip, :string, public?: true

    attribute :last_verified_at, :utc_datetime_usec, public?: true
    attribute :verification_results, :map, public?: true

    timestamps()
  end

  identities do
    identity :singleton_row, [:singleton]
  end
end
