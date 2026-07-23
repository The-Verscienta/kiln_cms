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

  test "creating from a template lands in the builder with the fields seeded", %{conn: conn} do
    {:ok, lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/forms")

    # The picker lists the blank card plus the built-in templates.
    assert html =~ "Blank form"
    assert html =~ "Contact form"
    assert html =~ "Newsletter signup"

    slug = "fl-tmpl-#{System.unique_integer([:positive])}"

    lv
    |> element(~s(button[phx-click="pick_template"][phx-value-key="contact"]))
    |> render_click()

    lv
    |> form("form[phx-submit=create_form]", %{form: %{name: "Say hi", slug: slug}})
    |> render_submit()

    assert [created] = CMS.list_forms!(authorize?: false, query: [filter: [slug: slug]])
    {path, _flash} = assert_redirect(lv)
    assert path == "/editor/forms/#{created.id}"

    names =
      created.id
      |> CMS.form_fields_for!(authorize?: false)
      |> Enum.map(& &1.name)

    assert names == ["full_name", "email", "subject", "message"]
    assert created.submit_label == "Send message"
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
        %{name: "Contact", slug: "fl-dup", success_message: "Merci!", submit_label: "Send"},
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
end
