defmodule KilnCMS.Staging.ScrubStorageTest do
  @moduledoc """
  What the staging scrub does to a site's own object storage (#2973). The
  owner's decision: staging gets its own bucket. A scrubbed clone

    * keeps serving the files production already uploaded, from production's
      public URLs (read-only: no credentials needed);
    * cannot write to or delete from production's bucket, even when started
      with production's `SECRET_KEY_BASE`;
    * stores new uploads in its operator storage (the Local adapter here)
      until someone configures a bucket for staging.

  The test env's operator store is the Local adapter, so a request that
  reaches the S3 stub at all is a request to the site's (production's) bucket.

  `async: false`: `Req.Test.stub/2` for `KilnCMS.Storage.S3` is shared, as in
  `KilnCMS.Storage.SiteStorageRoutingTest`.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Media.Ingest
  alias KilnCMS.Repo
  alias KilnCMS.Staging.Scrub
  alias KilnCMS.Storage
  alias KilnCMS.Storage.SiteProfiles

  @production %{
    enabled: true,
    endpoint: "https://s3.prod.example",
    region: "auto",
    bucket: "prod-bucket",
    public_base_url: "https://cdn.prod.example/prod-bucket",
    access_key_id: "PRODKEYID",
    secret_access_key: "prod-secret-value"
  }

  # 1x1 PNG.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  setup do
    org = KilnCMS.OrgFixtures.org("scrub-storage")
    test = self()

    Req.Test.stub(KilnCMS.Storage.S3, fn conn ->
      send(test, {:s3, conn.method, conn.host, conn.request_path})

      case conn.method do
        "GET" -> Plug.Conn.send_resp(conn, 200, "bytes")
        "DELETE" -> Plug.Conn.send_resp(conn, 204, "")
        _put -> Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "scrub-storage-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    # Production's state: the site's own bucket, and a file uploaded to it.
    # authorize?: false — fixture setup of a production clone; the settings
    # page's authorization is tested in site_storage_live_test.exs.
    setting = CMS.save_site_storage!(@production, tenant: org.id, authorize?: false)
    {:ok, item} = upload(org, actor)
    assert item.storage_profile_id == setting.profile_id
    assert_received {:s3, "PUT", "s3.prod.example", _path}

    %{org: org, actor: actor, item: item, setting: setting}
  end

  defp upload(org, actor) do
    path = Path.join(System.tmp_dir!(), "scrub-storage-#{System.unique_integer([:positive])}.png")
    File.write!(path, @png)
    on_exit(fn -> File.rm(path) end)
    Ingest.store_file(path, "cat.png", actor: actor, tenant: org.id)
  end

  defp profile!(org, id),
    do: CMS.get_storage_profile!(id, tenant: org.id, authorize?: false)

  test "the profile keeps where the files are and loses what reaches them", ctx do
    summary = Scrub.run([])

    assert summary.storage_credentials_scrubbed >= 1
    assert summary.site_storages_disabled >= 1

    profile = profile!(ctx.org, ctx.setting.profile_id)
    assert profile.bucket == "prod-bucket"
    assert profile.public_base_url == "https://cdn.prod.example/prod-bucket"
    assert profile.access_key_id == "scrubbed"
    refute profile.access_key_id =~ "PRODKEYID"
    refute SiteProfiles.secret_readable?(profile)
    assert {:error, :credentials_unreadable} = SiteProfiles.build(profile)
  end

  test "a scrubbed secret counts as empty to the vault re-encryption walk", ctx do
    Scrub.run([])

    reports = KilnCMS.Keys.Reencrypt.run(dry_run: true)

    report =
      Enum.find(
        reports,
        &(&1.table == "storage_profiles" and &1.column == "secret_access_key_encrypted")
      )

    refute ctx.setting.profile_id in report.unreadable
    assert report.empty >= 1
  end

  test "existing media keeps rendering from production's public URLs", ctx do
    Scrub.run([])

    item = CMS.get_media_item!(ctx.item.id, tenant: ctx.org.id, authorize?: false)
    assert item.url == ctx.item.url
    assert item.url =~ "https://cdn.prod.example/prod-bucket/"

    # The site's CSP still allows images from production's bucket; without
    # it the browser would refuse the URL above.
    KilnCMS.Cache.bust_site_storage_hosts(ctx.org.id)
    assert "https://cdn.prod.example" in SiteProfiles.csp_origins(ctx.org.id)
  end

  test "the clone cannot write to, read from or delete from production's bucket", ctx do
    Scrub.run([])

    item = CMS.get_media_item!(ctx.item.id, tenant: ctx.org.id, authorize?: false)

    assert {:error, {:site_storage, :credentials_unreadable}} =
             Storage.delete(item.storage_key, item)

    assert {:error, {:site_storage, :credentials_unreadable}} =
             Storage.fetch(item.storage_key, item)

    assert {:error, {:site_storage, :credentials_unreadable}} =
             Storage.store("staging-#{item.storage_key}", "/dev/null", item)

    refute_received {:s3, _method, _host, _path}
  end

  test "new uploads go to the staging host's own storage", ctx do
    Scrub.run([])

    assert {:ok, nil} = Storage.upload_target(ctx.org.id)
    assert {:ok, item} = upload(ctx.org, ctx.actor)

    assert item.storage_profile_id == nil
    refute item.url =~ "cdn.prod.example"
    refute_received {:s3, _method, _host, _path}
  end

  test "switched back on as it is, the scrubbed profile refuses uploads", ctx do
    Scrub.run([])

    [row] = CMS.list_site_storage!(tenant: ctx.org.id, authorize?: false)
    refute row.enabled
    CMS.update_site_storage!(row, %{enabled: true}, tenant: ctx.org.id, authorize?: false)

    assert {:error, {:site_storage, :credentials_unreadable}} =
             Storage.upload_target(ctx.org.id)

    refute_received {:s3, _method, _host, _path}
  end

  test "a second scrub finds the storage settings already scrubbed" do
    Scrub.run([])
    second = Scrub.run([])

    assert second.storage_credentials_scrubbed == 0
    assert second.site_storages_disabled == 0
    assert Repo.aggregate(KilnCMS.CMS.StorageProfile, :count) >= 1
  end
end
