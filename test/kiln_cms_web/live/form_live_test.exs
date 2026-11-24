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

    defp copies_of(form),
      do: CMS.list_forms!(authorize?: false, query: [filter: [slug: "#{form.slug}-copy"]])

    # A failed duplicate is logged (`KilnCMS.Forms.Duplicate`); keep it out of
    # the test output.
    defp capture_log_and(fun) do
      {result, _log} = ExUnit.CaptureLog.with_log(fun)
      result
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

      assert html =~
               "The field “website” was renamed “website_2” in the copy: that name is reserved for spam protection."

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

    test "a field named locale is renamed locale_2 in the copy, saying why", %{conn: conn} do
      admin = authed_user(:admin)
      slug = "fl-loc-#{System.unique_integer([:positive])}"
      form = CMS.create_form!(%{name: "Contact", slug: slug}, actor: admin)

      CMS.create_form_field!(
        %{form_id: form.id, name: "email", label: "Email", field_type: :email},
        actor: admin
      )

      # From before the name was reserved (#2716): the action refuses it now.
      Ash.Seed.seed!(KilnCMS.CMS.FormField, %{
        form_id: form.id,
        name: "locale",
        label: "Language",
        field_type: :string,
        position: 1
      })

      form =
        CMS.update_form!(
          form,
          %{
            autoresponder_enabled: true,
            autoresponder_subject: "Hi [field:locale]",
            autoresponder_body: "Sent to [field:email]."
          },
          actor: admin
        )

      html = duplicate(conn, admin, form)

      assert html =~ "Form duplicated (inactive until you activate it)."

      assert html =~
               "The field “locale” was renamed “locale_2” in the copy: that name is reserved for the submission&#39;s language."

      refute html =~ "spam protection"
      refute html =~ "couldn"

      copy = copy_of(form)
      assert field_names(copy) == ["email", "locale_2"]
      assert copy.autoresponder_enabled
      assert copy.autoresponder_subject == "Hi [field:locale_2]"
      assert field_names(form) == ["email", "locale"]
    end

    # One transaction (#2717): the copy used to commit without the field, and
    # with its autoresponder off, while the flash reported both.
    test "a field that can't be copied refuses the whole duplicate, naming it", %{conn: conn} do
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

      html = capture_log_and(fn -> duplicate(conn, admin, form) end)

      assert html =~
               "Couldn&#39;t duplicate “Contact”, so nothing was created. " <>
                 "Fix the field “topic” in this form and try again: " <>
                 "Invalid value provided for options: a select field must list at least one option."

      refute html =~ "Bread Crumbs"
      refute html =~ "Form duplicated"
      assert copies_of(form) == []
    end

    test "a template naming a field the copy lacks leaves its autoresponder off, tokens renamed",
         %{conn: conn} do
      admin = authed_user(:admin)
      form = CMS.create_form!(%{name: "Both", slug: "fl-dup-both"}, actor: admin)

      Ash.Seed.seed!(KilnCMS.CMS.FormField, %{
        form_id: form.id,
        name: "website",
        label: "Website",
        field_type: :string,
        position: 0
      })

      gone =
        CMS.create_form_field!(
          %{form_id: form.id, name: "gone", label: "Gone", field_type: :string, position: 1},
          actor: admin
        )

      form =
        CMS.update_form!(
          form,
          %{
            autoresponder_enabled: true,
            autoresponder_subject: "[field:website] about [field:gone]",
            autoresponder_body: "Thanks."
          },
          actor: admin
        )

      # A stale token: the field it names moved away underneath the actions,
      # which refuse that while the template uses it (#2343).
      other = CMS.create_form!(%{name: "Other", slug: "fl-dup-other"}, actor: admin)
      Ash.Seed.update!(gone, %{form_id: other.id})

      html = duplicate(conn, admin, form)

      assert html =~ "Form duplicated (inactive until you activate it)."

      assert html =~
               "The copy&#39;s autoresponder stays off: its template names a field the copy doesn&#39;t have ([field:gone])."

      refute html =~ "autoresponder_body"
      refute html =~ "autoresponder_subject"

      copy = copy_of(form)
      assert field_names(copy) == ["website_2"]
      refute copy.autoresponder_enabled
      assert copy.autoresponder_subject == "[field:website_2] about [field:gone]"
    end

    # The flash renders through `Exception.message/1`, which interpolates an
    # error's `vars`; reading `.message` handed the admin `%{value}` (#2717).
    test "a refused copy's flash names the offending value", %{conn: conn} do
      admin = authed_user(:admin)
      slug = "fl-csp-#{System.unique_integer([:positive])}"

      # From before `CspOrigins` refused a plain-http origin.
      form =
        Ash.Seed.seed!(KilnCMS.CMS.Form, %{
          name: "Embedded",
          slug: slug,
          embed_origins: ["http://insecure.test"]
        })

      html = capture_log_and(fn -> duplicate(conn, admin, form) end)

      assert html =~ "&quot;http://insecure.test&quot; is not an allowed CSP source."
      refute html =~ "%{value}"
      refute html =~ "Form duplicated"
      assert copies_of(form) == []
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

    # The tooltip says what a copy leaves behind (#2717).
    assert lv
           |> element(~s(button[phx-click="duplicate_form"][phx-value-id="#{form.id}"]))
           |> render() =~
             ~s(title="Duplicate Feedback: copies its settings and fields; its entries stay with the original.")

    assert has_element?(
             lv,
             ~s(button[phx-click="delete_form"][phx-value-id="#{form.id}"][aria-label="Delete Feedback"])
           )
  end
end
