defmodule KilnCMSWeb.AuthControllerTest do
  @moduledoc """
  The AshAuthentication success/failure callbacks set user-facing flash messages.
  Regression for #143: those messages are gettext-wrapped, so they honour the
  session locale instead of always rendering English.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts.User
  alias KilnCMSWeb.AuthController

  setup do
    # Reset the per-process locale after each test so it can't leak between the
    # shared-sandbox async tests.
    on_exit(fn -> Gettext.put_locale(KilnCMSWeb.Gettext, "en") end)
    :ok
  end

  defp flash_conn do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash([])
  end

  defp signed_in_user(role \\ :editor) do
    email = "auth-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => "password123456"
      })

    user
  end

  describe "failure/3 flash" do
    test "renders the English error under the default locale" do
      Gettext.put_locale(KilnCMSWeb.Gettext, "en")

      conn =
        AuthController.failure(
          flash_conn(),
          :sign_in,
          %AshAuthentication.Errors.AuthenticationFailed{}
        )

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Incorrect email or password"
    end

    test "renders the localized error under a non-default locale" do
      Gettext.put_locale(KilnCMSWeb.Gettext, "fr")

      conn =
        AuthController.failure(
          flash_conn(),
          :sign_in,
          %AshAuthentication.Errors.AuthenticationFailed{}
        )

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "E-mail ou mot de passe incorrect"
    end
  end

  describe "success/4 flash" do
    test "renders the localized sign-in message under a non-default locale" do
      Gettext.put_locale(KilnCMSWeb.Gettext, "fr")
      user = signed_in_user()

      conn = AuthController.success(flash_conn(), :sign_in, user, user.__metadata__.token)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Vous êtes maintenant connecté"
    end
  end

  # #157: editors/admins land on the console overview after sign-in; viewers
  # land on home.
  describe "success/4 redirect" do
    test "an editor is redirected to the console overview" do
      user = signed_in_user(:editor)
      conn = AuthController.success(flash_conn(), :sign_in, user, user.__metadata__.token)
      assert redirected_to(conn) == "/editor/overview"
    end

    test "a viewer is redirected to /" do
      user = signed_in_user(:viewer)
      conn = AuthController.success(flash_conn(), :sign_in, user, user.__metadata__.token)
      assert redirected_to(conn) == "/"
    end
  end
end
