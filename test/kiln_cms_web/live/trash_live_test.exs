defmodule KilnCMSWeb.TrashLiveTest do
  @moduledoc """
  `/editor/trash` — the only UI for restoring a soft-deleted document.

  It had no test at all, which is how Restore came to be broken on this path
  without anyone noticing: `@list_fields` selected a narrow column set for the
  list, and `:org_id` was not in it. Every hook on `:restore` needs it —
  `BustContentCache` reaches it through `Cache.key/5` (raising
  `Protocol.UndefinedError` on `%Ash.NotLoaded{}` inside an `after_action`, so
  the transaction rolled back), and since #1025 `FireArtifacts` puts it in the
  Oban args as well.

  Driven through the real LiveView event rather than by calling the action, so
  the select is exercised — that is the whole bug.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin(role \\ :admin) do
    email = "trash-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "restoring a trashed published page from the trash list works", %{conn: conn} do
    actor = authed_admin()

    page =
      CMS.create_page!(
        %{title: "Trashed", slug: "trash-#{System.unique_integer([:positive])}"},
        actor: actor
      )
      |> then(&CMS.publish_page!(&1, actor: actor))

    KilnCMS.DataCase.drain_oban()
    CMS.destroy_page!(page, actor: actor)
    KilnCMS.DataCase.drain_oban()

    {:ok, lv, html} = conn |> log_in(actor) |> live(~p"/editor/trash")
    assert html =~ "Trashed"

    lv
    |> element(~s(button[phx-click="restore"][phx-value-id="#{page.id}"]))
    |> render_click()

    KilnCMS.DataCase.drain_oban()

    # Back out of the trash, and live again.
    restored = CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)
    refute restored.archived_at
    assert restored.state == :published

    # And #1025: what trashing tore down is rebuilt.
    {:ok, artifacts} =
      KilnCMS.Firing.artifacts_for(:page, page.id, authorize?: false, tenant: page.org_id)

    refute artifacts == [], "restored from the trash UI with no artifacts"
  end

  # R5: a field set to "Don't allow it" keeps a linked record from being
  # deleted for good, and the trash says why in plain words.
  test "a purge refused by a reference field's delete rule is explained", %{conn: conn} do
    actor = authed_admin()
    name = "lead_#{System.unique_integer([:positive])}"

    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: name,
        label: "Lead story",
        field_type: :reference,
        target_type: "page",
        on_target_delete: :restrict
      },
      actor: actor
    )

    page =
      CMS.create_page!(
        %{title: "Linked page", slug: "trash-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    CMS.create_post!(
      %{
        title: "Referrer",
        slug: "trash-#{System.unique_integer([:positive])}",
        custom_fields: %{name => page.id}
      },
      actor: actor
    )

    CMS.destroy_page!(page, actor: actor)

    {:ok, lv, _html} = conn |> log_in(actor) |> live(~p"/editor/trash")

    html =
      lv
      |> element(~s(button[phx-click="purge"][phx-value-id="#{page.id}"]))
      |> render_click()

    assert html =~
             "“Linked page” can&#39;t be deleted for good: 1 record still links to it through “Lead story”"

    assert CMS.list_trashed_pages!(actor: actor) |> Enum.any?(&(&1.id == page.id))
  end

  # #2531: the list was rendered before someone else restored or purged the
  # row. Both actions take only a row still in the trash, so the click is a
  # `StaleRecord`; the page says which of the two happened and drops the row.
  describe "a row someone else already handled" do
    defp trashed_page(actor) do
      page =
        CMS.create_page!(
          %{title: "Contested", slug: "trash-#{System.unique_integer([:positive])}"},
          actor: actor
        )

      :ok = CMS.destroy_page!(page, actor: actor)
      page
    end

    defp held(page, actor),
      do: CMS.list_trashed_pages!(actor: actor) |> Enum.find(&(&1.id == page.id))

    defp click(lv, action, page) do
      lv
      |> element(~s(button[phx-click="#{action}"][phx-value-id="#{page.id}"]))
      |> render_click()
    end

    defp listed?(lv, page), do: has_element?(lv, "#trash-page-#{page.id}")

    test "restore after someone restored it says so and drops the row", %{conn: conn} do
      actor = authed_admin()
      page = trashed_page(actor)
      {:ok, lv, _html} = conn |> log_in(actor) |> live(~p"/editor/trash")

      {:ok, _} = CMS.restore_page(held(page, actor), actor: authed_admin())

      assert click(lv, "restore", page) =~ "Someone else already restored that item."
      refute listed?(lv, page)
    end

    test "purge after someone restored it leaves the page live", %{conn: conn} do
      actor = authed_admin()
      page = trashed_page(actor)
      {:ok, lv, _html} = conn |> log_in(actor) |> live(~p"/editor/trash")

      {:ok, _} = CMS.restore_page(held(page, actor), actor: authed_admin())

      assert click(lv, "purge", page) =~ "Someone else already restored that item."
      refute listed?(lv, page)
      assert %{archived_at: nil} = CMS.get_page!(page.id, actor: actor)
    end

    test "purge after someone purged it says it is gone", %{conn: conn} do
      actor = authed_admin()
      page = trashed_page(actor)
      {:ok, lv, _html} = conn |> log_in(actor) |> live(~p"/editor/trash")

      :ok = CMS.purge_page(held(page, actor), actor: authed_admin())

      assert click(lv, "purge", page) =~
               "That item is no longer in the trash — someone permanently deleted it."

      refute listed?(lv, page)
    end

    test "restore after someone purged it says it is gone", %{conn: conn} do
      actor = authed_admin()
      page = trashed_page(actor)
      {:ok, lv, _html} = conn |> log_in(actor) |> live(~p"/editor/trash")

      :ok = CMS.purge_page(held(page, actor), actor: authed_admin())

      assert click(lv, "restore", page) =~
               "That item is no longer in the trash — someone permanently deleted it."

      refute listed?(lv, page)
    end

    test "empty trash counts a row someone restored mid-walk as neither", %{conn: conn} do
      actor = authed_admin()
      kept = trashed_page(actor)
      gone = trashed_page(actor)
      {:ok, lv, _html} = conn |> log_in(actor) |> live(~p"/editor/trash")

      {:ok, _} = CMS.restore_page(held(kept, actor), actor: authed_admin())

      lv |> element(~s(button[phx-click="request_empty"])) |> render_click()
      html = lv |> element(~s(button[phx-click="confirm_empty"])) |> render_click()

      # The walk reads the trash afresh, so the restored row is not even
      # tried; the guard is what keeps a racing restore from being purged.
      refute html =~ "skipped"
      assert %{archived_at: nil} = CMS.get_page!(kept.id, actor: actor)
      refute Enum.any?(CMS.list_trashed_pages!(actor: actor), &(&1.id == gone.id))
    end
  end

  describe "a failure that is not a race" do
    test "a restore refused by a unique field keeps the generic message and the row",
         %{conn: conn} do
      actor = authed_admin()

      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "sku",
          label: "SKU",
          field_type: :string,
          validation: %{"unique" => true}
        },
        actor: actor
      )

      post =
        CMS.create_post!(
          %{
            title: "First",
            slug: "trash-#{System.unique_integer([:positive])}",
            custom_fields: %{"sku" => "T-1"}
          },
          actor: actor
        )

      :ok = CMS.destroy_post!(post, actor: actor)

      CMS.create_post!(
        %{
          title: "Second",
          slug: "trash-#{System.unique_integer([:positive])}",
          custom_fields: %{"sku" => "T-1"}
        },
        actor: actor
      )

      {:ok, lv, _html} = conn |> log_in(actor) |> live(~p"/editor/trash")

      html =
        lv
        |> element(~s(button[phx-click="restore"][phx-value-id="#{post.id}"]))
        |> render_click()

      assert html =~ "Couldn&#39;t restore that item."
      assert has_element?(lv, "#trash-post-#{post.id}")
    end

    test "a refused actor keeps the generic message and the row", %{conn: conn} do
      # A site admin by membership, not a platform admin, so demoting the
      # membership after mount takes the trash away mid-session.
      actor = authed_admin(:editor)

      {:ok, membership} =
        KilnCMS.Accounts.create_org_membership(
          %{user_id: actor.id, organization_id: KilnCMS.Accounts.default_org_id(), role: :admin},
          authorize?: false
        )

      page = trashed_page(actor)
      {:ok, lv, _html} = conn |> log_in(actor) |> live(~p"/editor/trash")

      {:ok, _} =
        KilnCMS.Accounts.update_org_membership(membership, %{role: :viewer}, authorize?: false)

      assert click(lv, "restore", page) =~ "Couldn&#39;t restore that item."
      assert click(lv, "purge", page) =~ "Couldn&#39;t delete that item."
      assert listed?(lv, page)
    end
  end
end
