defmodule KilnCMS.WebhooksTest do
  @moduledoc """
  Publishing content dispatches signed webhook deliveries (via Oban) to active,
  subscribed endpoints.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
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
    assert headers["x-kilncms-signature"] == Webhooks.signature(endpoint.secret, body)

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

    refute_received {:delivered, _, _, _, _}
  end

  test "archiving a draft (never published) document dispatches nothing" do
    stub_capture()
    admin = admin()
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    page = CMS.create_page!(%{title: "Never live", slug: slug()}, actor: admin)
    CMS.archive_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    # A draft was never delivered, so archiving it must stay as silent as
    # unpublishing would have been — this is what `only_when: :was_published`
    # (rather than the generic `:published`, which checks the resulting
    # state — always `:archived` here, so it would never gate anything) is
    # for.
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
