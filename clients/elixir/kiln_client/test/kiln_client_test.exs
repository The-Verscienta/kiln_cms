defmodule KilnClientTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  # Every stub records the conn it saw, so tests assert on path/params after
  # the call. The Req.Test plug runs in the test process, so send/1 is safe.
  defp record(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    send(self(), {:request, conn.request_path, conn.params})
    conn
  end

  defp stub_doc(doc) do
    Req.Test.stub(KilnClient, fn conn -> conn |> record() |> Req.Test.json(doc) end)
  end

  defp empty_doc, do: %{"data" => []}

  describe "list/2" do
    test "reads the /published feed by default and flattens the document" do
      stub_doc(%{
        "data" => [
          %{
            "id" => "p1",
            "type" => "post",
            "attributes" => %{"title" => "Hello"},
            "relationships" => %{
              "tags" => %{"data" => [%{"type" => "tag", "id" => "t1", "meta" => %{}}]},
              "category" => %{"links" => %{}}
            }
          }
        ],
        "included" => [%{"id" => "t1", "type" => "tag", "attributes" => %{"name" => "Elixir"}}],
        "meta" => %{"page" => %{"total" => 41}}
      })

      assert {:ok, %{items: [item], included: included, total: 41}} = KilnClient.list("posts")

      assert_received {:request, "/api/json/posts/published", params}
      assert params["page"]["count"] == "true"

      assert item["id"] == "p1"
      assert item["title"] == "Hello"
      assert item["relationships"]["tags"] == [%{"type" => "tag", "id" => "t1"}]
      # A relationship without a "data" key flattens to no refs.
      assert item["relationships"]["category"] == []
      assert included[{"tag", "t1"}]["name"] == "Elixir"

      tags = KilnClient.resolve(item, "tags", included)
      assert [%{"name" => "Elixir"}] = tags
    end

    test "published: false reads the plain (credential-widened) index" do
      stub_doc(empty_doc())

      assert {:ok, _} = KilnClient.list("posts", published: false)
      assert_received {:request, "/api/json/posts", _params}
    end

    test "encodes filters, operators, nested relationship filters, sorts and pagination" do
      stub_doc(empty_doc())

      assert {:ok, %{total: nil}} =
               KilnClient.list("entries",
                 filter: %{type_name: "product", id: {:in, ["a", "b"]}, tags: %{slug: "sale"}},
                 custom_filter: %{price: {:lte, 10}},
                 sort: ["-published_at", "title"],
                 custom_sort: ["-price"],
                 include: ["tags", "category"],
                 fields: %{"entry" => ["title", "slug"]},
                 limit: 5,
                 offset: 10,
                 count: false
               )

      assert_received {:request, "/api/json/entries/published", params}

      assert params["filter"] == %{
               "type_name" => "product",
               "id" => %{"in" => ["a", "b"]},
               "tags" => %{"slug" => "sale"}
             }

      assert params["custom_filter"] == %{"price" => %{"lte" => "10"}}
      assert params["sort"] == "-published_at,title"
      assert params["custom_sort"] == "-price"
      assert params["include"] == "tags,category"
      assert params["fields"] == %{"entry" => "title,slug"}
      assert params["page"] == %{"limit" => "5", "offset" => "10"}
    end
  end

  describe "one/3" do
    test "returns the first match with the included lookup merged in" do
      stub_doc(%{
        "data" => [%{"id" => "p1", "type" => "post", "attributes" => %{"title" => "Hit"}}],
        "included" => [%{"id" => "t1", "type" => "tag", "attributes" => %{}}]
      })

      assert {:ok, item} = KilnClient.one("posts", %{slug: "hit", locale: "en"})
      assert item["title"] == "Hit"
      assert Map.has_key?(item["included"], {"tag", "t1"})

      assert_received {:request, "/api/json/posts/published", params}
      assert params["filter"] == %{"slug" => "hit", "locale" => "en"}
      # one/3 forces limit 1 and drops the count.
      assert params["page"] == %{"limit" => "1"}
    end

    test "returns :not_found when nothing matches" do
      stub_doc(empty_doc())
      assert {:error, :not_found} = KilnClient.one("posts", %{slug: "missing"})
    end
  end

  describe "by_ids/3" do
    test "returns items in the requested order and drops misses" do
      stub_doc(%{
        "data" => [
          %{"id" => "b", "type" => "post", "attributes" => %{}},
          %{"id" => "a", "type" => "post", "attributes" => %{}}
        ]
      })

      assert {:ok, items} = KilnClient.by_ids("posts", ["a", "gone", "b"])
      assert Enum.map(items, & &1["id"]) == ["a", "b"]

      assert_received {:request, "/api/json/posts/published", params}
      assert params["filter"]["id"]["in"] == ["a", "gone", "b"]
    end

    test "short-circuits an empty id list without a request" do
      # No stub installed — a request would raise.
      assert {:ok, []} = KilnClient.by_ids("posts", [])
    end
  end

  describe "per-type search" do
    test "text_search/3 hits the /search/published twin by default" do
      stub_doc(empty_doc())

      assert {:ok, %{items: [], total: nil}} =
               KilnClient.text_search("posts", "elixir",
                 locale: "en",
                 custom_filter: %{price: {:gt, 1}},
                 include: ["tags"],
                 fields: %{"post" => ["title"]}
               )

      assert_received {:request, "/api/json/posts/search/published", params}
      assert params["query"] == "elixir"
      assert params["locale"] == "en"
      assert params["custom_filter"] == %{"price" => %{"gt" => "1"}}
      assert params["include"] == "tags"
      assert params["fields"] == %{"post" => "title"}
    end

    test "text_search/3 published: false uses the base route" do
      stub_doc(empty_doc())

      assert {:ok, _} = KilnClient.text_search("posts", "elixir", published: false)
      assert_received {:request, "/api/json/posts/search", _params}
    end

    test "semantic_search/3 and autocomplete/3 hit their published twins" do
      stub_doc(empty_doc())

      assert {:ok, _} = KilnClient.semantic_search("posts", "functional")
      assert_received {:request, "/api/json/posts/semantic-search/published", params}
      assert params["query"] == "functional"

      assert {:ok, _} = KilnClient.autocomplete("posts", "eli", locale: "en")
      assert_received {:request, "/api/json/posts/autocomplete/published", params}
      assert params["prefix"] == "eli"
      assert params["locale"] == "en"
    end
  end

  describe "search/2 (hybrid)" do
    test "hits /api/search with its params and returns the raw payload" do
      Req.Test.stub(KilnClient, fn conn ->
        conn |> record() |> Req.Test.json(%{"results" => %{"posts" => []}, "suggestion" => nil})
      end)

      assert {:ok, %{"results" => _}} =
               KilnClient.search("kiln", limit: 5, locale: "en", category: "news", facets: true)

      assert_received {:request, "/api/search", params}

      assert params == %{
               "q" => "kiln",
               "limit" => "5",
               "locale" => "en",
               "category" => "news",
               "facets" => "true"
             }
    end
  end

  describe "artifact/3" do
    test "retries once after a cold-cache 503" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(KilnClient, fn conn ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(503, "{}")

          _ ->
            Req.Test.json(record(conn), %{"type" => "post", "slug" => "hello"})
        end
      end)

      assert {:ok, %{"slug" => "hello"}} =
               KilnClient.artifact("posts", "hello", surface: "json", retry_delay_ms: 0)

      assert_received {:request, "/api/content/posts/hello", %{"surface" => "json"}}
    end

    test "retry: false fails fast on 503" do
      Req.Test.stub(KilnClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, "{}")
      end)

      assert {:error, {:http_status, 503, _}} =
               KilnClient.artifact("posts", "hello", retry: false)
    end
  end

  describe "transport" do
    test "sends the configured bearer key" do
      Application.put_env(:kiln_client, :api_key, "kiln_secret")
      on_exit(fn -> Application.delete_env(:kiln_client, :api_key) end)

      Req.Test.stub(KilnClient, fn conn ->
        send(self(), {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, empty_doc())
      end)

      assert {:ok, _} = KilnClient.list("posts")
      assert_received {:auth, ["Bearer kiln_secret"]}
    end

    test "no auth header without a key, JSON:API accept header always" do
      Req.Test.stub(KilnClient, fn conn ->
        send(
          self(),
          {:headers, Plug.Conn.get_req_header(conn, "authorization"),
           Plug.Conn.get_req_header(conn, "accept")}
        )

        Req.Test.json(conn, empty_doc())
      end)

      assert {:ok, _} = KilnClient.list("posts")
      assert_received {:headers, [], ["application/vnd.api+json"]}
    end

    test "non-2xx responses come back as {:error, {:http_status, status, body}}" do
      Req.Test.stub(KilnClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"errors":[]}))
      end)

      assert {:error, {:http_status, 500, %{"errors" => []}}} = KilnClient.list("posts")
    end

    test "404 is an error, not a crash" do
      Req.Test.stub(KilnClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, ~s({"errors":[{"code":"not_found"}]}))
      end)

      assert {:error, {:http_status, 404, _}} = KilnClient.artifact("posts", "gone")
    end
  end

  test "public_url/0 falls back to base_url" do
    assert KilnClient.public_url() == "http://kiln.test"

    Application.put_env(:kiln_client, :public_url, "https://cdn.example.com")
    on_exit(fn -> Application.delete_env(:kiln_client, :public_url) end)

    assert KilnClient.public_url() == "https://cdn.example.com"
  end
end
