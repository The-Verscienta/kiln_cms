defmodule KilnCMSWeb.FormBuilderEmbedWarningTest do
  @moduledoc """
  The form builder's Embed-tab warning for the closed framing default (#562).

  The suite-wide `:embed_origins` allowlist in `config/test.exs` means the
  warning branch never renders in `KilnCMSWeb.FormBuilderLiveTest` — which is
  exactly the production configuration it exists for. Cleared here instead, in
  an `async: false` module because `Application.delete_env/2` is global.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  setup do
    previous = Application.get_env(:kiln_cms, :embed_origins)
    Application.delete_env(:kiln_cms, :embed_origins)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:kiln_cms, :embed_origins)
        value -> Application.put_env(:kiln_cms, :embed_origins, value)
      end
    end)

    :ok
  end

  # Same shape as KilnCMSWeb.FormBuilderLiveTest: seed, then sign in for real so
  # the session carries a usable token.
  defp admin do
    email = "fbw-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
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

  test "the embed tab warns that cross-site embedding is off", %{conn: conn} do
    user = admin()

    form =
      CMS.create_form!(
        %{name: "Contact", slug: "fbw-#{System.unique_integer([:positive])}"},
        actor: user
      )

    {:ok, lv, _html} =
      conn
      |> log_in(user)
      |> live(~p"/editor/forms/#{form.id}")

    html = lv |> element(~s(nav button[phx-value-tab="embed"])) |> render_click()

    assert html =~ "Cross-site embedding is off"
    assert html =~ "EMBED_ORIGINS"
    # No allowlist to show when embedding is closed.
    refute html =~ "Sites allowed to embed"
  end
end
