defmodule KilnCMS.Storage.SiteStorageIsolationTest do
  @moduledoc """
  A request to a site's own object store carries nothing from the operator's
  ExAws config (#1559, `KilnCMS.Storage.SiteProfiles`'s moduledoc).

  `ExAws.request/2` merges its overrides over the app's `:ex_aws` config, so a
  site config handed to it would inherit whatever the site's config does not
  set — the operator's session token, its endpoint host, its region — and the
  operator's signed request would go to a host a tenant chose. In the test env
  the operator's config is only dummy `test`/`test` keys, which prove nothing
  about a merge, so this file PLANTS distinctive operator credentials and an
  operator endpoint, and asserts none of them reaches the site's store: not in
  a request, not in a presigned URL.

  The operator's own request is asserted too, as the control: it is what shows
  the planted values are live, so their absence on the site's request means
  something.

  `async: false` because it rewrites the global `:ex_aws` config.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Storage
  alias KilnCMS.Storage.SiteProfiles

  @operator_key "OPERATORKEYID"
  @operator_secret "operator-secret-value"
  @operator_token "OPERATOR-SESSION-TOKEN"
  @operator_host "operator-s3.internal"

  setup do
    common = Application.get_all_env(:ex_aws)
    s3 = Application.get_env(:ex_aws, :s3)

    Application.put_env(:ex_aws, :access_key_id, @operator_key)
    Application.put_env(:ex_aws, :secret_access_key, @operator_secret)
    Application.put_env(:ex_aws, :security_token, @operator_token)
    Application.put_env(:ex_aws, :s3, scheme: "https://", host: @operator_host, port: 443)

    on_exit(fn ->
      for key <- [:access_key_id, :secret_access_key, :security_token, :s3],
          do: Application.delete_env(:ex_aws, key)

      for {key, value} <- common, do: Application.put_env(:ex_aws, key, value)
      if s3, do: Application.put_env(:ex_aws, :s3, s3)
    end)

    org = KilnCMS.OrgFixtures.org("storage-isolation")

    CMS.save_site_storage!(
      %{
        enabled: true,
        endpoint: "https://s3.site.example",
        region: "auto",
        bucket: "site-bucket",
        private_bucket: "site-private",
        public_base_url: "https://cdn.site.example/site-bucket",
        access_key_id: "SITEKEYID",
        secret_access_key: "site-secret-value"
      },
      tenant: org,
      authorize?: false
    )

    {:ok, profile} = SiteProfiles.for_upload(org.id)

    test = self()

    Req.Test.stub(KilnCMS.Storage.S3, fn conn ->
      send(test, {:s3, conn.host, conn.request_path, Map.new(conn.req_headers)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    %{profile: profile}
  end

  defp source do
    path = Path.join(System.tmp_dir!(), "isolation-#{System.unique_integer([:positive])}.png")
    File.write!(path, "bytes")
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "the operator's request carries the planted operator credentials (the control)" do
    # The S3 adapter directly: the test env's operator adapter is Local.
    assert {:ok, "control.png"} = KilnCMS.Storage.S3.store("control.png", source())

    assert_received {:s3, @operator_host, _path, headers}
    assert headers["authorization"] =~ "Credential=#{@operator_key}/"
    assert headers["x-amz-security-token"] == @operator_token
  end

  test "a site's request goes to the site's endpoint, signed with the site's key alone",
       %{profile: profile} do
    assert {:ok, "site.png"} = Storage.store("site.png", source(), profile)

    assert_received {:s3, host, path, headers}
    assert host == "s3.site.example"
    assert path == "/site-bucket/site.png"
    assert headers["authorization"] =~ "Credential=SITEKEYID/"
    refute Map.has_key?(headers, "x-amz-security-token")
    refute_operator(headers)
  end

  test "every operation on a site's store stays off the operator's config", %{profile: profile} do
    Storage.fetch("a.png", profile)
    Storage.delete("a.png", profile)
    Storage.fetch_range("a.png", 0, 10, profile)
    Storage.store_private("b.pdf", source(), profile)
    Storage.fetch_private("b.pdf", profile)
    Storage.delete_private("b.pdf", profile)

    for _call <- 1..6 do
      assert_received {:s3, "s3.site.example", _path, headers}
      assert headers["authorization"] =~ "Credential=SITEKEYID/"
      refute_operator(headers)
    end
  end

  test "a presigned upload URL is the site's, signed with the site's key", %{profile: profile} do
    assert {:ok, %{url: url}} =
             Storage.presign_private_put("direct-uploads/x", 10, 60, profile)

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.host == "s3.site.example"
    assert uri.path == "/site-private/direct-uploads/x"
    assert query["X-Amz-Credential"] =~ ~r/\ASITEKEYID\//
    refute Map.has_key?(query, "X-Amz-Security-Token")
    refute url =~ @operator_key
    refute url =~ @operator_token
  end

  defp refute_operator(headers) do
    for {name, value} <- headers do
      for planted <- [@operator_key, @operator_secret, @operator_token, @operator_host] do
        refute value =~ planted, "#{name} carries the operator's #{planted}"
      end
    end
  end
end
