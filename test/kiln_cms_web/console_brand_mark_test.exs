defmodule KilnCMSWeb.ConsoleBrandMarkTest do
  @moduledoc """
  #2400: the console sidebar renders the built-in logo through
  `Layouts.brand_mark/1` — the right-sized WebP/PNG pair (#2165), not the
  278x379 `logo-mark.png` — and an operator's own logo stays a plain `<img>`.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password1234!"

  setup do
    org =
      Ash.Seed.seed!(Accounts.Organization, %{
        name: "Brand Mark Site",
        slug: "brandmark-#{System.unique_integer([:positive])}",
        status: :active
      })

    on_exit(fn -> KilnCMS.Cache.bust_branding(org.id) end)
    %{org: org}
  end

  defp sidebar_head(conn, org) do
    user = editor()

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: :editor
    })

    {:ok, lv, _html} = conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/overview")
    lv |> element("#console-sidebar .side-head") |> render()
  end

  test "the stock logo renders as the small picture", %{conn: conn, org: org} do
    head = sidebar_head(conn, org)

    assert head =~
             ~r{<picture[^>]*>\s*<source type="image/webp" srcset="/images/logo-mark-sm[^"]*\.webp"}

    assert head =~
             ~r{<img[^>]* src="/images/logo-mark-sm[^"]*\.png"[^>]*class="side-brand h-7 w-auto"}

    refute head =~ "logo-mark.png"
  end

  test "a custom logo is a plain <img> of exactly that URL", %{conn: conn, org: org} do
    CMS.save_site_branding!(%{logo_url: "/uploads/acme.png"}, tenant: org, authorize?: false)
    KilnCMS.Cache.bust_branding(org.id)

    head = sidebar_head(conn, org)

    assert head =~ ~r{<img[^>]* src="/uploads/acme.png"[^>]*class="side-brand h-7 w-auto"}
    refute head =~ "<picture"
    refute head =~ "logo-mark"
  end

  defp editor do
    email = "brandmark-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
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
end
