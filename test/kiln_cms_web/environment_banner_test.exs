defmodule KilnCMSWeb.EnvironmentBannerTest do
  @moduledoc """
  The environment strip in the console chrome (#469): absent unless the operator
  labelled this deployment, and carrying the label as text rather than as colour
  alone.
  """
  use KilnCMSWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User

  @password "password123456"

  setup do
    previous = Application.get_env(:kiln_cms, :environment, [])
    on_exit(fn -> Application.put_env(:kiln_cms, :environment, previous) end)
    :ok
  end

  defp put_env(opts), do: Application.put_env(:kiln_cms, :environment, opts)

  defp editor do
    email = "envban-#{System.unique_integer([:positive])}@example.com"

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

  test "an unlabelled deployment renders no strip at all", %{conn: conn} do
    put_env(label: nil, tone: nil)

    {:ok, _lv, html} = conn |> log_in(editor()) |> live(~p"/editor/overview")

    refute html =~ "Environment:"
  end

  test "a labelled deployment names itself in the console chrome", %{conn: conn} do
    put_env(label: "staging", tone: "error")

    {:ok, _lv, html} = conn |> log_in(editor()) |> live(~p"/editor/overview")

    # The word, not just the colour: colour alone survives neither a screen
    # reader nor a monochrome display.
    assert html =~ "Environment: staging"
    assert html =~ "bg-error/20"
    assert html =~ "text-error-ink"
  end

  test "an unknown tone still renders a strip, in the default tone", %{conn: conn} do
    put_env(label: "qa", tone: "chartreuse")

    {:ok, _lv, html} = conn |> log_in(editor()) |> live(~p"/editor/overview")

    # Fail to the default, not to silence — a typo must not quietly remove the
    # warning it was meant to add.
    assert html =~ "Environment: qa"
    assert html =~ "bg-warning/20"
  end

  test "an unlabelled deployment never asks for a tone, so a stale one can't log", %{conn: conn} do
    # `tone/0` warns on an unrecognized value and the chrome renders once per
    # page — asking on a deployment that shows no strip would warn forever about
    # a value nothing uses.
    put_env(label: nil, tone: "chartreuse")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _lv, _html} = conn |> log_in(editor()) |> live(~p"/editor/overview")
      end)

    refute log =~ "KILN_ENV_COLOR"
  end

  test "the strip rides inside the sticky header, not above it", %{conn: conn} do
    put_env(label: "staging", tone: "warning")

    {:ok, _lv, html} = conn |> log_in(editor()) |> live(~p"/editor/overview")

    # An environment indicator that scrolls away is visible only at the top of
    # an unscrolled page — the moment nothing is at stake.
    [_, after_sticky] = String.split(html, ~s(class="sticky top-0 z-20"), parts: 2)
    [before_header, _] = String.split(after_sticky, "<header", parts: 2)
    assert before_header =~ "Environment: staging"
  end

  describe "surfaces outside the console shell" do
    test "the account/API-key layout carries it too", %{conn: conn} do
      put_env(label: "staging", tone: "warning")

      # `/editor/api-keys` renders in `Layouts.app`, not `Layouts.console` —
      # minting a key against the wrong deployment is one of the more expensive
      # mistakes on the surface.
      {:ok, _lv, html} = conn |> log_in(admin()) |> live(~p"/editor/api-keys")

      assert html =~ "Environment: staging"
    end

    test "the sign-in page carries it, before anyone authenticates", %{conn: conn} do
      put_env(label: "staging", tone: "warning")

      html = conn |> Phoenix.ConnTest.get(~p"/sign-in") |> Phoenix.ConnTest.html_response(200)

      # Sign-in is where an operator forms their belief about which deployment
      # they are on, and a scrubbed clone shows production's logo here.
      assert html =~ "Environment: staging"
    end
  end

  defp admin do
    email = "envban-admin-#{System.unique_integer([:positive])}@example.com"

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
end
