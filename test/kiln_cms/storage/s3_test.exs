defmodule KilnCMS.Storage.S3Test do
  @moduledoc """
  The S3 storage adapter issues correctly-signed S3 requests. ExAws HTTP is
  routed through a `Req.Test` stub (see `config/test.exs`), so the full path —
  operation building + SigV4 signing + transport — is exercised without a live
  S3/MinIO server.
  """
  # async: false — the ACL test mutates the global Storage.S3 config.
  use ExUnit.Case, async: false

  alias KilnCMS.Storage.S3

  defp tmp_source(contents) do
    path = Path.join(System.tmp_dir!(), "s3src_#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    path
  end

  # Capture each request forwarded to the stub and reply with `status`.
  defp stub(status) do
    test_pid = self()

    Req.Test.stub(KilnCMS.Storage.S3, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:s3, conn.method, conn.request_path, body, Map.new(conn.req_headers)})
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  test "store uploads the file body and returns the key" do
    stub(200)
    src = tmp_source("the-bytes")

    assert {:ok, "abc.png"} = S3.store("abc.png", src)

    assert_received {:s3, "PUT", path, "the-bytes", headers}
    assert path =~ "abc.png"
    # SigV4 signing actually ran.
    assert headers["authorization"] =~ "AWS4-HMAC-SHA256"
    # No per-object ACL by default (works with R2/B2/Wasabi/modern AWS).
    refute Map.has_key?(headers, "x-amz-acl")
  end

  test "store sends a canned ACL only when configured" do
    original = Application.get_env(:kiln_cms, KilnCMS.Storage.S3)
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Storage.S3, original) end)
    Application.put_env(:kiln_cms, KilnCMS.Storage.S3, [acl: :public_read] ++ original)

    stub(200)
    assert {:ok, "acl.png"} = S3.store("acl.png", tmp_source("x"))

    assert_received {:s3, "PUT", _path, _body, headers}
    assert headers["x-amz-acl"] == "public-read"
  end

  test "delete issues a DELETE for the key" do
    stub(200)

    assert :ok = S3.delete("abc.png")

    assert_received {:s3, "DELETE", path, _body, _headers}
    assert path =~ "abc.png"
  end

  test "url joins the configured public base URL and key" do
    assert S3.url("abc.png") == "https://cdn.test/kiln-test/abc.png"
  end

  test "store surfaces an error when the upload is rejected" do
    stub(403)
    src = tmp_source("x")

    assert {:error, _reason} = S3.store("denied.png", src)
  end
end
