defmodule KilnCMSWeb.ContentEditorProvenanceTest do
  @moduledoc """
  The editor shows where a draft came from when a service created it with a
  drafts-only API key (#2273), and shows nothing for a person's draft.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "editor-prov-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "ep-#{System.unique_integer([:positive])}"

  test "a token draft shows its key and the service's label", %{conn: conn} do
    editor = authed_user(:editor)

    post =
      Ash.Seed.seed!(CMS.Post, %{
        title: "Via key",
        slug: slug(),
        created_via_key_name: "verscienta-svc",
        on_behalf_of: "<b>user-7</b>"
      })

    {:ok, _view, html} = live(log_in(conn, editor), "/editor/content/post/#{post.id}")

    assert html =~ "draft-write-provenance"
    assert html =~ "verscienta-svc"
    # Escaped, never rendered as markup.
    assert html =~ "&lt;b&gt;user-7&lt;/b&gt;"
  end

  test "a person's draft shows no provenance", %{conn: conn} do
    editor = authed_user(:editor)
    post = CMS.create_post!(%{title: "Human", slug: slug()}, actor: editor)

    {:ok, _view, html} = live(log_in(conn, editor), "/editor/content/post/#{post.id}")
    refute html =~ "draft-write-provenance"
  end
end
