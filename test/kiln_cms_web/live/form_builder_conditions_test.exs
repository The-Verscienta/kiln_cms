defmodule KilnCMSWeb.FormBuilderConditionsTest do
  @moduledoc """
  The form builder's "Conditional logic" section (#2262): building a field's
  condition from earlier fields only, the canvas badge, and what the builder
  says when the resource refuses a delete, a reorder, or carries a rename
  into other fields' rules.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "fbc-#{System.unique_integer([:positive])}@example.com"

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

  setup %{conn: conn} do
    admin = authed_user(:admin)

    form =
      CMS.create_form!(%{name: "Contact", slug: "fbc-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    field = fn name, position, attrs ->
      CMS.create_form_field!(
        Map.merge(
          %{
            form_id: form.id,
            name: name,
            label: String.capitalize(name),
            field_type: :string,
            position: position
          },
          attrs
        ),
        actor: admin
      )
    end

    topic = field.("topic", 0, %{field_type: :select, options: ["Sales", "Other"]})
    details = field.("details", 1, %{})
    later = field.("later", 2, %{})

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/forms/#{form.id}")
    %{admin: admin, form: form, lv: lv, topic: topic, details: details, later: later}
  end

  defp stored(field),
    do:
      field.form_id |> CMS.form_fields_for!(authorize?: false) |> Enum.find(&(&1.id == field.id))

  defp select(lv, field),
    do:
      lv
      |> element("button[phx-value-id='#{field.id}'][phx-click=select_field]")
      |> render_click()

  test "a condition offers only the fields before this one", %{lv: lv, details: details} do
    select(lv, details)
    lv |> element("#field-condition-#{details.id} button", "Add a condition") |> render_click()

    options = lv |> element("#fs-condition-field-0") |> render()
    assert options =~ ~s(value="topic")
    refute options =~ ~s(value="later")
    refute options =~ ~s(value="details")

    # A choice field's value is one of its options.
    assert lv |> element("#fs-condition-value-0") |> render() =~ ~s(value="Other")

    assert stored(details).condition.rule == %{
             "field" => "topic",
             "op" => "eq",
             "value" => "Sales"
           }
  end

  test "the first field has nothing to depend on", %{lv: lv, topic: topic} do
    select(lv, topic)
    assert render(lv) =~ "Add a field above this one first"
    refute has_element?(lv, "#field-condition-#{topic.id} button", "Add a condition")
  end

  test "editing a row saves it, and the canvas says the field is conditional", %{
    lv: lv,
    details: details
  } do
    select(lv, details)
    lv |> element("#field-condition-#{details.id} button", "Add a condition") |> render_click()

    lv
    |> form("#field-condition-form-#{details.id}", %{
      "condition" => %{
        "action" => "hide",
        "mode" => "all",
        "rows" => %{"0" => %{"field" => "topic", "op" => "eq", "value" => "Other"}}
      }
    })
    |> render_change()

    assert stored(details).condition.action == :hide

    assert stored(details).condition.rule == %{
             "field" => "topic",
             "op" => "eq",
             "value" => "Other"
           }

    assert has_element?(lv, "#canvas-field-condition-#{details.id}", "Hidden when…")
  end

  test "operators are filtered by the type of the field they test", %{lv: lv, details: details} do
    select(lv, details)
    lv |> element("#field-condition-#{details.id} button", "Add a condition") |> render_click()
    ops = lv |> element("#fs-condition-op-0") |> render()
    assert ops =~ ~s(value="contains")
    refute ops =~ ~s(value="gt")
  end

  test "removing the condition clears it", %{lv: lv, details: details} do
    select(lv, details)
    lv |> element("#field-condition-#{details.id} button", "Add a condition") |> render_click()
    lv |> element("#field-condition-#{details.id} button", "Remove condition") |> render_click()

    assert stored(details).condition == nil
    refute has_element?(lv, "#canvas-field-condition-#{details.id}")
  end

  test "deleting a field a condition names is refused with the reason", %{
    lv: lv,
    details: details,
    topic: topic
  } do
    select(lv, details)
    lv |> element("#field-condition-#{details.id} button", "Add a condition") |> render_click()

    html =
      lv
      |> element("button[phx-click=delete_field][phx-value-id='#{topic.id}']")
      |> render_click()

    assert html =~ "is used in the conditions of “Details”"
    assert stored(topic)
  end

  test "a reorder that would put a dependent first is refused, naming both", %{
    lv: lv,
    details: details,
    topic: topic,
    later: later
  } do
    select(lv, details)
    lv |> element("#field-condition-#{details.id} button", "Add a condition") |> render_click()

    html = render_hook(lv, "reorder", %{"order" => [details.id, topic.id, later.id]})
    assert html =~ "nothing was moved"
    assert html =~ "“Details” is shown based on “Topic”, which would come after it"
    assert stored(topic).position == 0
  end

  test "renaming a field says whose conditions now use the new name", %{
    lv: lv,
    details: details,
    topic: topic
  } do
    select(lv, details)
    lv |> element("#field-condition-#{details.id} button", "Add a condition") |> render_click()
    select(lv, topic)

    html =
      lv
      |> form("#field-settings-#{topic.id}", %{"field" => %{"name" => "subject"}})
      |> render_change(%{"_target" => ["field", "name"]})

    assert html =~ "Conditions on “Details” now use subject."
    assert stored(details).condition.rule["field"] == "subject"
  end

  test "a field retyped to hidden loses its condition", %{lv: lv, details: details} do
    select(lv, details)
    lv |> element("#field-condition-#{details.id} button", "Add a condition") |> render_click()

    lv
    |> form("#field-settings-#{details.id}", %{"field" => %{"field_type" => "hidden"}})
    |> render_change(%{"_target" => ["field", "field_type"]})

    assert stored(details).field_type == :hidden
    assert stored(details).condition == nil
    refute has_element?(lv, "#field-condition-#{details.id}")
  end

  test "a rule an older release left dangling is flagged on the canvas", %{
    form: form,
    admin: admin,
    details: details
  } do
    KilnCMS.Repo.query!("UPDATE form_fields SET condition = $1 WHERE id = $2", [
      %{"action" => "show", "rule" => %{"field" => "gone", "op" => "not_empty"}},
      Ecto.UUID.dump!(details.id)
    ])

    {:ok, lv, _html} = build_conn() |> log_in(admin) |> live(~p"/editor/forms/#{form.id}")

    assert has_element?(
             lv,
             "#canvas-field-condition-#{details.id}",
             "Condition names a removed field"
           )

    select(lv, details)
    assert has_element?(lv, "#fs-condition-note")
    lv |> element("#field-condition-#{details.id} button", "Remove condition") |> render_click()
    assert stored(details).condition == nil
  end
end
