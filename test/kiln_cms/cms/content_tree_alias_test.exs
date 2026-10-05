defmodule KilnCMS.CMS.ContentTreeAliasTest do
  @moduledoc """
  Paths derived from the content tree (#1597, D21): the `[ancestors]` alias
  token, and what a move does to the subtree beneath it.

  The token is only meaningful together with the re-derivation, because
  `Changes.DeriveAlias` fills a *blank* alias and `parent_id` cannot be set on
  create — so without a move there is never an ancestor chain to expand.
  """
  use KilnCMS.DataCase, async: false

  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ta-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp tree_type(actor) do
    CMS.create_type_definition!(
      %{
        name: "doc#{System.unique_integer([:positive])}",
        label: "Doc",
        alias_pattern: "/[ancestors]/[slug]"
      },
      actor: actor
    )
  end

  defp entry(actor, type, title) do
    CMS.create_entry!(
      %{
        type_definition_id: type.id,
        title: title,
        slug: KilnCMS.Slug.derive(title)
      },
      actor: actor
    )
  end

  defp reload(record), do: CMS.get_entry!(record.id, authorize?: false, tenant: record.org_id)

  describe "the [ancestors] token" do
    test "a root document gets a flat path, with no stray separator" do
      actor = admin()
      type = tree_type(actor)

      # No parent, so the token expands empty and the segment drops out.
      assert entry(actor, type, "Alpha").path_alias == "/alpha"
    end

    test "a move re-derives the moved document's path from its new chain" do
      actor = admin()
      type = tree_type(actor)
      section = entry(actor, type, "Guides")
      leaf = entry(actor, type, "Routing")

      assert leaf.path_alias == "/routing"

      {:ok, _moved} = CMS.move_entry(leaf, %{parent_id: section.id}, actor: actor)
      drain_oban()

      assert reload(leaf).path_alias == "/guides/routing"
    end

    test "moving a section re-derives every path beneath it, not just its own" do
      actor = admin()
      type = tree_type(actor)

      top = entry(actor, type, "Docs")
      section = entry(actor, type, "Guides")
      leaf = entry(actor, type, "Routing")

      # Build Guides > Routing, then move the whole thing under Docs.
      {:ok, _} = CMS.move_entry(leaf, %{parent_id: section.id}, actor: actor)
      drain_oban()
      assert reload(leaf).path_alias == "/guides/routing"

      {:ok, _} = CMS.move_entry(section, %{parent_id: top.id}, actor: actor)
      drain_oban()

      # The section moved, and the leaf followed — the fan-out this exists for.
      assert reload(section).path_alias == "/docs/guides"
      assert reload(leaf).path_alias == "/docs/guides/routing"
    end

    test "re-parenting from one section to another rewrites the subtree" do
      actor = admin()
      type = tree_type(actor)

      from = entry(actor, type, "From")
      to = entry(actor, type, "To")
      section = entry(actor, type, "Section")
      leaf = entry(actor, type, "Leaf")

      {:ok, _} = CMS.move_entry(leaf, %{parent_id: section.id}, actor: actor)
      drain_oban()
      {:ok, section} = CMS.move_entry(section, %{parent_id: from.id}, actor: actor)
      drain_oban()

      assert reload(leaf).path_alias == "/from/section/leaf"

      # The case that needs the OLD parent: `section` was not a root before this
      # move, so rewinding its edge to `nil` would misjudge the whole subtree as
      # hand-written and skip it.
      {:ok, _} = CMS.move_entry(section, %{parent_id: to.id}, actor: actor)
      drain_oban()

      assert reload(section).path_alias == "/to/section"
      assert reload(leaf).path_alias == "/to/section/leaf"
    end

    test "a hand-written alias survives a move" do
      actor = admin()
      type = tree_type(actor)
      section = entry(actor, type, "Guides")

      pinned =
        CMS.create_entry!(
          %{
            type_definition_id: type.id,
            title: "Pinned",
            slug: "pinned",
            path_alias: "/kept/by/hand"
          },
          actor: actor
        )

      {:ok, _} = CMS.move_entry(pinned, %{parent_id: section.id}, actor: actor)
      drain_oban()

      # The author pinned it; a bulk re-derivation must not take it back.
      assert reload(pinned).path_alias == "/kept/by/hand"
    end

    test "a move leaves a redirect behind on the old path" do
      actor = admin()
      type = tree_type(actor)
      section = entry(actor, type, "Guides")
      leaf = entry(actor, type, "Routing")

      published = CMS.publish_entry!(leaf, %{}, actor: actor)
      drain_oban()

      {:ok, _} = CMS.move_entry(published, %{parent_id: section.id}, actor: actor)
      drain_oban()

      assert reload(published).path_alias == "/guides/routing"

      redirects = CMS.list_redirects!(authorize?: false, tenant: published.org_id)
      assert Enum.any?(redirects, &(&1.path == "/routing"))
    end
  end

  describe "a type with no alias pattern" do
    test "is untouched by a move" do
      actor = admin()

      parent =
        CMS.create_page!(%{title: "P", slug: "p-#{System.unique_integer([:positive])}"},
          actor: actor
        )

      child =
        CMS.create_page!(%{title: "C", slug: "c-#{System.unique_integer([:positive])}"},
          actor: actor
        )

      {:ok, _} = CMS.move_page(child, %{parent_id: parent.id}, actor: actor)
      drain_oban()

      # Pages derive no alias, so their URLs stay flat and manual.
      assert is_nil(CMS.get_page!(child.id, authorize?: false, tenant: child.org_id).path_alias)
    end
  end
end
