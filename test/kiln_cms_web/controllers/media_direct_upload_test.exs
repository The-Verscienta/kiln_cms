defmodule KilnCMSWeb.MediaDirectUploadTest do
  @moduledoc """
  The presigned direct-upload flow (`KilnCMS.Media.DirectUpload`), end to end
  on the S3 adapter against an in-memory bucket behind the adapter's
  `Req.Test` seam — so the presigning, the ranged reads of the staged object,
  the ingest's public `PUT` and the staging delete are all real ExAws requests.

  `async: false`: it swaps the global storage adapter to S3 and configures a
  private bucket.
  """
  use KilnCMSWeb.ConnCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  # The refusal paths log what they refused (Ingest, the cleanup worker).
  @moduletag :capture_log

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  @private_bucket "kiln-test-private"

  setup do
    storage = Application.get_env(:kiln_cms, KilnCMS.Storage)
    s3 = Application.get_env(:kiln_cms, KilnCMS.Storage.S3)

    Application.put_env(:kiln_cms, KilnCMS.Storage, adapter: KilnCMS.Storage.S3)
    Application.put_env(:kiln_cms, KilnCMS.Storage.S3, [private_bucket: @private_bucket] ++ s3)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Storage, storage)
      Application.put_env(:kiln_cms, KilnCMS.Storage.S3, s3)
    end)

    {:ok, bucket} = Agent.start_link(fn -> %{} end)
    fake_s3(bucket)

    editor = user(:editor)
    %{bucket: bucket, editor: editor, key: mint(editor, :read_write)}
  end

  # A bucket in an Agent: PUT stores, ranged GET answers 206 with the
  # Content-Range the adapter reads the total from, DELETE removes. Paths are
  # `/<bucket>/<key>` (path-style addressing, the adapter's default).
  defp fake_s3(bucket) do
    Req.Test.stub(KilnCMS.Storage.S3, &s3_request(&1, bucket))
  end

  defp s3_request(%{method: "PUT", request_path: path} = conn, bucket) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 100_000_000)
    Agent.update(bucket, &Map.put(&1, path, body))
    Plug.Conn.send_resp(conn, 200, "")
  end

  defp s3_request(%{method: "DELETE", request_path: path} = conn, bucket) do
    Agent.update(bucket, &Map.delete(&1, path))
    Plug.Conn.send_resp(conn, 204, "")
  end

  defp s3_request(%{method: "GET", request_path: path} = conn, bucket) do
    case Agent.get(bucket, &Map.get(&1, path)) do
      nil -> Plug.Conn.send_resp(conn, 404, "")
      bytes -> ranged(conn, bytes)
    end
  end

  defp ranged(conn, bytes) do
    total = byte_size(bytes)
    [range] = Plug.Conn.get_req_header(conn, "range")
    [first, last] = Regex.run(~r/bytes=(\d+)-(\d*)/, range, capture: :all_but_first)
    first = String.to_integer(first)
    last = if last == "", do: total - 1, else: min(String.to_integer(last), total - 1)

    conn
    |> Plug.Conn.put_resp_header("content-range", "bytes #{first}-#{last}/#{total}")
    |> Plug.Conn.send_resp(206, binary_part(bytes, first, last - first + 1))
  end

  defp put_object(bucket, path, bytes), do: Agent.update(bucket, &Map.put(&1, path, bytes))
  defp objects(bucket), do: Agent.get(bucket, & &1)

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "direct-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint(owner, access) do
    owner.id
    |> Accounts.mint_api_key!(
      "direct",
      DateTime.add(DateTime.utc_now(), 30, :day),
      %{access: access},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp post_json(conn, key, path, body) do
    conn
    |> put_req_header("authorization", "Bearer #{key}")
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  # Issue an upload for `bytes`, and return the token plus the fake bucket
  # path the presigned URL points at — what a client's PUT would write.
  defp begin(ctx, bytes, filename \\ "clip.png") do
    data =
      ctx.conn
      |> post_json(ctx.key, "/api/media/uploads", %{
        filename: filename,
        byte_size: byte_size(bytes)
      })
      |> json_response(201)
      |> Map.fetch!("data")

    %{data: data, path: URI.parse(data["upload_url"]).path}
  end

  test "begin issues a presigned PUT into the private bucket, size-locked", ctx do
    %{data: data, path: path} = begin(ctx, @png)

    assert data["method"] == "PUT"
    assert path =~ ~r"^/#{@private_bucket}/direct-uploads/[0-9a-f-]{36}$"
    assert data["headers"] == %{"content-length" => Integer.to_string(byte_size(@png))}

    query = URI.decode_query(URI.parse(data["upload_url"]).query)
    assert query["X-Amz-SignedHeaders"] == "content-length;host"
    assert query["X-Amz-Expires"] == Integer.to_string(KilnCMS.Media.DirectUpload.url_ttl())
    assert is_binary(data["token"])

    # The staging object is cleaned up even if the client never completes.
    "/#{@private_bucket}/" <> key = path

    assert_enqueued(worker: KilnCMS.Media.StagedUploadCleanup, args: %{key: key})
  end

  test "complete runs the staged bytes through the pipeline and removes the staging object",
       ctx do
    %{data: data, path: path} = begin(ctx, @png, "from-s3.txt")
    put_object(ctx.bucket, path, @png)

    conn =
      post_json(build_conn(), ctx.key, "/api/media/uploads/complete", %{
        token: data["token"],
        alt: "Direct",
        focal_x: 0.2
      })

    attrs = json_response(conn, 201)["data"]["attributes"]
    # Sniffed from the bytes, not the declared name.
    assert attrs["content_type"] == "image/png"
    assert attrs["alt"] == "Direct"
    assert attrs["focal_x"] == 0.2
    assert attrs["uploaded_by_id"] == ctx.editor.id
    assert attrs["url"] =~ "https://cdn.test/kiln-test/"

    objects = objects(ctx.bucket)
    refute Map.has_key?(objects, path), "the staging object must be deleted"
    # The ingested copy went to the PUBLIC bucket under its own key.
    assert Enum.any?(Map.keys(objects), &String.starts_with?(&1, "/kiln-test/"))

    id = json_response(conn, 201)["data"]["id"]
    assert CMS.get_media_item!(id, actor: ctx.editor).uploaded_by_id == ctx.editor.id
  end

  test "a token completes once", ctx do
    %{data: data, path: path} = begin(ctx, @png)
    put_object(ctx.bucket, path, @png)

    post_json(build_conn(), ctx.key, "/api/media/uploads/complete", %{token: data["token"]})
    |> json_response(201)

    again =
      post_json(build_conn(), ctx.key, "/api/media/uploads/complete", %{token: data["token"]})

    assert json_response(again, 422)["errors"] |> hd() |> Map.fetch!("code") == "not_uploaded"
  end

  test "a token is bound to the credential's user", ctx do
    %{data: data, path: path} = begin(ctx, @png)
    put_object(ctx.bucket, path, @png)

    other = mint(user(:editor), :read_write)
    conn = post_json(build_conn(), other, "/api/media/uploads/complete", %{token: data["token"]})

    assert json_response(conn, 422)["errors"] |> hd() |> Map.fetch!("code") ==
             "invalid_upload_token"

    # Not consumed by the refused attempt — the owner can still complete it.
    assert Map.has_key?(objects(ctx.bucket), path)
  end

  test "a staged object whose size differs from the one signed is refused and removed", ctx do
    %{data: data, path: path} = begin(ctx, @png)
    put_object(ctx.bucket, path, @png <> "trailing")

    conn =
      post_json(build_conn(), ctx.key, "/api/media/uploads/complete", %{token: data["token"]})

    assert json_response(conn, 422)["errors"] |> hd() |> Map.fetch!("code") == "size_mismatch"
    refute Map.has_key?(objects(ctx.bucket), path)
  end

  test "a declared size past the upload ceiling gets no URL", ctx do
    conn =
      post_json(ctx.conn, ctx.key, "/api/media/uploads", %{
        filename: "huge.mp4",
        byte_size: KilnCMS.Media.Ingest.max_upload_size() + 1
      })

    assert json_response(conn, 413)["errors"] |> hd() |> Map.fetch!("code") == "too_large"
  end

  test "a read-only key cannot begin", ctx do
    conn =
      post_json(ctx.conn, mint(ctx.editor, :read), "/api/media/uploads", %{
        filename: "a.png",
        byte_size: 10
      })

    assert json_response(conn, 403)
  end

  test "the cleanup job deletes a staging key, and refuses any other key", ctx do
    put_object(ctx.bucket, "/#{@private_bucket}/direct-uploads/abc", "x")
    put_object(ctx.bucket, "/#{@private_bucket}/gated.pdf", "x")

    assert :ok = perform_job(KilnCMS.Media.StagedUploadCleanup, %{key: "direct-uploads/abc"})
    assert {:cancel, _} = perform_job(KilnCMS.Media.StagedUploadCleanup, %{key: "gated.pdf"})

    objects = objects(ctx.bucket)
    refute Map.has_key?(objects, "/#{@private_bucket}/direct-uploads/abc")
    assert Map.has_key?(objects, "/#{@private_bucket}/gated.pdf")
  end
end
