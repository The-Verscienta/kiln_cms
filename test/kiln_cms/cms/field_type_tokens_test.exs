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

  # The shipped composite. #804's own motivating example is `[field:location.lat]`,
  # and until the review it was cited in four docstrings while no in-tree type
  # implemented the callback — so on a real install the token was still
  # rejected at save time.
  describe "the shipped geolocation type" do
    defp located_type!(actor, pattern) do
      type =
        CMS.create_type_definition!(
          %{name: "venue#{System.unique_integer([:positive])}", label: "Venue"},
          actor: actor
        )

      CMS.create_field_definition!(
        %{
          type_definition_id: type.id,
          name: "location",
          label: "Location",
          field_type: :geolocation
        },
        actor: actor
      )

      CMS.update_type_definition!(type, %{slug_pattern: pattern}, actor: actor)
    end

    test "a coordinate part reaches a derived slug" do
      actor = admin()
      type = located_type!(actor, "[title]-[field:location.label]")

      entry =
        ContentTypes.create!(
          type.name,
          %{
            title: "Autumn Show",
            custom_fields: %{
              "location" => %{"lat" => "51.5074", "lng" => "-0.1278", "label" => "London"}
            }
          },
          actor: actor
        )

      assert entry.slug == "autumn-show-london"
    end

    test "latitude and longitude are offered, zoom is not" do
      actor = admin()
      type = located_type!(actor, nil)

      assert {:ok, _updated} =
               CMS.update_type_definition(
                 type,
                 %{slug_pattern: "[field:location.lat]-[field:location.lng]"},
                 actor: actor
               )

      assert {:error, _error} =
               CMS.update_type_definition(
                 type,
                 %{slug_pattern: "[field:location.zoom]"},
                 actor: actor
               )
    end

    test "a token is scoped to its own field, so two fields never contend" do
      actor = admin()
      type = located_type!(actor, nil)

      CMS.create_field_definition!(
        %{
          type_definition_id: type.id,
          name: "meeting",
          label: "Meeting",
          field_type: :geolocation
        },
        actor: actor
      )

      entry =
        ContentTypes.create!(
          type.name,
          %{
            title: "Show",
            custom_fields: %{
              "location" => %{"lat" => 1.0, "lng" => 2.0, "label" => "London"},
              "meeting" => %{"lat" => 3.0, "lng" => 4.0, "label" => "Leeds"}
            }
          },
          actor: actor
        )

      updated =
        CMS.update_type_definition!(
          type,
          %{slug_pattern: "[field:meeting.label]"},
          actor: actor
        )

      assert updated.slug_pattern == "[field:meeting.label]"

      # And the entry created above still resolves each field separately.
      definitions = CMS.field_definitions_for_definition!(type.id, authorize?: false)
      extra = Slugs.type_token_definitions(definitions)
      context = Slugs.record_context(entry)

      assert KilnCMS.Slug.Pattern.expand("[field:location.label]", context, extra) == "london"
      assert KilnCMS.Slug.Pattern.expand("[field:meeting.label]", context, extra) == "leeds"
    end
  end

  describe "type_token_definitions/1" do
    # The probe branch. A module that implements the behaviour but NOT the
    # optional callback must contribute nothing rather than raise — the branch
    # `Code.ensure_loaded?/1 and function_exported?/3` guards.
    test "a field-type module without the callback contributes nothing" do
      definition = %{name: "plain", field_type: :tokenless}
      assert KilnCMS.CMS.FieldTypes.get(:tokenless)

      assert Slugs.type_token_definitions([definition]) == []
    end

    # The rescue. A plugin whose `tokens/1` raises must not fail the save that
    # was merely deriving a slug.
    test "a field type whose tokens/1 raises contributes nothing" do
      definition = %{name: "boom", field_type: :exploding}
      assert KilnCMS.CMS.FieldTypes.get(:exploding)

      assert Slugs.type_token_definitions([definition]) == []
    end

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
