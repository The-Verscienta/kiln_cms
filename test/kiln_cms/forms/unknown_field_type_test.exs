defmodule KilnCMS.Forms.UnknownFieldTypeTest do
  @moduledoc """
  A form field whose `field_type` this release doesn't know (#2262): a newer
  release's type, read during a rolling deploy or after a rollback.
  `FormField.field_type` is a `KilnCMS.Types.KnownAtom`, so the row loads as
  a `KilnCMS.Types.UnknownAtom` instead of failing every read of the form,
  and every reader skips it (`KilnCMS.Forms.known_fields/1`).

  A write can't produce one, so the type is set with raw SQL
  (`KilnCMS.NewerReleaseRows`), the way the newer release stored it.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Forms
  alias KilnCMS.NewerReleaseRows
  alias KilnCMS.Types.UnknownAtom
  alias KilnCMSWeb.BlockComponents

  @password "password123456"

  defp admin do
    email = "unknown-form-type-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  setup do
    admin = admin()

    form =
      CMS.create_form!(
        %{
          name: "Contact",
          slug: "unknown-type-#{System.unique_integer([:positive])}",
          active: true
        },
        actor: admin
      )

    email =
      CMS.create_form_field!(
        %{
          form_id: form.id,
          name: "email",
          label: "Email",
          field_type: :email,
          required: true,
          position: 0
        },
        actor: admin
      )

    signature =
      CMS.create_form_field!(
        %{
          form_id: form.id,
          name: "signature",
          label: "Signature",
          field_type: :string,
          required: true,
          position: 1
        },
        actor: admin
      )

    NewerReleaseRows.form_field_type!(signature.id)

    %{admin: admin, form: form, email: email, signature: signature}
  end

  test "the form still loads, with the row as an UnknownAtom", %{form: form} do
    loaded = Forms.get_active(form.slug)

    assert %UnknownAtom{value: value} =
             Enum.find(loaded.fields, &(&1.name == "signature")).field_type

    assert value == NewerReleaseRows.unknown()
    assert Enum.map(Forms.known_fields(loaded.fields), & &1.name) == ["email"]
  end

  test "a submission skips it: not required, and a value sent for it is dropped", %{form: form} do
    loaded = Forms.get_active(form.slug)

    assert {:ok, submission} =
             Forms.submit(loaded, %{"email" => "ada@example.com", "signature" => "x"})

    assert submission.data == %{"email" => "ada@example.com"}
  end

  test "the public form doesn't draw it", %{form: form} do
    html = render_component(&BlockComponents.public_form/1, form: Forms.get_active(form.slug))
    assert html =~ ~s(name="email")
    refute html =~ "signature"
  end

  test "the headless schema leaves it out", %{conn: conn, form: form} do
    body = conn |> get("/api/forms/#{form.slug}") |> json_response(200)
    assert Enum.map(body["fields"], & &1["name"]) == ["email"]
  end

  test "the CSV export gives it no column of its own", %{conn: conn, admin: admin, form: form} do
    conn = conn |> log_in(admin) |> get(~p"/editor/forms/#{form.id}/entries/export.csv")
    assert conn.resp_body =~ "email,status,spam_score,submitted_at\r\n"
  end

  test "the autoresponder offers no token for it", %{form: form} do
    names =
      form.id
      |> CMS.form_fields_for!(authorize?: false)
      |> Forms.Autoresponder.definitions("Contact", false)
      |> Kiln.Tokens.names()

    assert "field:email" in names
    refute "field:signature" in names
  end

  test "a duplicate leaves it out", %{admin: admin, form: form} do
    assert {:ok, %{copy: copy}} = Forms.Duplicate.run(form, actor: admin)
    assert Enum.map(CMS.form_fields_for!(copy.id, authorize?: false), & &1.name) == ["email"]
  end

  test "the builder leaves it off the canvas and keeps its name taken", %{
    conn: conn,
    admin: admin,
    form: form,
    email: email,
    signature: signature
  } do
    {:ok, view, html} = conn |> log_in(admin) |> live(~p"/editor/forms/#{form.id}")
    assert html =~ "canvas-field-name-#{email.id}"
    refute html =~ "canvas-field-name-#{signature.id}"

    view |> element("button[phx-value-type=string]") |> render_click()

    names =
      form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.map(& &1.name) |> Enum.sort()

    assert names == ["email", "signature", "string"]
  end

  test "a label edit or a delete of a known field still works beside it", %{
    admin: admin,
    email: email
  } do
    assert {:ok, _} = CMS.update_form_field(email, %{label: "Your email"}, actor: admin)
    assert :ok = CMS.destroy_form_field(email, actor: admin)
  end
end
