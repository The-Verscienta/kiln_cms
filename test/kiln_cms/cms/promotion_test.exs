defmodule KilnCMS.CMS.PromotionTest do
  @moduledoc """
  Phase 6 (decision D17): promoting a dynamic type's data into a compiled
  type's tables. `:page` stands in as the compiled target — same table shape
  the generator produces — so the move is exercised without compiling a new
  module in tests.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Promotion

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "promo-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define_type!(actor) do
    CMS.create_type_definition!(
      %{name: "pr#{System.unique_integer([:positive])}", label: "Promotable"},
      actor: actor
    )
  end

  defp slug, do: "pr-#{System.unique_integer([:positive])}"

  test "promote!/2 moves entries, versions, tags and fields, then archives the type" do
    actor = admin()
    definition = define_type!(actor)
    bystander = define_type!(actor)

    CMS.create_field_definition!(
      %{
        type_definition_id: definition.id,
        name: "servings",
        label: "Servings",
        field_type: :integer
      },
      actor: actor
    )

    tag = CMS.create_tag!(%{name: "Kept", slug: slug()}, actor: actor)

    # A published entry with edit history, custom fields, a tag, and a fired
    # artifact — the full battery.
    entry =
      ContentTypes.create!(
        definition.name,
        %{title: "First", slug: slug(), custom_fields: %{"servings" => "4"}},
        actor: actor
      )

    {:ok, entry} = CMS.update_entry(entry, %{title: "Pancakes", tag_ids: [tag.id]}, actor: actor)
    {:ok, entry} = ContentTypes.transition(definition.name, "publish", entry, actor: actor)
    KilnCMS.DataCase.drain_oban()

    assert {:ok, _artifact} =
             KilnCMS.Firing.get_artifact(:entry, entry.id, :json, authorize?: false)

    draft = ContentTypes.create!(definition.name, %{title: "Draft", slug: slug()}, actor: actor)

    # Another dynamic type's entry must stay put.
    unrelated =
      ContentTypes.create!(bystander.name, %{title: "Stays", slug: slug()}, actor: actor)

    assert {:ok, %{entries: 2, versions: versions_moved}} =
             Promotion.promote!(definition.name, into: :page)

    assert versions_moved >= 2

    # Rows moved with ids, state, and custom fields intact.
    page = CMS.get_page!(entry.id, actor: actor, load: [:tags])
    assert page.title == "Pancakes"
    assert page.state == :published
    assert page.custom_fields == %{"servings" => 4}
    # Taggings are polymorphic by UUID, so the tag survived untouched.
    assert Enum.map(page.tags, & &1.id) == [tag.id]

    assert CMS.get_page!(draft.id, actor: actor).state == :draft

    # The entry tier no longer holds them; the bystander type is untouched.
    assert CMS.list_entries!(
             authorize?: false,
             query: [filter: [type_definition_id: definition.id]]
           ) == []

    assert [%{id: unrelated_id}] = ContentTypes.list!(bystander.name, actor: actor)
    assert unrelated_id == unrelated.id

    # Version history came along and left the entry versions table.
    page_versions =
      CMS.list_page_versions!(actor: actor, query: [filter: [version_source_id: entry.id]])

    assert length(page_versions) >= 2

    assert CMS.list_entry_versions!(
             actor: actor,
             query: [filter: [version_source_id: entry.id]]
           ) == []

    # Stale :entry artifacts were purged (they re-fire under :page on demand).
    assert {:error, _} = KilnCMS.Firing.get_artifact(:entry, entry.id, :json, authorize?: false)

    # Custom-field definitions now belong to the compiled type.
    assert Enum.any?(
             CMS.field_definitions_for!(:page, authorize?: false),
             &(&1.name == "servings")
           )

    # The TypeDefinition is archived: gone from the registry, present in trash.
    assert is_nil(ContentTypes.get_dynamic(definition.name))

    assert Enum.any?(
             CMS.list_archived_type_definitions!(actor: actor),
             &(&1.id == definition.id)
           )
  end

  test "promote! demands a compiled target and guides toward the generator" do
    actor = admin()
    definition = define_type!(actor)

    assert_raise ArgumentError, ~r/mix kiln\.gen\.content --from/, fn ->
      Promotion.promote!(definition.name)
    end

    # Nothing changed: the definition is still live.
    assert ContentTypes.get_dynamic(definition.name)
  end

  test "the generator derives promotion options from the definition" do
    actor = admin()

    plain =
      CMS.create_type_definition!(
        %{name: "recipe#{System.unique_integer([:positive])}", label: "Recipe"},
        actor: actor
      )

    # Default path_segment ("<name>s") is identifier-safe → used as the plural.
    opts = Mix.Tasks.Kiln.Gen.Content.promotion_opts(plain)
    assert opts[:plural] == plain.path_segment
    assert opts[:excerpt] == false

    fancy =
      CMS.create_type_definition!(
        %{
          name: "cook#{System.unique_integer([:positive])}",
          label: "Cookbook",
          path_segment: "cook-book-#{System.unique_integer([:positive])}",
          has_excerpt: true,
          has_published_feed: true
        },
        actor: actor
      )

    # A hyphenated segment can't name functions — no plural override.
    opts = Mix.Tasks.Kiln.Gen.Content.promotion_opts(fancy)
    refute opts[:plural]
    assert opts[:excerpt] == true
    assert opts[:published] == true
  end
end
