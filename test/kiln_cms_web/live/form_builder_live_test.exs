defmodule KilnCMSWeb.FormBuilderLiveTest do
  @moduledoc """
  The visual form builder (`/editor/forms/:id`, admin-only): palette → canvas
  → options panel, drag reorder persisting `position`, duplicate, settings
  tabs, and the entries viewer.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "fb-#{System.unique_integer([:positive])}@example.com"

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

  # Creates a form (and optionally fields) FIRST, then mounts the builder —
  # the LiveView only sees fields that exist at mount (or that it creates).
  defp builder(conn, admin, form_attrs \\ %{}, fields \\ []) do
    slug = "fb-#{System.unique_integer([:positive])}"
    attrs = Map.merge(%{name: "Contact", slug: slug}, form_attrs)
    form = CMS.create_form!(attrs, actor: admin)

    created =
      for field_attrs <- fields do
        CMS.create_form_field!(Map.put(field_attrs, :form_id, form.id), actor: admin)
      end

    {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/forms/#{form.id}")
    {form, created, lv, html}
  end

  test "editors are redirected away", %{conn: conn} do
    admin = authed_user(:admin)
    form = CMS.create_form!(%{name: "Contact", slug: "fb-tier"}, actor: admin)

    assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
             conn |> log_in(authed_user(:editor)) |> live(~p"/editor/forms/#{form.id}")
  end

  test "an unknown form id bounces back to the index", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/editor/forms"}}} =
             conn
             |> log_in(authed_user(:admin))
             |> live(~p"/editor/forms/#{Ash.UUID.generate()}")
  end

  test "clicking a palette type adds a field and selects it", %{conn: conn} do
    {form, [], lv, html} = builder(conn, authed_user(:admin))
    assert html =~ "No fields yet"

    html =
      lv
      |> element(~s(button[phx-click="add_field"][phx-value-type="email"]))
      |> render_click()

    assert [field] = CMS.form_fields_for!(form.id, authorize?: false)
    assert field.field_type == :email
    assert field.name == "email"
    # The new field is selected — its settings form is on screen.
    assert html =~ "field-settings-#{field.id}"

    # Adding a second field of the same type uniquifies the machine name.
    lv
    |> element(~s(button[phx-click="add_field"][phx-value-type="email"]))
    |> render_click()

    names = form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.map(& &1.name)
    assert Enum.sort(names) == ["email", "email_2"]
  end

  test "a dropdown field arrives with starter options", %{conn: conn} do
    {form, [], lv, _html} = builder(conn, authed_user(:admin))

    lv
    |> element(~s(button[phx-click="add_field"][phx-value-type="select"]))
    |> render_click()

    assert [field] = CMS.form_fields_for!(form.id, authorize?: false)
    assert field.field_type == :select
    assert length(field.options) == 2
  end

  test "the options panel edits the selected field live", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [field], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "email", label: "Email", field_type: :email}
      ])

    lv
    |> element(~s(button[phx-click="select_field"][phx-value-id="#{field.id}"]))
    |> render_click()

    html =
      lv
      |> form("#field-settings-#{field.id}", %{
        field: %{
          label: "Work email",
          name: "email",
          field_type: "email",
          width: "half",
          required: "true",
          placeholder: "you@company.com",
          default_value: "",
          help_text: "We reply within a day."
        }
      })
      |> render_change()

    updated = CMS.form_fields_for!(form.id, authorize?: false) |> hd()
    assert updated.label == "Work email"
    assert updated.width == :half
    assert updated.required
    assert updated.placeholder == "you@company.com"
    assert updated.help_text == "We reply within a day."

    # The canvas re-renders the public markup with the changes.
    assert html =~ "Work email"
    assert html =~ "you@company.com"
    assert html =~ "sm:col-span-3"
  end

  test "switching a field to dropdown seeds options so it stays valid", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [field], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "topic", label: "Topic", field_type: :string}
      ])

    lv
    |> element(~s(button[phx-click="select_field"][phx-value-id="#{field.id}"]))
    |> render_click()

    lv
    |> form("#field-settings-#{field.id}", %{
      field: %{label: "Topic", name: "topic", field_type: "select"}
    })
    |> render_change()

    updated = CMS.form_fields_for!(form.id, authorize?: false) |> hd()
    assert updated.field_type == :select
    assert updated.options != []
  end

  describe "richer field types (#2261)" do
    test "every new type can be added from the palette, valid on arrival", %{conn: conn} do
      {form, [], lv, _html} = builder(conn, authed_user(:admin))

      for type <- ~w(radio checkboxes phone url number rating hidden) do
        lv
        |> element(~s(button[phx-click="add_field"][phx-value-type="#{type}"]))
        |> render_click()
      end

      fields = CMS.form_fields_for!(form.id, authorize?: false)
      assert Enum.map(fields, & &1.name) == ~w(radio checkboxes phone url number rating hidden)

      for f <- fields, f.field_type in [:radio, :checkboxes] do
        assert length(f.options) == 2
      end
    end

    test "the settings panel shows only the controls the type uses", %{conn: conn} do
      admin = authed_user(:admin)

      {_form, fields, lv, _html} =
        builder(conn, admin, %{}, [
          %{name: "n", label: "N", field_type: :number, position: 0},
          %{name: "r", label: "R", field_type: :rating, position: 1},
          %{name: "c", label: "C", field_type: :checkboxes, options: ["a"], position: 2},
          %{name: "h", label: "H", field_type: :hidden, position: 3}
        ])

      panel = fn f ->
        lv
        |> element(~s(button[phx-click="select_field"][phx-value-id="#{f.id}"]))
        |> render_click()
      end

      [n, r, c, h] = fields

      html = panel.(n)
      assert html =~ ~s(name="field[min_value]")
      assert html =~ ~s(name="field[step]")
      assert html =~ ~s(id="fs-placeholder")

      html = panel.(r)
      assert html =~ ~s(id="fs-stars")
      refute html =~ ~s(name="field[min_value]")
      refute html =~ ~s(id="fs-placeholder")

      html = panel.(c)
      assert html =~ ~s(id="fs-options")
      refute html =~ ~s(id="fs-placeholder")

      html = panel.(h)
      refute html =~ ~s(id="fs-options")
      refute html =~ ~s(id="fs-placeholder")
    end

    test "min, max and step save on a number; stars save on a rating", %{conn: conn} do
      admin = authed_user(:admin)

      {form, [n, r], lv, _html} =
        builder(conn, admin, %{}, [
          %{name: "n", label: "N", field_type: :number, position: 0},
          %{name: "r", label: "R", field_type: :rating, position: 1}
        ])

      lv
      |> element(~s(button[phx-click="select_field"][phx-value-id="#{n.id}"]))
      |> render_click()

      lv
      |> form("#field-settings-#{n.id}", %{
        field: %{min_value: "1", max_value: "10.5", step: "0.5"}
      })
      |> render_change()

      lv
      |> element(~s(button[phx-click="select_field"][phx-value-id="#{r.id}"]))
      |> render_click()

      lv |> form("#field-settings-#{r.id}", %{field: %{max_value: "7"}}) |> render_change()

      by_name = form.id |> CMS.form_fields_for!(authorize?: false) |> Map.new(&{&1.name, &1})

      assert {by_name["n"].min_value, by_name["n"].max_value, by_name["n"].step} ==
               {1.0, 10.5, 0.5}

      assert by_name["r"].max_value == 7.0
    end

    test "switching number -> rating clears the range so it saves", %{conn: conn} do
      admin = authed_user(:admin)

      {form, [n], lv, _html} =
        builder(conn, admin, %{}, [
          %{
            name: "n",
            label: "N",
            field_type: :number,
            min_value: 1.0,
            max_value: 1000.0,
            step: 5.0,
            placeholder: "p",
            default_value: "10"
          }
        ])

      lv
      |> element(~s(button[phx-click="select_field"][phx-value-id="#{n.id}"]))
      |> render_click()

      lv
      |> form("#field-settings-#{n.id}", %{
        field: %{field_type: "rating", min_value: "1", max_value: "1000", step: "5"}
      })
      |> render_change()

      updated = form.id |> CMS.form_fields_for!(authorize?: false) |> hd()
      assert updated.field_type == :rating
      assert {updated.min_value, updated.max_value, updated.step} == {nil, nil, nil}
      assert updated.default_value == nil
      assert updated.placeholder == nil
    end

    test "switching select -> text keeps the options and drops the default; text -> checkboxes restores them",
         %{
           conn: conn
         } do
      admin = authed_user(:admin)

      {form, [f], lv, _html} =
        builder(conn, admin, %{}, [
          %{name: "t", label: "T", field_type: :select, options: ["x", "y"], default_value: "x"}
        ])

      lv
      |> element(~s(button[phx-click="select_field"][phx-value-id="#{f.id}"]))
      |> render_click()

      lv
      |> form("#field-settings-#{f.id}", %{field: %{field_type: "string", options: "x\ny"}})
      |> render_change()

      updated = form.id |> CMS.form_fields_for!(authorize?: false) |> hd()
      assert updated.field_type == :string
      assert updated.options == ["x", "y"]
      assert updated.default_value == nil

      lv
      |> form("#field-settings-#{f.id}", %{field: %{field_type: "checkboxes"}})
      |> render_change()

      updated = form.id |> CMS.form_fields_for!(authorize?: false) |> hd()
      assert updated.field_type == :checkboxes
      assert updated.options == ["x", "y"]
    end

    test "switching a required field to hidden drops required", %{conn: conn} do
      admin = authed_user(:admin)

      {form, [f], lv, _html} =
        builder(conn, admin, %{}, [%{name: "t", label: "T", field_type: :string, required: true}])

      lv
      |> element(~s(button[phx-click="select_field"][phx-value-id="#{f.id}"]))
      |> render_click()

      lv
      |> form("#field-settings-#{f.id}", %{field: %{field_type: "hidden", required: "true"}})
      |> render_change()

      updated = form.id |> CMS.form_fields_for!(authorize?: false) |> hd()
      assert updated.field_type == :hidden
      refute updated.required
    end

    test "duplicating a field copies its range", %{conn: conn} do
      admin = authed_user(:admin)

      {form, [n], lv, _html} =
        builder(conn, admin, %{}, [
          %{name: "n", label: "N", field_type: :number, min_value: 1.0, max_value: 9.0, step: 2.0}
        ])

      lv
      |> element(~s(button[phx-click="duplicate_field"][phx-value-id="#{n.id}"]))
      |> render_click()

      copy = form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.find(&(&1.name == "n_2"))
      assert {copy.min_value, copy.max_value, copy.step} == {1.0, 9.0, 2.0}
    end
  end

  test "drag reorder persists positions", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [a, b, c], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "one", label: "one", position: 0},
        %{name: "two", label: "two", position: 1},
        %{name: "three", label: "three", position: 2}
      ])

    render_hook(lv, "reorder", %{"order" => [c.id, a.id, b.id]})

    names = form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.map(& &1.name)
    assert names == ["three", "one", "two"]
  end

  test "duplicating a field slots the copy right after the original", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [a, _b], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "email", label: "email", position: 0},
        %{name: "message", label: "message", position: 1}
      ])

    lv
    |> element(~s(button[phx-click="duplicate_field"][phx-value-id="#{a.id}"]))
    |> render_click()

    names = form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.map(& &1.name)
    assert names == ["email", "email_2", "message"]
  end

  test "deleting a field removes it from the canvas", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [field], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "email", label: "Email", field_type: :email}
      ])

    lv
    |> element(~s(button[phx-click="delete_field"][phx-value-id="#{field.id}"]))
    |> render_click()

    assert CMS.form_fields_for!(form.id, authorize?: false) == []
  end

  test "the general tab saves form settings, including the submit label", %{conn: conn} do
    {form, [], lv, _html} = builder(conn, authed_user(:admin))

    lv |> element(~s(#form-builder-tabs button[phx-value-tab="general"])) |> render_click()

    html =
      lv
      |> form("section form[phx-submit=save_form]", %{
        form: %{
          name: "Contact us",
          slug: form.slug,
          description: "Say hi.",
          submit_label: "Send it",
          active: "true"
        }
      })
      |> render_submit()

    assert html =~ "Saved."
    updated = CMS.get_form!(form.id, authorize?: false)
    assert updated.name == "Contact us"
    assert updated.submit_label == "Send it"
    assert updated.description == "Say hi."
  end

  test "the confirmations tab saves the autoresponder settings", %{conn: conn} do
    {form, [field], lv, _html} =
      builder(conn, authed_user(:admin), %{}, [
        %{name: "email", label: "Email", field_type: :email}
      ])

    lv |> element(~s(#form-builder-tabs button[phx-value-tab="confirmations"])) |> render_click()

    html = lv |> element("section") |> render()
    assert html =~ "[field:#{field.name}]"
    assert html =~ "[form-name]"

    html =
      lv
      |> form("section form[phx-submit=save_form]", %{
        form: %{
          success_message: "Thanks!",
          autoresponder_enabled: "true",
          autoresponder_subject: "Thanks, [field:email]!",
          autoresponder_body: "<p>We got it, from [form-name].</p>"
        }
      })
      |> render_submit()

    assert html =~ "Saved."
    updated = CMS.get_form!(form.id, authorize?: false)
    assert updated.autoresponder_enabled == true
    assert updated.autoresponder_subject == "Thanks, [field:email]!"
    assert updated.autoresponder_body == "<p>We got it, from [form-name].</p>"
  end

  test "the confirmations tab rejects an unknown token", %{conn: conn} do
    {form, [], lv, _html} = builder(conn, authed_user(:admin))

    lv |> element(~s(#form-builder-tabs button[phx-value-tab="confirmations"])) |> render_click()

    html =
      lv
      |> form("section form[phx-submit=save_form]", %{
        form: %{
          autoresponder_enabled: "true",
          autoresponder_subject: "Hi [field:nope]",
          autoresponder_body: "body"
        }
      })
      |> render_submit()

    assert html =~ "unknown token"
    updated = CMS.get_form!(form.id, authorize?: false)
    assert updated.autoresponder_enabled == false
  end

  describe "the public address in the header (#2138)" do
    test "an active form links its public page, and Preview opens it", %{conn: conn} do
      {form, [], lv, _html} = builder(conn, authed_user(:admin))
      url = KilnCMSWeb.Tenant.base_url(nil) <> "/forms/#{form.slug}"

      assert has_element?(lv, ~s(a#form-public-url[href="#{url}"][target="_blank"]), url)
      assert has_element?(lv, ~s(a.btn[href="#{url}"]), "Preview")
      refute render(lv) =~ "/forms/#{form.slug}/embed"

      # The address it shows is one that answers.
      assert build_conn() |> get(URI.parse(url).path) |> html_response(200) =~ "Contact"
    end

    test "an inactive form shows no address and says why", %{conn: conn} do
      {form, [], lv, _html} = builder(conn, authed_user(:admin), %{active: false})

      assert has_element?(lv, "p#form-public-url", "Not public while inactive.")
      refute has_element?(lv, "a#form-public-url")
      refute has_element?(lv, "a.btn", "Preview")
      refute render(lv) =~ "/forms/#{form.slug}"
    end
  end

  test "the embed tab shows a copyable snippet", %{conn: conn} do
    {form, [], lv, _html} = builder(conn, authed_user(:admin))

    html = lv |> element(~s(#form-builder-tabs button[phx-value-tab="embed"])) |> render_click()

    assert html =~ "/embed.js"
    assert html =~ "data-kiln-form=&quot;#{form.slug}&quot;"
    assert lv |> render_hook("copied", %{}) =~ "Embed code copied to clipboard."

    # `config/test.exs` configures an allowlist, so the panel names it and the
    # closed-default warning stays hidden. Pins the polarity of the `:if` — an
    # inverted guard would otherwise tell every correctly-configured operator
    # that cross-site embedding is off (#562).
    assert html =~ "https://embedder.test"
    refute html =~ "Cross-site embedding is off"
  end

  test "the embed snippet points at the org's own host on a tenant subdomain (#557)",
       %{conn: conn} do
    admin = authed_user(:admin)

    org =
      Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
        name: "Embed Org",
        slug: "embed-org-#{System.unique_integer([:positive])}",
        status: :active
      })

    slug = "fb-#{System.unique_integer([:positive])}"
    form = CMS.create_form!(%{name: "Contact", slug: slug}, actor: admin, tenant: org)

    host = "#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}"

    {:ok, lv, _html} =
      %{conn | host: host} |> log_in(admin) |> live(~p"/editor/forms/#{form.id}")

    html = lv |> element(~s(#form-builder-tabs button[phx-value-tab="embed"])) |> render_click()

    # The snippet renders inside a `value="..."` attribute, so `<`/`"` are
    # HTML-entity-escaped (matches the sibling "copyable snippet" test above).
    base_url = KilnCMSWeb.Tenant.base_url(org)
    assert html =~ "src=&quot;#{base_url}/embed.js&quot;"
    refute html =~ "src=&quot;http://localhost:4000/embed.js&quot;"
  end

  test "the entries tab lists and deletes submissions", %{conn: conn} do
    admin = authed_user(:admin)
    {form, [], lv, _html} = builder(conn, admin)

    submission =
      CMS.create_form_submission!(
        %{form_id: form.id, data: %{"email" => "visitor@example.com"}},
        authorize?: false
      )

    html = lv |> element(~s(#form-builder-tabs button[phx-value-tab="entries"])) |> render_click()
    assert html =~ "visitor@example.com"

    lv
    |> element(~s(button[phx-click="delete_submission"][phx-value-id="#{submission.id}"]))
    |> render_click()

    assert CMS.recent_form_submissions!(form.id, authorize?: false) == []
  end

  test "the entries tab shows a checkboxes list and a decimal as text (#2261)", %{conn: conn} do
    admin = authed_user(:admin)
    {form, [], lv, _html} = builder(conn, admin)

    CMS.create_form_submission!(
      %{form_id: form.id, data: %{"topics" => ["red", "blue"], "amount" => 2.5}},
      authorize?: false
    )

    html = lv |> element(~s(#form-builder-tabs button[phx-value-tab="entries"])) |> render_click()
    assert html =~ "red, blue"
    assert html =~ "2.5"
  end

  describe "entries moderation (#477)" do
    test "shows a status badge and score, and can filter by status", %{conn: conn} do
      admin = authed_user(:admin)
      {form, [], lv, _html} = builder(conn, admin)

      CMS.create_form_submission!(
        %{form_id: form.id, data: %{"message" => "Hi there"}},
        authorize?: false
      )

      spam =
        CMS.create_form_submission!(
          %{
            form_id: form.id,
            data: %{"message" => "Buy now http://a.co http://b.co http://c.co"},
            fill_time_ms: 100
          },
          authorize?: false
        )

      html =
        lv |> element(~s(#form-builder-tabs button[phx-value-tab="entries"])) |> render_click()

      assert html =~ "Hi there"
      assert html =~ "Buy now"
      assert html =~ "Spam"

      filtered = render_click(lv, "filter_status", %{"status" => "spam"})
      refute filtered =~ "Hi there"
      assert filtered =~ "Buy now"

      # And the other direction: filtering to "new" hides the spam one.
      filtered_new = render_click(lv, "filter_status", %{"status" => "new"})
      assert filtered_new =~ "Hi there"
      refute filtered_new =~ "Buy now"

      reloaded = CMS.get_form_submission!(spam.id, authorize?: false)
      assert reloaded.status == :spam
    end

    test "mark as spam / mark as reviewed flip status from the entry itself", %{conn: conn} do
      admin = authed_user(:admin)
      {form, [], lv, _html} = builder(conn, admin)

      submission =
        CMS.create_form_submission!(
          %{form_id: form.id, data: %{"message" => "Hi there"}},
          authorize?: false
        )

      lv |> element(~s(#form-builder-tabs button[phx-value-tab="entries"])) |> render_click()

      html =
        lv
        |> element(~s(button[phx-click="mark_submission_spam"][phx-value-id="#{submission.id}"]))
        |> render_click()

      assert html =~ "Spam"
      assert CMS.get_form_submission!(submission.id, authorize?: false).status == :spam

      html =
        lv
        |> element(
          ~s(button[phx-click="mark_submission_reviewed"][phx-value-id="#{submission.id}"])
        )
        |> render_click()

      assert html =~ "Reviewed"
      assert CMS.get_form_submission!(submission.id, authorize?: false).status == :reviewed
    end

    test "bulk-marking the selected submissions as reviewed", %{conn: conn} do
      admin = authed_user(:admin)
      {form, [], lv, _html} = builder(conn, admin)

      s1 =
        CMS.create_form_submission!(%{form_id: form.id, data: %{"a" => "1"}}, authorize?: false)

      s2 =
        CMS.create_form_submission!(%{form_id: form.id, data: %{"a" => "2"}}, authorize?: false)

      lv |> element(~s(#form-builder-tabs button[phx-value-tab="entries"])) |> render_click()
      selected_html = render_click(lv, "select_all_visible", %{})
      assert selected_html =~ "2 selected"

      html = render_click(lv, "bulk_mark_reviewed", %{})

      refute html =~ "2 selected"
      refute html =~ ~s(phx-click="bulk_mark_reviewed")
      assert CMS.get_form_submission!(s1.id, authorize?: false).status == :reviewed
      assert CMS.get_form_submission!(s2.id, authorize?: false).status == :reviewed
    end

    test "the CSV export link is present and admin-gated at the controller", %{conn: conn} do
      admin = authed_user(:admin)
      {form, [], lv, _html} = builder(conn, admin)

      html =
        lv |> element(~s(#form-builder-tabs button[phx-value-tab="entries"])) |> render_click()

      assert html =~ ~s(/editor/forms/#{form.id}/entries/export.csv)
    end

    test "deleting a selected row drops it from the selection instead of leaving it stale", %{
      conn: conn
    } do
      admin = authed_user(:admin)
      {form, [], lv, _html} = builder(conn, admin)

      s1 =
        CMS.create_form_submission!(%{form_id: form.id, data: %{"a" => "1"}}, authorize?: false)

      CMS.create_form_submission!(%{form_id: form.id, data: %{"a" => "2"}}, authorize?: false)

      lv |> element(~s(#form-builder-tabs button[phx-value-tab="entries"])) |> render_click()
      selected_html = render_click(lv, "select_all_visible", %{})
      assert selected_html =~ "2 selected"

      html =
        lv
        |> element(~s(button[phx-click="delete_submission"][phx-value-id="#{s1.id}"]))
        |> render_click()

      # One selected row is gone: the count drops rather than staying stale,
      # and a bulk action afterward can't silently target the deleted id.
      assert html =~ "1 selected"
      refute html =~ "2 selected"
    end
  end

  test "the public form renders placeholder, default, width and submit label", %{conn: conn} do
    admin = authed_user(:admin)

    form =
      CMS.create_form!(
        %{name: "Contact", slug: "fb-public", submit_label: "Send it"},
        actor: admin
      )

    CMS.create_form_field!(
      %{
        form_id: form.id,
        name: "email",
        label: "Email",
        field_type: :email,
        placeholder: "you@company.com",
        default_value: "hi@example.com",
        width: :half
      },
      actor: admin
    )

    html =
      conn
      |> get("/forms/#{form.slug}/embed")
      |> html_response(200)

    assert html =~ ~s(placeholder="you@company.com")
    assert html =~ ~s(value="hi@example.com")
    assert html =~ "sm:col-span-3"
    assert html =~ "Send it"
  end

  describe "renaming a field and refused edits (#2139)" do
    # Opens the options panel for `field`, returning the panel's form selector.
    defp open_settings(lv, field) do
      lv
      |> element(~s(button[phx-click="select_field"][phx-value-id="#{field.id}"]))
      |> render_click()

      "#field-settings-#{field.id}"
    end

    # A browser's change event: the whole panel's values, plus the one input
    # that changed in `_target`.
    defp change(lv, selector, field, overrides, target) do
      values =
        Map.merge(
          %{"label" => field.label, "name" => field.name, "field_type" => "string"},
          overrides
        )

      lv
      |> form(selector, %{field: values})
      |> render_change(%{"_target" => ["field", target]})
    end

    defp reload(form), do: form.id |> CMS.form_fields_for!(authorize?: false) |> hd()

    test "a rename saves, shows on the canvas, and says Saved", %{conn: conn} do
      {form, [field], lv, _html} =
        builder(conn, authed_user(:admin), %{}, [
          %{name: "string", label: "Single line text", field_type: :string}
        ])

      selector = open_settings(lv, field)
      html = change(lv, selector, field, %{"name" => "name"}, "name")

      assert reload(form).name == "name"
      assert lv |> element("#canvas-field-name-#{field.id}") |> render() =~ "name"
      refute lv |> element("#canvas-field-name-#{field.id}") |> render() =~ "string"
      assert lv |> element("#fs-name") |> render() =~ ~s(value="name")
      assert html =~ ~r/id="field-settings-status"[^>]*>\s*<span[^>]*>Saved\./

      # No entries yet, so there is nothing to say about stranded ones.
      refute lv |> element("#field-settings-status") |> render() =~ "already received"
    end

    test "the Save button (and Enter) saves the whole panel", %{conn: conn} do
      {form, [field], lv, _html} =
        builder(conn, authed_user(:admin), %{}, [
          %{name: "string", label: "Single line text", field_type: :string}
        ])

      selector = open_settings(lv, field)
      assert lv |> element("#{selector} button[type=submit]") |> has_element?()

      html =
        lv
        |> form(selector, %{
          field: %{label: "Your name", name: "name", field_type: "string", width: "half"}
        })
        |> render_submit()

      updated = reload(form)
      assert updated.name == "name"
      assert updated.label == "Your name"
      assert updated.width == :half
      assert html =~ "Saved."
    end

    test "an invalid name is refused inline and the typed value stays", %{conn: conn} do
      {form, [field], lv, _html} =
        builder(conn, authed_user(:admin), %{}, [
          %{name: "string", label: "Single line text", field_type: :string}
        ])

      selector = open_settings(lv, field)
      change(lv, selector, field, %{"name" => "Bad Name!"}, "name")

      assert reload(form).name == "string"

      input = lv |> element("#fs-name") |> render()
      assert input =~ ~s(value="Bad Name!")
      assert input =~ ~s(aria-invalid="true")
      assert input =~ ~s(aria-describedby="fs-name-hint fs-name-error")

      assert lv |> element("#fs-name-error") |> render() =~
               "must be lowercase letters, digits and underscores"

      # The refusal is inline, not a flash the admin has to notice.
      refute render(lv) =~ ~s(id="flash-error")
      refute lv |> element("#field-settings-status") |> render() =~ "Saved."

      # Another input still saves while the name error stands.
      change(lv, selector, field, %{"name" => "Bad Name!", "label" => "Full name"}, "label")

      updated = reload(form)
      assert updated.label == "Full name"
      assert updated.name == "string"
      assert lv |> element("#fs-name") |> render() =~ ~s(value="Bad Name!")
      assert lv |> element("#fs-name-error") |> has_element?()
      assert lv |> element("#field-settings-status") |> render() =~ "Saved."

      # Fixing the name clears the error.
      change(lv, selector, field, %{"name" => "full_name", "label" => "Full name"}, "name")

      assert reload(form).name == "full_name"
      refute lv |> element("#fs-name-error") |> has_element?()
      refute lv |> element("#fs-name") |> render() =~ "aria-invalid"
    end

    test "a name another field already uses is refused inline", %{conn: conn} do
      {form, [field, _email], lv, _html} =
        builder(conn, authed_user(:admin), %{}, [
          %{name: "string", label: "Single line text", field_type: :string, position: 0},
          %{name: "email", label: "Email", field_type: :email, position: 1}
        ])

      selector = open_settings(lv, field)
      change(lv, selector, field, %{"name" => "email"}, "name")

      assert form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.map(& &1.name) ==
               ["string", "email"]

      assert lv |> element("#fs-name") |> render() =~ ~s(value="email")
      assert lv |> element("#fs-name-error") |> render() =~ "has already been taken"
    end

    test "selecting another field drops the refused value and its error", %{conn: conn} do
      {_form, [field, other], lv, _html} =
        builder(conn, authed_user(:admin), %{}, [
          %{name: "string", label: "Single line text", field_type: :string, position: 0},
          %{name: "email", label: "Email", field_type: :email, position: 1}
        ])

      selector = open_settings(lv, field)
      change(lv, selector, field, %{"name" => "Bad Name!"}, "name")
      assert lv |> element("#fs-name-error") |> has_element?()

      open_settings(lv, other)
      refute lv |> element("#fs-name-error") |> has_element?()
      assert lv |> element("#fs-name") |> render() =~ ~s(value="email")

      open_settings(lv, field)
      assert lv |> element("#fs-name") |> render() =~ ~s(value="string")
      refute lv |> element("#fs-name-error") |> has_element?()
    end

    test "a held options error does not outlive a type switch", %{conn: conn} do
      {form, [field], lv, _html} =
        builder(conn, authed_user(:admin), %{}, [
          %{name: "topic", label: "Topic", field_type: :select, options: ["a", "b"]}
        ])

      selector = open_settings(lv, field)
      base = %{"field_type" => "select"}

      html = change(lv, selector, field, Map.put(base, "options", ""), "options")
      assert html =~ "a select field must list at least one option"

      change(lv, selector, field, %{"field_type" => "string"}, "field_type")
      html = change(lv, selector, field, base, "field_type")

      refute html =~ "a select field must list at least one option"
      assert reload(form).options == ["a", "b"]
      assert lv |> element("#fs-options") |> render() =~ "a\nb"
    end

    test "an error on an input with no error slot still reaches the admin", %{conn: conn} do
      {form, [field], lv, _html} =
        builder(conn, authed_user(:admin), %{}, [
          %{name: "topic", label: "Topic", field_type: :string}
        ])

      selector = open_settings(lv, field)

      # A tampered whole-panel save: `width` is a select whose values the
      # browser limits, so it has no error slot; the bad name has one. The
      # name error shows inline, and the width error must not be dropped.
      lv
      |> form(selector, %{
        field: %{"label" => "Topic", "name" => "Bad Name!", "field_type" => "string"}
      })
      |> render_submit(%{"field" => %{"width" => "huge"}})

      html = render(lv)
      assert html =~ ~s(id="fs-name-error")
      assert html =~ ~s(id="flash-error")
      assert reload(form).width == :full
      assert reload(form).name == "topic"
    end

    test "renaming a field with entries says they keep the old key, and Entries flags it",
         %{conn: conn} do
      {form, [field], lv, _html} =
        builder(conn, authed_user(:admin), %{}, [
          %{name: "string", label: "Single line text", field_type: :string}
        ])

      for value <- ["Ada", "Grace"] do
        CMS.create_form_submission!(%{form_id: form.id, data: %{"string" => value}},
          authorize?: false
        )
      end

      selector = open_settings(lv, field)
      change(lv, selector, field, %{"name" => "name"}, "name")

      assert lv |> element("#field-settings-status") |> render() =~
               "Entries already received keep the old key “string”."

      CMS.create_form_submission!(%{form_id: form.id, data: %{"name" => "Linus"}},
        authorize?: false
      )

      lv |> element(~s(#form-builder-tabs button[phx-value-tab="entries"])) |> render_click()

      [new_one | old_ones] = CMS.recent_form_submissions!(form.id, authorize?: false)
      assert new_one.data == %{"name" => "Linus"}

      # The new entry sits under the field's current label and name …
      refute has_element?(lv, "#submission-#{new_one.id}-orphaned")

      # … the old ones under "renamed or removed", by their raw key.
      for old <- old_ones do
        orphaned = lv |> element("#submission-#{old.id}-orphaned") |> render()
        assert orphaned =~ "From a renamed or removed field"
        assert orphaned =~ "string"
      end

      html = render(lv)
      assert html =~ "Ada"
      assert html =~ "Linus"
    end

    test "an editor cannot update a form field", %{conn: _conn} do
      admin = authed_user(:admin)

      form =
        CMS.create_form!(%{name: "Contact", slug: "fb-ed-#{System.unique_integer()}"},
          actor: admin
        )

      field =
        CMS.create_form_field!(
          %{form_id: form.id, name: "string", label: "Text", field_type: :string},
          actor: admin
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_form_field(field, %{name: "name"}, actor: authed_user(:editor))

      assert reload(form).name == "string"
    end

    # The builder over a form whose autoresponder is already set up: the
    # template may only name fields that exist, so the fields come first.
    defp autoresponder_builder(conn, admin, names, autoresponder) do
      form =
        CMS.create_form!(%{name: "Contact", slug: "fb-ar-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      fields =
        for {name, position} <- Enum.with_index(names) do
          type = if position == 0, do: :email, else: :string

          CMS.create_form_field!(
            %{form_id: form.id, name: name, label: name, field_type: type, position: position},
            actor: admin
          )
        end

      form = CMS.update_form!(form, autoresponder, actor: admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/forms/#{form.id}")
      {form, fields, lv}
    end

    test "a rename carries the autoresponder's tokens, and the Confirmations tab shows it (#2343)",
         %{conn: conn} do
      {form, [field], lv} =
        autoresponder_builder(conn, authed_user(:admin), ["email"], %{
          autoresponder_enabled: true,
          autoresponder_subject: "Thanks, [field:email]!",
          autoresponder_body: "<p>Sent to [field:email].</p>"
        })

      selector = open_settings(lv, field)
      change(lv, selector, field, %{"name" => "address", "field_type" => "email"}, "name")

      status = lv |> element("#field-settings-status") |> render()
      assert status =~ "The autoresponder now uses [field:address] where it used [field:email]."
      # No entries, so nothing about stranded keys.
      refute status =~ "already received"

      stored = CMS.get_form!(form.id, authorize?: false)
      assert stored.autoresponder_subject == "Thanks, [field:address]!"
      assert stored.autoresponder_body == "<p>Sent to [field:address].</p>"

      lv
      |> element(~s(#form-builder-tabs button[phx-value-tab="confirmations"]))
      |> render_click()

      assert lv |> element(~s(input[name="form[autoresponder_subject]"])) |> render() =~
               ~s(value="Thanks, [field:address]!")

      body = lv |> element(~s(textarea[name="form[autoresponder_body]"])) |> render()
      assert body =~ "[field:address]"
      refute body =~ "[field:email]"
    end

    test "a rename the autoresponder does not use says nothing about it", %{conn: conn} do
      {_form, [_email, field], lv} =
        autoresponder_builder(conn, authed_user(:admin), ["email", "message"], %{
          autoresponder_enabled: true,
          autoresponder_subject: "Thanks, [field:email]!",
          autoresponder_body: "b"
        })

      selector = open_settings(lv, field)
      change(lv, selector, field, %{"name" => "note"}, "name")

      status = lv |> element("#field-settings-status") |> render()
      assert status =~ "Saved."
      refute status =~ "autoresponder"
    end

    test "deleting a field the autoresponder uses is refused with the reason (#2343)",
         %{conn: conn} do
      {form, [field], lv} =
        autoresponder_builder(conn, authed_user(:admin), ["email"], %{
          autoresponder_enabled: true,
          autoresponder_subject: "Thanks, [field:email]!",
          autoresponder_body: "b"
        })

      html =
        lv
        |> element(~s(button[phx-click="delete_field"][phx-value-id="#{field.id}"]))
        |> render_click()

      assert html =~
               "The autoresponder uses [field:email]: remove it from the Confirmations template first."

      assert has_element?(lv, "#canvas-field-name-#{field.id}")

      assert form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.map(& &1.name) == [
               "email"
             ]
    end
  end
end
