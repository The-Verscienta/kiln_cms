defmodule KilnCMS.Forms.ReservedFieldNameTest do
  @moduledoc """
  `KilnCMS.CMS.Validations.ReservedFieldName`: no form field of any type may
  take a reserved name — the honeypot's (#2267) or `locale` (#2716) — on
  create, rename or retype, while a field that already carries one keeps its
  other edits. The refusal says why, per name.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FormField
  alias KilnCMS.Forms

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rf-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp form!(admin) do
    CMS.create_form!(%{name: "T", slug: "rf-#{System.unique_integer([:positive])}"},
      actor: admin
    )
  end

  # Valid attributes for each type, so a refusal can only be the name.
  defp type_attrs(type) when type in [:select, :radio, :checkboxes],
    do: %{field_type: type, options: ["a", "b"]}

  defp type_attrs(type), do: %{field_type: type}

  defp refused_on_name?({:error, %Ash.Error.Invalid{errors: errors}}),
    do: Enum.any?(errors, &(Map.get(&1, :field) == :name))

  defp refused_on_name?(_result), do: false

  defp name_error({:error, %Ash.Error.Invalid{errors: errors}}),
    do: Enum.find_value(errors, &(Map.get(&1, :field) == :name && &1.message))

  defp name_error(_result), do: nil

  defp fields(form), do: CMS.form_fields_for!(form.id, authorize?: false)

  # A row from before the rule: the create action now refuses it, so it is
  # written underneath the actions.
  defp legacy_field!(form, name \\ Forms.honeypot_field()) do
    Ash.Seed.seed!(FormField, %{
      form_id: form.id,
      name: name,
      label: "Legacy",
      field_type: :string,
      position: 0
    })
  end

  test "the honeypot's name and locale are reserved" do
    assert Forms.reserved_field_names() == [Forms.honeypot_field(), "locale"]
    assert Forms.reserved_field_name?("website")
    assert Forms.reserved_field_name?("locale")
    refute Forms.reserved_field_name?("website_2")
    refute Forms.reserved_field_name?("locale_2")
    refute Forms.reserved_field_name?("Locale")
    refute Forms.reserved_field_name?(nil)
  end

  test "each reserved name has its reason" do
    assert Forms.reserved_field_reason("website") == :honeypot
    assert Forms.reserved_field_reason("locale") == :locale
    assert Forms.reserved_field_reason("email") == nil
    assert Forms.reserved_field_reason(nil) == nil
  end

  test "creating a field named like the honeypot is refused on every type" do
    admin = user(:admin)
    form = form!(admin)

    for type <- FormField.field_types() do
      result =
        type
        |> type_attrs()
        |> Map.merge(%{form_id: form.id, name: "website", label: "W"})
        |> CMS.create_form_field(actor: admin)

      assert name_error(result) == "is reserved for spam protection",
             "#{type}: #{inspect(result)}"
    end

    assert fields(form) == []
  end

  test "creating a field named locale is refused on every type, saying why" do
    admin = user(:admin)
    form = form!(admin)

    for type <- FormField.field_types() do
      result =
        type
        |> type_attrs()
        |> Map.merge(%{form_id: form.id, name: "locale", label: "Language"})
        |> CMS.create_form_field(actor: admin)

      assert name_error(result) == "is reserved for the submission's language",
             "#{type}: #{inspect(result)}"
    end

    assert fields(form) == []
  end

  test "renaming a field to locale is refused and leaves the name" do
    admin = user(:admin)
    form = form!(admin)

    field =
      CMS.create_form_field!(%{form_id: form.id, name: "language", label: "Language"},
        actor: admin
      )

    assert name_error(CMS.update_form_field(field, %{name: "locale"}, actor: admin)) ==
             "is reserved for the submission's language"

    assert [%{name: "language"}] = fields(form)
  end

  test "renaming a field to the honeypot's name is refused and leaves the name" do
    admin = user(:admin)
    form = form!(admin)

    field =
      CMS.create_form_field!(%{form_id: form.id, name: "site", label: "Site"}, actor: admin)

    assert refused_on_name?(CMS.update_form_field(field, %{name: "website"}, actor: admin))
    assert [%{name: "site"}] = fields(form)
  end

  describe "a field that already carries the name" do
    setup do
      admin = user(:admin)
      form = form!(admin)
      %{admin: admin, form: form, field: legacy_field!(form)}
    end

    test "a label edit saves", %{admin: admin, field: field} do
      assert {:ok, %{label: "Homepage"}} =
               CMS.update_form_field(field, %{label: "Homepage"}, actor: admin)
    end

    test "a position edit saves (reorder)", %{admin: admin, field: field} do
      assert {:ok, %{position: 3}} = CMS.update_form_field(field, %{position: 3}, actor: admin)
    end

    test "a whole-panel save that carries the unchanged name saves",
         %{admin: admin, field: field} do
      assert {:ok, updated} =
               CMS.update_form_field(
                 field,
                 %{name: "website", label: "Homepage", field_type: :string, required: true},
                 actor: admin
               )

      assert {updated.name, updated.label, updated.required} == {"website", "Homepage", true}
    end

    test "a retype is refused", %{admin: admin, form: form, field: field} do
      assert refused_on_name?(CMS.update_form_field(field, %{field_type: :url}, actor: admin))
      assert [%{field_type: :string}] = fields(form)
    end

    test "a rename away saves, and renaming back is refused",
         %{admin: admin, form: form, field: field} do
      assert {:ok, renamed} = CMS.update_form_field(field, %{name: "site_url"}, actor: admin)
      assert refused_on_name?(CMS.update_form_field(renamed, %{name: "website"}, actor: admin))
      assert [%{name: "site_url"}] = fields(form)
    end
  end

  describe "a field that already carries the name locale" do
    setup do
      admin = user(:admin)
      form = form!(admin)
      %{admin: admin, form: form, field: legacy_field!(form, "locale")}
    end

    test "a label edit saves", %{admin: admin, field: field} do
      assert {:ok, %{label: "Language"}} =
               CMS.update_form_field(field, %{label: "Language"}, actor: admin)
    end

    test "a retype is refused, saying why", %{admin: admin, form: form, field: field} do
      assert name_error(CMS.update_form_field(field, %{field_type: :text}, actor: admin)) ==
               "is reserved for the submission's language"

      assert [%{field_type: :string}] = fields(form)
    end

    test "a rename away saves, and renaming back is refused",
         %{admin: admin, form: form, field: field} do
      assert {:ok, renamed} = CMS.update_form_field(field, %{name: "language"}, actor: admin)
      assert refused_on_name?(CMS.update_form_field(renamed, %{name: "locale"}, actor: admin))
      assert [%{name: "language"}] = fields(form)
    end
  end

  describe "an actor who may not write fields" do
    test "is refused by the policy, whatever the name" do
      admin = user(:admin)
      form = form!(admin)

      for actor <- [user(:editor), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.create_form_field(%{form_id: form.id, name: "email", label: "E"},
                   actor: actor
                 )
      end

      assert fields(form) == []
    end

    # Ash validates a create before it authorizes it, so the reserved name may
    # answer first; either way nothing is written.
    test "using the reserved name writes nothing" do
      admin = user(:admin)
      form = form!(admin)

      assert {:error, _error} =
               CMS.create_form_field(%{form_id: form.id, name: "website", label: "W"},
                 actor: user(:editor)
               )

      assert fields(form) == []
    end
  end

  describe "unique_field_name/2" do
    test "never hands back a reserved name" do
      assert Forms.unique_field_name("website", []) == "website_2"
      assert Forms.unique_field_name("website", [%{name: "website_2"}]) == "website_3"
      assert Forms.unique_field_name("email", [%{name: "email"}]) == "email_2"
      assert Forms.unique_field_name("email", []) == "email"
      assert Forms.unique_field_name("locale", []) == "locale_2"
      assert Forms.unique_field_name("locale", [%{name: "locale_2"}]) == "locale_3"
    end
  end
end
