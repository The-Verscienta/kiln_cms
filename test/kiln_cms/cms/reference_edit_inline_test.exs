defmodule KilnCMS.CMS.ReferenceEditInlineTest do
  @moduledoc """
  A field definition's `edit_inline` flag (#2283): a nullable boolean that only
  a top-level `:reference` may carry, cleared on any other type, with off stored
  as nil, round-tripped through the field sync file and reported to clients as
  `x-kiln-edit-inline`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldSync

  defp admin do
    Ash.Seed.seed!(User, %{
      email: "ei-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp field!(actor, attrs) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: "ei_#{System.unique_integer([:positive])}",
          label: "Linked",
          field_type: :reference,
          target_type: "page"
        },
        attrs
      ),
      actor: actor
    )
  end

  test "is stored on a top-level reference, and off is nil" do
    actor = admin()

    assert field!(actor, %{edit_inline: true}).edit_inline == true
    assert field!(actor, %{edit_inline: false}).edit_inline == nil
    assert field!(actor, %{}).edit_inline == nil
  end

  test "an update can turn it off, and the off is nil" do
    actor = admin()
    field = field!(actor, %{edit_inline: true})

    assert CMS.update_field_definition!(field, %{edit_inline: false}, actor: actor).edit_inline ==
             nil
  end

  test "is cleared when the field stops being a reference" do
    actor = admin()
    field = field!(actor, %{edit_inline: true})

    retyped =
      CMS.update_field_definition!(field, %{field_type: :string, target_type: nil}, actor: actor)

    assert retyped.edit_inline == nil

    assert field!(actor, %{field_type: :string, target_type: nil, edit_inline: true}).edit_inline ==
             nil
  end

  test "is refused on a reference that is a sub-field of a group" do
    actor = admin()
    group = field!(actor, %{field_type: :group, target_type: nil})

    assert {:error, error} =
             CMS.create_field_definition(
               %{
                 content_type: :post,
                 name: "ei_sub",
                 label: "Sub",
                 field_type: :reference,
                 target_type: "page",
                 group_of_id: group.id,
                 edit_inline: true
               },
               actor: actor
             )

    assert Exception.message(error) =~ "only for a reference field of the record itself"
  end

  test "is part of the field sync file and round-trips" do
    actor = admin()
    field = field!(actor, %{edit_inline: true})

    assert {:ok, doc} = FieldSync.export(actor: actor)
    json = Jason.encode!(doc)
    assert json =~ ~s("edit_inline":true)

    CMS.destroy_field_definition!(field, actor: actor)
    assert {:ok, _report} = FieldSync.import_doc(Jason.decode!(json), actor: actor, apply?: true)

    restored =
      :post |> CMS.field_definitions_for!(actor: actor) |> Enum.find(&(&1.name == field.name))

    assert restored.edit_inline == true
  end
end
