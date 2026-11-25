defmodule KilnCMSWeb.EditorLiveStaleRowTest do
  @moduledoc """
  The content list acting on a row someone else has trashed or deleted since
  the list loaded (#2781). Row actions and the bulk bar read each record
  again before the write; a miss is a flash and a refreshed list, never a
  crash that remounts the view and drops the selection.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"
  @gone "That content no longer exists. Someone else may have moved it to trash or deleted it."

  defp authed_user(role) do
    email = "staterow-#{System.unique_integer([:positive])}@example.com"

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

  defp page!(admin, title) do
    CMS.create_page!(%{title: title, slug: "staterow-#{System.unique_integer([:positive])}"},
      actor: admin
    )
  end

  defp select(lv, page),
    do: lv |> element(~s(input[phx-value-key="page:#{page.id}"])) |> render_click()

  # The flash text as LiveView renders it (apostrophes escaped).
  defp escaped(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  describe "a row action on a row trashed elsewhere" do
    for verb <- ~w(publish submit return unpublish unarchive confirm_proposed_date) do
      test "#{verb} flashes and refreshes the list instead of crashing", %{conn: conn} do
        admin = authed_user(:admin)
        page = page!(admin, "Stale #{unquote(verb)}")

        {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor")
        assert html =~ "Stale #{unquote(verb)}"

        :ok = CMS.destroy_page(page, actor: admin)

        html = render_click(lv, unquote(verb), %{"kind" => "page", "id" => page.id})

        assert Process.alive?(lv.pid)
        assert html =~ escaped(@gone)
        refute html =~ "Stale #{unquote(verb)}"
      end
    end

    test "an unknown type or a malformed id is the same flash", %{conn: conn} do
      admin = authed_user(:admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")

      for params <- [
            %{"kind" => "nosuchtype", "id" => Ecto.UUID.generate()},
            %{"kind" => "page", "id" => Ecto.UUID.generate()},
            %{"kind" => "page", "id" => "not-a-uuid"}
          ] do
        assert render_click(lv, "publish", params) =~ escaped(@gone)
      end

      assert Process.alive?(lv.pid)
    end
  end

  describe "a bulk action with a selected row trashed elsewhere" do
    test "publishes the rows that remain and counts the missing one", %{conn: conn} do
      admin = authed_user(:admin)
      kept = page!(admin, "Bulk kept")
      other = page!(admin, "Bulk also kept")
      stale = page!(admin, "Bulk stale")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")

      Enum.each([kept, other, stale], &select(lv, &1))

      :ok = CMS.destroy_page(stale, actor: admin)

      lv |> element("button[phx-value-action='publish']") |> render_click()
      html = lv |> element("button[phx-click='confirm_bulk']") |> render_click()

      assert Process.alive?(lv.pid)
      assert html =~ "Publish: 2 updated, 1 no longer exists"
      # Nothing was skipped for a reason the editor could fix.
      refute html =~ "A row is skipped when"

      assert CMS.get_page!(kept.id, authorize?: false).state == :published
      assert CMS.get_page!(other.id, authorize?: false).state == :published
    end

    test "moves the remaining rows to trash and counts the missing ones", %{conn: conn} do
      admin = authed_user(:admin)
      kept = page!(admin, "Delete kept")
      stale = page!(admin, "Delete stale")
      deleted = page!(admin, "Delete gone")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")

      Enum.each([kept, stale, deleted], &select(lv, &1))

      :ok = CMS.destroy_page(stale, actor: admin)
      :ok = CMS.destroy_page(deleted, actor: admin)

      lv |> element("button[phx-value-action='delete']") |> render_click()
      html = lv |> element("button[phx-click='confirm_bulk']") |> render_click()

      assert Process.alive?(lv.pid)
      assert html =~ "Moved 1 item(s) to trash, 2 no longer exist"
      assert Enum.any?(CMS.list_trashed_pages!(actor: admin), &(&1.id == kept.id))
    end
  end
end
