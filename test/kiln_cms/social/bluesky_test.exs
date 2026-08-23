defmodule KilnCMS.Social.Providers.BlueskyTest do
  @moduledoc """
  The Bluesky provider's two XRPC calls (#497): `createSession` exchanges the
  handle and app password for an access JWT, `createRecord` writes the post.

  `KilnCMS.Social.AnnouncerTest` drives the *Mastodon* provider end to end and
  covers this module's `link_facets/2` in isolation, which left everything
  between the two — the session exchange, the bearer token it hands to the
  post, and the failure classification — unexercised.

  That classification is the load-bearing part, and it is not symmetric with
  Mastodon's: `createRecord` has no idempotency key, so a repeat creates a
  *second* public post. A 5xx or a dropped connection on the post therefore has
  to answer `:unknown` (the ledger stops, an operator decides), while the same
  ambiguity on the *session* call is a definite `:failed` — a session creates
  no record, so nothing can have been posted. Getting those two backwards is
  how one timeout becomes two posts on the operator's timeline, so each is
  pinned separately below.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Social
  alias KilnCMS.Social.Providers.Bluesky

  @session %{"accessJwt" => "jwt-abc", "did" => "did:plc:abc"}
  @record_uri "at://did:plc:abc/app.bsky.feed.post/3kabc"

  setup do
    %{org_id: KilnCMS.Accounts.default_org_id(), actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "bsky-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp account(ctx, attrs \\ %{}) do
    Social.create_account!(
      Map.merge(
        %{provider: :bluesky, handle: "kiln.bsky.social", credential: "app-pw"},
        attrs
      ),
      actor: ctx.actor,
      tenant: ctx.org_id
    )
  end

  # Routes the two XRPC methods to separate handlers and reports every call to
  # the test process, so a test can assert on the request that was made — and,
  # just as importantly, on the one that was *not*: `refute_received` is how
  # "the post was never attempted" gets asserted rather than assumed.
  defp stub(handlers) do
    test_pid = self()

    Req.Test.stub(KilnCMS.Social, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      method = conn.request_path |> String.split("/") |> List.last()
      send(test_pid, {:xrpc, method, body, conn.req_headers})

      case Map.fetch(handlers, method) do
        {:ok, handler} -> handler.(conn)
        :error -> flunk("unexpected XRPC call: #{conn.request_path}")
      end
    end)
  end

  defp json(status, payload) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(payload))
    end
  end

  defp status(code), do: fn conn -> Plug.Conn.send_resp(conn, code, "nope") end

  defp post(account),
    do:
      Bluesky.post(account, %{text: "A post\n\nhttps://kiln.test/a", url: "https://kiln.test/a"})

  describe "post/2" do
    test "signs in, posts with the session's bearer token, and returns the permalink", ctx do
      stub(%{
        "com.atproto.server.createSession" => json(200, @session),
        "com.atproto.repo.createRecord" => json(200, %{"uri" => @record_uri})
      })

      assert {:ok, %{id: @record_uri, url: url}} = post(account(ctx))
      assert url == "https://bsky.app/profile/kiln.bsky.social/post/3kabc"

      assert_received {:xrpc, "com.atproto.server.createSession", session_body, _headers}

      assert Jason.decode!(session_body) == %{
               "identifier" => "kiln.bsky.social",
               "password" => "app-pw"
             }

      assert_received {:xrpc, "com.atproto.repo.createRecord", record_body, headers}
      # The JWT has to come from *this* session response; a stale or absent
      # token is the failure this asserts against.
      assert {"authorization", "Bearer jwt-abc"} in headers

      assert %{
               "repo" => "did:plc:abc",
               "collection" => "app.bsky.feed.post",
               "record" => record
             } = Jason.decode!(record_body)

      assert record["$type"] == "app.bsky.feed.post"
      assert record["text"] == "A post\n\nhttps://kiln.test/a"
      assert {:ok, _, _} = DateTime.from_iso8601(record["createdAt"])
      assert [%{"index" => %{"byteStart" => 8}}] = record["facets"]
    end

    test "an unrecognised record URI yields no permalink rather than a broken one", ctx do
      stub(%{
        "com.atproto.server.createSession" => json(200, @session),
        "com.atproto.repo.createRecord" => json(200, %{"uri" => "not-an-at-uri"})
      })

      assert {:ok, %{id: "not-an-at-uri", url: nil}} = post(account(ctx))
    end

    test "a 4xx on the post is a definite failure — nothing was written", ctx do
      stub(%{
        "com.atproto.server.createSession" => json(200, @session),
        "com.atproto.repo.createRecord" => status(400)
      })

      assert {:error, {:failed, "Bluesky rejected the post (400)"}} = post(account(ctx))
    end

    test "a 5xx on the post is UNKNOWN — createRecord has no idempotency key", ctx do
      stub(%{
        "com.atproto.server.createSession" => json(200, @session),
        "com.atproto.repo.createRecord" => status(503)
      })

      # Not `{:failed, _}`: calling this failed is what invites the retry that
      # puts a second copy on the operator's timeline.
      assert {:error, :unknown} = post(account(ctx))
    end

    test "a dropped connection on the post is UNKNOWN for the same reason", ctx do
      stub(%{
        "com.atproto.server.createSession" => json(200, @session),
        "com.atproto.repo.createRecord" => fn conn ->
          Req.Test.transport_error(conn, :econnrefused)
        end
      })

      assert {:error, :unknown} = post(account(ctx))
    end

    test "a 200 whose body carries no uri is UNKNOWN — the post may well exist", ctx do
      stub(%{
        "com.atproto.server.createSession" => json(200, @session),
        "com.atproto.repo.createRecord" => json(200, %{"ok" => true})
      })

      assert {:error, :unknown} = post(account(ctx))
    end

    test "refused credentials fail definitely, and the post is never attempted", ctx do
      stub(%{"com.atproto.server.createSession" => status(401)})

      assert {:error, {:failed, "Bluesky refused the credentials (401)"}} = post(account(ctx))

      assert_received {:xrpc, "com.atproto.server.createSession", _body, _headers}
      refute_received {:xrpc, "com.atproto.repo.createRecord", _body, _headers}
    end

    test "a 5xx on the session is still a definite failure — a session posts nothing", ctx do
      stub(%{"com.atproto.server.createSession" => status(500)})

      assert {:error, {:failed, "Bluesky answered 500"}} = post(account(ctx))
      refute_received {:xrpc, "com.atproto.repo.createRecord", _body, _headers}
    end

    test "a session response missing its token is a failure, not a post without one", ctx do
      stub(%{"com.atproto.server.createSession" => json(200, %{"did" => "did:plc:abc"})})

      assert {:error, {:failed, "Bluesky returned a session we could not read"}} =
               post(account(ctx))

      refute_received {:xrpc, "com.atproto.repo.createRecord", _body, _headers}
    end

    test "a transport failure on the session is definite, not unknown", ctx do
      stub(%{
        "com.atproto.server.createSession" => fn conn ->
          Req.Test.transport_error(conn, :econnrefused)
        end
      })

      assert {:error, {:failed, _reason}} = post(account(ctx))
      refute_received {:xrpc, "com.atproto.repo.createRecord", _body, _headers}
    end

    test "an account whose app password cannot be decrypted never reaches the network", ctx do
      # A restored backup or a rotated secret_key_base: the row survives, the
      # credential does not.
      broken = %{account(ctx) | credential_encrypted: <<0, 1, 2>>}

      assert {:error, {:failed, "no usable app password stored"}} = post(broken)
      refute_received {:xrpc, _method, _body, _headers}
    end

    test "an account with no handle never reaches the network", ctx do
      assert {:error, {:failed, "no handle configured"}} = post(%{account(ctx) | handle: nil})
      refute_received {:xrpc, _method, _body, _headers}
    end
  end

  describe "verify/1" do
    test "a session that opens is a working account", ctx do
      stub(%{"com.atproto.server.createSession" => json(200, @session)})

      assert :ok = Bluesky.verify(account(ctx))
      # Verifying must not announce anything.
      refute_received {:xrpc, "com.atproto.repo.createRecord", _body, _headers}
    end

    test "a refusal comes back as the bare reason, never :unknown", ctx do
      stub(%{"com.atproto.server.createSession" => status(401)})

      assert {:error, "Bluesky refused the credentials (401)"} = Bluesky.verify(account(ctx))
    end

    test "a transport failure is still a definite answer", ctx do
      stub(%{
        "com.atproto.server.createSession" => fn conn ->
          Req.Test.transport_error(conn, :econnrefused)
        end
      })

      assert {:error, reason} = Bluesky.verify(account(ctx))
      refute reason == :unknown
    end
  end

  test "max_length is Bluesky's own limit" do
    assert Bluesky.max_length() == 300
  end
end
