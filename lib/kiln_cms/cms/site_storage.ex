defmodule KilnCMS.CMS.SiteStorage do
  @moduledoc """
  A site's own object storage (#1559): whether this site's new uploads go to
  a bucket its admin chose, at `/editor/site-storage`, instead of to the
  operator's (`S3_*` environment variables, or the Local adapter).

  Built on `KilnCMS.CMS.OrgSettings` like the other per-site integrations
  (#1322). Unlike them it holds no settings of its own beyond the switch: the
  bucket and credentials live on the `KilnCMS.CMS.StorageProfile` that
  `profile_id` names, because storage holds data. Every media item records the
  profile its file went to, and a profile's location never changes in place,
  so moving the site to another bucket leaves the files it already has
  readable where they are. See `StorageProfile`'s moduledoc.

  `:save` and `:update` take the profile's fields as arguments;
  `Changes.SaveStorageProfile` turns them into a profile (updating the current
  one when only its credentials changed, creating a new one when its location
  did) and points `profile_id` at it.

  Read through `KilnCMS.Storage.SiteProfiles`, which owns the precedence rule
  and the fail direction; nothing else should read this row. Reads are
  admin-only, as for every integration.

  ## Switching off

  `enabled: false` keeps the profile and sends new uploads to the operator's
  storage again. Files already uploaded stay in the site's bucket and are still
  read from it — switching off is about where the *next* file goes. The same
  is true of removing the row.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_storages",
    accept: [:enabled],
    upsert_fields: [:enabled, :profile_id],
    save_arguments: [
      {:endpoint, :string},
      {:region, :string},
      {:bucket, :string},
      {:private_bucket, :string},
      {:public_base_url, :string},
      {:access_key_id, :string},
      {:secret_access_key, :string, sensitive?: true}
    ],
    save_changes: [KilnCMS.CMS.Changes.SaveStorageProfile],
    read: :admin

  # The site's pages allow images and media from every profile's public origin
  # (`KilnCMSWeb.Plugs.SiteStorageCsp`), cached per site, and profiles are only
  # ever written by this resource's saves. After the commit, not in it: a bust
  # that ran before the write landed could be refilled from the old rows.
  changes do
    change after_transaction(fn
             _changeset, {:ok, row}, _context ->
               KilnCMS.Cache.bust_site_storage_hosts(row.org_id)
               {:ok, row}

             _changeset, error, _context ->
               error
           end),
           on: [:create, :update]
  end

  attributes do
    # Off keeps the profile but sends new uploads to the operator's storage
    # again — the way back from a broken bucket that does not mean retyping it.
    attribute :enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    # The `StorageProfile` new uploads go to while `enabled`. Set only by
    # `Changes.SaveStorageProfile`. No foreign key: profiles have no destroy
    # action, and media rows name profiles without one either.
    attribute :profile_id, :uuid do
      writable? false
      public? false
    end
  end
end
