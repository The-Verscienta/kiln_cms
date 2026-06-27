defmodule KilnCMSWeb.MediaLiveTest do
  @moduledoc false
  # async: false — the upload test points Storage.Local at a temp dir via the
  # global app env.
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  # A minimal valid 1x1 PNG.
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
         6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 250, 207, 0, 0,
         0, 7, 0, 1, 2, 254, 165, 53, 230, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

  @password "password123456"

  # Seed a user and sign in so the returned struct carries the token metadata
  # that `store_in_session/2` needs (token presence is required).
  defp authed_user(role) do
    email = "media-#{System.unique_integer([:positive])}@example.com"

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

  describe "authorization" do
    test "anonymous users are redirected to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/media")
    end

    test "viewers are redirected away", %{conn: conn} do
      conn = log_in(conn, authed_user(:viewer))
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/media")
    end

    test "editors can load the media library", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))
      {:ok, _lv, html} = live(conn, ~p"/media")
      assert html =~ "Media library"
    end
  end

  describe "library filter" do
    defp seed_media(filename) do
      Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
        filename: filename,
        url: "/uploads/#{System.unique_integer([:positive])}"
      })
    end

    test "filters the library by filename", %{conn: conn} do
      seed_media("sunset.png")
      seed_media("logo.svg")
      {:ok, lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      # Match the filename text node (the navbar also references logo.svg).
      assert html =~ ">sunset.png<"
      assert html =~ ">logo.svg<"

      filtered = lv |> form("#media-filter", %{q: "sunset"}) |> render_change()

      assert filtered =~ ">sunset.png<"
      refute filtered =~ ">logo.svg<"
    end

    # #160: the delete button isn't hover-only — visible on touch and on focus.
    test "the delete button is visible without hover", %{conn: conn} do
      seed_media("touchable.png")
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      [_, delete_class] =
        Regex.run(~r/phx-click="delete"[^>]*class="([^"]+)"/s, html) ||
          Regex.run(~r/class="([^"]+)"[^>]*phx-click="delete"/s, html)

      assert delete_class =~ "opacity-100"
      assert delete_class =~ "focus:opacity-100"
    end
  end

  describe "detail panel" do
    test "opens a panel with metadata and saves alt text + caption", %{conn: conn} do
      item =
        Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
          filename: "photo.png",
          url: "/uploads/photo",
          content_type: "image/png",
          byte_size: 2048,
          width: 1200,
          height: 800,
          variants: %{
            "thumb" => %{"key" => "k", "url" => "/uploads/thumb", "width" => 400, "height" => 267}
          }
        })

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      panel = lv |> element(~s(img[phx-value-id="#{item.id}"])) |> render_click()
      assert panel =~ "Alt text"
      assert panel =~ "2.0 KB"
      assert panel =~ "image/png"
      # Dimensions + responsive variants are surfaced.
      assert panel =~ "1200"
      assert panel =~ "Responsive variants"
      assert panel =~ "thumb"

      lv
      |> form("form[phx-submit=save_meta]", %{alt: "A nice photo", caption: "At dusk"})
      |> render_submit()

      saved = CMS.get_media_item!(item.id, authorize?: false)
      assert saved.alt == "A nice photo"
      assert saved.caption == "At dusk"
    end

    # Regression for #169: the drawer is a labeled modal dialog with a focus trap.
    test "the detail drawer exposes dialog semantics and a focus trap", %{conn: conn} do
      item = Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{filename: "dlg.png", url: "/uploads/dlg"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      panel = lv |> element(~s(img[phx-value-id="#{item.id}"])) |> render_click()

      assert panel =~ ~s(role="dialog")
      assert panel =~ ~s(aria-modal="true")
      assert panel =~ ~s(aria-labelledby="media-detail-title")
      assert panel =~ ~s(id="media-detail-title")
      assert panel =~ ~s(phx-hook="FocusTrap")
    end
  end

  describe "trash" do
    test "admin can soft-delete from the library, then restore from trash", %{conn: conn} do
      item = seed_media("doomed.png")
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/media")

      # Soft-delete: the item leaves the library but the row survives.
      lv |> element(~s(button[phx-value-id="#{item.id}"][phx-click="delete"])) |> render_click()
      refute render(lv) =~ ">doomed.png<"
      assert CMS.list_trashed_media_items!(authorize?: false) |> Enum.any?(&(&1.id == item.id))

      # Trash view lists it; restoring returns it to the library.
      trash = lv |> element("button", "Trash") |> render_click()
      assert trash =~ ">doomed.png<"

      lv |> element(~s(button[phx-value-id="#{item.id}"][phx-click="restore"])) |> render_click()
      assert CMS.get_media_item!(item.id, authorize?: false)
      refute CMS.list_trashed_media_items!(authorize?: false) |> Enum.any?(&(&1.id == item.id))
    end

    test "purge permanently removes a trashed item", %{conn: conn} do
      item = seed_media("gone.png")
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/media")

      lv |> element(~s(button[phx-value-id="#{item.id}"][phx-click="delete"])) |> render_click()
      lv |> element("button", "Trash") |> render_click()
      lv |> element(~s(button[phx-value-id="#{item.id}"][phx-click="purge"])) |> render_click()

      assert {:error, _} = CMS.get_media_item(item.id, authorize?: false)
    end

    test "non-admins don't see the trash toggle", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")
      refute html =~ ~s(phx-click="show_trash")
    end
  end

  describe "live refresh" do
    test "the library refreshes when a variant job broadcasts completion", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/media")

      # An item created after mount isn't shown until a refresh.
      item = seed_media("late-arrival.png")
      refute render(lv) =~ ">late-arrival.png<"

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        KilnCMS.Media.VariantWorker.topic(),
        {:media_processed, item.id}
      )

      assert render(lv) =~ ">late-arrival.png<"
    end
  end

  describe "upload" do
    setup do
      root = Path.join(System.tmp_dir!(), "kiln_media_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      Application.put_env(:kiln_cms, KilnCMS.Storage.Local, root: root, base_url: "/uploads")

      on_exit(fn ->
        File.rm_rf!(root)
        Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
      end)

      %{root: root}
    end

    test "rejects a file whose content is not a real image", %{conn: conn, root: root} do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "fake.png", content: "not-a-png", type: "image/png"}
        ])

      assert render_upload(input, "fake.png")

      html = lv |> element("#upload-form") |> render_submit()
      assert html =~ "failed"
      refute Enum.any?(CMS.list_media_items!(actor: editor))
      refute File.exists?(Path.join(root, "fake.png"))
    end

    test "uploading an image stores it and adds it to the library", %{conn: conn, root: root} do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/media")

      input =
        file_input(lv, "#upload-form", :media, [
          %{name: "pixel.png", content: @png, type: "image/png"}
        ])

      assert render_upload(input, "pixel.png")

      html = lv |> element("#upload-form") |> render_submit()
      assert html =~ "pixel.png"

      assert [item] = CMS.list_media_items!(actor: editor)
      assert item.filename == "pixel.png"
      assert item.content_type == "image/png"
      assert File.exists?(Path.join(root, item.storage_key))

      # Dimensions are filled in asynchronously by the variant worker (the 1x1
      # pixel is too small for any responsive variant, so none are produced).
      KilnCMS.DataCase.drain_oban()
      processed = CMS.get_media_item!(item.id, actor: editor)
      assert processed.width == 1
      assert processed.height == 1
    end
  end
end
