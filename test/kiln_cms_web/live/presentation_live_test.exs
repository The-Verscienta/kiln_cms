defmodule KilnCMSWeb.PresentationLiveTest do
  @moduledoc """
  Presentation console (#355): editor gating, click-to-edit panel (driven by the
  bridge's postMessage payload), and Save writing through the shared engine +
  broadcasting to the /ws/bridge preview topic.
  """
  # async: false — sets the global :presentation_preview_url config.
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.CMS
  alias KilnCMSWeb.PreviewLive

  @password "password123456"

  setup do
    Application.put_env(
      :kiln_cms,
      :presentation_preview_url,
      "https://front.test{path}?kilnPreview=1"
    )

    on_exit(fn -> Application.delete_env(:kiln_cms, :presentation_preview_url) end)
    :ok
  end

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pl-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp log_in(conn, user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => user.email,
        "password" => @password
      })

    token = signed_in.__metadata__.token

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp post_with_heading(admin) do
    CMS.create_post!(
      %{
        title: "Live post",
        slug: "pl-#{System.unique_integer([:positive])}",
        block_tree: [%{"type" => "heading", "content" => "Original heading", "order" => 1}]
      },
      actor: admin
    )
  end

  defp heading_block_id(post) do
    post.blocks |> hd() |> Map.get(:value) |> Map.get(:id)
  end

  test "redirects a non-editor away", %{conn: conn} do
    admin = user(:admin)
    post = post_with_heading(admin)
    viewer = user(:viewer)

    assert {:error, {:redirect, %{to: to}}} =
             conn |> log_in(viewer) |> live(~p"/editor/presentation/post/#{post.slug}")

    assert to in ["/", "/sign-in"]
  end

  test "renders the framed front end at the configured preview URL", %{conn: conn} do
    admin = user(:admin)
    post = post_with_heading(admin)

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/presentation/post/#{post.slug}")

    assert html =~ "presentation-frame"
    assert html =~ "https://front.test"
    assert html =~ "data-frontend-origin=\"https://front.test\""
    assert html =~ "Click a highlighted region"
  end

  test "shows a setup hint when no preview URL is configured", %{conn: conn} do
    Application.delete_env(:kiln_cms, :presentation_preview_url)
    admin = user(:admin)
    post = post_with_heading(admin)

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/presentation/post/#{post.slug}")
    assert html =~ "No preview URL configured"
    refute html =~ "id=\"presentation-frame\""
  end

  test "edit_field opens the clicked block, and Save persists + broadcasts", %{conn: conn} do
    admin = user(:admin)
    post = post_with_heading(admin)
    block_id = heading_block_id(post)

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/presentation/post/#{post.slug}")

    # The bridge relays a click as an edit_field with the stega payload.
    html =
      lv
      |> render_hook("edit_field", %{
        "type" => "post",
        "id" => post.id,
        "block" => block_id,
        "field" => "text"
      })

    # The edit panel opened for the heading block (its value + a Save button).
    assert html =~ "Original heading"
    assert html =~ ~s(data-kiln-block-id="#{block_id}")
    assert html =~ ~s(phx-click="save")

    # Subscribe to the preview topic the /ws/bridge socket listens on.
    Phoenix.PubSub.subscribe(KilnCMS.PubSub, PreviewLive.topic(:post, post.id))

    # Edit the region and save.
    render_hook(lv, "update_block", %{"id" => block_id, "value" => "Edited via console"})
    render_hook(lv, "save", %{})

    # Persisted…
    updated = CMS.get_post!(post.id, actor: admin)
    assert updated.blocks |> hd() |> Map.get(:value) |> Map.get(:text) == "Edited via console"

    # …and broadcast so the iframe refreshes.
    assert_receive {:preview_update, %{title: "Live post"}}
  end

  test "clicking the document title opens a scalar editor and Save persists it", %{conn: conn} do
    admin = user(:admin)
    post = post_with_heading(admin)

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/presentation/post/#{post.slug}")

    # A title click has no `block` in the payload.
    html = render_hook(lv, "edit_field", %{"type" => "post", "id" => post.id, "field" => "title"})
    assert html =~ ~s(name="value")
    assert html =~ "Live post"

    render_hook(lv, "update_scalar", %{"field" => "title", "value" => "Retitled via console"})
    render_hook(lv, "save", %{})

    assert CMS.get_post!(post.id, actor: admin).title == "Retitled via console"
  end

  test "an unknown scalar field still offers the full editor", %{conn: conn} do
    admin = user(:admin)
    post = post_with_heading(admin)

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/presentation/post/#{post.slug}")

    html =
      render_hook(lv, "edit_field", %{"type" => "post", "id" => post.id, "field" => "seo_image"})

    assert html =~ "inline-editable"
    assert html =~ "Open the full editor"
  end
end
