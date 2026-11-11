defmodule KilnClientDeliveryTest do
  # Not async: two tests set the global `:api_key` config — one to prove a
  # form submission never sends it, one to prove `mint_preview/3` refuses
  # without it. A sync module runs after every async one, so they can never
  # leak into `KilnClientTest`.
  use ExUnit.Case, async: false

  alias KilnClient.Error

  @moduletag :capture_log

  @key "kiln_preview_secret"

  setup do
    previous = Application.get_env(:kiln_client, :api_key)
    Application.delete_env(:kiln_client, :api_key)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_client, :api_key, previous),
        else: Application.delete_env(:kiln_client, :api_key)
    end)
  end

  # Records method, path, query, the headers that matter and the decoded JSON
  # body, then answers `status` + `body`.
  defp stub(status \\ 200, body \\ %{}) do
    Req.Test.stub(KilnClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(self(), {
        :request,
        conn.method,
        conn.request_path,
        conn.query_params,
        %{
          "accept" => Plug.Conn.get_req_header(conn, "accept"),
          "content-type" => Plug.Conn.get_req_header(conn, "content-type"),
          "authorization" => Plug.Conn.get_req_header(conn, "authorization")
        },
        if(raw == "", do: nil, else: Jason.decode!(raw))
      })

      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  describe "artifact/3 :as_of" do
    test "sends each accepted value as an ISO 8601 as_of" do
      stub(200, %{"slug" => "hello"})

      for {as_of, wire} <- [
            {~U[2026-10-01 12:30:00Z], "2026-10-01T12:30:00Z"},
            {~N[2026-10-01 12:30:00], "2026-10-01T12:30:00Z"},
            {~D[2026-10-01], "2026-10-01"},
            {"2026-10-01T08:00:00+02:00", "2026-10-01T08:00:00+02:00"}
          ] do
        assert {:ok, %{"slug" => "hello"}} = KilnClient.artifact("post", "hello", as_of: as_of)
        assert_received {:request, "GET", "/api/content/post/hello", %{"as_of" => ^wire}, _, _}
      end
    end

    test "a not_published 404 is a :not_found error carrying the code" do
      stub(404, %{"errors" => [%{"status" => "404", "code" => "not_published"}]})

      assert {:error, %Error{reason: :not_found, code: "not_published"}} =
               KilnClient.artifact("post", "hello", as_of: ~D[2020-01-01])
    end
  end

  describe "content_as_of/3" do
    test "reads the collection index at that moment and returns the raw body" do
      body = %{
        "as_of" => "2026-10-01T23:59:59.999999Z",
        "type" => "post",
        "entries" => [%{"slug" => "a", "title" => "A", "published_at" => nil, "href" => nil}]
      }

      stub(200, body)

      assert {:ok, ^body} = KilnClient.content_as_of("post", ~D[2026-10-01], limit: 50)

      assert_received {:request, "GET", "/api/content/post",
                       %{"as_of" => "2026-10-01", "limit" => "50"}, headers, nil}

      assert headers["accept"] == ["application/json"]
    end
  end

  describe "mint_preview/3" do
    test "POSTs with the key and returns the minted token" do
      minted = %{
        "token" => "tok",
        "url" => "https://cms.example.com/preview/tok",
        "type" => "post",
        "id" => "p 1",
        "expires_at" => "2026-11-02T12:15:00Z",
        "expires_in" => 900
      }

      stub(201, minted)

      assert {:ok, ^minted} = KilnClient.mint_preview("post", "p 1", api_key: @key)

      assert_received {:request, "POST", "/api/content/post/p%201/preview-token", _, headers, nil}
      assert headers["authorization"] == ["Bearer #{@key}"]
      assert headers["accept"] == ["application/json"]
    end

    test "refuses without a key and sends nothing" do
      stub()

      assert {:error, %Error{reason: :no_api_key, method: :post}} =
               KilnClient.mint_preview("post", "p1")

      refute_received {:request, _, _, _, _, _}
    end

    test "a 403 (not an editor of it) is :forbidden" do
      stub(403, %{"errors" => [%{"status" => "403", "code" => "forbidden"}]})

      assert {:error, %Error{reason: :forbidden}} =
               KilnClient.mint_preview("post", "p1", api_key: @key)
    end
  end

  describe "schema/1" do
    test "joins :types and maps blocks_only to ?blocks=only" do
      stub(200, %{"$defs" => %{}})

      assert {:ok, %{"$defs" => %{}}} = KilnClient.schema(types: ["post", "page"])
      assert_received {:request, "GET", "/api/schema", %{"type" => "post,page"} = params, _, _}
      refute Map.has_key?(params, "blocks")

      assert {:ok, _} = KilnClient.schema(blocks_only: true)
      assert_received {:request, "GET", "/api/schema", %{"blocks" => "only"} = params, _, _}
      refute Map.has_key?(params, "format")
    end

    test "format: :openapi asks for the OpenAPI components, with the same filters" do
      stub(200, %{"openapi" => "3.1.0", "components" => %{"schemas" => %{}}})

      assert {:ok, %{"openapi" => "3.1.0"}} =
               KilnClient.schema(format: :openapi, types: ["post"])

      assert_received {:request, "GET", "/api/schema", %{"format" => "openapi", "type" => "post"},
                       _, _}

      assert {:ok, _} = KilnClient.schema(format: :json)
      assert_received {:request, "GET", "/api/schema", params, _, _}
      refute Map.has_key?(params, "format")
    end

    test "format also takes the strings \"json\" and \"openapi\"" do
      stub(200, %{"openapi" => "3.1.0"})

      assert {:ok, _} = KilnClient.schema(format: "openapi")
      assert_received {:request, "GET", "/api/schema", %{"format" => "openapi"}, _, _}

      assert {:ok, _} = KilnClient.schema(format: "json")
      assert_received {:request, "GET", "/api/schema", params, _, _}
      refute Map.has_key?(params, "format")
    end

    test "a format that is not a map is refused before sending" do
      assert_raise ArgumentError, ~r/:json or :openapi/, fn ->
        KilnClient.schema(format: :typescript)
      end

      refute_received {:request, _, _, _, _, _}
    end
  end

  describe "sync_page/2" do
    @page %{"items" => [], "cursor" => "c1", "has_more" => true}

    test "nil starts a new sync with its scope; a cursor sends only itself" do
      stub(200, @page)

      assert {:ok, @page} = KilnClient.sync_page(nil, type: "post", surface: "json", limit: 10)

      assert_received {:request, "GET", "/api/sync",
                       %{
                         "initial" => "true",
                         "type" => "post",
                         "surface" => "json",
                         "limit" => "10"
                       }, _, _}

      assert {:ok, @page} = KilnClient.sync_page("c1", type: "post")
      assert_received {:request, "GET", "/api/sync", %{"cursor" => "c1"} = params, _, _}
      refute Map.has_key?(params, "type")
    end

    test "returns a 503 page as the error unless :retries is passed" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(KilnClient, fn conn ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 -> conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{})
          _ -> Req.Test.json(conn, @page)
        end
      end)

      assert {:error, %Error{status: 503}} = KilnClient.sync_page()

      Agent.update(counter, fn _ -> 0 end)
      assert {:ok, @page} = KilnClient.sync_page(nil, retries: 1, retry_delay_ms: 0)
    end
  end

  describe "resolve_path/2" do
    test "returns an ok verdict and sends the locale trio" do
      verdict = %{
        "status" => "ok",
        "type" => "post",
        "slug" => "hello",
        "id" => "p1",
        "path" => "/blog/hello",
        "locale" => "fr"
      }

      stub(200, verdict)

      assert {:ok, ^verdict} =
               KilnClient.resolve_path("/blog/hello",
                 locale: "fr-CA",
                 fallback: false,
                 fallback_locale: "en"
               )

      assert_received {:request, "GET", "/api/resolve",
                       %{
                         "path" => "/blog/hello",
                         "locale" => "fr-CA",
                         "fallback" => "false",
                         "fallback_locale" => "en"
                       }, _, _}
    end

    test "returns a moved verdict" do
      stub(200, %{"status" => "moved", "to" => "/blog/new"})

      assert {:ok, %{"status" => "moved", "to" => "/blog/new"}} =
               KilnClient.resolve_path("/blog/old")
    end

    test "the not_found 404 is a verdict, not an error" do
      stub(404, %{"status" => "not_found"})

      assert {:ok, %{"status" => "not_found"}} = KilnClient.resolve_path("/nothing")
    end

    test "a 404 without the verdict body stays an error" do
      stub(404, %{"errors" => [%{"status" => "404", "code" => "not_found"}]})

      assert {:error, %Error{reason: :not_found}} = KilnClient.resolve_path("/nothing")
    end

    test "a missing leading slash is the server's 400" do
      stub(400, %{"errors" => [%{"status" => "400", "code" => "missing_path"}]})

      assert {:error, %Error{reason: :validation, code: "missing_path"}} =
               KilnClient.resolve_path("blog/hello")
    end
  end

  describe "menus/1, menu/2 and locales/1" do
    test "menus lists every menu" do
      body = %{"menus" => [%{"key" => "main", "name" => "Main", "locale" => "en"}]}
      stub(200, body)

      assert {:ok, ^body} = KilnClient.menus()
      assert_received {:request, "GET", "/api/menus", _, _, _}
    end

    test "menu reads one resolved tree in a locale" do
      body = %{"key" => "main", "name" => "Main", "locale" => "fr", "items" => []}
      stub(200, body)

      assert {:ok, ^body} = KilnClient.menu("main", locale: "fr")
      assert_received {:request, "GET", "/api/menus/main", %{"locale" => "fr"}, _, _}
    end

    test "an unknown menu is :not_found" do
      stub(404, %{"error" => ~s(no menu "nope" for locale "en")})

      assert {:error, %Error{reason: :not_found}} = KilnClient.menu("nope")
    end

    test "locales returns the default, the locales and the chains" do
      body = %{"default" => "en", "locales" => ["en", "fr"], "fallbacks" => %{"fr" => ["en"]}}
      stub(200, body)

      assert {:ok, ^body} = KilnClient.locales()
      assert_received {:request, "GET", "/api/locales", _, _, _}
    end
  end

  describe "related/3" do
    test "reads the related documents with :limit and the locale" do
      body = %{"type" => "post", "slug" => "hello", "locale" => "en", "related" => []}
      stub(200, body)

      assert {:ok, ^body} = KilnClient.related("post", "hello", limit: 3, locale: "en")

      assert_received {:request, "GET", "/api/content/post/hello/related",
                       %{"limit" => "3", "locale" => "en"}, _, _}
    end
  end

  describe "form/2 and submit_form/3" do
    test "form reads the schema" do
      body = %{"slug" => "contact", "honeypot_field" => "website", "fields" => []}
      stub(200, body)

      assert {:ok, ^body} = KilnClient.form("contact")
      assert_received {:request, "GET", "/api/forms/contact", _, _, _}
    end

    test "form passes the new field types and min/max/step through" do
      body = %{
        "slug" => "contact",
        "fields" => [
          %{"name" => "tags", "type" => "checkboxes", "options" => ["a"], "min" => nil},
          %{"name" => "qty", "type" => "number", "min" => 0, "max" => 10, "step" => 0.5}
        ]
      }

      stub(200, body)
      assert {:ok, ^body} = KilnClient.form("contact")
    end

    test "an inactive form is :not_found" do
      stub(404, %{"errors" => [%{"status" => "404", "code" => "not_found"}]})

      assert {:error, %Error{reason: :not_found}} = KilnClient.form("gone")
    end

    test "submit_form posts the values as JSON and never sends the configured key" do
      Application.put_env(:kiln_client, :api_key, "kiln_configured_key")
      stub(200, %{"ok" => true, "message" => "Thanks!"})

      assert {:ok, %{"ok" => true, "message" => "Thanks!"}} =
               KilnClient.submit_form("contact", %{"email" => "a@example.com"}, locale: "fr")

      assert_received {:request, "POST", "/api/forms/contact", _, headers, body}
      assert body == %{"email" => "a@example.com", "locale" => "fr"}
      assert headers["content-type"] == ["application/json"]
      assert headers["authorization"] == []
    end

    test "a 422 refusal is :validation, read by field_errors/1" do
      stub(422, %{"ok" => false, "errors" => %{"email" => "is required"}})

      assert {:error, %Error{reason: :validation, status: 422} = error} =
               KilnClient.submit_form("contact", %{})

      assert Error.field_errors(error) == %{"email" => ["is required"]}
    end
  end
end
