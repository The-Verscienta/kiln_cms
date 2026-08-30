defmodule KilnCMSWeb.FederationControllerTest do
  @moduledoc """
  The public ActivityPub surface (#491): the two-part gate, the discovery
  documents, and an end-to-end signed `Follow`.

  The `Follow` test is the one that matters. It is the issue's own success
  criterion — "follow a Kiln site from Mastodon" — and it exercises the whole
  chain in one pass: raw-body capture, signature verification against a key
  fetched from the sending actor, follower persistence, and the `Accept` that
  makes the follow stick.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Federation.Follower
  alias KilnCMS.Federation.HttpSignature
  alias KilnCMS.Federation.SiteFederation
  alias KilnCMS.Keys

  @origin "http://www.example.com"
  @remote_actor "https://remote.example/users/alice"

  setup do
    KilnCMS.FederationFixtures.enable_deployment!()
    org_id = KilnCMS.Accounts.default_org_id()

    # `RemoteActor` caches a fetched document for minutes (#966), and every test
    # here mints a fresh key at the SAME actor URL — a key rotation per test,
    # which is precisely what the cache is designed not to notice. Clearing it
    # keeps each test's stub authoritative. `async: false`, so nothing races it.
    Cachex.clear(KilnCMS.Federation.RemoteActor.cache_name())

    remote_pem = Keys.generate_rsa_pem()
    {:ok, remote_key} = Keys.rsa_private_key(remote_pem)

    stub_remote_actor(Keys.rsa_public_key_pem(remote_key))

    %{org_id: org_id, remote_pem: remote_pem}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fedc-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp enable!(org_id, attrs \\ %{}) do
    Ash.create!(
      SiteFederation,
      Map.merge(%{origin: @origin, username: "kiln"}, attrs),
      action: :enable,
      authorize?: false,
      tenant: org_id
    )
  end

  defp stub_remote_actor(public_pem, overrides \\ %{}) do
    # Captured here, in the test process. The stub body runs in whichever
    # process serves the request, so a process-dictionary counter would be
    # written in one process and read in another — and silently report zero.
    test_pid = self()

    document =
      Map.merge(
        %{
          "id" => @remote_actor,
          "inbox" => @remote_actor <> "/inbox",
          "publicKey" => %{
            "id" => @remote_actor <> "#main-key",
            "owner" => @remote_actor,
            "publicKeyPem" => public_pem
          }
        },
        overrides
      )

    Req.Test.stub(KilnCMS.Federation, fn conn ->
      case conn.method do
        "GET" ->
          send(test_pid, :actor_fetched)

          conn
          |> Plug.Conn.put_resp_content_type("application/activity+json")
          |> Plug.Conn.send_resp(200, Jason.encode!(document))

        # An inbox delivery (the Accept). Answer 202 like a real server.
        _post ->
          Plug.Conn.send_resp(conn, 202, "")
      end
    end)
  end

  describe "the gate" do
    test "every route 404s for a site that has not enabled federation", %{conn: conn} do
      assert conn |> get("/actor") |> response(404)
      assert conn |> get("/actor/outbox") |> response(404)
      assert conn |> get("/actor/followers") |> response(404)

      assert conn
             |> get("/.well-known/webfinger?resource=acct:kiln@www.example.com")
             |> response(404)
    end

    test "and 404s again when the deployment switch is off", %{conn: conn, org_id: org_id} do
      enable!(org_id)

      original = Application.get_env(:kiln_cms, KilnCMS.Federation, [])
      Application.put_env(:kiln_cms, KilnCMS.Federation, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Federation, original) end)

      # A 404, not a 403: an instance that does not federate should be
      # indistinguishable from one built without the feature.
      assert conn |> get("/actor") |> response(404)
    end

    test "a site row that exists but is disabled still 404s", %{conn: conn, org_id: org_id} do
      settings = enable!(org_id)
      Ash.update!(settings, %{}, action: :disable, authorize?: false, tenant: org_id)

      assert conn |> get("/actor") |> response(404)
    end
  end

  describe "discovery" do
    setup %{org_id: org_id} do
      %{settings: enable!(org_id, %{display_name: "Example Site"})}
    end

    test "the actor document carries the key and the collections", %{conn: conn} do
      conn = get(conn, "/actor")
      body = conn |> response(200) |> Jason.decode!()

      assert Enum.at(conn |> get_resp_header("content-type"), 0) =~ "application/activity+json"

      assert body["id"] == "#{@origin}/actor"
      # `Service`, not `Person`: this is a publication that posts automatically,
      # and mislabelling automated accounts is what moderators block for.
      assert body["type"] == "Service"
      assert body["preferredUsername"] == "kiln"
      assert body["name"] == "Example Site"
      assert body["inbox"] == "#{@origin}/actor/inbox"
      assert body["outbox"] == "#{@origin}/actor/outbox"
      assert body["publicKey"]["id"] == "#{@origin}/actor#main-key"
      assert body["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    end

    test "the private key is never served", %{conn: conn} do
      body = conn |> get("/actor") |> response(200)

      refute body =~ "PRIVATE KEY"
    end

    test "webfinger resolves the site's handle", %{conn: conn} do
      body =
        conn
        |> get("/.well-known/webfinger?resource=acct:kiln@www.example.com")
        |> response(200)
        |> Jason.decode!()

      assert body["subject"] == "acct:kiln@www.example.com"

      self_link = Enum.find(body["links"], &(&1["rel"] == "self"))
      assert self_link["type"] == "application/activity+json"
      assert self_link["href"] == "#{@origin}/actor"
    end

    test "webfinger 404s an unknown handle rather than answering an empty record", %{conn: conn} do
      assert conn
             |> get("/.well-known/webfinger?resource=acct:someone@elsewhere.test")
             |> response(404)
    end

    test "the followers collection publishes a count, never the list", %{conn: conn} do
      body = conn |> get("/actor/followers") |> response(200) |> Jason.decode!()

      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 0
      # Who follows a publication is not the publication's information to publish.
      refute Map.has_key?(body, "orderedItems")
      refute Map.has_key?(body, "items")
    end

    test "the outbox carries published content as Create activities", %{conn: conn} do
      actor = admin()

      post =
        KilnCMS.CMS.create_post!(
          %{title: "Outboxed", slug: "outboxed-#{System.unique_integer([:positive])}"},
          actor: actor
        )

      KilnCMS.CMS.publish_post!(post, actor: actor)

      body = conn |> get("/actor/outbox") |> response(200) |> Jason.decode!()

      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] >= 1

      item = Enum.find(body["orderedItems"], &(&1["object"]["name"] == "Outboxed"))
      assert item["type"] == "Create"
      # Built from the pinned origin, not the request host — the outbox and the
      # delivered activities must agree on the object id.
      assert item["object"]["id"] == "#{@origin}/ap/object/#{post.id}"
    end

    test "a draft never reaches the outbox", %{conn: conn} do
      actor = admin()

      KilnCMS.CMS.create_post!(
        %{title: "Unpublished", slug: "draft-#{System.unique_integer([:positive])}"},
        actor: actor
      )

      body = conn |> get("/actor/outbox") |> response(200) |> Jason.decode!()

      refute Enum.any?(body["orderedItems"], &(&1["object"]["name"] == "Unpublished"))
    end

    # An object id that does not dereference is a broken post on the receiving
    # side: Mastodon re-resolves objects on refresh and to confirm a Delete.
    test "an object id minted into an activity actually resolves", %{conn: conn} do
      actor = admin()

      post =
        KilnCMS.CMS.create_post!(
          %{title: "Resolvable", slug: "resolvable-#{System.unique_integer([:positive])}"},
          actor: actor
        )

      KilnCMS.CMS.publish_post!(post, actor: actor)

      body = conn |> get("/ap/object/#{post.id}") |> response(200) |> Jason.decode!()

      assert body["type"] == "Article"
      assert body["id"] == "#{@origin}/ap/object/#{post.id}"
      assert body["name"] == "Resolvable"
    end

    test "an unpublished document's object id does not resolve", %{conn: conn} do
      actor = admin()

      post =
        KilnCMS.CMS.create_post!(
          %{title: "Hidden", slug: "hidden-#{System.unique_integer([:positive])}"},
          actor: actor
        )

      assert conn |> get("/ap/object/#{post.id}") |> response(404)
    end
  end

  describe "the inbox" do
    setup %{org_id: org_id} do
      %{settings: enable!(org_id)}
    end

    defp follow_activity do
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://remote.example/follows/1",
        "type" => "Follow",
        "actor" => @remote_actor,
        "object" => "#{@origin}/actor"
      }
    end

    defp post_signed(conn, activity, remote_pem, opts \\ []) do
      body = Jason.encode!(activity)
      key_id = Keyword.get(opts, :key_id, @remote_actor <> "#main-key")

      {:ok, headers} =
        HttpSignature.sign(
          "#{@origin}/actor/inbox",
          key_id,
          body,
          [private_key_pem: remote_pem] ++ Keyword.take(opts, [:date])
        )

      Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
      |> put_req_header("content-type", "application/activity+json")
      |> post("/actor/inbox", body)
    end

    test "an unsigned Follow is refused", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/activity+json")
        |> post("/actor/inbox", Jason.encode!(follow_activity()))

      assert response(conn, 401)
    end

    test "a signed Follow is recorded and accepted", %{
      conn: conn,
      org_id: org_id,
      remote_pem: remote_pem
    } do
      assert conn |> post_signed(follow_activity(), remote_pem) |> response(202)

      assert [follower] = Ash.read!(Follower, authorize?: false, tenant: org_id)
      assert follower.actor_uri == @remote_actor
      assert follower.inbox_uri == @remote_actor <> "/inbox"

      # The Accept is what makes a follow stick on Mastodon, and it goes out
      # through the same signed, ledgered delivery path as everything else.
      assert [delivery] =
               Ash.read!(KilnCMS.Federation.Delivery, authorize?: false, tenant: org_id)

      assert delivery.activity_type == :accept
      assert delivery.activity["type"] == "Accept"
      assert delivery.activity["object"]["type"] == "Follow"
    end

    test "a Follow signed with a key the actor does not own is refused", %{
      conn: conn,
      org_id: org_id,
      remote_pem: remote_pem
    } do
      # A valid signature over one's own key, claiming a keyId belonging to
      # someone else — the forgery that would otherwise let anyone subscribe any
      # account's server to this site's firehose.
      conn =
        post_signed(conn, follow_activity(), remote_pem,
          key_id: "https://remote.example/users/mallory#main-key"
        )

      assert response(conn, 401)
      assert [] = Ash.read!(Follower, authorize?: false, tenant: org_id)
    end

    test "a Follow addressed to a different actor is ignored, not recorded", %{
      conn: conn,
      org_id: org_id,
      remote_pem: remote_pem
    } do
      activity = Map.put(follow_activity(), "object", "https://elsewhere.test/actor")

      assert conn |> post_signed(activity, remote_pem) |> response(202)
      assert [] = Ash.read!(Follower, authorize?: false, tenant: org_id)
    end

    test "an Undo removes the follower", %{conn: conn, org_id: org_id, remote_pem: remote_pem} do
      assert conn |> post_signed(follow_activity(), remote_pem) |> response(202)
      assert [_follower] = Ash.read!(Follower, authorize?: false, tenant: org_id)

      undo = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Undo",
        "actor" => @remote_actor,
        "object" => follow_activity()
      }

      assert build_conn() |> unique_ip() |> post_signed(undo, remote_pem) |> response(202)
      assert [] = Ash.read!(Follower, authorize?: false, tenant: org_id)
    end

    # A 4xx would make the sending server retry for days over something that is
    # simply not built yet, which is a way to get an instance blocked.
    test "an unsupported activity is accepted and ignored", %{
      conn: conn,
      org_id: org_id,
      remote_pem: remote_pem
    } do
      like = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Like",
        "actor" => @remote_actor,
        "object" => "#{@origin}/ap/object/whatever"
      }

      assert conn |> post_signed(like, remote_pem) |> response(202)
      assert [] = Ash.read!(Follower, authorize?: false, tenant: org_id)
    end

    # #966. Verifying anything costs an outbound GET to a host the caller named,
    # because the key that verifies the signature lives in the document being
    # fetched. So an activity this phase does nothing with must not pay for one.
    test "an unsigned Like costs no outbound request", %{conn: conn} do
      like = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Like",
        "actor" => @remote_actor,
        "object" => "#{@origin}/ap/object/whatever"
      }

      assert conn
             |> put_req_header("content-type", "application/activity+json")
             |> post("/actor/inbox", Jason.encode!(like))
             |> response(202)

      refute_received :actor_fetched
    end

    # A Follow addressed elsewhere is dropped whatever the actor document
    # says, so reading one buys nothing.
    test "a Follow addressed to another actor costs no outbound request", %{conn: conn} do
      misdelivered = %{follow_activity() | "object" => "https://elsewhere.example/actor"}

      assert conn
             |> put_req_header("content-type", "application/activity+json")
             |> post("/actor/inbox", Jason.encode!(misdelivered))
             |> response(202)

      refute_received :actor_fetched
    end

    # An `Undo{Like}` carries `object` as a bare URI, and is ignored for the
    # same reason — but it must not be confused with the `Undo{Follow}` that
    # does need authenticating.
    test "an Undo of something other than a Follow costs no outbound request", %{conn: conn} do
      undo = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Undo",
        "actor" => @remote_actor,
        "object" => "https://remote.example/likes/1"
      }

      assert conn
             |> put_req_header("content-type", "application/activity+json")
             |> post("/actor/inbox", Jason.encode!(undo))
             |> response(202)

      refute_received :actor_fetched
    end

    # The case that has to keep paying: a Follow naming us is acted on, so its
    # sender must be authenticated, so its document must be read.
    test "a Follow naming this site is still fetched and verified", %{
      conn: conn,
      remote_pem: remote_pem
    } do
      assert conn |> post_signed(follow_activity(), remote_pem) |> response(202)

      assert_received :actor_fetched
    end

    # Repeats from the same actor were re-fetched on every request. The second
    # request is a *fresh* signature (a later `Date`): a byte-identical resend
    # is a replay and is refused by the nonce store (#967), which the test
    # below pins.
    test "a second activity from the same actor is served from cache", %{
      conn: conn,
      remote_pem: remote_pem
    } do
      assert conn |> post_signed(follow_activity(), remote_pem) |> response(202)
      assert_received :actor_fetched

      later = HttpSignature.http_date(DateTime.add(DateTime.utc_now(), 1, :second))
      assert conn |> post_signed(follow_activity(), remote_pem, date: later) |> response(202)
      refute_received :actor_fetched
    end

    # #967: a blocked actor, or a blocked instance, is refused before anything
    # is written — the durable answer to an abusive follower.
    test "a Follow from a blocked actor is accepted (202) but never recorded", %{
      conn: conn,
      org_id: org_id,
      remote_pem: remote_pem
    } do
      KilnCMS.Federation.block!(%{kind: :actor, value: @remote_actor, reason: "spam"},
        authorize?: false,
        tenant: org_id
      )

      assert conn |> post_signed(follow_activity(), remote_pem) |> response(202)
      assert [] == Ash.read!(Follower, authorize?: false, tenant: org_id)
      assert [] == Ash.read!(KilnCMS.Federation.Delivery, authorize?: false, tenant: org_id)
    end

    test "a Follow from a blocked INSTANCE is refused too, and blocking drops the existing follower",
         %{conn: conn, org_id: org_id, remote_pem: remote_pem} do
      assert conn |> post_signed(follow_activity(), remote_pem) |> response(202)
      assert [_follower] = Ash.read!(Follower, authorize?: false, tenant: org_id)

      # Block the whole instance: the recorded follower goes with it.
      assert {:ok, _block} =
               KilnCMS.Federation.block_and_drop(:instance, "Remote.Example", "abusive",
                 authorize?: false,
                 tenant: org_id
               )

      assert [] == Ash.read!(Follower, authorize?: false, tenant: org_id)

      # And a fresh follow (new date, so not a replay) is refused before write.
      later = HttpSignature.http_date(DateTime.add(DateTime.utc_now(), 2, :second))
      assert conn |> post_signed(follow_activity(), remote_pem, date: later) |> response(202)
      assert [] == Ash.read!(Follower, authorize?: false, tenant: org_id)

      # Normalized on the way in: the host is stored downcased.
      assert [%{kind: :instance, value: "remote.example"}] =
               Ash.read!(KilnCMS.Federation.Block, authorize?: false, tenant: org_id)
    end

    # #967: the replay nonce store. Inside the 300-second date window a
    # byte-identical signed request used to replay freely.
    test "a byte-identical replay of a verified request is refused", %{
      conn: conn,
      remote_pem: remote_pem,
      org_id: org_id
    } do
      body = Jason.encode!(follow_activity())

      {:ok, headers} =
        HttpSignature.sign("#{@origin}/actor/inbox", @remote_actor <> "#main-key", body,
          private_key_pem: remote_pem
        )

      send_it = fn ->
        Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/actor/inbox", body)
      end

      assert send_it.() |> response(202)
      # Same bytes, same signature, still inside the date window: replayed.
      assert send_it.() |> response(401)

      # And exactly one row was recorded, keyed by the signature.
      assert 1 == Ash.count!(KilnCMS.Federation.SeenSignature, authorize?: false)
      _ = org_id
    end

    # A remote server's bad minute must not be remembered as a bad ten.
    test "a failed fetch is not cached", %{conn: conn, remote_pem: remote_pem} do
      test_pid = self()

      Req.Test.stub(KilnCMS.Federation, fn c ->
        send(test_pid, :actor_fetched)
        Plug.Conn.send_resp(c, 503, "")
      end)

      assert conn |> post_signed(follow_activity(), remote_pem) |> response(401)
      assert_received :actor_fetched

      assert conn |> post_signed(follow_activity(), remote_pem) |> response(401)
      assert_received :actor_fetched
    end

    test "a tampered body is refused", %{conn: conn, remote_pem: remote_pem} do
      body = Jason.encode!(follow_activity())

      {:ok, headers} =
        HttpSignature.sign("#{@origin}/actor/inbox", @remote_actor <> "#main-key", body,
          private_key_pem: remote_pem
        )

      tampered = Jason.encode!(Map.put(follow_activity(), "actor", "https://evil.test/users/x"))

      conn =
        Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
        |> put_req_header("content-type", "application/activity+json")
        |> post("/actor/inbox", tampered)

      assert response(conn, 401)
    end
  end

  describe "the inbox refuses hostile actors" do
    setup %{org_id: org_id} do
      %{settings: enable!(org_id)}
    end

    # The takeover. An attacker serves their own document claiming a popular
    # account's id, signs with their own key, and the follower upsert would
    # overwrite the real account's row — redirecting every future delivery to
    # the attacker and letting a follow-up Undo delete the real follower.
    test "a document claiming an id it was not served from", %{
      conn: conn,
      org_id: org_id,
      remote_pem: remote_pem
    } do
      victim = "https://mastodon.example/users/victim"

      {:ok, key} = Keys.rsa_private_key(remote_pem)

      stub_remote_actor(Keys.rsa_public_key_pem(key), %{
        "id" => victim,
        "publicKey" => %{
          "id" => victim <> "#main-key",
          "owner" => victim,
          "publicKeyPem" => Keys.rsa_public_key_pem(key)
        }
      })

      activity = Map.put(follow_activity(), "actor", @remote_actor)

      assert conn
             |> post_signed(activity, remote_pem, key_id: victim <> "#main-key")
             |> response(401)

      assert [] = Ash.read!(Follower, authorize?: false, tenant: org_id)
    end

    # A follower's inbox is POSTed to on every publish. Letting an actor name
    # somebody else's server turns the site's editorial calendar into a signed
    # flood aimed at a third party.
    test "an actor whose inbox lives on another host", %{
      conn: conn,
      org_id: org_id,
      remote_pem: remote_pem
    } do
      {:ok, key} = Keys.rsa_private_key(remote_pem)
      stub_remote_actor(Keys.rsa_public_key_pem(key), %{"inbox" => "https://victim.example/"})

      assert conn |> post_signed(follow_activity(), remote_pem) |> response(202)
      assert [] = Ash.read!(Follower, authorize?: false, tenant: org_id)
    end

    test "an Undo{Follow} addressed to a different site leaves the follower alone", %{
      conn: conn,
      org_id: org_id,
      remote_pem: remote_pem
    } do
      assert conn |> post_signed(follow_activity(), remote_pem) |> response(202)

      undo = %{
        "type" => "Undo",
        "actor" => @remote_actor,
        "object" => Map.put(follow_activity(), "object", "https://elsewhere.test/actor")
      }

      assert build_conn() |> unique_ip() |> post_signed(undo, remote_pem) |> response(202)
      assert [_still_following] = Ash.read!(Follower, authorize?: false, tenant: org_id)
    end

    # `Undo{Like}` carries `object` as a bare URI and is far more common than
    # `Undo{Follow}`. A catch-all Undo clause would delete a follower for
    # un-liking one post.
    test "an Undo of something other than a Follow does not unfollow", %{
      conn: conn,
      org_id: org_id,
      remote_pem: remote_pem
    } do
      assert conn |> post_signed(follow_activity(), remote_pem) |> response(202)

      undo = %{
        "type" => "Undo",
        "actor" => @remote_actor,
        "object" => "https://remote.example/likes/1"
      }

      assert build_conn() |> unique_ip() |> post_signed(undo, remote_pem) |> response(202)
      assert [_still_following] = Ash.read!(Follower, authorize?: false, tenant: org_id)
    end

    test "a follow past the ceiling", %{conn: conn, org_id: org_id, remote_pem: remote_pem} do
      original = Application.get_env(:kiln_cms, KilnCMS.Federation, [])
      Application.put_env(:kiln_cms, KilnCMS.Federation, Keyword.put(original, :max_followers, 0))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Federation, original) end)

      assert conn |> post_signed(follow_activity(), remote_pem) |> response(202)
      assert [] = Ash.read!(Follower, authorize?: false, tenant: org_id)
    end

    # The Accept is stored for 30 days and POSTed back. Echoing the inbound
    # activity verbatim would let a caller choose the size of both.
    test "the Accept does not echo the inbound activity back", %{
      conn: conn,
      org_id: org_id,
      remote_pem: remote_pem
    } do
      padded = Map.put(follow_activity(), "padding", String.duplicate("x", 50_000))

      assert conn |> post_signed(padded, remote_pem) |> response(202)

      assert [delivery] =
               Ash.read!(KilnCMS.Federation.Delivery, authorize?: false, tenant: org_id)

      refute delivery.activity["object"]["padding"]
      assert delivery.activity["object"]["type"] == "Follow"
      assert byte_size(Jason.encode!(delivery.activity)) < 2_000
    end
  end

  describe "identity is pinned" do
    test "re-enabling keeps the actor id and key its followers already cached",
         %{org_id: org_id} do
      first = enable!(org_id)

      Ash.update!(first, %{}, action: :disable, authorize?: false, tenant: org_id)
      second = enable!(org_id, %{origin: "https://moved.example", username: "renamed"})

      assert second.origin == @origin
      assert second.username == "kiln"
      assert second.public_key_pem == first.public_key_pem
    end
  end
end
