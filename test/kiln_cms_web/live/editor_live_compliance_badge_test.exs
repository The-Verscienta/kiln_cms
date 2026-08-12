defmodule KilnCMSWeb.EditorLiveComplianceBadgeTest do
  @moduledoc """
  The in-list compliance badge (#856): the approving admin sees the publish
  gate (`Validations.ComplianceClaims`) refusing a claim, but never the panel
  that would have shown them why — the panel lives in the editor, and the
  approver acts from `/editor?status=in_review`. This surfaces the same
  verdict, and links to the panel, right in that list.

  `async: false`: claim-checking config is process-wide application env, and
  `Settings.for_org/1` caches per org (#857) — both shared with every other
  compliance test.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.Page
  alias KilnCMS.Compliance

  @password "password123456"

  setup do
    original = Application.get_env(:kiln_cms, Compliance, [])
    on_exit(fn -> Application.put_env(:kiln_cms, Compliance, original) end)
    KilnCMS.Cache.bust_compliance(Accounts.default_org_id())
    :ok
  end

  defp configure(opts) do
    Application.put_env(
      :kiln_cms,
      Compliance,
      Keyword.merge([enabled: true, rules: :default], opts)
    )

    KilnCMS.Cache.bust_compliance(Accounts.default_org_id())
  end

  defp authed_user(role) do
    email = "compliancebadge-#{System.unique_integer([:positive])}@example.com"

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

  defp in_review_page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{
          title: "In review page",
          slug: "compliancebadge-#{System.unique_integer([:positive])}",
          state: :in_review,
          locale: "en"
        },
        attrs
      )
    )
  end

  test "no badge when compliance is off for the org (default)", %{conn: conn} do
    in_review_page(%{search_text: "100% safe, no side effects"})

    {:ok, _lv, html} =
      conn |> log_in(authed_user(:admin)) |> live(~p"/editor?status=in_review")

    refute html =~ "Compliance panel"
    refute html =~ "Needs work"
    refute html =~ ">Poor<"
  end

  test "no badge for a non-English document (unjudgeable, same as the panel's :n_a)", %{
    conn: conn
  } do
    configure([])
    in_review_page(%{search_text: "100% safe, no side effects", locale: "fr"})

    {:ok, _lv, html} =
      conn |> log_in(authed_user(:admin)) |> live(~p"/editor?status=in_review")

    refute html =~ "Poor"
  end

  test "a clean in-review document shows a good-grade badge", %{conn: conn} do
    configure([])
    in_review_page(%{title: "Nothing to flag", search_text: "An ordinary paragraph."})

    {:ok, _lv, html} =
      conn |> log_in(authed_user(:admin)) |> live(~p"/editor?status=in_review")

    assert html =~ "Open the editor&#39;s Compliance panel" or
             html =~ "Open the editor's Compliance panel"

    assert html =~ "Good"
  end

  test "an in-review document with a flagged claim shows a poor-grade badge linking to the editor",
       %{conn: conn} do
    configure([])

    page =
      in_review_page(%{
        title: "Claimy page",
        search_text: "This product is 100% safe with no side effects."
      })

    {:ok, _lv, html} =
      conn |> log_in(authed_user(:admin)) |> live(~p"/editor?status=in_review")

    assert html =~ "Poor"
    assert html =~ ~p"/editor/content/page/#{page.id}"
  end

  test "a claim in the SEO description is scanned too, same as the publish gate", %{conn: conn} do
    configure([])

    in_review_page(%{
      title: "Meta claim",
      search_text: "Nothing here.",
      seo_description: "Guaranteed results every time."
    })

    {:ok, _lv, html} =
      conn |> log_in(authed_user(:admin)) |> live(~p"/editor?status=in_review")

    # efficacy_claim is :warning severity, one match → grade :ok ("Needs work").
    assert html =~ "Needs work"
  end

  # Same reasoning docs/compliance.md gives the publish gate: joining fields
  # before scanning invents claims that are not in the document. Neither half
  # here matches any rule on its own; concatenated with a space they would
  # form "risk free" (a safety_claim phrase).
  test "fields are scanned separately, not concatenated across the seam", %{conn: conn} do
    configure([])

    in_review_page(%{
      title: "Free consultation guide",
      search_text: "Use the sauna at your own risk"
    })

    {:ok, _lv, html} =
      conn |> log_in(authed_user(:admin)) |> live(~p"/editor?status=in_review")

    assert html =~ "Good"
    refute html =~ "Poor"
  end

  test "no badge outside the in_review filter, even with a flagged claim", %{conn: conn} do
    configure([])

    Ash.Seed.seed!(Page, %{
      title: "Draft claim",
      slug: "compliancebadge-#{System.unique_integer([:positive])}",
      state: :draft,
      locale: "en",
      search_text: "100% safe with no side effects."
    })

    {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor?status=draft")

    refute html =~ "Poor"
    refute html =~ "Open the editor"
  end
end
