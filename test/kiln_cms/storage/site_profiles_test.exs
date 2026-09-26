defmodule KilnCMS.Storage.SiteProfilesTest do
  @moduledoc """
  A site's own object storage (#1559): the settings row, the profiles it
  writes, and `KilnCMS.Storage.SiteProfiles`, which answers "where does this
  upload go" and "where is this file".

  The properties pinned here are the ones the issue is about:

    * **a file stays where it was stored** — a row names its profile, moving
      the site to another bucket makes a new profile and leaves the old one
      readable, and only a credentials change updates a profile in place;
    * **unusable fails closed** — an unreadable secret or a vanished profile is
      an error, never `{:ok, nil}` (the operator's store);
    * **nothing crosses sites** — a profile id from another site resolves to
      nothing.

  The no-operator-credentials property has its own file,
  `KilnCMS.Storage.SiteStorageIsolationTest`.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Storage
  alias KilnCMS.Storage.{Profile, SiteProfiles}

  @valid %{
    enabled: true,
    endpoint: "https://s3.site.example",
    region: "auto",
    bucket: "site-bucket",
    public_base_url: "https://cdn.site.example/site-bucket",
    access_key_id: "SITEKEY",
    secret_access_key: "site-secret"
  }

  setup do
    %{org: KilnCMS.OrgFixtures.org("storage-#{System.unique_integer([:positive])}")}
  end

  defp save!(org, attrs \\ %{}) do
    case CMS.list_site_storage(tenant: org, authorize?: false) do
      {:ok, [row]} ->
        CMS.update_site_storage!(row, Map.merge(@valid, attrs), tenant: org, authorize?: false)

      {:ok, []} ->
        CMS.save_site_storage!(Map.merge(@valid, attrs), tenant: org, authorize?: false)
    end
  end

  defp save(org, attrs) do
    CMS.save_site_storage(Map.merge(@valid, attrs), tenant: org, authorize?: false)
  end

  defp profiles(org), do: CMS.list_storage_profiles!(tenant: org, authorize?: false)

  describe "for_upload/1" do
    test "a site with no row uploads to the operator's store", %{org: org} do
      assert SiteProfiles.for_upload(org.id) == {:ok, nil}
    end

    test "a switched-off row uploads to the operator's store, and keeps its profile",
         %{org: org} do
      row = save!(org, %{enabled: false})

      assert SiteProfiles.for_upload(org.id) == {:ok, nil}
      assert row.profile_id
    end

    test "a switched-on row uploads to the site's own store", %{org: org} do
      row = save!(org)

      assert {:ok, %Profile{} = profile} = SiteProfiles.for_upload(org.id)
      assert profile.id == row.profile_id
      assert profile.org_id == org.id
      assert profile.bucket == "site-bucket"
      assert profile.public_base_url == "https://cdn.site.example/site-bucket"
      assert profile.config.access_key_id == "SITEKEY"
      assert profile.config.secret_access_key == "site-secret"
      assert profile.config.host == "s3.site.example"
    end

    test "an undecryptable secret refuses rather than falling back", %{org: org} do
      row = save!(org)
      corrupt_secret(row.profile_id)

      assert SiteProfiles.for_upload(org.id) == {:error, :credentials_unreadable}

      assert Storage.upload_target(org.id) ==
               {:error, {:site_storage, :credentials_unreadable}}
    end

    test "a row whose profile is gone refuses rather than falling back", %{org: org} do
      row = save!(org)
      Repo.query!("DELETE FROM storage_profiles WHERE id = $1", [Ecto.UUID.dump!(row.profile_id)])

      assert SiteProfiles.for_upload(org.id) == {:error, :unavailable}
    end

    test "the inspected profile does not carry the secret", %{org: org} do
      save!(org)
      {:ok, profile} = SiteProfiles.for_upload(org.id)

      refute inspect(profile) =~ "site-secret"
    end
  end

  describe "for_item/1" do
    test "a row with no profile is the operator's store — every row from before #1559" do
      assert SiteProfiles.for_item(%{storage_profile_id: nil, org_id: Ecto.UUID.generate()}) ==
               {:ok, nil}
    end

    test "a row naming its site's profile resolves it", %{org: org} do
      row = save!(org)

      assert {:ok, %Profile{id: id}} =
               SiteProfiles.for_item(%{storage_profile_id: row.profile_id, org_id: org.id})

      assert id == row.profile_id
    end

    test "another site's profile id resolves to nothing", %{org: org} do
      row = save!(org)
      other = KilnCMS.OrgFixtures.org("storage-other-#{System.unique_integer([:positive])}")

      assert SiteProfiles.for_item(%{storage_profile_id: row.profile_id, org_id: other.id}) ==
               {:error, :unavailable}
    end

    test "a row read without the column can't say where its file is" do
      assert SiteProfiles.for_item(%{org_id: Ecto.UUID.generate()}) == {:error, :unavailable}
    end
  end

  describe "saving" do
    test "new keys for the same bucket update the profile in place", %{org: org} do
      first = save!(org)
      second = save!(org, %{access_key_id: "NEWKEY", secret_access_key: "new-secret"})

      assert second.profile_id == first.profile_id
      assert [profile] = profiles(org)
      assert profile.access_key_id == "NEWKEY"

      assert {:ok, %{config: %{secret_access_key: "new-secret"}}} =
               SiteProfiles.for_upload(org.id)
    end

    test "a blank secret keeps the stored one", %{org: org} do
      save!(org)
      save!(org, %{secret_access_key: "", public_base_url: "https://cdn2.site.example/b"})

      assert {:ok, profile} = SiteProfiles.for_upload(org.id)
      assert profile.config.secret_access_key == "site-secret"
      assert profile.public_base_url == "https://cdn2.site.example/b"
    end

    test "another bucket makes a new profile and leaves the old one where it was",
         %{org: org} do
      first = save!(org)
      second = save!(org, %{bucket: "moved-bucket", secret_access_key: ""})

      refute second.profile_id == first.profile_id
      assert length(profiles(org)) == 2

      # The old profile still reaches the old bucket, with the key it had.
      assert {:ok, old} =
               SiteProfiles.for_item(%{storage_profile_id: first.profile_id, org_id: org.id})

      assert old.bucket == "site-bucket"
      assert old.config.secret_access_key == "site-secret"

      # New uploads go to the new one — the secret carried across (same key).
      assert {:ok, new} = SiteProfiles.for_upload(org.id)
      assert new.bucket == "moved-bucket"
      assert new.config.secret_access_key == "site-secret"
    end

    test "a new key for a new bucket needs its secret", %{org: org} do
      row = save!(org)

      assert {:error, error} =
               CMS.update_site_storage(
                 row,
                 Map.merge(@valid, %{
                   bucket: "moved-bucket",
                   access_key_id: "OTHERKEY",
                   secret_access_key: ""
                 }),
                 tenant: org,
                 authorize?: false
               )

      assert Exception.message(error) =~ "secret_access_key"
      assert [_only_the_first] = profiles(org)
    end

    test "the stored secret is never carried to another endpoint", %{org: org} do
      row = save!(org)

      assert {:error, error} =
               CMS.update_site_storage(
                 row,
                 Map.merge(@valid, %{
                   endpoint: "https://s3.elsewhere.example",
                   secret_access_key: ""
                 }),
                 tenant: org,
                 authorize?: false
               )

      assert Exception.message(error) =~ "secret_access_key"
      assert [_only_the_first] = profiles(org)
    end

    test "a private bucket can be added in place, not changed", %{org: org} do
      first = save!(org)
      added = save!(org, %{private_bucket: "site-private", secret_access_key: ""})

      assert added.profile_id == first.profile_id

      changed = save!(org, %{private_bucket: "other-private", secret_access_key: ""})
      refute changed.profile_id == first.profile_id

      profile = CMS.get_storage_profile!(first.profile_id, tenant: org, authorize?: false)

      assert {:error, _error} =
               CMS.update_storage_profile_credentials(profile, %{private_bucket: "x-private"},
                 tenant: org,
                 authorize?: false
               )
    end

    test "switching off with nothing entered keeps the profile", %{org: org} do
      row = save!(org)

      off =
        CMS.update_site_storage!(row, %{enabled: false}, tenant: org, authorize?: false)

      assert off.profile_id == row.profile_id
    end
  end

  describe "validation" do
    test "the endpoint must be https", %{org: org} do
      assert {:error, error} = save(org, %{endpoint: "http://s3.site.example"})
      assert Exception.message(error) =~ "https"
    end

    test "the endpoint may not be a private or metadata address", %{org: org} do
      for endpoint <- ["https://10.0.0.5", "https://169.254.169.254", "https://127.0.0.1:9000"] do
        assert {:error, _error} = save(org, %{endpoint: endpoint}), endpoint
      end

      assert profiles(org) == []
    end

    test "the endpoint is a host, not a path", %{org: org} do
      assert {:error, _error} = save(org, %{endpoint: "https://s3.site.example/bucket"})
    end

    test "no endpoint means AWS, so the region must be one AWS has", %{org: org} do
      assert {:error, error} = save(org, %{endpoint: "", region: "auto"})
      assert Exception.message(error) =~ "endpoint"

      assert {:ok, _row} = save(org, %{endpoint: "", region: "eu-west-1"})
      assert {:ok, profile} = SiteProfiles.for_upload(org.id)
      assert profile.config.host =~ "amazonaws.com"
    end

    test "the public URL must be https and a plain host name", %{org: org} do
      assert {:error, _error} = save(org, %{public_base_url: "http://cdn.site.example/b"})
      assert {:error, _error} = save(org, %{public_base_url: "https://cdn;x.example/b"})
    end

    test "bucket names are S3 bucket names", %{org: org} do
      assert {:error, _error} = save(org, %{bucket: "Not A Bucket/../x"})
    end
  end

  describe "the ExAws config" do
    test "is complete: no value is left for ExAws to look up at request time", %{org: org} do
      save!(org)
      {:ok, %{config: config}} = SiteProfiles.for_upload(org.id)

      # `{:system, "AWS_…"}`, `:instance_role`, `:pod_identity` and `{:awscli, …}`
      # are ExAws's lazy credential sources — each one would reach for the
      # operator's credentials. None may survive into a site's config.
      for {key, value} <- config do
        refute lazy?(value), "#{key} is left to ExAws to resolve: #{inspect(value)}"
      end

      assert Map.fetch!(config, :security_token) == nil
    end
  end

  describe "csp_origins/1" do
    test "every profile's public origin, old ones included", %{org: org} do
      save!(org)
      save!(org, %{bucket: "moved-bucket", public_base_url: "https://media.site.example:8443/x"})
      KilnCMS.Cache.bust_site_storage_hosts(org.id)

      assert Enum.sort(SiteProfiles.csp_origins(org.id)) ==
               ["https://cdn.site.example", "https://media.site.example:8443"]
    end

    test "a site without its own storage adds nothing", %{org: org} do
      assert SiteProfiles.csp_origins(org.id) == []
    end
  end

  defp lazy?({:system, _var}), do: true
  defp lazy?({:awscli, _profile, _ttl}), do: true
  defp lazy?(value) when value in [:instance_role, :pod_identity], do: true
  defp lazy?(values) when is_list(values), do: Enum.any?(values, &lazy?/1)
  defp lazy?(_value), do: false

  defp corrupt_secret(profile_id) do
    Repo.query!(
      "UPDATE storage_profiles SET secret_access_key_encrypted = $1 WHERE id = $2",
      ["not ciphertext", Ecto.UUID.dump!(profile_id)]
    )
  end
end
