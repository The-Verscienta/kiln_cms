defmodule Kiln.SafeFetchTest do
  @moduledoc """
  `Kiln.SafeFetch` (#2047), the covered way for a plugin to fetch a URL it did
  not write: inside a KilnCMS build every call reaches `KilnCMS.SafeFetch`, and
  nothing a plugin passes can take the pin away.

  The pinning itself is asserted as a value in `KilnCMS.SafeFetchTest`; this
  suite is about the seam — that the facade reaches the core, keeps its
  documented shapes, and drops the one option that could undo the pin.
  """
  use ExUnit.Case, async: false

  @url "https://feeds.example.test/rss"

  defp stub(name \\ __MODULE__, fun), do: Req.Test.stub(name, fun)

  defp plug(name \\ __MODULE__), do: {Req.Test, name}

  test "the core implements the behaviour the SDK dispatches to" do
    behaviours = KilnCMS.SafeFetch.module_info(:attributes) |> Keyword.get_values(:behaviour)
    assert [Kiln.SafeFetch] in behaviours
  end

  describe "the documented shapes" do
    test "get/2 returns status, lower-cased headers and the raw body" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"a":1}))
      end)

      assert {:ok, %{status: 200, headers: headers, body: ~s({"a":1})}} =
               Kiln.SafeFetch.get(@url, plug: plug())

      assert ["application/json" <> _charset] = headers["content-type"]
    end

    test "post/3 sends the body; head/2 and request/3 send their method" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, conn.method <> ":" <> body)
      end)

      assert {:ok, %{body: "POST:hello"}} = Kiln.SafeFetch.post(@url, "hello", plug: plug())
      assert {:ok, %{status: 200}} = Kiln.SafeFetch.head(@url, plug: plug())

      assert {:ok, %{body: "PUT:x"}} =
               Kiln.SafeFetch.request(:put, @url, body: "x", plug: plug())
    end

    test "a body over :max_bytes is an error, or a prefix with :truncate_body" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("a", 100)) end)

      assert {:error, reason} = Kiln.SafeFetch.get(@url, plug: plug(), max_bytes: 10)
      assert is_binary(reason)

      assert {:ok, %{body: "aaaaaaaaaa"}} =
               Kiln.SafeFetch.get(@url, plug: plug(), max_bytes: 10, truncate_body: true)
    end

    test "a redirect is returned, not followed, unless :max_redirects asks" do
      stub(fn
        %{request_path: "/rss"} = conn ->
          conn |> Plug.Conn.put_resp_header("location", "/feed") |> Plug.Conn.send_resp(301, "")

        conn ->
          Plug.Conn.send_resp(conn, 200, "feed")
      end)

      assert {:ok, %{status: 301}} = Kiln.SafeFetch.get(@url, plug: plug())

      assert {:ok, %{status: 200, body: "feed"}} =
               Kiln.SafeFetch.get(@url, plug: plug(), max_redirects: 1)
    end
  end

  describe "what a plugin cannot do" do
    test "a private or metadata address is refused before anything is dialled" do
      stub(fn _conn -> flunk("a refused address reached the network") end)

      for url <- [
            "http://169.254.169.254/latest/meta-data",
            "http://127.0.0.1:4000/",
            "http://10.0.0.1/"
          ] do
        assert {:error, "blocked URL: " <> _reason} = Kiln.SafeFetch.get(url, plug: plug())
      end
    end

    test "a redirect to a private address is refused at the hop" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, "blocked redirect from " <> _reason} =
               Kiln.SafeFetch.get(@url, plug: plug(), max_redirects: 3)
    end

    # `KilnCMS.SafeFetch` merges `:req_options` last, so it can replace the
    # pinned `url:` and `connect_options:`. The facade must not pass it on. A
    # second stub stands in for "whatever the plugin smuggled": Req applies
    # options in order, so if `:req_options` got through, its plug would answer.
    test ":req_options is dropped, so the client's own options stay the core's" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "facade") end)
      stub(Kiln.SafeFetchTest.Smuggled, fn conn -> Plug.Conn.send_resp(conn, 200, "smuggled") end)

      assert {:ok, %{body: "facade"}} =
               Kiln.SafeFetch.get(@url,
                 plug: plug(),
                 req_options: [plug: plug(Kiln.SafeFetchTest.Smuggled)]
               )
    end

    test "an unknown method or a non-string URL is an error, not a raise" do
      assert {:error, _reason} = Kiln.SafeFetch.request(:connect, @url, [])
      assert {:error, _reason} = Kiln.SafeFetch.get(nil)
    end
  end
end
