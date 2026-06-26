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

    for verb <- ~w(published unpublished updated) do
      assert "page.#{verb}" in events
      assert "post.#{verb}" in events
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
