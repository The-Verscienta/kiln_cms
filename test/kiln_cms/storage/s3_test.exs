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

  test "store sends an immutable Cache-Control so a CDN can cache forever (#42)" do
    stub(200)

    assert {:ok, "cached.png"} = S3.store("cached.png", tmp_source("x"))

    assert_received {:s3, "PUT", _path, _body, headers}
    assert headers["cache-control"] == "public, max-age=31536000, immutable"
  end

  test "store sends Content-Disposition: attachment, matching the Local adapter" do
    stub(200)

    assert {:ok, "download.png"} = S3.store("download.png", tmp_source("x"))

    assert_received {:s3, "PUT", _path, _body, headers}
    # Same defense-in-depth header KilnCMSWeb.Endpoint puts on /uploads/*, so
    # swapping Local -> S3 doesn't silently drop it. Ignored for <img> loads.
    assert headers["content-disposition"] == "attachment"
    # nosniff is deliberately absent: S3 would return an arbitrary header as
    # x-amz-meta-*, so it has to come from the CDN/bucket (docs/media-pipeline.md).
    refute Map.has_key?(headers, "x-content-type-options")
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

  test "fetch returns the object body" do
    Req.Test.stub(KilnCMS.Storage.S3, fn conn ->
      assert conn.method == "GET"
      Plug.Conn.send_resp(conn, 200, "image-bytes")
    end)

    assert {:ok, "image-bytes"} = S3.fetch("abc.png")
  end

  test "url joins the configured public base URL and key" do
    assert S3.url("abc.png") == "https://cdn.test/kiln-test/abc.png"
  end

  describe "error answers (#487 coverage plan, item 8)" do
    # A wrong credential or a missing bucket is a 4xx, which ExAws hands back
    # without retrying. Each operation must return it as data: these are the
    # paths an editor meets as "my upload vanished", so an `:ok` here — or a
    # raise — is a lost file with no error to show for it.

    test "a store refused by the bucket (wrong credential) is the 403, not a key" do
      stub(403)

      assert {:error, {:http_error, 403, _resp}} = S3.store("denied.png", tmp_source("x"))
    end

    test "a store whose source file is gone is the stat error, with no request made" do
      stub(200)

      missing =
        Path.join(System.tmp_dir!(), "s3src_missing_#{System.unique_integer([:positive])}")

      assert {:error, :enoent} = S3.store("gone.png", missing)
      refute_received {:s3, _method, _path, _body, _headers}
    end

    test "a fetch of a missing object is the 404, not an empty body" do
      stub(404)

      assert {:error, {:http_error, 404, _resp}} = S3.fetch("missing.png")
    end

    test "a delete the bucket refuses is an error, not :ok" do
      # S3 answers a DELETE of a missing *key* with 204, so a 404 here means the
      # bucket itself is gone — the one delete failure that must not be hidden.
      stub(404)

      assert {:error, {:http_error, 404, _resp}} = S3.delete("abc.png")
      assert_received {:s3, "DELETE", _path, _body, _headers}
    end

    test "a transport failure is returned, not raised" do
      # ExAws retries transport errors with a backoff; one attempt keeps the
      # test fast without changing which branch runs.
      original = Application.get_env(:ex_aws, :retries)

      on_exit(fn ->
        if original,
          do: Application.put_env(:ex_aws, :retries, original),
          else: Application.delete_env(:ex_aws, :retries)
      end)

      Application.put_env(:ex_aws, :retries,
        max_attempts: 1,
        base_backoff_in_ms: 1,
        max_backoff_in_ms: 1
      )

      Req.Test.stub(KilnCMS.Storage.S3, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Req.TransportError{reason: :econnrefused}} = S3.fetch("abc.png")
    end

    test "private fetch and delete pass the error through from the private bucket" do
      with_private_bucket()
      stub(403)

      assert {:error, {:http_error, 403, _resp}} = S3.fetch_private("doc.pdf")
      assert {:error, {:http_error, 403, _resp}} = S3.delete_private("doc.pdf")
    end
  end

  describe "ranged reads" do
    # The media download controller streams audio/video through these, and
    # picks its response (206, 416, or a plain 200 fallback) from the shape
    # returned — so each shape is part of the contract, not an implementation
    # detail.

    defp stub_range(status, headers, body) do
      test_pid = self()

      Req.Test.stub(KilnCMS.Storage.S3, fn conn ->
        send(test_pid, {:range, conn.request_path, Plug.Conn.get_req_header(conn, "range")})

        headers
        |> Enum.reduce(conn, fn {k, v}, conn -> Plug.Conn.put_resp_header(conn, k, v) end)
        |> Plug.Conn.send_resp(status, body)
      end)
    end

    test "a 206 returns the bytes and the range S3 says it served" do
      stub_range(206, [{"content-range", "bytes 2-4/10"}], "234")

      assert {:ok, %{bytes: "234", first: 2, last: 4, total: 10}} =
               S3.fetch_range("clip.mp4", 2, 4)

      assert_received {:range, path, ["bytes=2-4"]}
      assert path =~ "kiln-test"
    end

    test "an open-ended range asks for `first-` and takes the clamp from the header" do
      stub_range(206, [{"content-range", "bytes 7-9/10"}], "789")

      assert {:ok, %{bytes: "789", first: 7, last: 9, total: 10}} =
               S3.fetch_range("clip.mp4", 7, :eof)

      assert_received {:range, _path, ["bytes=7-"]}
    end

    test "a 416 is :range_not_satisfiable" do
      stub_range(416, [], "")

      assert {:error, :range_not_satisfiable} = S3.fetch_range("clip.mp4", 99, :eof)
    end

    test "a 200 with no Content-Range is refused rather than guessed at" do
      stub_range(200, [], "0123456789")

      assert {:error, {:no_content_range, 3}} = S3.fetch_range("clip.mp4", 3, 5)
    end

    test "a Content-Range that isn't `bytes a-b/total` is refused too" do
      # `*` is what S3 sends for an unknown total — no truthful header can be
      # built from it.
      stub_range(206, [{"content-range", "bytes 0-2/*"}], "012")

      assert {:error, {:no_content_range, 0}} = S3.fetch_range("clip.mp4", 0, 2)
    end

    test "any other error is passed through" do
      stub_range(403, [], "")

      assert {:error, {:http_error, 403, _resp}} = S3.fetch_range("clip.mp4", 0, 2)
    end

    test "the private variant reads the private bucket, and errors without one" do
      assert {:error, :private_storage_not_configured} = S3.fetch_private_range("doc.mp4", 0, 2)

      with_private_bucket()
      stub_range(206, [{"content-range", "bytes 0-2/3"}], "abc")

      assert {:ok, %{bytes: "abc", total: 3}} = S3.fetch_private_range("doc.mp4", 0, 2)
      assert_received {:range, path, ["bytes=0-2"]}
      assert path =~ "kiln-private"
    end
  end

  describe "multipart upload (#494)" do
    # Above 16 MB, `store/2` streams 5 MB parts: initiate (POST ?uploads), one
    # PUT per part, complete (POST ?uploadId). A part refused mid-way must
    # fail the store — never complete a truncated object under the key.

    @over_threshold 16 * 1024 * 1024 + 1

    defp big_source do
      path = tmp_source(:binary.copy(<<0>>, @over_threshold))
      on_exit(fn -> File.rm(path) end)
      path
    end

    # Answers the three multipart calls; the part numbers in `fail_parts` are
    # refused with a 403, every other part gets a 200 and an ETag.
    defp stub_multipart(fail_parts \\ []) do
      test_pid = self()

      Req.Test.stub(KilnCMS.Storage.S3, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 32 * 1024 * 1024)

        case {conn.method, conn.query_params} do
          {"POST", %{"uploads" => _}} ->
            send(test_pid, {:mp, :initiate, conn})

            Plug.Conn.send_resp(conn, 200, """
            <InitiateMultipartUploadResult><Bucket>kiln-test</Bucket><Key>big.mp4</Key><UploadId>up-1</UploadId></InitiateMultipartUploadResult>
            """)

          {"PUT", %{"partNumber" => n, "uploadId" => "up-1"}} ->
            n = String.to_integer(n)
            send(test_pid, {:mp, :part, n, byte_size(body)})

            answer_part(conn, n, n in fail_parts)

          {"POST", %{"uploadId" => "up-1"}} ->
            send(test_pid, {:mp, :complete, body})

            Plug.Conn.send_resp(conn, 200, """
            <CompleteMultipartUploadResult><Bucket>kiln-test</Bucket><Key>big.mp4</Key><ETag>"done"</ETag></CompleteMultipartUploadResult>
            """)
        end
      end)
    end

    defp answer_part(conn, _n, true = _refused), do: Plug.Conn.send_resp(conn, 403, "")

    defp answer_part(conn, n, false = _refused) do
      conn
      |> Plug.Conn.put_resp_header("etag", ~s("etag-#{n}"))
      |> Plug.Conn.send_resp(200, "")
    end

    test "a large file goes up in parts and is completed with every part's ETag" do
      stub_multipart()

      assert {:ok, "big.mp4"} = S3.store("big.mp4", big_source())

      assert_received {:mp, :initiate, init}
      # Object metadata rides on the initiate call, not on the parts.
      assert Plug.Conn.get_req_header(init, "cache-control") == [
               "public, max-age=31536000, immutable"
             ]

      assert Plug.Conn.get_req_header(init, "content-disposition") == ["attachment"]

      # 16 MB + 1 byte in 5 MB parts: three full parts and a one-byte-plus tail.
      sizes = for n <- 1..4, do: receive_part(n)
      assert Enum.sum(sizes) == @over_threshold
      refute_received {:mp, :part, _n, _size}

      assert_received {:mp, :complete, complete}

      for n <- 1..4,
          do: assert(complete =~ "<PartNumber>#{n}</PartNumber><ETag>\"etag-#{n}\"</ETag>")
    end

    test "a part refused mid-upload fails the store, and nothing is completed" do
      stub_multipart([2])

      assert {:error, {:http_error, 403, _resp}} = S3.store("big.mp4", big_source())
      refute_received {:mp, :complete, _body}
    end

    test "an initiate refused by the bucket fails before any part is sent" do
      stub(403)

      assert {:error, {:http_error, 403, _resp}} = S3.store("big.mp4", big_source())
      assert_received {:s3, "POST", _path, _body, _headers}
      refute_received {:s3, _method, _path, _body, _headers}
    end

    defp receive_part(n) do
      assert_received {:mp, :part, ^n, size}
      size
    end
  end

  test "a missing :bucket or :public_base_url is a configuration error, raised" do
    original = Application.get_env(:kiln_cms, KilnCMS.Storage.S3)
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Storage.S3, original) end)
    Application.put_env(:kiln_cms, KilnCMS.Storage.S3, [])

    assert_raise RuntimeError, ~r/requires a :bucket/, fn -> S3.fetch("abc.png") end
    assert_raise RuntimeError, ~r/requires a :public_base_url/, fn -> S3.url("abc.png") end
  end

  defp with_private_bucket do
    original = Application.get_env(:kiln_cms, KilnCMS.Storage.S3)
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Storage.S3, original) end)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Storage.S3,
      [private_bucket: "kiln-private"] ++ original
    )
  end

  describe "private storage (#481)" do
    test "unavailable — and every private operation errors — when no private bucket is configured" do
      refute S3.private_available?()

      assert {:error, :private_storage_not_configured} = S3.store_private("k", tmp_source("x"))
      assert {:error, :private_storage_not_configured} = S3.fetch_private("k")
      assert {:error, :private_storage_not_configured} = S3.delete_private("k")
    end

    test "available, and requests target the configured private bucket, once configured" do
      original = Application.get_env(:kiln_cms, KilnCMS.Storage.S3)
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Storage.S3, original) end)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Storage.S3,
        [private_bucket: "kiln-private"] ++ original
      )

      assert S3.private_available?()

      stub(200)
      assert {:ok, "doc.pdf"} = S3.store_private("doc.pdf", tmp_source("secret-bytes"))

      assert_received {:s3, "PUT", path, "secret-bytes", headers}
      assert path =~ "kiln-private"
      assert path =~ "doc.pdf"
      # No cache-control/content-disposition metadata — a private object is
      # never served directly, so there's no client to carry those for.
      refute Map.has_key?(headers, "cache-control")
      refute Map.has_key?(headers, "content-disposition")
    end

    test "fetch_private reads the object body from the private bucket" do
      original = Application.get_env(:kiln_cms, KilnCMS.Storage.S3)
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Storage.S3, original) end)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Storage.S3,
        [private_bucket: "kiln-private"] ++ original
      )

      Req.Test.stub(KilnCMS.Storage.S3, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path =~ "kiln-private"
        Plug.Conn.send_resp(conn, 200, "secret-bytes")
      end)

      assert {:ok, "secret-bytes"} = S3.fetch_private("doc.pdf")
    end

    test "delete_private issues a DELETE against the private bucket" do
      original = Application.get_env(:kiln_cms, KilnCMS.Storage.S3)
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Storage.S3, original) end)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Storage.S3,
        [private_bucket: "kiln-private"] ++ original
      )

      stub(200)
      assert :ok = S3.delete_private("doc.pdf")

      assert_received {:s3, "DELETE", path, _body, _headers}
      assert path =~ "kiln-private"
    end
  end
end
