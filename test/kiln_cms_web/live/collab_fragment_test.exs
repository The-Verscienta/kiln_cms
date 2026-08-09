defmodule KilnCMSWeb.CollabFragmentTest do
  @moduledoc """
  Collab Yjs fragments are keyed by **stable block ids** — a reorder must not
  re-key any block's fragment (index keys would swap two blocks' text across
  sessions), and only pre-id legacy blocks fall back to positional keys.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  # The other victim of the same leak (#1067, PR #1090): with
  # `:collab_prototype` off the editor renders no `collab_token`, so
  # `data-collab-fragment` is simply absent and every assertion here fails
  # describing a fragment-keying bug that is not there. The flag is VM-global,
  # so an `async: true` neighbour flipping it is all it takes — see the fuller
  # note in `KilnCMSWeb.CollabPersisterTest`.
  setup do
    assert KilnCMS.Collab.Crdt.enabled?(),
           ":collab_prototype is off — a concurrent async test flipped this " <>
             "VM-global flag, and every assertion in this file is downstream of " <>
             "it. See KilnCMSWeb.CollabPersisterTest's setup (#1067)."

    :ok
  end

  defp authed_user do
    email = "cf-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
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

  test "fragment keys are block ids and survive reordering", %{conn: conn} do
    editor = authed_user()

    page =
      CMS.create_page!(
        %{
          title: "Frag",
          slug: "frag-#{System.unique_integer([:positive])}",
          blocks: [
            %{"_type" => "rich_text", "legacy_html" => "<p>first</p>"},
            %{"_type" => "rich_text", "legacy_html" => "<p>second</p>"}
          ]
        },
        actor: editor
      )

    [id_a, id_b] =
      CMS.get_page!(page.id, actor: editor).blocks |> Enum.map(& &1.value.id)

    {:ok, lv, html} = conn |> log_in(editor) |> live(~p"/editor/pages/#{page.id}")

    assert html =~ ~s(data-collab-fragment="block-#{id_a}")
    assert html =~ ~s(data-collab-fragment="block-#{id_b}")
    refute html =~ "block-idx-"

    # Reordering must not re-key either fragment (blocks move by stable id now).
    html = render_click(lv, "move_block", %{"bid" => id_a, "dir" => "down"})

    assert html =~ ~s(data-collab-fragment="block-#{id_a}")
    assert html =~ ~s(data-collab-fragment="block-#{id_b}")
    refute html =~ "block-idx-"
  end
end
