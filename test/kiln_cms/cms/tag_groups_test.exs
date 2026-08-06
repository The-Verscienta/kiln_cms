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

  describe "content-type scope validation (#526)" do
    test "rejects an entry that names no content type" do
      actor = admin()

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.create_tag_group(
                 %{name: "Typo", slug: "typo-#{uniq()}", content_types: ["posts"]},
                 actor: actor
               )

      assert Enum.any?(error.errors, &(&1.field == :content_types))
    end

    test "accepts known compiled type names, and re-checks on update" do
      actor = admin()

      assert {:ok, g} =
               CMS.create_tag_group(
                 %{name: "Good", slug: "good-#{uniq()}", content_types: ["post", "page"]},
                 actor: actor
               )

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.update_tag_group(g, %{content_types: ["post", "ghost"]}, actor: actor)

      assert {:ok, _} = CMS.update_tag_group(g, %{content_types: ["page"]}, actor: actor)
    end
  end

  describe "cross-tenant tag_group_id (#526)" do
    defp other_org do
      Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
        name: "Other",
        slug: "other-#{uniq()}",
        status: :active
      })
    end

    test "rejects a group that belongs to another organization" do
      actor = admin()
      # Seeded straight into a second org, bypassing the write path under test.
      foreign = group(%{org_id: other_org().id})

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.create_tag(
                 %{name: "X", slug: "x-#{uniq()}", tag_group_id: foreign.id},
                 actor: actor
               )

      assert Enum.any?(error.errors, &(&1.field == :tag_group_id))
    end

    test "accepts a group in the writer's own organization" do
      actor = admin()
      home = group()

      assert {:ok, tag} =
               CMS.create_tag(
                 %{name: "Y", slug: "y-#{uniq()}", tag_group_id: home.id},
                 actor: actor
               )

      assert tag.tag_group_id == home.id
    end

    test "on create, resolves the group under the WRITE's tenant, not the default org" do
      actor = admin()
      org_b = other_org()
      home_b = group(%{org_id: org_b.id})
      default_group = group()

      # Same-org group written under org_b: accepted. On the buggy version the
      # validation read the not-yet-stamped `org_id` attribute (nil on create)
      # and fell back to the default org, so this legitimate group was REJECTED.
      assert {:ok, _} =
               CMS.create_tag(
                 %{name: "Ok", slug: "ok-#{uniq()}", tag_group_id: home_b.id},
                 actor: actor,
                 tenant: org_b
               )

      # The DEFAULT org's group is cross-tenant for an org_b tag: rejected. On the
      # buggy version this resolved under the default org, found the group, and
      # WRONGLY ACCEPTED it — the security control inverted for any non-default
      # tenant.
      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_tag(
                 %{name: "Bad", slug: "bad-#{uniq()}", tag_group_id: default_group.id},
                 actor: actor,
                 tenant: org_b
               )
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
