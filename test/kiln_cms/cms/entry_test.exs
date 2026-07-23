defmodule KilnCMS.CMS.EntryTest do
  @moduledoc """
  The generic entry tier (decision D17): dynamic-type records carry the full
  content behaviour (workflow, versions, custom fields, optimistic locking)
  through one shared `Entry` resource, dispatched by name string via
  `KilnCMS.CMS.ContentTypes`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "entry-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp define_type!(actor, attrs \\ %{}) do
    CMS.create_type_definition!(
      Map.merge(%{name: "dyn#{System.unique_integer([:positive])}", label: "Dynamic"}, attrs),
      actor: actor
    )
  end

  defp slug, do: "entry-#{System.unique_integer([:positive])}"

  describe "entries through ContentTypes dispatch" do
    test "create/list/get are scoped to the dynamic type" do
      admin = user(:admin)
      recipes = define_type!(admin)
      guides = define_type!(admin)

      recipe =
        ContentTypes.create!(recipes.name, %{title: "Pancakes", slug: slug()}, actor: admin)

      _guide = ContentTypes.create!(guides.name, %{title: "Intro", slug: slug()}, actor: admin)

      assert recipe.type_definition_id == recipes.id

      listed = ContentTypes.list!(recipes.name, actor: admin)
      assert Enum.map(listed, & &1.id) == [recipe.id]

      assert ContentTypes.get_record!(recipes.name, recipe.id, actor: admin).id == recipe.id
    end

    test "slugs are unique per dynamic type, not globally" do
      admin = user(:admin)
      first = define_type!(admin)
      second = define_type!(admin)
      shared = slug()

      ContentTypes.create!(first.name, %{title: "A", slug: shared}, actor: admin)

      # Same slug in another dynamic type is fine…
      assert ContentTypes.create!(second.name, %{title: "B", slug: shared}, actor: admin)

      # …but a duplicate within the same type is rejected.
      assert_raise Ash.Error.Invalid, fn ->
        ContentTypes.create!(first.name, %{title: "Dup", slug: shared}, actor: admin)
      end
    end

    test "the path calculation resolves the dynamic type's URL prefix" do
      admin = user(:admin)
      recipes = define_type!(admin)
      entry = ContentTypes.create!(recipes.name, %{title: "Pancakes", slug: slug()}, actor: admin)

      loaded = ContentTypes.get_record!(recipes.name, entry.id, actor: admin, load: [:path])
      assert loaded.path == "/#{recipes.path_segment}/#{entry.slug}"
    end

    test "the publishing workflow runs end-to-end and public reads are type-scoped" do
      admin = user(:admin)
      recipes = define_type!(admin)
      other = define_type!(admin)

      entry =
        ContentTypes.create!(recipes.name, %{title: "Pancakes", slug: slug()}, actor: admin)

      assert entry.state == :draft

      {:ok, entry} = ContentTypes.transition(recipes.name, "submit", entry, actor: admin)
      assert entry.state == :in_review

      {:ok, entry} = ContentTypes.transition(recipes.name, "publish", entry, actor: admin)
      assert entry.state == :published
      assert entry.published_at

      # Anonymous public delivery read, scoped by the dynamic type.
      found =
        CMS.get_published_entry_by_slug!(entry.slug, entry.locale, recipes.id, authorize?: false)

      assert found.id == entry.id

      # The same slug under another dynamic type resolves to nothing.
      assert CMS.list_entry_translations!(entry.slug, other.id, authorize?: false) == []

      {:ok, entry} = ContentTypes.transition(recipes.name, "unpublish", entry, actor: admin)
      assert entry.state == :draft
    end

    test "editors author but cannot publish (same policies as compiled types)" do
      admin = user(:admin)
      editor = user(:editor)
      recipes = define_type!(admin)

      entry = ContentTypes.create!(recipes.name, %{title: "Draft", slug: slug()}, actor: editor)

      assert {:error, _} = ContentTypes.transition(recipes.name, "publish", entry, actor: editor)
    end
  end

  describe "custom fields on entries" do
    test "values are coerced and validated against the dynamic type's definitions" do
      admin = user(:admin)
      recipes = define_type!(admin)

      CMS.create_field_definition!(
        %{
          type_definition_id: recipes.id,
          name: "servings",
          label: "Servings",
          field_type: :integer
        },
        actor: admin
      )

      CMS.create_field_definition!(
        %{
          type_definition_id: recipes.id,
          name: "difficulty",
          label: "Difficulty",
          field_type: :select,
          options: ~w(easy hard),
          required: true
        },
        actor: admin
      )

      entry =
        ContentTypes.create!(
          recipes.name,
          %{
            title: "Pancakes",
            slug: slug(),
            custom_fields: %{"servings" => "4", "difficulty" => "easy", "unknown" => "dropped"}
          },
          actor: admin
        )

      assert entry.custom_fields == %{"servings" => 4, "difficulty" => "easy"}

      # A required field can't be blank; select membership is enforced.
      assert_raise Ash.Error.Invalid, fn ->
        ContentTypes.create!(
          recipes.name,
          %{title: "Bad", slug: slug(), custom_fields: %{"difficulty" => "impossible"}},
          actor: admin
        )
      end
    end

    test "another dynamic type's definitions do not apply" do
      admin = user(:admin)
      recipes = define_type!(admin)
      guides = define_type!(admin)

      CMS.create_field_definition!(
        %{type_definition_id: guides.id, name: "audience_level", label: "Level", required: true},
        actor: admin
      )

      # Recipes has no required fields, so this creates fine — the guides
      # schema doesn't leak across types.
      entry = ContentTypes.create!(recipes.name, %{title: "Free", slug: slug()}, actor: admin)
      assert entry.custom_fields == %{}
    end
  end

  describe "history and trash" do
    test "edits create paper-trail versions and restore_version reverts" do
      admin = user(:admin)
      recipes = define_type!(admin)

      entry = ContentTypes.create!(recipes.name, %{title: "First", slug: slug()}, actor: admin)
      {:ok, entry} = CMS.update_entry(entry, %{title: "Second"}, actor: admin)

      versions =
        CMS.list_entry_versions!(
          actor: admin,
          query: [filter: [version_source_id: entry.id]]
        )

      assert length(versions) >= 2

      first_snapshot = Enum.find(versions, &(&1.changes["title"] == "First"))
      assert first_snapshot

      {:ok, reverted} =
        ContentTypes.restore_version(recipes.name, entry, first_snapshot.id, actor: admin)

      assert reverted.title == "First"
    end

    test "destroy soft-deletes into the type-scoped trash and restore recovers" do
      admin = user(:admin)
      recipes = define_type!(admin)
      other = define_type!(admin)

      entry = ContentTypes.create!(recipes.name, %{title: "Gone", slug: slug()}, actor: admin)
      :ok = ContentTypes.destroy(recipes.name, entry, actor: admin)

      assert ContentTypes.list!(recipes.name, actor: admin) == []

      trashed = ContentTypes.list_trashed!(recipes.name, actor: admin)
      assert Enum.map(trashed, & &1.id) == [entry.id]
      assert ContentTypes.list_trashed!(other.name, actor: admin) == []

      {:ok, restored} = ContentTypes.restore(recipes.name, hd(trashed), actor: admin)
      assert is_nil(restored.archived_at)
    end
  end
end
