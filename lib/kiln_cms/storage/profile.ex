defmodule KilnCMS.Storage.Profile do
  @moduledoc """
  A site's object store, resolved and ready to use (#1559): the buckets, the
  public base URL, and a complete ExAws config built from the site's
  `KilnCMS.CMS.StorageProfile` row alone.

  Built only by `KilnCMS.Storage.SiteProfiles`, and passed as the last
  argument to `KilnCMS.Storage`'s functions to aim them at the site's store
  instead of the operator's. `config` holds the decrypted secret, so it is left
  out of `inspect/1` (and so out of every log line and crash report).
  """

  @derive {Inspect, only: [:id, :org_id, :bucket, :private_bucket, :public_base_url]}
  @enforce_keys [:id, :org_id, :bucket, :public_base_url, :config]
  defstruct [:id, :org_id, :bucket, :private_bucket, :public_base_url, :config]

  @type t :: %__MODULE__{
          id: Ash.UUID.t(),
          org_id: Ash.UUID.t(),
          bucket: String.t(),
          private_bucket: String.t() | nil,
          public_base_url: String.t(),
          config: map()
        }
end
