defmodule KilnCMSWeb.PublishShowsUnpublishDateTest do
  @moduledoc """
  A draft can carry a takedown date (`unpublish_at`) set in the editor, and
  whoever publishes it approves that date with the page (ADR 0051). Every
  route that publishes without opening the editor shows the date (#2892): the
  content list's row, the bulk Publish confirm and a release's item list.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  @password "password123456"

  defp authed_user(role) do
    email = "unpub-date-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{title: "A page", slug: "unpub-#{System.unique_integer([:positive])}", state: :draft},
        attrs
      )
    )
  end

  defp in_days(days),
    do: DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)

  defp utc(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  describe "the content list row" do
    test "a draft with a takedown date shows it beside its Publish button", %{conn: conn} do
      at = in_days(5)
      draft = page(%{title: "Embargoed draft", unpublish_at: at})
      review = page(%{title: "Embargoed review", state: :in_review, unpublish_at: at})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      assert has_element?(lv, "#page-#{draft.id} button[phx-click=publish]")

      for record <- [draft, review] do
        assert has_element?(
                 lv,
                 "#page-#{record.id} span:has(> #unpublish-page-#{record.id})",
                 "Unpublishes"
               )

        assert has_element?(lv, "#unpublish-page-#{record.id}", utc(at))
      end
    end

    test "the verb follows the expiry action", %{conn: conn} do
      draft = page(%{unpublish_at: in_days(5), expiry_action: :archive})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      assert has_element?(
               lv,
               "#page-#{draft.id} span:has(> #unpublish-page-#{draft.id})",
               "Archives"
             )
    end

    test "a draft without one shows no date", %{conn: conn} do
      draft = page(%{title: "Open-ended draft"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      assert has_element?(lv, "#page-#{draft.id}")
      refute has_element?(lv, "#unpublish-page-#{draft.id}")
    end
  end

  describe "the bulk Publish confirm" do
    test "names the selected drafts that have a takedown date", %{conn: conn} do
      soon = in_days(3)
      later = in_days(9)
      a = page(%{title: "Comes down soon", unpublish_at: later})
      b = page(%{title: "Comes down sooner", state: :in_review, unpublish_at: soon})
      plain = page(%{title: "Stays up"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      for record <- [a, b, plain] do
        render_click(lv, "toggle_select", %{"key" => "page:#{record.id}"})
      end

      render_click(lv, "bulk", %{"action" => "publish"})

      assert has_element?(
               lv,
               "#bulk-confirm-expiring",
               "2 of these have a scheduled unpublish date"
             )

      assert has_element?(lv, "#bulk-expiring-#{a.id}", "Comes down soon")
      assert has_element?(lv, "#bulk-expiring-time-#{a.id}", utc(later))
      assert has_element?(lv, "#bulk-expiring-#{b.id}", "Unpublishes")
      refute has_element?(lv, "#bulk-expiring-#{plain.id}")

      # Soonest first: the order they would come down in.
      html = lv |> element("#bulk-confirm-expiring") |> render()

      assert :binary.match(html, "bulk-expiring-#{b.id}") <
               :binary.match(html, "bulk-expiring-#{a.id}")
    end

    test "says nothing when no selected draft has one", %{conn: conn} do
      plain = page(%{title: "Stays up"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")
      render_click(lv, "toggle_select", %{"key" => "page:#{plain.id}"})
      render_click(lv, "bulk", %{"action" => "publish"})

      assert has_element?(lv, "#bulk-confirm")
      refute has_element?(lv, "#bulk-confirm-expiring")
    end

    test "a selection kept from off screen is still checked", %{conn: conn} do
      draft = page(%{title: "Filtered away", unpublish_at: in_days(4)})
      page(%{title: "Still listed", state: :in_review})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")
      render_click(lv, "toggle_select", %{"key" => "page:#{draft.id}"})

      # Filter the row off the page; the selection survives a filter change.
      render_patch(lv, ~p"/editor?status=in_review")
      refute has_element?(lv, "#page-#{draft.id}")

      render_click(lv, "bulk", %{"action" => "publish"})
      assert has_element?(lv, "#bulk-expiring-#{draft.id}", "Filtered away")
    end
  end

  describe "a release" do
    test "lists a draft's takedown date on its item and totals them", %{conn: conn} do
      admin = authed_user(:admin)
      at = in_days(6)
      rel = CMS.create_release!(%{name: "Launch"}, actor: admin)
      dated = page(%{title: "Dated", unpublish_at: at})
      plain = page(%{title: "Undated"})

      items =
        for record <- [dated, plain] do
          CMS.add_release_item!(
            %{release_id: rel.id, content_type: "page", content_id: record.id},
            actor: admin
          )
        end

      [dated_item, plain_item] = items

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/releases/#{rel.id}")

      assert has_element?(lv, "#release-item-expiry-#{dated_item.id}", "Unpublishes")
      assert has_element?(lv, "#release-item-expiry-time-#{dated_item.id}", utc(at))
      refute has_element?(lv, "#release-item-expiry-#{plain_item.id}")

      assert has_element?(
               lv,
               "#release-expiring",
               "1 draft in this release has a scheduled unpublish date"
             )
    end

    test "says nothing when no item has one", %{conn: conn} do
      admin = authed_user(:admin)
      rel = CMS.create_release!(%{name: "Launch"}, actor: admin)
      plain = page(%{title: "Undated"})

      item =
        CMS.add_release_item!(
          %{release_id: rel.id, content_type: "page", content_id: plain.id},
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/releases/#{rel.id}")

      refute has_element?(lv, "#release-item-expiry-#{item.id}")
      refute has_element?(lv, "#release-expiring")
    end
  end
end
