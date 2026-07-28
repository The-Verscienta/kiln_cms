defmodule KilnCMS.CMS.TagGroupsTest do
  @moduledoc """
  Behaviour of the tag-group taxonomy: filing tags under a group, the
  content-type scope, ordering, and what happens to tags when their group is
  deleted.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Tag
  alias KilnCMS.CMS.TagGroup

  defp uniq, do: System.unique_integer([:positive])

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "tg-admin-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      role: :admin
    })
  end

  defp group(attrs \\ %{}) do
    Ash.Seed.seed!(
      TagGroup,
      Map.merge(%{name: "Topics", slug: "topics-#{uniq()}"}, attrs)
    )
  end

  defp tag(attrs) do
    Ash.Seed.seed!(Tag, Map.merge(%{name: "Elixir", slug: "elixir-#{uniq()}"}, attrs))
  end

  describe "filing tags under a group" do
    test "a tag can be created into a group and moved between groups" do
      actor = admin()
      a = group(%{name: "Topics"})
      b = group(%{name: "Formats"})

      tag =
        CMS.create_tag!(%{name: "Guides", slug: "guides-#{uniq()}", tag_group_id: a.id},
          actor: actor
        )

      assert tag.tag_group_id == a.id

      moved = CMS.update_tag!(tag, %{tag_group_id: b.id}, actor: actor)
      assert moved.tag_group_id == b.id
    end

    test "tag_group_id is optional — ungrouped tags are the default" do
      actor = admin()
      tag = CMS.create_tag!(%{name: "Loose", slug: "loose-#{uniq()}"}, actor: actor)
      assert is_nil(tag.tag_group_id)
    end

    test "tag_count aggregates the tags filed under a group" do
      actor = admin()
      g = group()
      for _ <- 1..3, do: tag(%{tag_group_id: g.id})

      loaded = CMS.get_tag_group!(g.id, actor: actor, load: [:tag_count])
      assert loaded.tag_count == 3
    end
  end

  describe "destroying a group" do
    test "keeps its tags and leaves them ungrouped" do
      actor = admin()
      g = group()
      tag = tag(%{tag_group_id: g.id})

      :ok = CMS.destroy_tag_group!(g, actor: actor)

      survivor = CMS.get_tag!(tag.id, actor: actor)
      assert survivor.id == tag.id
      assert is_nil(survivor.tag_group_id), "the FK must nilify, not cascade the delete"
    end
  end

  describe "content-type scope" do
    test "defaults to every content type" do
      actor = admin()

      g =
        CMS.create_tag_group!(%{name: "Everywhere", slug: "everywhere-#{uniq()}"}, actor: actor)

      assert g.content_types == [],
             "empty means unrestricted — see KilnCMS.CMS.TagGroup"
    end

    test "accepts a list of content-type name strings" do
      actor = admin()

      g =
        CMS.create_tag_group!(
          %{name: "Post themes", slug: "post-themes-#{uniq()}", content_types: ["post"]},
          actor: actor
        )

      assert g.content_types == ["post"]

      widened = CMS.update_tag_group!(g, %{content_types: ["post", "page"]}, actor: actor)
      assert widened.content_types == ["post", "page"]

      cleared = CMS.update_tag_group!(widened, %{content_types: []}, actor: actor)
      assert cleared.content_types == []
    end
  end

  describe "listing" do
    test "groups come back ordered by position then name" do
      actor = admin()
      marker = "ord-#{uniq()}"

      group(%{name: "#{marker} Zulu", position: 0})
      group(%{name: "#{marker} Alpha", position: 0})
      group(%{name: "#{marker} First", position: -1})

      names =
        CMS.list_tag_groups!(actor: actor)
        |> Enum.map(& &1.name)
        |> Enum.filter(&String.starts_with?(&1, marker))

      assert names == ["#{marker} First", "#{marker} Alpha", "#{marker} Zulu"]
    end
  end
end
