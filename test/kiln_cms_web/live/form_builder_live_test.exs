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

    assert {:error, {:redirect, %{to: "/"}}} =
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

    lv |> element(~s(nav button[phx-value-tab="general"])) |> render_click()

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

  test "the embed tab shows a copyable snippet", %{conn: conn} do
    {form, [], lv, _html} = builder(conn, authed_user(:admin))

    html = lv |> element(~s(nav button[phx-value-tab="embed"])) |> render_click()

    assert html =~ "/embed.js"
    assert html =~ "data-kiln-form=&quot;#{form.slug}&quot;"
    assert lv |> render_hook("copied", %{}) =~ "Embed code copied to clipboard."
  end

  test "the entries tab lists and deletes submissions", %{conn: conn} do
    admin = authed_user(:admin)
    {form, [], lv, _html} = builder(conn, admin)

    submission =
      CMS.create_form_submission!(
        %{form_id: form.id, data: %{"email" => "visitor@example.com"}},
        authorize?: false
      )

    html = lv |> element(~s(nav button[phx-value-tab="entries"])) |> render_click()
    assert html =~ "visitor@example.com"

    lv
    |> element(~s(button[phx-click="delete_submission"][phx-value-id="#{submission.id}"]))
    |> render_click()

    assert CMS.recent_form_submissions!(form.id, authorize?: false) == []
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
end
