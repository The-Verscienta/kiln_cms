defmodule KilnCMSWeb.ContentEditorComplianceTest do
  @moduledoc """
  The compliance panel in the content editor (#377).

  What is worth pinning here is the wiring rather than the matching, which
  `KilnCMS.ComplianceTest` covers: that the panel is absent entirely until
  someone asks for it, that a claim in the body reaches it, and that a claim in
  the SEO description — scanned on a different schedule from the body — reaches
  it too. That last one is the part most likely to silently regress, because
  the two halves of the scan are computed in different functions.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  setup do
    previous = Application.get_env(:kiln_cms, KilnCMS.Compliance, [])
    bust()

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Compliance, previous)
      bust()
    end)

    :ok
  end

  defp enable!(opts \\ []) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Compliance,
      Keyword.merge([enabled: true, rules: :default], opts)
    )

    bust()
  end

  # The editor resolves this site's settings through the per-org cache — it does
  # so on every form change, which is the one path that needs one. A deployment
  # sets the config underneath once at boot; only a test rewrites it mid-run, so
  # only a test has to drop the entry. `KilnCMS.Feeds`' tests bust their policy
  # key for the same reason.
  defp bust, do: KilnCMS.Cache.bust_compliance(KilnCMS.Accounts.default_org_id())

  defp authed_user(role) do
    email = "compliance-panel-#{System.unique_integer([:positive])}@example.com"

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

  defp open_editor(conn, user, page) do
    {:ok, lv, html} = conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")
    {lv, html}
  end

  defp para(text),
    do: %{"_type" => "block", "style" => "normal", "children" => [%{"text" => text}]}

  defp rich(nodes), do: %{"_type" => "rich_text", "body" => nodes}

  defp page!(actor, attrs) do
    CMS.create_page!(
      Map.merge(
        %{title: "Compliance fixture #{System.unique_integer([:positive])}"},
        attrs
      ),
      actor: actor
    )
  end

  test "the panel is absent entirely while claim checking is off", %{conn: conn} do
    user = authed_user(:admin)
    page = page!(user, %{blocks: [rich([para("Our formula is FDA approved.")])]})

    {_lv, html} = open_editor(conn, user, page)

    refute html =~ "inspector-compliance"
  end

  test "a claim in the body reaches the panel, quoted", %{conn: conn} do
    enable!()
    user = authed_user(:admin)
    page = page!(user, %{blocks: [rich([para("Our formula is FDA approved.")])]})

    {_lv, html} = open_editor(conn, user, page)

    assert html =~ "inspector-compliance"
    assert html =~ "fda approved"
    assert html =~ "asserts an approval or endorsement"
  end

  # The body is scanned when it changes; the scalar fields are scanned per
  # keystroke and merged in. A regression in that merge shows up here and
  # nowhere else.
  test "a claim in the SEO description reaches the panel too", %{conn: conn} do
    enable!()
    user = authed_user(:admin)

    page =
      page!(user, %{
        blocks: [rich([para("A calm article about tea.")])],
        seo_description: "Clinically proven relief."
      })

    {_lv, html} = open_editor(conn, user, page)

    assert html =~ "inspector-compliance"
    assert html =~ "clinically proven"
  end

  test "a clean document shows the panel with a passing count, not findings", %{conn: conn} do
    enable!()
    user = authed_user(:admin)
    page = page!(user, %{blocks: [rich([para("Herbal tea is pleasant to drink.")])]})

    {_lv, html} = open_editor(conn, user, page)

    assert html =~ "inspector-compliance"
    assert html =~ "No claim issues found"
  end

  test "a missing disclaimer is reported when one is configured", %{conn: conn} do
    enable!(disclaimer: "Not medical advice.")
    user = authed_user(:admin)
    page = page!(user, %{blocks: [rich([para("An article with no disclaimer at all.")])]})

    {_lv, html} = open_editor(conn, user, page)

    assert html =~ "The required disclaimer is missing"
  end

  # The compliance panel must not swallow the other two, nor be swallowed by
  # them — three lenses, one registry run.
  test "compliance findings do not appear in the accessibility panel", %{conn: conn} do
    enable!()
    user = authed_user(:admin)
    page = page!(user, %{blocks: [rich([para("Our formula is FDA approved.")])]})

    {_lv, html} = open_editor(conn, user, page)

    [_before, after_a11y] = String.split(html, "inspector-accessibility", parts: 2)
    [a11y_section, _rest] = String.split(after_a11y, "inspector-compliance", parts: 2)

    refute a11y_section =~ "asserts an approval or endorsement"
  end
end
