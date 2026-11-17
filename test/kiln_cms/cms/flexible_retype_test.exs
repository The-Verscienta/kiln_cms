defmodule KilnCMS.CMS.FlexibleRetypeTest do
  @moduledoc """
  The admin-facing guards of a flexible field (#2282, PR 2):

    * a field is never retyped to or from `:flexible` (ADR 0065), however the
      update arrives;
    * `FlexiblePath.count_stored/2` counts the items a delete would remove, for
      an item type, a top-level flexible field and a nested one;
    * destroying an item type with `purge_items?: true` removes its items in the
      destroy's own transaction, before the post-commit sweep runs;
    * renaming an item type keeps its items.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FlexiblePath

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "flexr-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp def!(admin, attrs),
    do: CMS.create_field_definition!(Map.merge(%{label: "Field"}, attrs), actor: admin)

  defp item_type!(admin, flexible, name),
    do: def!(admin, %{name: name, field_type: :group, flex_of_id: flexible.id})

  defp sub!(admin, parent, name, attrs \\ %{}),
    do: def!(admin, Map.merge(%{name: name, group_of_id: parent.id, field_type: :string}, attrs))

  defp raw(post) do
    %{rows: [[value]]} =
      KilnCMS.Repo.query!("SELECT custom_fields FROM posts WHERE id = $1", [
        Ecto.UUID.dump!(post.id)
      ])

    value
  end

  setup do
    admin = user(:admin)
    sections = def!(admin, %{content_type: :post, name: "sections", field_type: :flexible})
    hero = item_type!(admin, sections, "hero")
    sub!(admin, hero, "headline")
    quote_type = item_type!(admin, sections, "quote")
    sub!(admin, quote_type, "text")
    rows = sub!(admin, hero, "rows", %{field_type: :flexible, position: 1})
    row = item_type!(admin, rows, "row")
    sub!(admin, row, "label")

    post =
      CMS.create_post!(
        %{
          title: "P",
          slug: "flexr-#{System.unique_integer([:positive])}",
          custom_fields: %{
            "sections" => [
              %{
                "_type" => "hero",
                "headline" => "A",
                "rows" => [
                  %{"_type" => "row", "label" => "1"},
                  %{"_type" => "row", "label" => "2"}
                ]
              },
              %{"_type" => "hero", "headline" => "B"},
              %{"_type" => "quote", "text" => "Q"}
            ]
          }
        },
        actor: admin
      )

    %{
      admin: admin,
      sections: sections,
      hero: hero,
      quote_type: quote_type,
      rows: rows,
      row: row,
      post: post
    }
  end

  describe "retyping" do
    test "a plain field cannot become flexible", %{admin: admin} do
      plain = def!(admin, %{content_type: :post, name: "plain", field_type: :string})

      assert {:error, error} =
               CMS.update_field_definition(plain, %{field_type: :flexible}, actor: admin)

      assert Exception.message(error) =~ "to or from a flexible field"
      assert CMS.get_field_definition!(plain.id, actor: admin).field_type == :string
    end

    test "a flexible field cannot become anything else, with or without items", ctx do
      assert {:error, error} =
               CMS.update_field_definition(ctx.sections, %{field_type: :group}, actor: ctx.admin)

      assert Exception.message(error) =~ "to or from a flexible field"

      empty = def!(ctx.admin, %{content_type: :post, name: "empty_flex", field_type: :flexible})

      assert {:error, _} =
               CMS.update_field_definition(empty, %{field_type: :text}, actor: ctx.admin)

      assert CMS.get_field_definition!(empty.id, actor: ctx.admin).field_type == :flexible
    end

    test "other edits of a flexible field and other retypes still work", ctx do
      assert {:ok, %{label: "Renamed"}} =
               CMS.update_field_definition(ctx.sections, %{label: "Renamed"}, actor: ctx.admin)

      plain = def!(ctx.admin, %{content_type: :post, name: "plain2", field_type: :string})

      assert {:ok, %{field_type: :text}} =
               CMS.update_field_definition(plain, %{field_type: :text}, actor: ctx.admin)
    end
  end

  describe "count_stored/2" do
    test "counts the items of an item type, a field and a nested field", ctx do
      org = ctx.hero.org_id
      assert {:ok, 2} = FlexiblePath.count_stored(ctx.hero, org)
      assert {:ok, 1} = FlexiblePath.count_stored(ctx.quote_type, org)
      assert {:ok, 2} = FlexiblePath.count_stored(ctx.row, org)
      # the field counts the items of its own item types; nested ones sit inside them
      assert {:ok, 3} = FlexiblePath.count_stored(ctx.sections, org)
      assert {:ok, 2} = FlexiblePath.count_stored(ctx.rows, org)
    end

    test "is zero for a type nothing uses and for a definition that holds no items", ctx do
      unused = item_type!(ctx.admin, ctx.sections, "unused")
      assert {:ok, 0} = FlexiblePath.count_stored(unused, unused.org_id)

      plain = def!(ctx.admin, %{content_type: :post, name: "plain3", field_type: :string})
      assert {:ok, 0} = FlexiblePath.count_stored(plain, plain.org_id)
    end

    test "moves with the stored items", ctx do
      CMS.update_post!(
        ctx.post,
        %{custom_fields: %{"sections" => [%{"_type" => "quote", "text" => "only"}]}},
        actor: ctx.admin
      )

      assert {:ok, 0} = FlexiblePath.count_stored(ctx.hero, ctx.hero.org_id)
      assert {:ok, 1} = FlexiblePath.count_stored(ctx.sections, ctx.hero.org_id)
    end
  end

  describe "purge_items? runs inside the destroy's transaction" do
    test "an outer rollback restores the type and its items", ctx do
      assert {:error, :undo} =
               KilnCMS.Repo.transaction(fn ->
                 assert :ok =
                          CMS.destroy_field_definition(ctx.hero, %{purge_items?: true},
                            actor: ctx.admin,
                            context: %{warn_on_transaction_hooks?: false}
                          )

                 assert [%{"_type" => "quote"}] = raw(ctx.post)["sections"]
                 KilnCMS.Repo.rollback(:undo)
               end)

      assert length(raw(ctx.post)["sections"]) == 3
      assert CMS.get_field_definition!(ctx.hero.id, actor: ctx.admin)
    end

    test "the items are gone before the sweep job is enqueued", ctx do
      CMS.publish_post!(ctx.post, %{}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()

      :ok = CMS.destroy_field_definition(ctx.hero, %{purge_items?: true}, actor: ctx.admin)

      assert_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => ctx.post.id})
      assert [%{"_type" => "quote"}] = raw(ctx.post)["sections"]
    end

    test "a refused destroy (no purge) leaves everything", ctx do
      assert {:error, _} = CMS.destroy_field_definition(ctx.hero, actor: ctx.admin)
      assert length(raw(ctx.post)["sections"]) == 3
    end

    test "without purge_items? an empty type is destroyed and nothing is rewritten", ctx do
      unused = item_type!(ctx.admin, ctx.sections, "unused")
      before = raw(ctx.post)
      assert :ok = CMS.destroy_field_definition(unused, actor: ctx.admin)
      assert raw(ctx.post) == before
    end
  end

  describe "renaming an item type" do
    test "keeps its items under the new type name", ctx do
      CMS.update_field_definition!(ctx.hero, %{name: "banner"}, actor: ctx.admin)

      assert [
               %{"_type" => "banner", "headline" => "A"},
               %{"_type" => "banner", "headline" => "B"},
               %{"_type" => "quote"}
             ] = raw(ctx.post)["sections"]

      assert {:ok, 2} =
               FlexiblePath.count_stored(
                 CMS.get_field_definition!(ctx.hero.id, actor: ctx.admin),
                 ctx.hero.org_id
               )
    end
  end
end
