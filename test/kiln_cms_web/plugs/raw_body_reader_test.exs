defmodule KilnCMSWeb.Plugs.RawBodyReaderTest do
  @moduledoc """
  The body reader's **scoping** is the property under test.

  Preserving raw bodies for every request would hold a second copy of every
  upload, up to the endpoint's 8 MB cap, for the benefit of one route. The
  negative assertions here are what stop a well-meaning future refactor from
  quietly making that global.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMSWeb.Plugs.RawBodyReader

  defp read(path, body) do
    :post
    |> Plug.Test.conn(path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> RawBodyReader.read_body([])
  end

  describe "the webhook path" do
    test "preserves the raw bytes" do
      body = ~s({"id":"evt_1"})

      assert {:ok, ^body, conn} = read("/billing/webhooks/stripe", body)
      assert conn.private[:raw_body] == body
    end

    test "preserves bytes exactly, including non-ASCII and unusual spacing" do
      # Byte-for-byte fidelity is the whole point: an HMAC over re-encoded JSON
      # would not match.
      body = ~s({ "note" : "café — ünïcode",  "id":"evt_2" })

      assert {:ok, ^body, conn} = read("/billing/webhooks/stripe", body)
      assert conn.private[:raw_body] == body
    end

    test "matches even behind a locale prefix" do
      # `KilnCMSWeb.Plugs.SetLocale` strips `/<locale>/…` but runs AFTER
      # Plug.Parsers, so the prefix is still present here.
      body = ~s({"id":"evt_3"})

      assert {:ok, ^body, conn} = read("/fr/billing/webhooks/stripe", body)
      assert conn.private[:raw_body] == body
    end

    test "an oversized body is not stashed as a partial read" do
      # Over the cap, `{:more, ...}` is passed through so Plug.Parsers raises its
      # own too-large error. Stashing a truncated body would surface as a
      # confusing signature failure instead of a size error.
      body = String.duplicate("a", RawBodyReader.max_bytes() + 1)

      assert {:more, _partial, conn} = read("/billing/webhooks/stripe", body)
      refute conn.private[:raw_body]
    end
  end

  # #2272: a plugin mounts its own paths with `plug_routes/0`; the fixture
  # plugin declares POST /fixture-hooks/echo and forwards /fixture-forward.
  describe "a plugin plug route" do
    test "preserves the raw bytes of a routed path" do
      body = ~s({ "id" : "evt_9" })

      assert {:ok, ^body, conn} = read("/fixture-hooks/echo", body)
      assert conn.private[:raw_body] == body
    end

    test "preserves everything below a forwarded path" do
      body = ~s({"id":"evt_10"})

      assert {:ok, ^body, conn} = read("/fixture-forward/any/depth", body)
      assert conn.private[:raw_body] == body
    end

    test "matches behind a locale prefix, as the webhook path does" do
      body = ~s({"id":"evt_11"})

      assert {:ok, ^body, conn} = read("/fr/fixture-hooks/echo", body)
      assert conn.private[:raw_body] == body
    end

    test "preserves the raw bytes of a parameterised route" do
      body = ~s({ "id" : "evt_12" })

      assert {:ok, ^body, conn} = read("/fixture-hooks/provider/stripe", body)
      assert conn.private[:raw_body] == body

      assert {:ok, ^body, conn} = read("/fr/fixture-hooks/provider/stripe", body)
      assert conn.private[:raw_body] == body
    end

    test "a parameterised route still matches whole segments only" do
      for path <- ["/fixture-hooks/provider", "/fixture-hooks/provider/a/b"] do
        assert {:ok, _body, conn} = read(path, ~s({"a":1}))
        refute conn.private[:raw_body], "#{path} must not be preserved"
      end
    end

    test "matches whole segments only" do
      for path <- ["/fixture-hooks/echo-more", "/fixture-hooks/echo/extra", "/fixture-forwarded"] do
        assert {:ok, _body, conn} = read(path, ~s({"a":1}))
        refute conn.private[:raw_body], "#{path} must not be preserved"
      end
    end

    test "is capped like the other preserved paths" do
      body = String.duplicate("a", RawBodyReader.max_bytes() + 1)

      assert {:more, _partial, conn} = read("/fixture-hooks/echo", body)
      refute conn.private[:raw_body]
    end

    test "is listed among the preserved paths" do
      assert ["fixture-hooks", "echo"] in RawBodyReader.preserved_paths()
    end
  end

  describe "every other path" do
    test "a public form submission is NOT preserved" do
      body = ~s({"field":"value"})

      assert {:ok, ^body, conn} = read("/api/forms/contact", body)
      refute conn.private[:raw_body]
    end

    test "a media upload is NOT preserved" do
      assert {:ok, _body, conn} = read("/media/upload", String.duplicate("x", 10_000))
      refute conn.private[:raw_body]
    end

    test "the GraphQL endpoint is NOT preserved" do
      assert {:ok, _body, conn} = read("/gql", ~s({"query":"{ __typename }"}))
      refute conn.private[:raw_body]
    end
  end
end
