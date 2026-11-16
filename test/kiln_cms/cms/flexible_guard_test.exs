defmodule KilnCMS.CMS.FlexibleGuardTest do
  @moduledoc """
  `Validations.ItemTypeInUse` fails closed (#2282): only an owner that is
  genuinely gone lets an item type's destroy through unguarded; a chain it
  cannot verify (no table for the owner, past the depth cap) refuses.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "flexg-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # Seeded, so the write-time validations that would stop a malformed chain
  # (an unregistered owner, one past the depth cap) do not run.
  defp seed!(attrs),
    do: Ash.Seed.seed!(FieldDefinition, Map.merge(%{label: "Field"}, attrs))

  defp name, do: "g#{System.unique_integer([:positive])}"

  test "an item type whose owner has no table is refused, not passed" do
    flexible = seed!(%{name: name(), field_type: :flexible, content_type: :no_such_type})
    item = seed!(%{name: "hero", field_type: :group, flex_of_id: flexible.id})

    assert {:error, error} = CMS.destroy_field_definition(item, actor: admin())
    assert Exception.message(error) =~ "could not be checked"
    assert CMS.get_field_definition!(item.id, actor: admin())
  end

  test "purge_items? still removes an item type that could not be verified" do
    flexible = seed!(%{name: name(), field_type: :flexible, content_type: :no_such_type})
    item = seed!(%{name: "hero", field_type: :group, flex_of_id: flexible.id})

    assert :ok = CMS.destroy_field_definition(item, %{purge_items?: true}, actor: admin())
  end

  test "an item type whose chain is past the depth cap is refused" do
    # max_flexible_depth + 1 flexible fields, each inside an item of the last
    top = seed!(%{name: name(), field_type: :flexible, content_type: :post})

    innermost =
      Enum.reduce(1..FieldDefinition.max_flexible_depth(), top, fn _level, flexible ->
        item = seed!(%{name: "item", field_type: :group, flex_of_id: flexible.id})
        seed!(%{name: name(), field_type: :flexible, group_of_id: item.id})
      end)

    deepest = seed!(%{name: "deepest", field_type: :group, flex_of_id: innermost.id})

    assert {:error, error} = CMS.destroy_field_definition(deepest, actor: admin())
    assert Exception.message(error) =~ "could not be checked"
  end
end
