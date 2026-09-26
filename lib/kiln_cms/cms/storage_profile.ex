defmodule KilnCMS.CMS.StorageProfile do
  @moduledoc """
  One object store a site has written files to (#1559): an endpoint, region
  and bucket (plus an optional private bucket), the public URL its files are
  served from, and the credentials to reach it.

  A site sets its own object storage at `/editor/site-storage`
  (`KilnCMS.CMS.SiteStorage`), and every media item uploaded while that is on
  records the profile its file went to (`MediaItem.storage_profile_id`). Reads,
  deletes, variants and transforms go through the item's profile, never through
  "whatever the site has set now", so a site that moves to another bucket does
  not strand the files it already has. `nil` on an item is the operator's
  storage (`S3_*` / the Local adapter), which is every item that existed before
  this did.

  That is why a profile is a row of its own rather than the settings row:

    * **Where the files are never changes in place.** The endpoint, region and
      bucket are set when the profile is created and never updated. Pointing
      the site somewhere else creates a new profile; the old one stays, because
      items still name it.
    * **What reaches them can.** The access key, the secret, the public base URL
      (a CDN put in front of the same bucket) and a private bucket added where
      there was none are updated on the profile itself (`:update_credentials`),
      so rotating a key reaches the files the site already has.

  Written only by `KilnCMS.CMS.Changes.SaveStorageProfile`, from the settings
  page, and read through `KilnCMS.Storage.SiteProfiles`, which owns the fail
  direction. Org admin on both sides: the row names the site's storage
  provider and account.

  ## The secret

  Encrypted with `KilnCMS.Keys.Vault` into `secret_access_key_encrypted` and
  never read back into a form. Database-only: a site admin cannot point it at
  an environment variable or a file, which would let them send the operator's
  own secrets to an endpoint of their choosing.

  ## The endpoint

  `https://` only, and SSRF-checked (`Validations.StorageEndpoint`): no
  private, loopback, link-local or metadata address, at save and again at every
  connection (`KilnCMS.Storage.SiteProfiles`). Blank means AWS S3 in the
  profile's region.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @location [:endpoint, :region, :bucket, :private_bucket]
  @reach [:public_base_url, :access_key_id]

  @doc "The fields that say where a profile's files are, and so never change in place."
  @spec location_fields() :: [atom()]
  def location_fields, do: [:endpoint, :region, :bucket]

  postgres do
    table "storage_profiles"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept @location ++ @reach

      argument :secret_access_key, :string, sensitive?: true

      # Copies an existing profile's ciphertext when the admin moved the site to
      # another bucket with the same key — the form never has the secret to send
      # again. Set only by `Changes.SaveStorageProfile`, never from a form.
      argument :secret_access_key_encrypted, KilnCMS.Keys.Vault.Ciphertext, sensitive?: true

      change KilnCMS.CMS.Changes.StoreStorageSecret
    end

    # What can change about a profile without moving its files. `private_bucket`
    # only from none to one — see `Validations.PrivateBucketAdded`.
    update :update_credentials do
      require_atomic? false
      accept [:public_base_url, :access_key_id, :private_bucket]
      argument :secret_access_key, :string, sensitive?: true

      validate KilnCMS.CMS.Validations.PrivateBucketAdded
      change KilnCMS.CMS.Changes.StoreStorageSecret
    end
  end

  policies do
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  validations do
    validate present([:bucket, :region, :public_base_url, :access_key_id])
    validate KilnCMS.CMS.Validations.StorageEndpoint

    # Bucket names as S3 defines them: 3-63 lowercase letters, digits, dots and
    # hyphens. Anything else would be an object key path, not a bucket.
    validate match(:bucket, ~r/\A[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]\z/),
      message: "must be a bucket name: lowercase letters, digits, dots and hyphens"

    validate match(:private_bucket, ~r/\A[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]\z/),
      message: "must be a bucket name: lowercase letters, digits, dots and hyphens"

    validate match(:region, ~r/\A[a-z0-9\-]{1,32}\z/),
      message: "must be a region name like us-east-1 or auto"
  end

  # The tenancy boundary (epic #336): `global?` keeps one site's profiles out of
  # another site's read, and `SiteProfiles` reads every profile tenant-scoped to
  # the item's own org, so an item can never name another site's store.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # `https://host[:port]`, no path. Blank is AWS S3 (the host follows the region).
    attribute :endpoint, :string, public?: true, constraints: [max_length: 255]

    attribute :region, :string do
      default "us-east-1"
      allow_nil? false
      public? true
      constraints max_length: 32
    end

    attribute :bucket, :string, allow_nil?: false, public?: true, constraints: [max_length: 63]

    # Gated documents (#481) and direct uploads. Optional, as for the operator:
    # without one, gating is refused rather than put in the public bucket.
    attribute :private_bucket, :string, public?: true, constraints: [max_length: 63]

    # Where the public bucket's files are served from — a CDN or the bucket's
    # public URL, bucket path included. The key is appended to it.
    attribute :public_base_url, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.url()]

    attribute :access_key_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: 128]

    # Set only by `Changes.StoreStorageSecret`. `Vault.Ciphertext`, not plain
    # `:binary`, so `mix kiln.vault.reencrypt` walks it across a
    # `SECRET_KEY_BASE` rotation (#1487).
    attribute :secret_access_key_encrypted, KilnCMS.Keys.Vault.Ciphertext do
      allow_nil? false
      sensitive? true
      writable? false
      public? false
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end
end
