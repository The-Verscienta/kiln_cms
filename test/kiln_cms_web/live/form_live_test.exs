defmodule KilnCMSWeb.FormLiveTest do
  @moduledoc """
  The forms index (`/editor/forms`, admin-only): create (landing in the
  builder), duplicate, and delete forms. Building happens in
  `FormBuilderLive` (see `form_builder_live_test.exs`).
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "fl-#{System.unique_integer([:positive])}@example.com"

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

  test "editors are redirected away", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in(authed_user(:editor)) |> live(~p"/editor/forms")
  end

  test "creating a form lands in its builder", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/forms")

    slug = "fl-#{System.unique_integer([:positive])}"

    lv
    |> form("form[phx-submit=create_form]", %{form: %{name: "Contact", slug: slug}})
    |> render_submit()

    assert [created] = CMS.list_forms!(authorize?: false, query: [filter: [slug: slug]])
    {path, _flash} = assert_redirect(lv)
    assert path == "/editor/forms/#{created.id}"
  end

  test "forms list links each form to its builder", %{conn: conn} do
    admin = authed_user(:admin)
    form = CMS.create_form!(%{name: "Contact", slug: "fl-link"}, actor: admin)

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/forms")
    assert html =~ ~s(href="/editor/forms/#{form.id}")
  end

  test "duplicating a form copies its settings and fields, inactive", %{conn: conn} do
    admin = authed_user(:admin)

    form =
      CMS.create_form!(
        %{
          name: "Contact",
          slug: "fl-dup",
          success_message: "Merci!",
          submit_label: "Send",
          embed_origins: ["https://acme.test"],
          autoresponder_enabled: true,
          autoresponder_subject: "Thanks!",
          autoresponder_body: "We got it."
        },
        actor: admin
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email, required: true},
      actor: admin
    )

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/forms")

    html =
      lv
      |> element(~s(button[phx-click="duplicate_form"][phx-value-id="#{form.id}"]))
      |> render_click()

    assert html =~ "Form duplicated"

    assert [copy] = CMS.list_forms!(authorize?: false, query: [filter: [slug: "fl-dup-copy"]])
    refute copy.active
    assert copy.success_message == "Merci!"
    assert copy.submit_label == "Send"

    # Every settable attribute, not a hand-kept subset. The list this replaced
    # had already lost the autoresponder fields, and since #648 a missed one is
    # a security default: a copy without `embed_origins` silently falls back to
    # the deployment-wide allowlist, which on a multi-org instance is every
    # other org's embedders.
    assert copy.embed_origins == ["https://acme.test"]
    assert copy.autoresponder_enabled
    assert copy.autoresponder_subject == "Thanks!"

    assert [field] = CMS.form_fields_for!(copy.id, authorize?: false)
    assert field.name == "email"
    assert field.field_type == :email
    assert field.required
  end

  test "deleting a form removes it from the list", %{conn: conn} do
    admin = authed_user(:admin)
    form = CMS.create_form!(%{name: "Contact", slug: "fl-del"}, actor: admin)

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/forms")

    html =
      lv
      |> element(~s(button[phx-click="delete_form"][phx-value-id="#{form.id}"]))
      |> render_click()

    assert html =~ "Form deleted."
    assert {:error, _} = CMS.get_form(form.id, authorize?: false)
  end

  describe "public addresses (#1783)" do
    # The list used to show `/forms/:slug`, which has no GET route at the root —
    # a browser got the public 404. Every address it shows now must answer, so
    # the test reads them off the rendered page and requests each one.
    test "an active form's hosted page and JSON API resolve, and the snippet is copyable",
         %{conn: conn} do
      admin = authed_user(:admin)
      slug = "fl-pub-#{System.unique_integer([:positive])}"
      form = CMS.create_form!(%{name: "Newsletter", slug: slug}, actor: admin)

      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/forms")
      doc = LazyHTML.from_fragment(html)

      [hosted] =
        doc
        |> LazyHTML.query("#form-links-#{form.id} a[data-role=hosted-form]")
        |> LazyHTML.attribute("href")

      api =
        doc
        |> LazyHTML.query("#form-links-#{form.id} [data-role=json-api]")
        |> LazyHTML.text()
        |> String.trim()

      assert URI.parse(hosted).path == "/forms/#{slug}/embed"
      assert URI.parse(api).path == "/api/forms/#{slug}"

      # Both resolve for an anonymous visitor.
      hosted_conn = get(build_conn(), URI.parse(hosted).path)
      assert html_response(hosted_conn, 200) =~ "Newsletter"

      api_conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get(URI.parse(api).path)

      assert %{"slug" => ^slug} = json_response(api_conn, 200)

      # The dead address is no longer advertised as a page anywhere on the row
      # (it still 404s for an HTML GET — which is why it had to go).
      refute html =~ ~s(>/forms/#{slug}<)
      assert get(build_conn(), "/forms/#{slug}").status == 404

      # The embed snippet is on the row with an accessible Copy button that
      # carries exactly the snippet the builder hands out.
      snippet = KilnCMSWeb.Embed.form_snippet(slug, nil)
      assert snippet =~ ~s(data-kiln-form="#{slug}")

      copy =
        doc
        |> LazyHTML.query("#copy-embed-#{form.id}[phx-hook=Clipboard]")

      assert LazyHTML.attribute(copy, "data-clipboard-text") == [snippet]
      assert LazyHTML.attribute(copy, "aria-label") == ["Copy embed code for Newsletter"]

      assert render_hook(element(lv, "#copy-embed-#{form.id}"), "copied", %{}) =~
               "Embed code copied to clipboard."
    end

    test "an inactive form advertises no address, and says why", %{conn: conn} do
      admin = authed_user(:admin)
      slug = "fl-off-#{System.unique_integer([:positive])}"
      form = CMS.create_form!(%{name: "Draft form", slug: slug, active: false}, actor: admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/forms")

      refute has_element?(lv, "#form-links-#{form.id} a[data-role=hosted-form]")
      refute has_element?(lv, "#copy-embed-#{form.id}")
      assert has_element?(lv, "#form-links-#{form.id}", "Not public yet")

      # …because none of them would answer.
      assert get(build_conn(), "/forms/#{slug}/embed").status == 404
    end
  end

  # Part of #1774: icon-only row actions named for the form they act on, so a
  # screen-reader list of buttons is not a column of identical "Delete form".
  test "row actions carry the form's name in their accessible name", %{conn: conn} do
    admin = authed_user(:admin)
    form = CMS.create_form!(%{name: "Feedback", slug: "fl-a11y"}, actor: admin)

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/forms")

    assert has_element?(
             lv,
             ~s(button[phx-click="duplicate_form"][phx-value-id="#{form.id}"][aria-label="Duplicate Feedback"])
           )

    assert has_element?(
             lv,
             ~s(button[phx-click="delete_form"][phx-value-id="#{form.id}"][aria-label="Delete Feedback"])
           )
  end
end
