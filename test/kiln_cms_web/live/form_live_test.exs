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
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "editors are redirected away", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
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

    CMS.create_form_field!(
      %{
        form_id: form.id,
        name: "qty",
        label: "Qty",
        field_type: :number,
        min_value: 1.0,
        max_value: 9.0,
        step: 2.0,
        position: 1
      },
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

    assert [field, qty] = CMS.form_fields_for!(copy.id, authorize?: false)
    assert field.name == "email"
    assert field.field_type == :email
    assert field.required
    # The range attributes travel with the field (#2261).
    assert {qty.min_value, qty.max_value, qty.step} == {1.0, 9.0, 2.0}
  end

  describe "duplicating a form (#2267)" do
    defp duplicate(conn, admin, form) do
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/forms")

      lv
      |> element(~s(button[phx-click="duplicate_form"][phx-value-id="#{form.id}"]))
      |> render_click()
    end

    defp copy_of(form) do
      assert [copy] =
               CMS.list_forms!(authorize?: false, query: [filter: [slug: "#{form.slug}-copy"]])

      copy
    end

    defp field_names(form),
      do: form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.map(& &1.name)

    # The copy's token check reads the copy's own fields, which used to be
    # created after the form: an enabled template naming a field refused the
    # whole duplicate.
    test "an enabled autoresponder that names a field is copied, still on", %{conn: conn} do
      admin = authed_user(:admin)
      slug = "fl-ar-#{System.unique_integer([:positive])}"
      form = CMS.create_form!(%{name: "Contact", slug: slug}, actor: admin)

      CMS.create_form_field!(
        %{form_id: form.id, name: "email", label: "Email", field_type: :email},
        actor: admin
      )

      form =
        CMS.update_form!(
          form,
          %{
            autoresponder_enabled: true,
            autoresponder_subject: "Hi [field:email]",
            autoresponder_body: "We got [field:email]."
          },
          actor: admin
        )

      html = duplicate(conn, admin, form)

      assert html =~ "Form duplicated (inactive until you activate it)."
      refute html =~ "couldn"

      copy = copy_of(form)
      assert copy.autoresponder_enabled
      assert copy.autoresponder_subject == "Hi [field:email]"
      assert copy.autoresponder_body == "We got [field:email]."
      assert field_names(copy) == ["email"]
    end

    test "a field named like the honeypot is renamed in the copy, tokens and all",
         %{conn: conn} do
      admin = authed_user(:admin)
      slug = "fl-hp-#{System.unique_integer([:positive])}"
      form = CMS.create_form!(%{name: "Contact", slug: slug}, actor: admin)

      CMS.create_form_field!(
        %{form_id: form.id, name: "email", label: "Email", field_type: :email},
        actor: admin
      )

      # From before the name was reserved: the action refuses it now.
      Ash.Seed.seed!(KilnCMS.CMS.FormField, %{
        form_id: form.id,
        name: "website",
        label: "Website",
        field_type: :string,
        position: 1
      })

      form =
        CMS.update_form!(
          form,
          %{
            autoresponder_enabled: true,
            autoresponder_subject: "Hi [field:website]",
            autoresponder_body: "Sent to [field:email] about [field:website]."
          },
          actor: admin
        )

      html = duplicate(conn, admin, form)

      assert html =~ "was renamed “website_2” in the copy"
      refute html =~ "couldn"

      copy = copy_of(form)
      refute copy.active
      assert field_names(copy) == ["email", "website_2"]
      assert copy.autoresponder_enabled
      assert copy.autoresponder_subject == "Hi [field:website_2]"
      assert copy.autoresponder_body == "Sent to [field:email] about [field:website_2]."

      # The original keeps its field and its template.
      assert field_names(form) == ["email", "website"]

      assert CMS.get_form!(form.id, authorize?: false).autoresponder_subject ==
               "Hi [field:website]"
    end

    test "a field that can't be copied is named, not dropped silently", %{conn: conn} do
      admin = authed_user(:admin)
      slug = "fl-bad-#{System.unique_integer([:positive])}"
      form = CMS.create_form!(%{name: "Contact", slug: slug}, actor: admin)

      CMS.create_form_field!(
        %{form_id: form.id, name: "email", label: "Email", field_type: :email},
        actor: admin
      )

      # A row the create action refuses for another reason: a dropdown
      # without options.
      Ash.Seed.seed!(KilnCMS.CMS.FormField, %{
        form_id: form.id,
        name: "topic",
        label: "Topic",
        field_type: :select,
        options: [],
        position: 1
      })

      form =
        CMS.update_form!(
          form,
          %{
            autoresponder_enabled: true,
            autoresponder_subject: "About [field:topic]",
            autoresponder_body: "Thanks."
          },
          actor: admin
        )

      html = duplicate(conn, admin, form)

      assert html =~ "Form duplicated, but a field couldn&#39;t be copied: topic."
      # Its template names the missing field, so the copy's stays off.
      assert html =~ "The copy&#39;s autoresponder stays off:"

      copy = copy_of(form)
      assert field_names(copy) == ["email"]
      refute copy.autoresponder_enabled
      assert copy.autoresponder_subject == "About [field:topic]"
    end
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
    # The list once showed `/forms/:slug` while nothing answered there (#1783),
    # then linked the iframe document instead; since #2138 the form has a page
    # of its own at that address. Every address shown must answer, so the test
    # reads them off the rendered page and requests each one.
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

      assert URI.parse(hosted).path == "/forms/#{slug}"
      assert URI.parse(api).path == "/api/forms/#{slug}"

      # Both resolve for an anonymous visitor — the hosted address as the
      # form's page in the site's chrome, not the transparent iframe document.
      hosted_conn = get(build_conn(), URI.parse(hosted).path)
      assert html_response(hosted_conn, 200) =~ "Newsletter"
      assert hosted_conn.resp_body =~ "public-shell"
      refute hosted_conn.resp_body =~ "kiln-embed-body"

      api_conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get(URI.parse(api).path)

      assert %{"slug" => ^slug} = json_response(api_conn, 200)

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
