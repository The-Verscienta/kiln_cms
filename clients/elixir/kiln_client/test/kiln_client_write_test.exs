defmodule KilnClientWriteTest do
  # Not async: the no-API-key guard needs the global `:api_key` config to be
  # unset, and `KilnClientTest` sets it in one of its transport tests. A sync
  # module runs after every async one, so the two can never overlap.
  use ExUnit.Case, async: false

  alias KilnClient.Error

  @moduletag :capture_log

  @key "kiln_write_secret"

  # Records method, path, the headers that matter and the decoded JSON body,
  # then answers with `status` + `body` (a map → JSON, a binary → raw).
  defp stub(status \\ 200, body \\ post_doc(), headers \\ []) do
    Req.Test.stub(KilnClient, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(self(), {
        :request,
        conn.method,
        conn.request_path,
        %{
          "accept" => Plug.Conn.get_req_header(conn, "accept"),
          "content-type" => Plug.Conn.get_req_header(conn, "content-type"),
          "authorization" => Plug.Conn.get_req_header(conn, "authorization")
        },
        if(raw == "", do: nil, else: Jason.decode!(raw))
      })

      conn =
        Enum.reduce(headers, conn, fn {name, value}, conn ->
          Plug.Conn.put_resp_header(conn, name, value)
        end)

      case body do
        body when is_map(body) ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

        body when is_binary(body) ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, body)
      end
    end)
  end

  defp post_doc(attributes \\ %{}, id \\ "p1") do
    %{"data" => %{"id" => id, "type" => "post", "attributes" => attributes}}
  end

  describe "create/3" do
    test "POSTs a JSON:API resource object with the key and flattens the answer" do
      stub(201, post_doc(%{"title" => "Via SDK", "state" => "draft"}))

      assert {:ok, post} =
               KilnClient.create("posts", %{title: "Via SDK", slug: "via-sdk"}, api_key: @key)

      assert_received {:request, "POST", "/api/json/posts", headers, body}
      assert headers["accept"] == ["application/vnd.api+json"]
      assert headers["content-type"] == ["application/vnd.api+json"]
      assert headers["authorization"] == ["Bearer #{@key}"]
      # No `id` on a create: the server's schema rejects one.
      assert body == %{
               "data" => %{
                 "type" => "post",
                 "attributes" => %{"title" => "Via SDK", "slug" => "via-sdk"}
               }
             }

      assert post["id"] == "p1"
      assert post["title"] == "Via SDK"
      assert post["state"] == "draft"
    end

    test "falls back to the configured key" do
      Application.put_env(:kiln_client, :api_key, "kiln_configured")
      on_exit(fn -> Application.delete_env(:kiln_client, :api_key) end)
      stub(201)

      assert {:ok, _} = KilnClient.create("posts", %{title: "x"})
      assert_received {:request, "POST", _, %{"authorization" => ["Bearer kiln_configured"]}, _}
    end

    test "derives entry from entries, and honours an explicit :type" do
      stub(201)

      assert {:ok, _} = KilnClient.create("entries", %{title: "Doc"}, api_key: @key)
      assert {:ok, _} = KilnClient.create("people", %{}, api_key: @key, type: "person")
      assert {:ok, _} = KilnClient.create("pages", %{}, api_key: @key)

      assert_received {:request, _, _, _, %{"data" => %{"type" => "entry"}}}
      assert_received {:request, _, _, _, %{"data" => %{"type" => "person"}}}
      assert_received {:request, _, _, _, %{"data" => %{"type" => "page"}}}
    end
  end

  describe "update/4" do
    test "PATCHes /:id with the id in both the path and the resource object" do
      stub(200, post_doc(%{"title" => "Edited"}, "a/b"))

      assert {:ok, %{"title" => "Edited"}} =
               KilnClient.update("posts", "a/b", %{add_tag_ids: ["t1"]}, api_key: @key)

      assert_received {:request, "PATCH", "/api/json/posts/a%2Fb", _headers, body}

      assert body == %{
               "data" => %{
                 "type" => "post",
                 "id" => "a/b",
                 "attributes" => %{"add_tag_ids" => ["t1"]}
               }
             }
    end
  end

  describe "workflow transitions" do
    for {fun, route} <- [
          submit_for_review: "submit-for-review",
          return_to_draft: "return-to-draft",
          publish: "publish",
          unpublish: "unpublish"
        ] do
      test "#{fun}/3 PATCHes /:id/#{route} with an empty resource object" do
        stub()

        assert {:ok, %{"id" => "p1"}} =
                 apply(KilnClient, unquote(fun), ["posts", "p1", [api_key: @key]])

        path = "/api/json/posts/p1/#{unquote(route)}"
        assert_received {:request, "PATCH", ^path, headers, body}
        assert headers["content-type"] == ["application/vnd.api+json"]
        assert body == %{"data" => %{"type" => "post", "id" => "p1", "attributes" => %{}}}
      end
    end

    test "transition/4 kebab-cases any verb, so a newer server's verb is reachable" do
      stub()

      assert {:ok, _} = KilnClient.transition("entries", "e1", :some_new_verb, api_key: @key)
      assert {:ok, _} = KilnClient.transition("entries", "e1", "other_verb", api_key: @key)

      assert_received {:request, "PATCH", "/api/json/entries/e1/some-new-verb", _,
                       %{"data" => %{"type" => "entry"}}}

      assert_received {:request, "PATCH", "/api/json/entries/e1/other-verb", _, _}
    end

    test "a wrong-state transition is a :conflict carrying the current state" do
      stub(409, %{
        "errors" => [
          %{
            "status" => "409",
            "code" => "invalid_state_transition",
            "detail" => "cannot publish: already published",
            "meta" => %{"current_state" => "published"}
          }
        ]
      })

      assert {:error, %Error{reason: :conflict, status: 409} = error} =
               KilnClient.publish("posts", "p1", api_key: @key)

      assert error.code == "invalid_state_transition"
      assert Error.current_state(error) == "published"
      assert Exception.message(error) =~ "already published"
    end
  end

  describe "delete/3" do
    test "DELETEs /:id with no body and returns :ok on a 200 document" do
      stub()

      assert :ok = KilnClient.delete("posts", "p1", api_key: @key)
      assert_received {:request, "DELETE", "/api/json/posts/p1", headers, nil}
      assert headers["content-type"] == []
    end

    test "returns :ok on an empty 204" do
      stub(204, "")
      assert :ok = KilnClient.delete("posts", "p1", api_key: @key)
    end
  end

  describe "the no-API-key guard" do
    test "every write refuses with :no_api_key and sends nothing" do
      stub()

      writes = [
        create: &KilnClient.create("posts", %{title: "x"}, &1),
        update: &KilnClient.update("posts", "p1", %{}, &1),
        transition: &KilnClient.transition("posts", "p1", :publish, &1),
        submit_for_review: &KilnClient.submit_for_review("posts", "p1", &1),
        return_to_draft: &KilnClient.return_to_draft("posts", "p1", &1),
        publish: &KilnClient.publish("posts", "p1", &1),
        unpublish: &KilnClient.unpublish("posts", "p1", &1),
        delete: &KilnClient.delete("posts", "p1", &1)
      ]

      for {name, write} <- writes, opts <- [[], [api_key: nil], [api_key: ""]] do
        result = write.(opts)

        assert match?({:error, %Error{reason: :no_api_key}}, result),
               "#{name} with #{inspect(opts)} returned #{inspect(result)}"

        {:error, error} = result
        assert Exception.message(error) =~ "api_key"
      end

      refute_received {:request, _, _, _, _}
    end

    test "reads still work without a key" do
      stub(200, %{"data" => []})
      assert {:ok, _} = KilnClient.list("posts")
      assert_received {:request, "GET", "/api/json/posts/published", %{"authorization" => []}, _}
    end
  end

  describe "error mapping" do
    for {status, reason} <- [
          {401, :unauthorized},
          {403, :forbidden},
          {404, :not_found},
          {400, :validation},
          {422, :validation},
          {409, :conflict},
          {429, :rate_limited},
          {500, :server},
          {503, :server},
          {418, :http}
        ] do
      test "#{status} → #{inspect(reason)}" do
        stub(unquote(status), %{"errors" => [%{"code" => "c", "detail" => "d"}]})

        assert {:error, %Error{} = error} = KilnClient.update("posts", "p1", %{}, api_key: @key)
        assert error.reason == unquote(reason)
        assert error.status == unquote(status)
        assert error.code == "c"
        assert error.errors == [%{"code" => "c", "detail" => "d"}]
        assert error.method == :patch
        assert error.path == "/api/json/posts/p1"
      end
    end

    test "a validation error exposes the field pointers" do
      stub(400, %{
        "errors" => [
          %{
            "code" => "invalid_attribute",
            "detail" => "has already been taken",
            "source" => %{"pointer" => "/data/attributes/slug"}
          },
          %{
            "code" => "required",
            "detail" => "is required",
            "source" => %{"pointer" => "/data/attributes/title"}
          },
          %{"code" => "invalid_body", "detail" => "no pointer here"}
        ]
      })

      assert {:error, %Error{reason: :validation} = error} =
               KilnClient.create("posts", %{}, api_key: @key)

      assert Error.pointers(error) == ["/data/attributes/slug", "/data/attributes/title"]

      assert Error.field_errors(error) == %{
               "slug" => ["has already been taken"],
               "title" => ["is required"]
             }
    end

    test "a 429 carries Retry-After as seconds" do
      stub(429, %{"errors" => [%{"code" => "too_many_requests"}]}, [{"retry-after", "42"}])

      assert {:error, %Error{reason: :rate_limited, retry_after: 42, code: "too_many_requests"}} =
               KilnClient.create("posts", %{}, api_key: @key)
    end

    test "an HTTP-date Retry-After becomes seconds from now" do
      at =
        DateTime.utc_now()
        |> DateTime.add(30, :second)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      stub(503, %{}, [{"retry-after", at}])

      assert {:error, %Error{reason: :server, retry_after: seconds}} =
               KilnClient.publish("posts", "p1", api_key: @key)

      assert seconds in 28..31
    end

    test "a transport failure is :transport with the exception kept" do
      Req.Test.stub(KilnClient, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error{reason: :transport, status: nil} = error} =
               KilnClient.create("posts", %{}, api_key: @key)

      assert %Req.TransportError{reason: :econnrefused} = error.exception
      assert Exception.message(error) =~ "connection refused"
    end

    test "never puts the API key in an error" do
      stub(401, %{"errors" => [%{"code" => "unauthorized"}]})

      assert {:error, %Error{reason: :unauthorized} = error} =
               KilnClient.create("posts", %{}, api_key: @key)

      refute inspect(error) =~ @key
      refute Exception.message(error) =~ @key
    end

    test "normalize/1 lifts the read functions' legacy errors into the struct" do
      assert %Error{reason: :server, status: 500, code: "boom"} =
               Error.normalize({:http_status, 500, %{"errors" => [%{"code" => "boom"}]}})

      assert %Error{reason: :not_found, status: 404} = Error.normalize(:not_found)

      assert %Error{reason: :transport} =
               Error.normalize(%Req.TransportError{reason: :timeout})

      error = %Error{reason: :conflict}
      assert Error.normalize(error) == error
    end
  end

  describe "graphql/3" do
    @query "query ($slug: String!, $locale: String!) { postBySlug(slug: $slug, locale: $locale) { title } }"

    test "POSTs {query, variables} to /gql as plain JSON and returns data" do
      stub(200, %{"data" => %{"postBySlug" => %{"title" => "Hi"}}})

      assert {:ok, %{"postBySlug" => %{"title" => "Hi"}}} =
               KilnClient.graphql(@query, %{slug: "hi"}, api_key: @key)

      assert_received {:request, "POST", "/gql", headers, body}
      assert headers["content-type"] == ["application/json"]
      assert headers["accept"] == ["application/json"]
      assert headers["authorization"] == ["Bearer #{@key}"]
      assert body == %{"query" => @query, "variables" => %{"slug" => "hi"}}
    end

    test "needs no key, and forwards :operation_name" do
      stub(200, %{"data" => %{}})

      assert {:ok, %{}} =
               KilnClient.graphql("query A { a } query B { b }", %{}, operation_name: "B")

      assert_received {:request, "POST", "/gql", %{"authorization" => []},
                       %{"operationName" => "B"}}
    end

    test "top-level errors are :graphql with the partial data" do
      stub(200, %{
        "data" => %{"postBySlug" => nil},
        "errors" => [%{"message" => "forbidden", "path" => ["postBySlug"], "code" => "forbidden"}]
      })

      assert {:error, %Error{reason: :graphql, status: 200} = error} =
               KilnClient.graphql(@query, %{slug: "x"})

      assert error.code == "forbidden"
      assert error.data == %{"postBySlug" => nil}
      assert [%{"path" => ["postBySlug"]}] = error.errors
      assert Exception.message(error) =~ "forbidden"
    end

    test "reads the code from extensions when that is where it is" do
      stub(200, %{
        "errors" => [
          %{"message" => "nope", "extensions" => %{"code" => "invalid_state_transition"}}
        ]
      })

      assert {:error, %Error{reason: :graphql, code: "invalid_state_transition", data: nil}} =
               KilnClient.graphql("{ a }")
    end

    test "a GraphQL-shaped 400 (unparseable document) is :graphql" do
      stub(400, %{"errors" => [%{"message" => "syntax error"}]})
      assert {:error, %Error{reason: :graphql, status: 400}} = KilnClient.graphql("{")
    end

    test "transport refusals keep their HTTP reason (429 is still :rate_limited)" do
      stub(429, %{}, [{"retry-after", "5"}])

      assert {:error, %Error{reason: :rate_limited, retry_after: 5}} =
               KilnClient.graphql("{ a }")
    end

    test "mutation payload errors are data, not an error" do
      # Ash reports a refused mutation inside the payload; the helper must not
      # invent a failure the caller did not ask it to detect.
      payload = %{"createPost" => %{"result" => nil, "errors" => [%{"message" => "forbidden"}]}}
      stub(200, %{"data" => payload})

      assert {:ok, ^payload} = KilnClient.graphql("mutation { createPost }")
    end
  end
end
