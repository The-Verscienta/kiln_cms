defmodule KilnCMS.WebhooksTest do
  @moduledoc """
  Publishing content dispatches signed webhook deliveries (via Oban) to active,
  subscribed endpoints.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.WebhookEndpoint
  alias KilnCMS.Webhooks

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "wh-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "wh-#{System.unique_integer([:positive])}"

  # Stub the outbound HTTP and forward each request back to the test process.
  defp stub_capture do
    test_pid = self()

    Req.Test.stub(KilnCMS.Webhooks, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:delivered, conn.host, conn.request_path, Map.new(conn.req_headers), body})
      Req.Test.json(conn, %{ok: true})
    end)
  end

  defp publish_page(admin) do
    page = CMS.create_page!(%{title: "Launch", slug: slug()}, actor: admin)
    CMS.publish_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()
  end

  test "publishing delivers a signed payload to a subscribed endpoint" do
    stub_capture()
    admin = admin()
    endpoint = CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    publish_page(admin)

    assert_received {:delivered, "example.test", "/hook", headers, body}
    assert headers["x-kilncms-event"] == "page.published"

    assert headers["x-kilncms-signature"] ==
             Webhooks.signature(WebhookEndpoint.secret(endpoint), body)

    assert %{
             "event" => "page.published",
             "data" => %{"title" => "Launch", "state" => "published"}
           } =
             Jason.decode!(body)
  end

  test "the payload carries `audience`, so a subscriber can filter gated content" do
    # A webhook fires for a members-only document exactly as it does for a
    # public one, with the full block tree. That is deliberate — an endpoint is
    # somewhere an operator chose to send content, HMAC-signed and SSRF-guarded,
    # unlike the anonymously-queryable Meilisearch index (#1006). But it was not
    # KNOWABLE: without this field a subscriber mirroring publishes to a public
    # front end had nothing to filter on (#1014).
    stub_capture()
    admin = admin()
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    page =
      CMS.create_page!(%{title: "Members only", slug: slug(), audience: :member}, actor: admin)

    CMS.publish_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    assert_received {:delivered, "example.test", "/hook", _headers, body}

    assert %{"data" => %{"audience" => "member", "title" => "Members only", "locked" => false}} =
             Jason.decode!(body)
  end

  test "a passphrase-locked document says so, since `audience` cannot" do
    # The half `audience` alone misses. Publish public, then lock: the payload
    # still reads `"audience" => "public"` and carries the whole body, so a
    # receiver reproducing Kiln's own three-part rule needs this flag or it
    # mirrors a locked document to its public front end.
    stub_capture()
    admin = admin()
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    page = CMS.create_page!(%{title: "Confidential", slug: slug()}, actor: admin)
    page = CMS.publish_page!(page, %{}, actor: admin)
    CMS.update_page!(page, %{access_password: "shared secret"}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    payloads =
      Stream.repeatedly(fn ->
        receive do
          {:delivered, _, _, _, body} -> Jason.decode!(body)["data"]
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&(&1 != nil))

    assert %{"locked" => true, "audience" => "public"} = List.last(payloads)

    # And the hash itself never leaves.
    refute Map.has_key?(List.last(payloads), "access_password_hash")
    refute Map.has_key?(List.last(payloads), "password_fingerprint")
  end

  test "a public document says so rather than omitting the field" do
    # An absent key and `"public"` must not be the same thing on the wire: a
    # subscriber writing `if payload["audience"] not in [nil, "public"]` and one
    # writing `if payload["audience"] != "public"` should both be right.
    stub_capture()
    admin = admin()
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    publish_page(admin)

    assert_received {:delivered, "example.test", "/hook", _headers, body}
    assert %{"data" => %{"audience" => "public", "locked" => false}} = Jason.decode!(body)
  end

  test "unpublishing dispatches an unpublished event" do
    stub_capture()
    admin = admin()
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    page = CMS.create_page!(%{title: "Live", slug: slug()}, actor: admin)
    page = CMS.publish_page!(page, %{}, actor: admin)
    CMS.unpublish_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    events =
      Stream.repeatedly(fn ->
        receive do
          {:delivered, _, _, headers, _} -> headers["x-kilncms-event"]
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&(&1 != nil))

    assert "page.published" in events
    assert "page.unpublished" in events
  end

  # #914: archiving a published record removes it from delivery exactly as
  # unpublishing does, so it must tell a subscriber the same way — but only
  # when there was anything to remove.
  test "archiving a published document dispatches an unpublished event" do
    stub_capture()
    admin = admin()
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    page = CMS.create_page!(%{title: "Live", slug: slug()}, actor: admin)
    page = CMS.publish_page!(page, %{}, actor: admin)
    CMS.archive_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    events =
      Stream.repeatedly(fn ->
        receive do
          {:delivered, _, _, headers, _} -> headers["x-kilncms-event"]
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&(&1 != nil))

    assert "page.published" in events
    assert "page.unpublished" in events
  end

  test "archiving an in-review (never published) document dispatches nothing" do
    # Distinct from the draft case: `:archive`'s `from: [:draft, :in_review,
    # :published]` makes `:in_review` a real reachable pre-state, and only
    # `changeset.data.state == :published` — not, say, `!= :draft` — is the
    # right predicate. This case is what would catch that looser one.
    stub_capture()
    admin = admin()
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    page = CMS.create_page!(%{title: "Under review", slug: slug()}, actor: admin)
    page = CMS.submit_page_for_review!(page, actor: admin)
    CMS.archive_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    # No `unpublished` — only the body-less `archived` tombstone.
    assert_received {:delivered, _, _, %{"x-kilncms-event" => "page.archived"}, _}
    refute_received {:delivered, _, _, _, _}
  end

  test "archiving a draft (never published) document dispatches nothing" do
    stub_capture()
    admin = admin()
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    page = CMS.create_page!(%{title: "Never live", slug: slug()}, actor: admin)
    CMS.archive_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    # A draft was never delivered, so archiving it must not say `unpublished`
    # — this is what `only_when: :was_published` (rather than the generic
    # `:published`, which checks the resulting state — always `:archived`
    # here, so it would never gate anything) is for. It does say `archived`,
    # with identity only: the draft's title and body stay home.
    assert_received {:delivered, _, _, %{"x-kilncms-event" => "page.archived"}, body}
    assert %{"data" => data} = Jason.decode!(body)
    assert Map.keys(data) |> Enum.sort() == ~w(id locale slug state updated_at)
    assert data["id"] == page.id
    refute_received {:delivered, _, _, _, _}
  end

  test "editing published content dispatches an updated event" do
    stub_capture()
    admin = admin()
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    page = CMS.create_page!(%{title: "Live", slug: slug()}, actor: admin)
    page = CMS.publish_page!(page, %{}, actor: admin)
    CMS.update_page!(page, %{title: "Live (edited)"}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    events =
      Stream.repeatedly(fn ->
        receive do
          {:delivered, _, _, headers, _} -> headers["x-kilncms-event"]
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&(&1 != nil))

    assert "page.published" in events
    assert "page.updated" in events
  end

  test "editing a draft does not dispatch an updated event" do
    stub_capture()
    admin = admin()
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    page = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: admin)
    CMS.update_page!(page, %{title: "Draft (edited)"}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    refute_received {:delivered, _, _, _, _}
  end

  test "inactive endpoints receive nothing" do
    stub_capture()
    admin = admin()
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook", active: false}, actor: admin)

    publish_page(admin)

    refute_received {:delivered, _, _, _, _}
  end

  test "endpoints not subscribed to the event are skipped" do
    stub_capture()
    admin = admin()

    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook", events: ["post.published"]},
      actor: admin
    )

    publish_page(admin)

    refute_received {:delivered, _, _, _, _}
  end

  test "selectable events include every content type crossed with each verb" do
    events = KilnCMS.CMS.WebhookEndpoint.events()

    for verb <- ~w(published unpublished updated in_review returned_to_draft) do
      assert "page.#{verb}" in events
      assert "post.#{verb}" in events
    end
  end

  test "review events are opt-in: the default subscription excludes them (#375)" do
    stub_capture()
    admin = admin()
    # Default subscription (no explicit events list) — publish lifecycle only.
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    page = CMS.create_page!(%{title: "Quiet Draft", slug: slug()}, actor: admin)
    CMS.submit_page_for_review!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    # The draft-carrying review event must NOT reach a default subscriber.
    refute_received {:delivered, _, _, _, _}
  end

  test "review-workflow transitions dispatch in_review / returned_to_draft events (#375)" do
    stub_capture()
    admin = admin()

    # Review events carry draft bodies, so the endpoint opts in explicitly.
    CMS.create_webhook_endpoint!(
      %{url: "https://example.test/hook", events: KilnCMS.CMS.WebhookEndpoint.events()},
      actor: admin
    )

    page = CMS.create_page!(%{title: "Reviewable", slug: slug()}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    assert_received {:delivered, _, _, %{"x-kilncms-event" => "page.created"}, _}

    page = CMS.submit_page_for_review!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    assert_received {:delivered, "example.test", "/hook", headers, body}
    assert headers["x-kilncms-event"] == "page.in_review"

    assert %{"event" => "page.in_review", "data" => %{"state" => "in_review"}} =
             Jason.decode!(body)

    CMS.return_page_to_draft!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    assert_received {:delivered, "example.test", "/hook", headers, body}
    assert headers["x-kilncms-event"] == "page.returned_to_draft"

    assert %{"event" => "page.returned_to_draft", "data" => %{"state" => "draft"}} =
             Jason.decode!(body)
  end

  describe "the record's own lifecycle: created, archived, deleted, restored" do
    defp events_received do
      Stream.repeatedly(fn ->
        receive do
          {:delivered, _, _, %{"x-kilncms-event" => event}, body} -> {event, Jason.decode!(body)}
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&(&1 != nil))
    end

    test "created carries the draft's body, and only to an endpoint that opted in" do
      stub_capture()
      admin = admin()
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

      CMS.create_page!(%{title: "Secret draft", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()
      refute_received {:delivered, _, _, _, _}

      CMS.create_webhook_endpoint!(
        %{url: "https://example.test/all", events: ["page.created"]},
        actor: admin
      )

      page = CMS.create_page!(%{title: "Opted in", slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert [{"page.created", %{"data" => data}}] = events_received()
      assert data["id"] == page.id
      assert data["title"] == "Opted in"
      assert data["state"] == "draft"
    end

    test "trashing sends a body-less deleted tombstone to a default subscriber" do
      stub_capture()
      admin = admin()
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

      page = CMS.create_page!(%{title: "Live then gone", slug: slug()}, actor: admin)
      page = CMS.publish_page!(page, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()
      assert [{"page.published", _}] = events_received()

      CMS.destroy_page!(page, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert [{"page.deleted", %{"data" => data}}] = events_received()

      assert data == %{
               "id" => page.id,
               "slug" => page.slug,
               "locale" => "en",
               "state" => "published",
               "updated_at" => data["updated_at"]
             }
    end

    test "restoring a published document sends its body; a draft, the tombstone" do
      stub_capture()
      admin = admin()
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

      live = CMS.create_page!(%{title: "Back on air", slug: slug()}, actor: admin)
      live = CMS.publish_page!(live, %{}, actor: admin)
      draft = CMS.create_page!(%{title: "Private words", slug: slug()}, actor: admin)
      CMS.destroy_page!(live, actor: admin)
      CMS.destroy_page!(draft, actor: admin)
      KilnCMS.DataCase.drain_oban()
      _ = events_received()

      [trashed_live] = CMS.list_trashed_pages!(actor: admin, query: [filter: [id: live.id]])
      CMS.restore_page!(trashed_live, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert [{"page.restored", %{"data" => %{"title" => "Back on air", "blocks" => _}}}] =
               events_received()

      [trashed_draft] = CMS.list_trashed_pages!(actor: admin, query: [filter: [id: draft.id]])
      CMS.restore_page!(trashed_draft, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert [{"page.restored", %{"data" => data}}] = events_received()
      refute Map.has_key?(data, "title")
      assert data["state"] == "draft"
    end

    test "unarchiving says restored, as a tombstone" do
      stub_capture()
      admin = admin()
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

      page = CMS.create_page!(%{title: "Shelved", slug: slug()}, actor: admin)
      page = CMS.archive_page!(page, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()
      assert [{"page.archived", _}] = events_received()

      CMS.unarchive_page!(page, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert [{"page.restored", %{"data" => %{"state" => "draft"} = data}}] = events_received()
      refute Map.has_key?(data, "title")
    end
  end

  describe "signing" do
    @secret "whsec-test"
    @body ~s({"event":"page.published","data":{}})

    test "the timestamped signature verifies, inside the window" do
      header = Webhooks.timestamped_signature(@secret, 1_800_000_000, @body)
      assert header =~ ~r/\At=1800000000,v1=[0-9a-f]{64}\z/

      assert Webhooks.verify(@secret, @body, header, now: 1_800_000_000) == :ok
      assert Webhooks.verify(@secret, @body, header, now: 1_800_000_300) == :ok
      assert Webhooks.verify(@secret, @body, header, now: 1_799_999_700) == :ok
    end

    # The vector `clients/js/test/webhooks.test.ts` and
    # `clients/elixir/kiln_client/test/webhook_test.exs` assert too: the
    # three implementations are pinned to one answer.
    test "matches the vector the client libraries verify" do
      body = ~s({"event":"page.published","delivery_id":"d-1","data":{}})

      assert Webhooks.timestamped_signature(@secret, 1_800_000_000, body) ==
               "t=1800000000,v1=e09a0895dc1b7f726710de36079d36941c634959f61a2c547ff00e848c3df80a"
    end

    test "it refuses a stale or future timestamp, a changed body, and a wrong secret" do
      header = Webhooks.timestamped_signature(@secret, 1_800_000_000, @body)

      assert Webhooks.verify(@secret, @body, header, now: 1_800_000_301) == {:error, :expired}
      assert Webhooks.verify(@secret, @body, header, now: 1_799_999_699) == {:error, :expired}

      assert Webhooks.verify(@secret, @body <> " ", header, now: 1_800_000_000) ==
               {:error, :mismatch}

      assert Webhooks.verify("other", @body, header, now: 1_800_000_000) == {:error, :mismatch}
      assert Webhooks.verify(@secret, @body, header, now: 1_800_000_900, tolerance: 900) == :ok
    end

    # The timestamp is inside the MAC: re-stamping a captured request with a
    # fresh `t` and its old `v1` is exactly the replay the scheme exists to stop.
    test "a captured v1 cannot be re-stamped with a fresh t" do
      "t=1800000000," <> v1 = Webhooks.timestamped_signature(@secret, 1_800_000_000, @body)

      assert Webhooks.verify(@secret, @body, "t=1800009999," <> v1, now: 1_800_009_999) ==
               {:error, :mismatch}
    end

    test "several v1 entries: any one matching is enough (secret roll-over)" do
      "t=1800000000,v1=" <> good = Webhooks.timestamped_signature(@secret, 1_800_000_000, @body)
      header = "t=1800000000,v1=#{String.duplicate("0", 64)},v1=#{good}"

      assert Webhooks.verify(@secret, @body, header, now: 1_800_000_000) == :ok
    end

    test "a header that does not parse is malformed, not a mismatch" do
      for header <- [nil, "", "v1=abc", "t=soon,v1=abc", "t=1,t=2,v1=abc", "t=1800000000"] do
        assert Webhooks.verify(@secret, @body, header, now: 1_800_000_000) ==
                 {:error, :malformed},
               inspect(header)
      end
    end
  end

  describe "the signing secret at rest" do
    test "is stored encrypted, never as the plaintext" do
      endpoint = CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin())
      secret = WebhookEndpoint.secret(endpoint)
      assert byte_size(secret) == 43

      %{rows: [[stored]]} =
        KilnCMS.Repo.query!(
          "SELECT secret_encrypted FROM webhook_endpoints WHERE id = $1",
          [Ecto.UUID.dump!(endpoint.id)]
        )

      refute stored =~ secret
      assert KilnCMS.Keys.Vault.decrypt(stored) == {:ok, secret}
    end

    # Ciphertext from a `SECRET_KEY_BASE` this server no longer has: sending the
    # delivery unsigned, or signed with anything else, would be accepted by a
    # receiver that does not verify and rejected by one that does. Refused.
    test "a secret that no longer opens refuses the delivery before dialling" do
      Req.Test.stub(KilnCMS.Webhooks, fn _conn -> flunk("an unsigned delivery was sent") end)

      Ash.Seed.seed!(WebhookEndpoint, %{
        url: "https://example.test/hook",
        events: ["page.published"],
        active: true,
        secret_encrypted: :crypto.strong_rand_bytes(60)
      })

      Webhooks.dispatch("page.published", %{})
      Oban.drain_queue(queue: :webhooks)

      assert [%{last_error: "delivery failed: signing secret unreadable"}] =
               CMS.recent_webhook_deliveries!(authorize?: false)
    end
  end

  test "webhook endpoints are admin-only" do
    editor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "wh-ed-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :editor
      })

    refute CMS.can_create_webhook_endpoint?(editor)
    assert CMS.can_create_webhook_endpoint?(admin())
  end
end
