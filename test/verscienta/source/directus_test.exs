defmodule Verscienta.Source.DirectusTest do
  @moduledoc "Directus REST client: pagination + bearer auth, stubbed via Req.Test."
  use ExUnit.Case, async: true

  alias Verscienta.Source

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "paginates until a short page and sends the read token + fields selector" do
    {:ok, handle} = Source.resolve({:directus, url: "https://api.example.com", token: "secret"})

    Req.Test.stub(Verscienta.Source.Directus, fn conn ->
      assert ["Bearer secret"] = Plug.Conn.get_req_header(conn, "authorization")
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["fields"] == "*.*"

      data =
        case conn.query_params["page"] do
          "1" -> Enum.map(1..100, &%{"id" => &1})
          "2" -> [%{"id" => 101}, %{"id" => 102}]
        end

      Req.Test.json(conn, %{"data" => data})
    end)

    assert {:ok, items} = Source.fetch_all(handle, "herbs")
    assert length(items) == 102
    assert List.last(items)["id"] == 102
  end

  test "surfaces a non-200 response as an error" do
    {:ok, handle} = Source.resolve({:directus, url: "https://api.example.com", token: "secret"})

    Req.Test.stub(Verscienta.Source.Directus, fn conn ->
      Plug.Conn.send_resp(conn, 403, "forbidden")
    end)

    assert {:error, message} = Source.fetch_all(handle, "herbs")
    assert message =~ "HTTP 403"
  end

  test "resolve/1 reports missing credentials" do
    assert {:error, msg} = Source.resolve({:directus, url: "https://x", token: nil})
    assert msg =~ "DIRECTUS_TOKEN"
  end
end
