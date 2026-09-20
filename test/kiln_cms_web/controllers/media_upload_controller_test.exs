defmodule KilnCMSWeb.MediaUploadControllerTest do
  @moduledoc """
  The media upload API (`/api/media/*`) and the metadata write that pairs with
  it (`PATCH /api/json/media-items/:id`, GraphQL `updateMediaItem`).

  What is pinned is that an API upload is the media library's upload — the
  same byte-sniffing, the same policies, the same uploader stamp and derivation
  — and that the route's larger body limit is only reachable once a caller is
  authenticated and allowed to create media. The pipeline's own internals
  (strip, quarantine, caps) are `KilnCMS.Media.IngestTest`'s and
  `AVQuarantineTest`'s.

  The direct (presigned) flow needs the S3 adapter and lives in
  `KilnCMSWeb.MediaDirectUploadTest`.
  """
  use KilnCMSWeb.ConnCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMSWeb.MediaUploadJSON

  # The refusal paths log what they refused (Ingest, the cleanup worker).
  @moduletag :capture_log

  @password "password123456"

  # 1x1 PNG — the same bytes `IngestTest` and `AVQuarantineTest` use.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "media-api-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint(owner, access) do
    key =
      Accounts.mint_api_key!(
        owner.id,
        "media-api",
        DateTime.add(DateTime.utc_now(), 30, :day),
        %{access: access},
        actor: user(:admin)
      )

    Ash.Resource.get_metadata(key, :plaintext_api_key)
  end

  defp jwt(user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => user.email,
        "password" => @password
      })

    signed_in.__metadata__.token
  end

  defp tmp_file(bytes) do
    path = Path.join(System.tmp_dir!(), "media-api-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp upload(bytes, filename, content_type \\ "application/octet-stream") do
    %Plug.Upload{path: tmp_file(bytes), filename: filename, content_type: content_type}
  end

  defp bearer(conn, nil), do: conn
  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp items_named(filename, actor) do
    CMS.list_media_items!(actor: actor, query: [filter: [filename: filename]])
  end

  defp unique_name(ext), do: "api-#{System.unique_integer([:positive])}#{ext}"

  setup do
    editor = user(:editor)
    %{editor: editor, key: mint(editor, :read_write)}
  end

  describe "POST /api/media — who may upload" do
    test "a :read_write key on an editor account uploads, attributed to the owner", ctx do
      tag = CMS.create_tag!(%{name: "api", slug: unique_name("")}, actor: user(:admin))
      name = unique_name(".png")

      conn =
        ctx.conn
        |> bearer(ctx.key)
        |> post("/api/media", %{
          "file" => upload(@png, name),
          "alt" => "A single pixel",
          "caption" => "Tiny",
          "focal_x" => "0.25",
          "focal_y" => "0.75",
          "tag_ids" => [tag.id]
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["type"] == "media_item"
      assert [location] = get_resp_header(conn, "location")
      assert location == "/api/json/media-items/#{data["id"]}"
      assert data["links"]["self"] == location

      attrs = data["attributes"]
      assert attrs["filename"] == name
      assert attrs["content_type"] == "image/png"
      assert attrs["kind"] == "image"
      assert attrs["alt"] == "A single pixel"
      assert attrs["caption"] == "Tiny"
      assert attrs["focal_x"] == 0.25
      assert attrs["focal_y"] == 0.75
      assert attrs["uploaded_by_id"] == ctx.editor.id
      assert data["relationships"]["tags"]["data"] == [%{"type" => "tag", "id" => tag.id}]
      assert data["meta"]["processing"] == false

      # The row the library shows, not just a response shaped like one.
      assert [item] = items_named(name, ctx.editor)
      assert item.id == data["id"]
      assert item.uploaded_by_id == ctx.editor.id
      assert item.focal_x == 0.25

      # Derivation was queued, as for a library upload.
      assert_enqueued(worker: KilnCMS.Media.VariantWorker, args: %{media_item_id: item.id})
    end

    test "a JWT-authenticated editor may upload too", ctx do
      name = unique_name(".png")

      conn =
        ctx.conn
        |> bearer(jwt(ctx.editor))
        |> post("/api/media", %{"file" => upload(@png, name)})

      assert json_response(conn, 201)["data"]["attributes"]["uploaded_by_id"] == ctx.editor.id
    end

    test "a read-only key is refused, whatever the owner's role", ctx do
      name = unique_name(".png")

      conn =
        ctx.conn
        |> bearer(mint(user(:admin), :read))
        |> post("/api/media", %{"file" => upload(@png, name)})

      assert %{"errors" => [%{"status" => "403", "code" => "forbidden"}]} =
               json_response(conn, 403)

      assert items_named(name, user(:admin)) == []
    end

    test "a :read_write key on a viewer account is refused (the role has no upload right)",
         ctx do
      name = unique_name(".png")

      conn =
        ctx.conn
        |> bearer(mint(user(:viewer), :read_write))
        |> post("/api/media", %{"file" => upload(@png, name)})

      assert json_response(conn, 403)["errors"] |> hd() |> Map.fetch!("code") == "forbidden"
      assert items_named(name, user(:admin)) == []
    end

    test "an anonymous caller is told to authenticate", ctx do
      name = unique_name(".png")
      conn = post(ctx.conn, "/api/media", %{"file" => upload(@png, name)})

      assert json_response(conn, 401)["errors"] |> hd() |> Map.fetch!("code") == "unauthorized"
      assert items_named(name, user(:admin)) == []
    end
  end

  describe "POST /api/media — the pipeline" do
    test "the kind comes from the bytes, not the name: a PNG called .txt is an image", ctx do
      conn =
        ctx.conn
        |> bearer(ctx.key)
        |> post("/api/media", %{"file" => upload(@png, "notes.txt", "text/plain")})

      attrs = json_response(conn, 201)["data"]["attributes"]
      assert attrs["content_type"] == "image/png"
      assert attrs["kind"] == "image"
    end

    test "bytes no processor recognises are a 415, and nothing is created", ctx do
      name = unique_name(".png")

      conn =
        ctx.conn
        |> bearer(ctx.key)
        |> post("/api/media", %{"file" => upload("just some text", name, "image/png")})

      assert json_response(conn, 415)["errors"] |> hd() |> Map.fetch!("code") ==
               "unsupported_media_type"

      assert items_named(name, ctx.editor) == []
    end

    test "no file is a 422 naming the field", ctx do
      conn = ctx.conn |> bearer(ctx.key) |> post("/api/media", %{"alt" => "orphan"})

      assert %{"code" => "missing_file", "status" => "422"} =
               json_response(conn, 422)["errors"] |> hd()
    end

    test "metadata is validated before the file is processed: a focal point past 1.0", ctx do
      name = unique_name(".png")

      conn =
        ctx.conn
        |> bearer(ctx.key)
        |> post("/api/media", %{"file" => upload(@png, name), "focal_x" => "1.5"})

      assert %{"code" => "invalid_parameter", "detail" => detail} =
               json_response(conn, 422)["errors"] |> hd()

      assert detail =~ "focal_x"
      assert items_named(name, ctx.editor) == []
    end

    test "an over-long filename is refused before the file is processed", ctx do
      name = String.duplicate("a", KilnCMS.Limits.identifier() + 1) <> ".png"

      conn = ctx.conn |> bearer(ctx.key) |> post("/api/media", %{"file" => upload(@png, name)})

      assert %{"code" => "invalid_parameter", "detail" => "filename is too long"} =
               json_response(conn, 422)["errors"] |> hd()
    end

    test "a path in the client's filename is reduced to its basename", ctx do
      name = unique_name(".png")

      conn =
        ctx.conn
        |> bearer(ctx.key)
        |> post("/api/media", %{"file" => upload(@png, "../../#{name}")})

      assert json_response(conn, 201)["data"]["attributes"]["filename"] == name
    end

    test "pipeline-owned fields in the request are ignored, not written", ctx do
      name = unique_name(".png")

      conn =
        ctx.conn
        |> bearer(ctx.key)
        |> post("/api/media", %{
          "file" => upload(@png, name),
          "url" => "https://evil.test/x.png",
          "storage_key" => "someone-elses-key.pdf",
          "content_type" => "text/html"
        })

      attrs = json_response(conn, 201)["data"]["attributes"]
      refute attrs["url"] == "https://evil.test/x.png"
      assert attrs["content_type"] == "image/png"

      [item] = items_named(name, ctx.editor)
      refute item.storage_key == "someone-elses-key.pdf"
    end

    test "an unknown tag id refuses the create rather than dropping the tag", ctx do
      name = unique_name(".png")

      conn =
        ctx.conn
        |> bearer(ctx.key)
        |> post("/api/media", %{"file" => upload(@png, name), "tag_ids" => [Ecto.UUID.generate()]})

      assert json_response(conn, 422)["errors"] |> hd() |> Map.fetch!("code") == "create_failed"
      assert items_named(name, ctx.editor) == []
    end

    test "the response carries every attribute the JSON:API route serializes", ctx do
      conn =
        ctx.conn
        |> bearer(ctx.key)
        |> post("/api/media", %{"file" => upload(@png, unique_name(".png"))})

      id = json_response(conn, 201)["data"]["id"]

      jsonapi =
        build_conn()
        |> bearer(ctx.key)
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/json/media-items/#{id}")
        |> json_response(200)

      served = jsonapi["data"]["attributes"] |> Map.keys() |> MapSet.new()
      ours = MediaUploadJSON.attribute_names() |> MapSet.new(&Atom.to_string/1)

      # Pinned both ways: an attribute made public later must be added to the
      # upload response too, and the upload response must not invent one.
      assert served == ours
    end
  end

  describe "POST /api/media — body parsing" do
    # Through the real endpoint with a raw multipart body, rather than
    # `post/3` with a params map (which hands the controller pre-parsed
    # params and so never exercises `MultipartParser` or the controller's own
    # `Plug.Parsers` call).
    defp multipart(fields, file_name, file_bytes) do
      boundary = "kilnboundary#{System.unique_integer([:positive])}"

      parts =
        Enum.map(fields, fn {name, value} ->
          ~s(--#{boundary}\r\ncontent-disposition: form-data; name="#{name}"\r\n\r\n#{value}\r\n)
        end)

      file =
        ~s(--#{boundary}\r\ncontent-disposition: form-data; name="file"; filename="#{file_name}"\r\n) <>
          "content-type: application/octet-stream\r\n\r\n" <> file_bytes <> "\r\n"

      {"multipart/form-data; boundary=#{boundary}",
       IO.iodata_to_binary([parts, file, "--#{boundary}--\r\n"])}
    end

    test "a raw multipart request is parsed after authorization and ingested", ctx do
      name = unique_name(".png")
      {content_type, body} = multipart([{"alt", "raw"}], name, @png)

      conn =
        ctx.conn
        |> bearer(ctx.key)
        |> put_req_header("content-type", content_type)
        |> post("/api/media", body)

      attrs = json_response(conn, 201)["data"]["attributes"]
      assert attrs["filename"] == name
      assert attrs["alt"] == "raw"
    end

    test "an anonymous raw multipart request is refused without its body being parsed", ctx do
      {content_type, body} = multipart([], unique_name(".png"), @png)

      conn =
        ctx.conn
        |> put_req_header("content-type", content_type)
        |> post("/api/media", body)

      assert json_response(conn, 401)
      # Refused ahead of the parse: the endpoint left the body unread, and the
      # controller halted before its own `Plug.Parsers` call.
      assert %Plug.Conn.Unfetched{} = conn.body_params
    end
  end

  describe "POST /api/media/import-url" do
    defp serve_png(test_pid) do
      Req.Test.stub(KilnCMS.Media.Ingest, fn conn ->
        send(test_pid, {:fetched, conn.request_path})

        case conn.request_path do
          "/moved.png" ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://media.test/final.png")
            |> Plug.Conn.send_resp(302, "")

          "/gone.png" ->
            Plug.Conn.send_resp(conn, 404, "")

          _ ->
            Plug.Conn.send_resp(conn, 200, @png)
        end
      end)
    end

    defp import_url(conn, key, body) do
      conn
      |> bearer(key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/media/import-url", Jason.encode!(body))
    end

    test "fetches the URL through the ingest pipeline, with metadata", ctx do
      serve_png(self())
      name = unique_name(".png")

      conn =
        import_url(ctx.conn, ctx.key, %{
          "url" => "https://media.test/cat.png",
          "filename" => name,
          "alt" => "A cat",
          "decorative" => false
        })

      attrs = json_response(conn, 201)["data"]["attributes"]
      assert attrs["filename"] == name
      assert attrs["alt"] == "A cat"
      assert attrs["content_type"] == "image/png"
      assert attrs["uploaded_by_id"] == ctx.editor.id
      assert_received {:fetched, "/cat.png"}
    end

    test "follows a redirect, re-validating the hop", ctx do
      serve_png(self())

      conn = import_url(ctx.conn, ctx.key, %{"url" => "https://media.test/moved.png"})

      assert json_response(conn, 201)["data"]["attributes"]["filename"] == "moved.png"
      assert_received {:fetched, "/moved.png"}
      assert_received {:fetched, "/final.png"}
    end

    test "refuses an internal address without dialling it", ctx do
      serve_png(self())

      for url <- ["http://127.0.0.1/x.png", "http://169.254.169.254/latest/meta-data/"] do
        conn = import_url(build_conn(), ctx.key, %{"url" => url})
        assert json_response(conn, 422)["errors"] |> hd() |> Map.fetch!("code") == "unsafe_url"
      end

      refute_received {:fetched, _}
    end

    test "an upstream error status is a 422 that names it", ctx do
      serve_png(self())

      conn = import_url(ctx.conn, ctx.key, %{"url" => "https://media.test/gone.png"})

      assert %{"code" => "fetch_failed", "detail" => detail} =
               json_response(conn, 422)["errors"] |> hd()

      assert detail =~ "404"
    end

    test "a missing url is a 422", ctx do
      conn = import_url(ctx.conn, ctx.key, %{"alt" => "nothing"})
      assert json_response(conn, 422)["errors"] |> hd() |> Map.fetch!("detail") =~ "url"
    end

    test "a read-only key cannot import", ctx do
      serve_png(self())

      conn =
        import_url(ctx.conn, mint(ctx.editor, :read), %{"url" => "https://media.test/cat.png"})

      assert json_response(conn, 403)
      refute_received {:fetched, _}
    end
  end

  describe "POST /api/media/uploads" do
    test "is a 501 on storage that cannot presign (the Local adapter)", ctx do
      conn =
        ctx.conn
        |> bearer(ctx.key)
        |> put_req_header("content-type", "application/json")
        |> post("/api/media/uploads", Jason.encode!(%{filename: "a.mp4", byte_size: 10}))

      assert json_response(conn, 501)["errors"] |> hd() |> Map.fetch!("code") ==
               "direct_uploads_unavailable"
    end
  end

  describe "rate limiting" do
    test "the upload routes charge the :media_upload bucket", ctx do
      {limit, _scale} = Map.fetch!(KilnCMSWeb.RateLimit.limits(), :media_upload)
      key = KilnCMSWeb.RateLimit.client_key(ctx.conn.remote_ip)

      # Spend the address's whole budget directly, then show the route is
      # refused by it — the route is behind this bucket, not merely `:api`.
      for _ <- 1..limit, do: KilnCMSWeb.RateLimit.check(:media_upload, key)

      conn = ctx.conn |> bearer(ctx.key) |> post("/api/media", %{})

      assert json_response(conn, 429)["errors"] |> hd() |> Map.fetch!("code") ==
               "too_many_requests"
    end

    test "the production limit is one upload a second per address" do
      assert %{media_upload: {60, 60_000}} =
               Map.take(KilnCMSWeb.RateLimit.default_limits(), [:media_upload])
    end
  end

  describe "PATCH /api/json/media-items/:id (metadata)" do
    @accept "application/vnd.api+json"

    defp patch_media(key, id, attributes) do
      build_conn()
      |> bearer(key)
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> patch(
        "/api/json/media-items/#{id}",
        Jason.encode!(%{data: %{type: "media_item", id: id, attributes: attributes}})
      )
    end

    setup ctx do
      conn =
        ctx.conn
        |> bearer(ctx.key)
        |> post("/api/media", %{"file" => upload(@png, unique_name(".png"))})

      %{item_id: json_response(conn, 201)["data"]["id"]}
    end

    test "edits alt text, caption and the decorative flag", ctx do
      conn =
        patch_media(ctx.key, ctx.item_id, %{alt: "", caption: "Now captioned", decorative: true})

      attrs = json_response(conn, 200)["data"]["attributes"]
      assert attrs["caption"] == "Now captioned"
      assert attrs["decorative"] == true
    end

    test "moving the focal point re-derives the crops", ctx do
      conn = patch_media(ctx.key, ctx.item_id, %{focal_x: 0.1, focal_y: 0.9})
      assert json_response(conn, 200)["data"]["attributes"]["focal_x"] == 0.1

      jobs =
        all_enqueued(worker: KilnCMS.Media.VariantWorker, args: %{media_item_id: ctx.item_id})

      # One from the upload, one from the focal move.
      assert length(jobs) == 2
    end

    test "a caption-only edit does not re-derive", ctx do
      patch_media(ctx.key, ctx.item_id, %{caption: "words"}) |> json_response(200)

      jobs =
        all_enqueued(worker: KilnCMS.Media.VariantWorker, args: %{media_item_id: ctx.item_id})

      assert length(jobs) == 1
    end

    test "a focal point out of range is refused", ctx do
      conn = patch_media(ctx.key, ctx.item_id, %{focal_x: 2.0})
      assert conn.status in 400..499
      assert CMS.get_media_item!(ctx.item_id, actor: ctx.editor).focal_x == 0.5
    end

    test "cannot reach the pipeline's fields", ctx do
      before = CMS.get_media_item!(ctx.item_id, actor: ctx.editor)
      conn = patch_media(ctx.key, ctx.item_id, %{url: "https://evil.test/x.png"})

      assert conn.status in 400..499
      assert CMS.get_media_item!(ctx.item_id, actor: ctx.editor).url == before.url
    end

    test "tags follow the same replace / merge verbs as content", ctx do
      admin = user(:admin)
      a = CMS.create_tag!(%{name: "a", slug: unique_name("")}, actor: admin)
      b = CMS.create_tag!(%{name: "b", slug: unique_name("")}, actor: admin)

      patch_media(ctx.key, ctx.item_id, %{tag_ids: [a.id]}) |> json_response(200)
      patch_media(ctx.key, ctx.item_id, %{add_tag_ids: [b.id]}) |> json_response(200)

      tags = CMS.get_media_item!(ctx.item_id, actor: admin, load: [:tags]).tags
      assert MapSet.new(tags, & &1.id) == MapSet.new([a.id, b.id])
    end

    test "a read-only key cannot edit", ctx do
      conn = patch_media(mint(ctx.editor, :read), ctx.item_id, %{caption: "nope"})
      assert conn.status == 403
      assert CMS.get_media_item!(ctx.item_id, actor: ctx.editor).caption == nil
    end
  end

  describe "GraphQL updateMediaItem" do
    test "edits metadata with a :read_write key", ctx do
      conn =
        ctx.conn
        |> bearer(ctx.key)
        |> post("/api/media", %{"file" => upload(@png, unique_name(".png"))})

      id = json_response(conn, 201)["data"]["id"]

      query = """
      mutation ($id: ID!, $input: UpdateMediaItemInput) {
        updateMediaItem(id: $id, input: $input) { result { id alt focalX } errors { message } }
      }
      """

      body =
        build_conn()
        |> bearer(ctx.key)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/gql",
          Jason.encode!(%{
            query: query,
            variables: %{id: id, input: %{alt: "GQL alt", focalX: 0.3}}
          })
        )
        |> json_response(200)

      assert body["errors"] == nil, inspect(body["errors"])
      assert %{"alt" => "GQL alt", "focalX" => 0.3} = body["data"]["updateMediaItem"]["result"]
    end
  end
end
