defmodule KilnCMSWeb.OverviewProvenanceWarningTest do
  @moduledoc """
  The overview's "served unsigned" strip (#1929): provenance is on but no
  signing key resolves. Its own file and `async: false`, because it flips the
  VM-global provenance config.
  """
  use KilnCMSWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Provenance

  @password "password123456"

  setup do
    prev = Application.get_env(:kiln_cms, Provenance)

    Application.put_env(:kiln_cms, Provenance,
      enabled: true,
      signing_key: {:env, %{"var" => "KILN_TEST_UNSET_#{System.unique_integer([:positive])}"}}
    )

    Provenance.forget_stored_key()

    on_exit(fn ->
      Application.put_env(:kiln_cms, Provenance, prev)
      Provenance.forget_stored_key()
    end)

    :ok
  end

  defp log_in(conn, role) do
    email = "ov-prov-#{System.unique_integer([:positive])}@example.com"

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

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "a platform admin is told content is unsigned, and can generate a key", %{conn: conn} do
    {:ok, view, html} = conn |> log_in(:admin) |> live(~p"/editor/overview")

    assert html =~ "served unsigned"
    assert html =~ "KILN_PROVENANCE_KEY_FILE"

    html = view |> element("#overview-provenance-generate") |> render_click()

    assert html =~ "Signing key generated"
    refute has_element?(view, "#overview-provenance-warning")
    assert Provenance.key_available?()
  end

  test "an editor sees nothing: the key is not theirs to set", %{conn: conn} do
    {:ok, _view, html} = conn |> log_in(:editor) |> live(~p"/editor/overview")
    refute html =~ "served unsigned"
  end

  test "absent when provenance is switched off", %{conn: conn} do
    cfg = Application.get_env(:kiln_cms, Provenance)
    Application.put_env(:kiln_cms, Provenance, Keyword.put(cfg, :enabled, false))

    {:ok, _view, html} = conn |> log_in(:admin) |> live(~p"/editor/overview")
    refute html =~ "served unsigned"
  end
end
