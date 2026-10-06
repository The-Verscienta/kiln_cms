defmodule KilnCMSWeb.OrganizeLiveTest do
  @moduledoc "The derived-organization console page, `/editor/organize` (#1596)."
  # async: false — swaps the global KilnCMS.Search env.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import KilnCMS.OrganizeFixtures, except: [user!: 1, user!: 2]

  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "organize-lv-#{uniq()}@example.com"

    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

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

  defp org, do: KilnCMS.Accounts.default_org()

  defp open(conn, user, tab \\ "clusters") do
    {:ok, view, _html} = conn |> log_in(user) |> live(~p"/editor/organize?#{%{tab: tab}}")
    render_async(view)
    view
  end

  describe "semantic search off (the default)" do
    test "one quiet line, no tabs, and no nav item", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, view, html} = conn |> log_in(admin) |> live(~p"/editor/organize")

      assert has_element?(view, "#organize-off")
      refute has_element?(view, "#organize-tab-clusters")
      refute html =~ ~s(href="/editor/organize")
    end
  end

  describe "semantic search on" do
    setup do
      semantic_on!()
      :ok
    end

    test "the nav links the page, and the clusters tab renders groups", %{conn: conn} do
      admin = authed_user(:admin)
      post!(org(), admin, "cluster passage one", title: "Cluster One")
      post!(org(), admin, "cluster passage two", title: "Cluster Two")

      {:ok, view, html} = conn |> log_in(admin) |> live(~p"/editor/organize")
      assert html =~ ~s(href="/editor/organize")
      assert render_async(view) =~ "Cluster One"
      assert has_element?(view, "#organize-clusters article")
    end

    test "a viewer is turned away", %{conn: conn} do
      viewer = authed_user(:viewer)
      assert {:error, {_kind, _}} = conn |> log_in(viewer) |> live(~p"/editor/organize")
    end

    test "tag review: index, propose, apply only what was proposed", %{conn: conn} do
      admin = authed_user(:admin)
      tag = tag!(org(), admin, "review tag #{uniq()}")
      stranger = tag!(org!(), admin, "other org tag #{uniq()}")
      draft = post!(org(), admin, "review passage #{uniq()}", title: "Review me", publish?: false)

      view = open(conn, admin, "tagging")

      # The tag index first: Propose is not offered until it is complete.
      assert has_element?(view, "#index-tags")
      refute has_element?(view, "#propose")
      view |> element("#index-tags") |> render_click()
      render_async(view)
      assert has_element?(view, "#propose")

      view |> element("#propose") |> render_click()
      assert render_async(view) =~ "Review me"
      assert has_element?(view, "#apply-#{draft.id}")

      # A forged id rides along with the real one; only the proposed one lands.
      render_submit(view, "apply", %{"row" => draft.id, "tag_ids" => [tag.id, stranger.id]})

      tags = CMS.get_post!(draft.id, actor: admin, load: [:tags]).tags
      assert Enum.map(tags, & &1.id) == [tag.id]
      assert render(view) =~ "Applied"
    end

    test "the other tabs render", %{conn: conn} do
      admin = authed_user(:admin)
      post!(org(), admin, "untagged passage #{uniq()}", title: "Bare document", publish?: false)

      queue = open(conn, admin, "queue")
      assert has_element?(queue, "#organize-queue")
      assert render(queue) =~ "Bare document"

      assert has_element?(open(conn, admin, "health"), "#organize-health")
      assert has_element?(open(conn, admin, "gaps"), "#organize-gaps")
    end

    test "malformed payloads are ignored, not crashed", %{conn: conn} do
      admin = authed_user(:admin)
      view = open(conn, admin, "tagging")

      render_submit(view, "apply", %{"row" => ["not", "a", "string"]})
      render_submit(view, "apply", %{"row" => Ecto.UUID.generate(), "tag_ids" => %{"a" => 1}})
      render_change(view, "filter", %{"filter" => "nope"})
      render_change(view, "filter", %{"filter" => %{"state" => "deleted", "type" => ["x"]}})
      render_click(view, "continue", %{})
      render_click(view, "propose", %{"x" => 1})

      assert Process.alive?(view.pid)
      assert has_element?(view, "#organize-tagging")
    end
  end
end
