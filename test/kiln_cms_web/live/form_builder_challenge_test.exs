defmodule KilnCMSWeb.FormBuilderChallengeTest do
  @moduledoc """
  The form builder's human-verification setting (#2249): a toggle on the
  General tab, disabled with a reason while no form can ask for a check, and
  what the check decided shown against each entry.

  `async: false`: `KilnCMS.ChallengeFixtures.enable!/1` writes application env
  and an OS variable, both node-wide.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.ChallengeFixtures
  import Phoenix.LiveViewTest

  alias KilnCMS.CMS
  alias KilnCMS.Forms

  @password "password123456"

  defp admin do
    email = "fbc-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp open(conn, admin, form) do
    {:ok, lv, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)
      |> live(~p"/editor/forms/#{form.id}")

    lv |> element(~s(#form-builder-tabs button[phx-value-tab="general"])) |> render_click()
    lv
  end

  defp save_general(lv, form, extra) do
    lv
    |> form(
      "section form[phx-submit=save_form]",
      %{form: Map.merge(%{name: form.name, slug: form.slug, active: "true"}, extra)}
    )
    |> render_submit()
  end

  test "an admin switches the check on and off", %{conn: conn} do
    enable!()
    admin = admin()
    form = KilnCMS.FormFixtures.form!(%{}, actor: admin)
    lv = open(conn, admin, form)

    refute has_element?(lv, "#gf-challenge[disabled]")
    assert render(lv) =~ "_kiln_challenge"

    assert save_general(lv, form, %{challenge: "always"}) =~ "Saved."
    assert CMS.get_form!(form.id, authorize?: false).challenge == :always

    assert save_general(lv, form, %{challenge: "off"}) =~ "Saved."
    assert CMS.get_form!(form.id, authorize?: false).challenge == :off
  end

  test "while no form can ask, an off toggle is disabled and a save leaves it alone",
       %{conn: conn} do
    enable!(forms: false)
    admin = admin()
    form = KilnCMS.FormFixtures.form!(%{}, actor: admin)

    lv = open(conn, admin, form)

    assert has_element?(lv, "#gf-challenge[disabled]")
    assert render(lv) =~ "isn&#39;t available on this deployment"

    assert save_general(lv, form, %{name: "Renamed"}) =~ "Saved."
    updated = CMS.get_form!(form.id, authorize?: false)
    assert updated.name == "Renamed"
    assert updated.challenge == :off
  end

  test "while no form can ask, a form that has the check on can still be renamed and switched off",
       %{conn: conn} do
    enable!()
    admin = admin()
    form = KilnCMS.FormFixtures.form!(%{challenge: :always}, actor: admin)
    enable!(forms: false)

    lv = open(conn, admin, form)

    refute has_element?(lv, "#gf-challenge[disabled]")
    assert render(lv) =~ "isn&#39;t available on this deployment"

    assert save_general(lv, form, %{name: "Renamed", challenge: "always"}) =~ "Saved."
    updated = CMS.get_form!(form.id, authorize?: false)
    assert updated.name == "Renamed"
    assert updated.challenge == :always

    assert save_general(lv, form, %{challenge: "off"}) =~ "Saved."
    assert CMS.get_form!(form.id, authorize?: false).challenge == :off
  end

  test "each entry shows what the check decided", %{conn: conn} do
    enable!()
    admin = admin()
    form = KilnCMS.FormFixtures.form!(%{challenge: :always}, actor: admin)
    active = Forms.get_active(form.slug)

    {:ok, _} = Forms.submit(active, %{"email" => "a@b.co", "_kiln_challenge" => "pass"})
    {:ok, _} = Forms.submit(active, %{"email" => "c@d.co"})

    lv = open(conn, admin, form)
    lv |> element(~s(#form-builder-tabs button[phx-value-tab="entries"])) |> render_click()
    html = render(lv)

    assert html =~ "Verified"
    assert html =~ "Held"
    assert html =~ "Held: sent without completing the check."
  end
end
