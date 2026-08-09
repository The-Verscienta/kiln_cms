defmodule KilnCMS.CMS.FieldTypeTokensTest do
  @moduledoc """
  A custom field type contributing its own slug/alias tokens, end to end (#804).

  `c:Kiln.FieldType.tokens/1` shipped with #468 and nothing called it — the
  callback defaulted to `[]` and `KilnCMS.Slug.Pattern` never asked. The blocker
  named in its own docs was that the pattern engine's context carries a custom
  field's *value* but not which type produced it; the lookup that closes that is
  `KilnCMS.CMS.Slugs.type_token_definitions/1`, driven off the same
  `FieldDefinition` rows the computed-field path already reads.

  What is exercised here is the real chain: a type definition, a
  `FieldDefinition` naming a **plugin** field type, that type's `tokens/1`, and a
  slug derived by the ordinary write path.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ftt-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # `:rating` is `KilnCMS.FixturePlugin.FieldTypes.Rating`, which declares a
  # `[field:<name>.word]` token — a value derived from the stored one, which is
  # exactly what the generic `[field:<name>]` path cannot produce.
  # The field is created BEFORE the pattern names its token, deliberately: until
  # the field exists nothing in the system claims `[field:rating.word]`, and
  # "unknown token" is the truthful answer. See the validation's moduledoc.
  defp rated_type!(actor, pattern) do
    type =
      CMS.create_type_definition!(
        %{name: "rated#{System.unique_integer([:positive])}", label: "Rated"},
        actor: actor
      )

    CMS.create_field_definition!(
      %{type_definition_id: type.id, name: "rating", label: "Rating", field_type: :rating},
      actor: actor
    )

    if pattern do
      CMS.update_type_definition!(type, %{slug_pattern: pattern}, actor: actor)
    else
      type
    end
  end

  test "a type-declared token expands in a derived slug" do
    actor = admin()
    type = rated_type!(actor, "[title]-[field:rating.word]")

    entry =
      ContentTypes.create!(
        type.name,
        %{title: "Kiln Guide", custom_fields: %{"rating" => 3}},
        actor: actor
      )

    assert entry.slug == "kiln-guide-three"
  end

  # The generic path is untouched and still free: a scalar value slugifies
  # without any type involvement.
  test "the generic field token still works alongside it" do
    actor = admin()
    type = rated_type!(actor, "[title]-[field:rating]-[field:rating.word]")

    entry =
      ContentTypes.create!(
        type.name,
        %{title: "Guide", custom_fields: %{"rating" => 5}},
        actor: actor
      )

    assert entry.slug == "guide-5-five"
  end

  # A token no definition claims expands empty rather than raising or leaving
  # brackets in a URL — the same answer `Kiln.Tokens` gives any unmatched token.
  # Reachable at expansion time even though save-time validation rejects such a
  # pattern: a field can be DELETED after the pattern was saved, and the slug
  # derivation on the next write must not blow up over it.
  test "a token whose field has since been removed expands empty" do
    actor = admin()
    type = rated_type!(actor, "[title]-[field:rating.word]")

    [rating] =
      type.id
      |> CMS.field_definitions_for_definition!(authorize?: false)
      |> Enum.filter(&(&1.name == "rating"))

    CMS.destroy_field_definition!(rating, actor: actor)

    entry =
      ContentTypes.create!(type.name, %{title: "Guide"}, actor: actor)

    assert entry.slug == "guide"
  end

  # The save-time half. A pattern naming a token no field claims must still be
  # rejected — that is what stops `[titel]` reaching production.
  describe "save-time validation" do
    test "accepts a token the type's own field declares" do
      actor = admin()
      type = rated_type!(actor, nil)

      assert {:ok, updated} =
               CMS.update_type_definition(
                 type,
                 %{slug_pattern: "[title]-[field:rating.word]"},
                 actor: actor
               )

      assert updated.slug_pattern == "[title]-[field:rating.word]"
    end

    test "still rejects a typo" do
      actor = admin()
      type = rated_type!(actor, nil)

      assert {:error, error} =
               CMS.update_type_definition(type, %{slug_pattern: "[titel]"}, actor: actor)

      assert Exception.message(error) =~ "unknown token"
    end

    test "rejects a type token no field on this type claims" do
      actor = admin()
      type = rated_type!(actor, nil)

      assert {:error, _error} =
               CMS.update_type_definition(
                 type,
                 %{slug_pattern: "[field:rating.colour]"},
                 actor: actor
               )
    end
  end

  describe "type_token_definitions/1" do
    test "collects from a plugin type and ignores core ones" do
      actor = admin()
      type = rated_type!(actor, nil)

      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "servings", label: "Servings", field_type: :integer},
        actor: actor
      )

      definitions = CMS.field_definitions_for_definition!(type.id, authorize?: false)

      # `:integer` is a core type with no module at all; only `:rating`
      # contributes.
      assert [%{match: %Regex{}}] = Slugs.type_token_definitions(definitions)
    end

    test "a type that declares nothing contributes nothing" do
      actor = admin()

      type =
        CMS.create_type_definition!(
          %{name: "plain#{System.unique_integer([:positive])}", label: "Plain"},
          actor: actor
        )

      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "size", label: "Size", field_type: :text},
        actor: actor
      )

      definitions = CMS.field_definitions_for_definition!(type.id, authorize?: false)

      assert Slugs.type_token_definitions(definitions) == []
    end
  end
end
