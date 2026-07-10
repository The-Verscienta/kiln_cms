defmodule KilnCMSWeb.FormLiveTest do
  @moduledoc """
  The form builder (`/editor/forms`, admin-only): create a form, add fields,
  review + delete submissions.
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

  test "admin builds a form end to end: create, add a field, see a submission", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/forms")

    slug = "fl-#{System.unique_integer([:positive])}"

    # Create — the new form's detail panel opens.
    html =
      lv
      |> form("form[phx-submit=create_form]", %{form: %{name: "Contact", slug: slug}})
      |> render_submit()

    assert html =~ "add its fields below"
    assert [created] = CMS.list_forms!(authorize?: false, query: [filter: [slug: slug]])

    # Add a field.
    html =
      lv
      |> form("form[phx-submit=add_field]", %{
        field: %{
          label: "Email",
          name: "email",
          field_type: "email",
          required: "true",
          options: ""
        }
      })
      |> render_submit()

    assert html =~ "email"
    assert [field] = CMS.form_fields_for!(created.id, authorize?: false)
    assert field.field_type == :email
    assert field.required

    # A submission arrives and shows up in the viewer.
    submission =
      CMS.create_form_submission!(
        %{form_id: created.id, data: %{"email" => "visitor@example.com"}},
        authorize?: false
      )

    html = lv |> element("button[phx-click=select_form]") |> render_click()
    assert html =~ "visitor@example.com"

    # And can be deleted.
    lv
    |> element(~s(button[phx-click="delete_submission"][phx-value-id="#{submission.id}"]))
    |> render_click()

    assert CMS.recent_form_submissions!(created.id, authorize?: false) == []
  end

  test "the selected form shows a copyable embed snippet", %{conn: conn} do
    admin = authed_user(:admin)

    form =
      CMS.create_form!(%{name: "Contact", slug: "embed-snippet"}, actor: admin)

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/forms")
    html = lv |> element("button[phx-click=select_form]") |> render_click()

    assert html =~ "Embed on another site"
    assert html =~ "/embed.js"
    # The snippet sits in a readonly input's value, so its quotes are escaped.
    assert html =~ "data-kiln-form=&quot;#{form.slug}&quot;"

    # Clicking Copy (via the Clipboard hook) flashes a confirmation.
    assert lv |> render_hook("copied", %{}) =~ "Embed code copied to clipboard."
  end
end
