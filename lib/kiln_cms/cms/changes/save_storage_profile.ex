defmodule KilnCMS.CMS.Changes.SaveStorageProfile do
  @moduledoc """
  Turns the storage fields a site admin saved (`KilnCMS.CMS.SiteStorage`'s
  `:save`/`:update` arguments) into the `KilnCMS.CMS.StorageProfile` new
  uploads go to, and points `SiteStorage.profile_id` at it.

    * **Same place, new keys.** The endpoint, region and bucket match the
      current profile's (and its private bucket, or it had none): the profile
      is updated in place (`:update_credentials`). The site's existing files
      are in that bucket, so they need the new key too.
    * **Somewhere else.** Anything about the location differs: a **new**
      profile is created and the old one is left alone, because the files
      already uploaded are still in the old bucket and still named by their
      media rows. A blank secret with an unchanged endpoint, region and access
      key carries the old profile's ciphertext across — the admin moved
      buckets, not accounts. Anything else needs the secret typed again.
    * **Nothing entered**, and switched off: nothing changes. The profile, if
      there is one, stays where it was for when the site switches back on.

  Runs in a `before_action`, inside the settings write's transaction, so a
  refused profile write leaves the settings row as it was. The profile's own
  validations (SSRF, bucket names, required fields) are its errors, reported
  on the same field names the form uses.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS
  alias KilnCMS.CMS.StorageProfile

  @fields [:endpoint, :region, :bucket, :private_bucket, :public_base_url, :access_key_id]

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &sync(&1, context))
  end

  defp sync(changeset, context) do
    args = entered(changeset)
    enabled? = Ash.Changeset.get_attribute(changeset, :enabled)

    if args == %{} and (not enabled? or not is_nil(changeset.data.profile_id)) do
      changeset
    else
      opts = context |> Ash.Context.to_opts() |> Keyword.put(:tenant, changeset.tenant)
      secret = Ash.Changeset.get_argument(changeset, :secret_access_key)

      case write_profile(current(changeset.data.profile_id, opts), args, secret, opts) do
        {:ok, profile} -> Ash.Changeset.force_change_attribute(changeset, :profile_id, profile.id)
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end
  end

  defp write_profile(%StorageProfile{} = current, args, secret, opts) do
    if same_location?(current, args) do
      attrs =
        args
        |> Map.take([:public_base_url, :access_key_id, :private_bucket])
        |> Map.put(:secret_access_key, secret)

      CMS.update_storage_profile_credentials(current, attrs, opts)
    else
      create(args, secret, carried_secret(current, args, secret), opts)
    end
  end

  defp write_profile(nil, args, secret, opts), do: create(args, secret, nil, opts)

  defp create(args, secret, carried, opts) do
    args
    |> Map.put(:secret_access_key, secret)
    |> Map.put(:secret_access_key_encrypted, carried)
    |> CMS.create_storage_profile(opts)
  end

  # Only for the same account at the same provider: a new access key with no
  # secret is a mistake the create should refuse, not a key to pair with
  # somebody else's secret — and a stored secret is never carried to an
  # endpoint the admin who typed it didn't choose. (SigV4 sends signatures, not
  # the secret, but a co-admin who was never shown the key has no business
  # aiming it anywhere new.)
  defp carried_secret(current, args, secret) do
    if blank?(secret) and args[:access_key_id] == current.access_key_id and
         normalize_endpoint(current.endpoint) == normalize_endpoint(args[:endpoint]) and
         region(current.region) == region(args[:region]),
       do: current.secret_access_key_encrypted
  end

  defp same_location?(current, args) do
    normalize_endpoint(current.endpoint) == normalize_endpoint(args[:endpoint]) and
      region(current.region) == region(args[:region]) and
      current.bucket == args[:bucket] and
      (is_nil(current.private_bucket) or current.private_bucket == args[:private_bucket])
  end

  # The profile the settings row points at now. Read with the caller's own
  # options (an org admin, tenant-scoped); a profile that can't be read is
  # treated as none, so the save creates a fresh one rather than updating
  # something it could not see.
  defp current(nil, _opts), do: nil

  defp current(id, opts) do
    case CMS.get_storage_profile(id, opts) do
      {:ok, profile} -> profile
      {:error, _error} -> nil
    end
  end

  # The arguments the admin filled in, trimmed; blanks left out so the
  # profile's own defaults and `present` validations apply.
  defp entered(changeset) do
    for field <- @fields,
        value = trim(Ash.Changeset.get_argument(changeset, field)),
        value != nil,
        into: %{} do
      {field, if(field == :endpoint, do: normalize_endpoint(value), else: value)}
    end
  end

  defp normalize_endpoint(nil), do: nil
  defp normalize_endpoint(url), do: String.trim_trailing(url, "/")

  defp region(nil), do: "us-east-1"
  defp region(region), do: region

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(_value), do: nil

  defp blank?(value), do: is_nil(trim(value))
end
