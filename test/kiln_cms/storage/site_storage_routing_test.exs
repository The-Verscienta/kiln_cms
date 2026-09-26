defmodule KilnCMS.Storage.SiteStorageRoutingTest do
  @moduledoc """
  Where a file goes, and where it is read from, once a site has its own
  object storage (#1559).

    * **An upload goes to the site's current store and the row says so** —
      `storage_profile_id` and a `url` under the site's public base.
    * **Every later operation follows the row, not the setting.** Switched off
      or moved to another bucket, the site's old files are still read and
      deleted where they are.
    * **An unusable store refuses the upload.** Nothing is written to the
      operator's store, and no row is created.

  The test env's operator store is the Local adapter, so a request that
  reaches the S3 stub at all is a request to a site's store.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Media.Ingest
  alias KilnCMS.Storage

  @valid %{
    enabled: true,
    endpoint: "https://s3.site.example",
    region: "auto",
    bucket: "site-bucket",
    public_base_url: "https://cdn.site.example/site-bucket",
    access_key_id: "SITEKEYID",
    secret_access_key: "site-secret-value"
  }

  # 1x1 PNG.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  setup do
    org = KilnCMS.OrgFixtures.org("storage-routing")
    test = self()

    # A tiny bucket: PUT stores, GET returns, DELETE forgets — keyed by host
    # and path, so a request to the wrong bucket finds nothing.
    {:ok, bucket} = Agent.start_link(fn -> %{} end)

    Req.Test.stub(KilnCMS.Storage.S3, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      key = {conn.host, conn.request_path}
      send(test, {:s3, conn.method, conn.host, conn.request_path})

      case conn.method do
        "PUT" ->
          Agent.update(bucket, &Map.put(&1, key, body))
          Plug.Conn.send_resp(conn, 200, "")

        "GET" ->
          case {Agent.get(bucket, &Map.get(&1, key)), Plug.Conn.get_req_header(conn, "range")} do
            {nil, _range} ->
              Plug.Conn.send_resp(conn, 404, "")

            {bytes, []} ->
              Plug.Conn.send_resp(conn, 200, bytes)

            # `Storage.copy_to_file/3` reads in ranges and needs the total.
            {bytes, ["bytes=" <> range]} ->
              [first, last] = String.split(range, "-")
              first = String.to_integer(first)
              last = min(String.to_integer(last), byte_size(bytes) - 1)

              conn
              |> Plug.Conn.put_resp_header(
                "content-range",
                "bytes #{first}-#{last}/#{byte_size(bytes)}"
              )
              |> Plug.Conn.send_resp(206, binary_part(bytes, first, last - first + 1))
          end

        "DELETE" ->
          Agent.update(bucket, &Map.delete(&1, key))
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    %{org: org, actor: admin(), bucket: bucket}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "routing-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp save!(org, attrs \\ %{}) do
    case CMS.list_site_storage(tenant: org, authorize?: false) do
      {:ok, [row]} ->
        CMS.update_site_storage!(row, Map.merge(@valid, attrs), tenant: org, authorize?: false)

      {:ok, []} ->
        CMS.save_site_storage!(Map.merge(@valid, attrs), tenant: org, authorize?: false)
    end
  end

  defp upload(org, actor) do
    path = Path.join(System.tmp_dir!(), "routing-#{System.unique_integer([:positive])}.png")
    File.write!(path, @png)
    on_exit(fn -> File.rm(path) end)
    Ingest.store_file(path, "cat.png", actor: actor, tenant: org)
  end

  test "an upload goes to the site's store, and the row records which", %{org: org} = ctx do
    row = save!(org)

    assert {:ok, item} = upload(org, ctx.actor)

    assert item.storage_profile_id == row.profile_id
    assert item.url == "https://cdn.site.example/site-bucket/#{item.storage_key}"
    assert_received {:s3, "PUT", "s3.site.example", path}
    assert path == "/site-bucket/#{item.storage_key}"
  end

  test "a site without its own store uploads as before: operator store, no profile",
       %{org: org} = ctx do
    assert {:ok, item} = upload(org, ctx.actor)

    assert item.storage_profile_id == nil
    refute_received {:s3, _method, _host, _path}
  end

  test "switched off, the site's old files are still read and deleted where they are",
       %{org: org} = ctx do
    save!(org)
    {:ok, item} = upload(org, ctx.actor)

    save!(org, %{enabled: false, secret_access_key: ""})

    # A new upload goes to the operator's store now…
    assert {:ok, %{storage_profile_id: nil}} = upload(org, ctx.actor)

    # …and the old one is still read from the site's bucket, through its row.
    # (The stored bytes are the metadata-stripped copy, so not `@png` itself.)
    assert {:ok, <<0x89, "PNG", _rest::binary>> = stored} = Storage.fetch(item.storage_key, item)

    dest = Path.join(System.tmp_dir!(), "routing-copy-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(dest) end)
    assert :ok = Storage.copy_to_file(item.storage_key, dest, at: item)
    assert File.read!(dest) == stored

    assert :ok = Storage.delete(item.storage_key, item)
    assert {:error, _gone} = Storage.fetch(item.storage_key, item)
  end

  test "moved to another bucket, old files stay in the old one", %{org: org} = ctx do
    save!(org)
    {:ok, old} = upload(org, ctx.actor)

    save!(org, %{bucket: "moved-bucket", secret_access_key: ""})
    {:ok, new} = upload(org, ctx.actor)

    refute new.storage_profile_id == old.storage_profile_id
    assert_received {:s3, "PUT", _host, "/moved-bucket/" <> _key}

    assert {:ok, <<0x89, "PNG", _rest::binary>>} = Storage.fetch(old.storage_key, old)
    assert_received {:s3, "GET", _host, "/site-bucket/" <> _key}
  end

  test "an unusable store refuses the upload and writes nothing anywhere",
       %{org: org} = ctx do
    row = save!(org)

    Repo.query!(
      "UPDATE storage_profiles SET secret_access_key_encrypted = $1 WHERE id = $2",
      ["not ciphertext", Ecto.UUID.dump!(row.profile_id)]
    )

    before = CMS.list_media_items!(tenant: org, authorize?: false)

    assert upload(org, ctx.actor) == {:error, {:site_storage, :credentials_unreadable}}

    assert CMS.list_media_items!(tenant: org, authorize?: false) == before
    refute_received {:s3, _method, _host, _path}
  end

  test "an item whose store can't be resolved fails to read rather than asking the operator's",
       %{org: org} = ctx do
    row = save!(org)
    {:ok, item} = upload(org, ctx.actor)

    Repo.query!(
      "UPDATE storage_profiles SET secret_access_key_encrypted = $1 WHERE id = $2",
      ["not ciphertext", Ecto.UUID.dump!(row.profile_id)]
    )

    assert Storage.fetch(item.storage_key, item) ==
             {:error, {:site_storage, :credentials_unreadable}}
  end

  test "a direct upload stages in the site's private bucket and lands in its store",
       %{org: org, bucket: bucket} = ctx do
    row = save!(org, %{private_bucket: "site-private"})

    assert {:ok, %{upload_url: url, token: token}} =
             KilnCMS.Media.DirectUpload.begin(
               %{"filename" => "cat.png", "byte_size" => byte_size(@png)},
               ctx.actor,
               org.id
             )

    uri = URI.parse(url)
    assert uri.host == "s3.site.example"
    assert "/site-private/direct-uploads/" <> _id = uri.path

    # The client's PUT, straight to the bucket.
    Agent.update(bucket, &Map.put(&1, {uri.host, uri.path}, @png))

    {:ok, metadata} = KilnCMS.Media.Upload.metadata(%{})

    assert {:ok, item} = KilnCMS.Media.DirectUpload.complete(token, metadata, ctx.actor, org.id)

    assert item.storage_profile_id == row.profile_id
    # The staged object was read from, and then deleted in, the site's bucket.
    assert_received {:s3, "GET", "s3.site.example", "/site-private/direct-uploads/" <> _}
    assert_received {:s3, "DELETE", "s3.site.example", "/site-private/direct-uploads/" <> _}
  end

  test "a site store without a private bucket offers no direct uploads", %{org: org} = ctx do
    save!(org)

    refute KilnCMS.Media.DirectUpload.available?(org.id)

    assert KilnCMS.Media.DirectUpload.begin(
             %{"filename" => "cat.png", "byte_size" => 10},
             ctx.actor,
             org.id
           ) == {:error, :direct_uploads_unavailable}
  end
end
