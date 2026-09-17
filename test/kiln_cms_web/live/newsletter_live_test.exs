defmodule KilnCMSWeb.NewsletterLiveTest do
  @moduledoc """
  The newsletter console (`/editor/newsletter`) — the segment and subscriber
  half of it (#337 Phase 1).

  `newsletter_send_test.exs` covers the send gate and
  `actorless_handler_authz_test.exs` covers the refusals, both by calling
  `handle_event/3` directly. Nothing drove the page itself, so six of its eight
  events had never run: every one of them writes or deletes a row, and a
  subscriber list is the one screen here where a wrong row is somebody's inbox.

  These go through the rendered page — `render_submit`/`render_click` on the
  real form ids and buttons — because half of what is being asserted is that
  the event a button pushes is the event the module handles.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Newsletter
  alias KilnCMS.Newsletter.Segment
  alias KilnCMS.Newsletter.Subscriber

  @password "password123456"

  setup %{conn: conn} do
    admin = authed_user(:admin)

    %{
      conn: log_in(conn, admin),
      actor: admin,
      org: KilnCMS.Accounts.default_org_id()
    }
  end

  defp authed_user(role) do
    email = "newsletter-live-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp segments(ctx), do: Newsletter.list_segments!(actor: ctx.actor, tenant: ctx.org)

  # `email` is an `Ash.CiString`, so compare it as a plain string.
  defp subscribers(ctx) do
    Subscriber
    |> Ash.read!(actor: ctx.actor, tenant: ctx.org)
    |> Enum.map(&%{id: &1.id, email: to_string(&1.email), status: &1.status})
    |> Enum.sort_by(& &1.email)
  end

  defp subscriber!(ctx, email, attrs \\ %{}) do
    Subscriber
    |> Ash.Changeset.for_create(:subscribe, Map.merge(%{email: email}, attrs))
    |> Ash.create!(actor: ctx.actor, tenant: ctx.org)
  end

  describe "segments" do
    test "a submitted segment is created and listed", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")

      html =
        view
        |> form("#segment-form", segment: %{name: "Weekly readers", slug: "weekly"})
        |> render_submit()

      assert html =~ "Segment created."
      assert html =~ "Weekly readers"
      assert [%Segment{name: "Weekly readers", slug: "weekly"}] = segments(ctx)
    end

    test "a segment with no name is refused, and nothing is written", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")

      html =
        view
        |> form("#segment-form", segment: %{name: "", slug: ""})
        |> render_submit()

      refute html =~ "Segment created."
      assert segments(ctx) == []
    end

    test "a second segment on the same slug is refused, keeping the first", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")
      form = fn -> form(view, "#segment-form", segment: %{name: "Readers", slug: "readers"}) end

      render_submit(form.())
      html = render_submit(form.())

      # Uniqueness is the database's, so it is reported on submit — the change
      # event does not know about it.
      assert html =~ "has already been taken"
      assert [%Segment{name: "Readers"}] = segments(ctx)
    end

    test "delete removes the segment", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")
      view |> form("#segment-form", segment: %{name: "Gone", slug: "gone"}) |> render_submit()
      [segment] = segments(ctx)

      html = view |> element("button[phx-value-id='#{segment.id}']") |> render_click()

      assert html =~ "Segment deleted."
      assert segments(ctx) == []
    end

    test "deleting a segment that is already gone says so, and does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")

      html = render_click(view, "delete_segment", %{"id" => Ecto.UUID.generate()})

      assert html =~ "Couldn&#39;t delete that segment."
    end
  end

  describe "subscribers" do
    test "an added subscriber starts pending, not confirmed", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")

      html =
        view
        |> form("#subscriber-form", subscriber: %{email: "reader@example.com", name: "Reader"})
        |> render_submit()

      assert html =~ "Subscriber added (pending confirmation)."
      assert [%{email: "reader@example.com", status: :pending}] = subscribers(ctx)
      # The heading counts confirmed subscribers, and this one is not one.
      assert html =~ "(0 confirmed)"
    end

    test "an invalid address is refused, and nothing is written", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")

      html =
        view
        |> form("#subscriber-form", subscriber: %{email: "not-an-address", name: ""})
        |> render_submit()

      refute html =~ "Subscriber added"
      assert subscribers(ctx) == []
    end

    test "confirm moves a pending subscriber to confirmed", %{conn: conn} = ctx do
      subscriber = subscriber!(ctx, "pending@example.com")
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")

      html =
        view
        |> element("button[phx-click='confirm_subscriber'][phx-value-id='#{subscriber.id}']")
        |> render_click()

      assert html =~ "Subscriber confirmed."
      assert [%{status: :confirmed}] = subscribers(ctx)
      assert html =~ "(1 confirmed)"
    end

    test "remove deletes the subscriber", %{conn: conn} = ctx do
      subscriber = subscriber!(ctx, "leaving@example.com")
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")

      html =
        view
        |> element("button[phx-click='remove_subscriber'][phx-value-id='#{subscriber.id}']")
        |> render_click()

      assert html =~ "Subscriber removed."
      assert subscribers(ctx) == []
    end

    test "an id that is not a subscriber here is refused, not obeyed", %{conn: conn} = ctx do
      subscriber = subscriber!(ctx, "kept@example.com")
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")

      # A forged event, of the shape the buttons push. It must not remove the
      # subscriber that does exist, and must not crash the page.
      html = render_click(view, "remove_subscriber", %{"id" => Ecto.UUID.generate()})

      assert html =~ "Couldn&#39;t remove that subscriber."
      assert [%{id: id}] = subscribers(ctx)
      assert id == subscriber.id
    end

    test "confirming an id that is not a subscriber here is refused", %{conn: conn} = ctx do
      subscriber!(ctx, "still-pending@example.com")
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")

      html = render_click(view, "confirm_subscriber", %{"id" => Ecto.UUID.generate()})

      assert html =~ "Couldn&#39;t confirm that subscriber."
      assert [%{status: :pending}] = subscribers(ctx)
    end

    test "only the confirmed ones are counted in the heading", %{conn: conn} = ctx do
      subscriber!(ctx, "one@example.com")
      two = subscriber!(ctx, "two@example.com")
      Newsletter.confirm_subscriber!(two, actor: ctx.actor, tenant: ctx.org)

      {:ok, _view, html} = live(conn, ~p"/editor/newsletter")

      assert html =~ "(1 confirmed)"
    end
  end

  describe "sending from the page" do
    # `newsletter_send_test.exs` calls `handle_event("send", …)` directly, so
    # the form that pushes it, and the campaign table that shows the result,
    # had never rendered.

    # Published AND fired: `send_as_newsletter/2` mails the frozen `:web`
    # artifact, so without the drain the send is refused `:not_fired`.
    defp fired_post(ctx) do
      n = System.unique_integer([:positive])

      post =
        %{title: "Dispatch #{n}", slug: "nl-live-#{n}"}
        |> KilnCMS.CMS.create_post!(actor: ctx.actor, tenant: ctx.org)
        |> KilnCMS.CMS.publish_post!(%{}, actor: ctx.actor, tenant: ctx.org)

      KilnCMS.DataCase.drain_oban()
      post
    end

    test "with no campaigns the page says so", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/editor/newsletter")

      assert html =~ "No campaigns yet."
      assert html =~ "No published, public posts available to send."
    end

    test "a sent campaign is queued and appears in the history", %{conn: conn} = ctx do
      post = fired_post(ctx)
      {:ok, view, html} = live(conn, ~p"/editor/newsletter")
      # The post is offered, so the choice the operator makes is a real one.
      assert html =~ post.title

      html =
        view
        |> form("form[phx-submit='send']",
          send: %{post_id: post.id, segment_id: "", subject: "This week"}
        )
        |> render_submit()

      assert html =~ "Newsletter queued for delivery."
      # The campaign table, not just the flash: subject, segment and counters.
      assert html =~ "This week"
      assert html =~ "All"
      refute html =~ "No campaigns yet."

      assert [%{content_id: content_id}] =
               Ash.read!(KilnCMS.Newsletter.NewsletterSend, actor: ctx.actor, tenant: ctx.org)

      assert content_id == post.id
    end

    test "only published posts are offered to send", %{conn: conn} = ctx do
      published = fired_post(ctx)

      draft =
        KilnCMS.CMS.create_post!(%{title: "Still drafting", slug: "nl-draft"},
          actor: ctx.actor,
          tenant: ctx.org
        )

      {:ok, _view, html} = live(conn, ~p"/editor/newsletter")

      assert html =~ published.title
      # A draft in the picker is an unsendable choice — and worse, one an
      # operator would read as "this is ready to go out".
      refute html =~ draft.title
    end

    test "a manual re-send is allowed, and makes a second campaign", %{conn: conn} = ctx do
      post = fired_post(ctx)
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")

      send_it = fn ->
        view
        |> form("form[phx-submit='send']", send: %{post_id: post.id, segment_id: "", subject: ""})
        |> render_submit()
      end

      assert send_it.() =~ "Newsletter queued for delivery."
      assert send_it.() =~ "Newsletter queued for delivery."

      # The `:already_sent` dedupe is the automation identity's
      # ({rule, content, publish revision}); a person pressing Send twice is
      # taken at their word. Pinned because the opposite is the natural guess,
      # and the difference is two copies in every subscriber's inbox.
      assert [_first, _second] =
               Ash.read!(KilnCMS.Newsletter.NewsletterSend, actor: ctx.actor, tenant: ctx.org)
    end

    test "submitting with no post chosen asks for one, and records nothing",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")

      html =
        view
        |> render_submit("send", %{
          "send" => %{"post_id" => "", "segment_id" => "", "subject" => ""}
        })

      assert html =~ "Choose a published post to send."
      assert Ash.read!(KilnCMS.Newsletter.NewsletterSend, actor: ctx.actor, tenant: ctx.org) == []
    end
  end

  describe "validation as you type" do
    test "a missing name is reported on change, and nothing is written", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")

      html =
        view
        |> form("#segment-form", segment: %{name: "", slug: "readers"})
        |> render_change()

      assert html =~ "is required"
      # Changing the form must not write: only the submit does.
      assert segments(ctx) == []
    end

    test "a bad subscriber address is reported on change, and nothing is written",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/editor/newsletter")

      html =
        view
        |> form("#subscriber-form", subscriber: %{email: "nope", name: ""})
        |> render_change()

      assert html =~ "is not a valid email address"
      assert subscribers(ctx) == []
    end
  end
end
