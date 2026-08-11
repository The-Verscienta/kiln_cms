defmodule KilnCMS.CMS.DuplicationTest do
  @moduledoc """
  The generic duplicate action (#471): clone a content record into a new draft
  of the same locale, carrying the authored payload and leaving the source's
  identity, workflow and history behind.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Duplication
  alias KilnCMS.CMS.Translations

  require Ash.Query

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "dup-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp slug, do: "dup-#{System.unique_integer([:positive])}"

  test "copies the authored payload into a new draft with a (copy) title" do
    actor = user(:admin)

    field =
      CMS.create_field_definition!(
        %{content_type: :page, name: "region", label: "Region"},
        actor: actor
      )

    category = CMS.create_category!(%{name: "Cat #{slug()}", slug: slug()}, actor: actor)
    tag = CMS.create_tag!(%{name: "tag-#{slug()}", slug: slug()}, actor: actor)

    source =
      CMS.create_page!(
        %{
          title: "Guide",
          slug: slug(),
          locale: "en",
          blocks: [%{"_type" => "heading", "text" => "Top"}],
          seo_title: "Guide SEO",
          seo_description: "About the guide",
          custom_fields: %{field.name => "alsace"},
          category_id: category.id,
          tag_ids: [tag.id]
        },
        actor: actor
      )

    copy = Duplication.duplicate!(:page, source, actor: actor)

    assert copy.id != source.id
    assert copy.title == "Guide (copy)"
    assert copy.state == :draft
    assert copy.locale == "en"
    assert copy.seo_title == "Guide SEO"
    assert copy.seo_description == "About the guide"
    assert copy.custom_fields == %{field.name => "alsace"}
    assert copy.category_id == category.id

    # A fresh slug derived from the new title — never the source's.
    assert copy.slug != source.slug
    assert copy.slug =~ "copy"

    # Blocks copied through the storage shape, with fresh stable ids.
    assert [%Ash.Union{type: :heading, value: heading}] = copy.blocks
    assert heading.text == "Top"
    [%Ash.Union{value: source_heading}] = CMS.get_page!(source.id, actor: actor).blocks
    refute heading.id == source_heading.id

    # Taxonomy carried over.
    copy_tags = CMS.get_page!(copy.id, actor: actor, load: [:tags]).tags
    assert Enum.map(copy_tags, & &1.id) == [tag.id]
  end

  test "the source's workflow state, schedules and history never travel" do
    actor = user(:admin)
    later = DateTime.add(DateTime.utc_now(), 3600, :second)

    source =
      CMS.create_page!(
        %{title: "Live", slug: slug(), unpublish_at: later},
        actor: actor
      )

    source = CMS.publish_page!(source, %{}, actor: actor)
    source = CMS.update_page!(source, %{seo_title: "v2"}, actor: actor)

    copy = Duplication.duplicate!(:page, source, actor: actor)

    assert copy.state == :draft
    assert is_nil(copy.scheduled_at)
    assert is_nil(copy.unpublish_at)
    assert is_nil(copy.published_at)

    # The copy's history is its own create, not the source's edit trail.
    assert length(versions_of(copy)) == 1
    assert length(versions_of(source)) > 1
  end

  defp versions_of(record) do
    KilnCMS.CMS.Page.Version
    |> Ash.Query.filter(version_source_id == ^record.id)
    |> Ash.read!(authorize?: false, tenant: record.org_id)
  end

  # The default slug chain is focus keyphrase → title, so carrying the keyphrase
  # would slug the copy off the *source*'s SEO target — and put two records on
  # one keyphrase.
  test "the focus keyphrase stays with the source, and the copy slugs off its title" do
    actor = user(:admin)

    source =
      CMS.create_page!(
        %{title: "Guide", slug: slug(), seo_keywords: "kiln firing"},
        actor: actor
      )

    copy = Duplication.duplicate!(:page, source, actor: actor)

    assert is_nil(copy.seo_keywords)
    assert copy.slug == "guide-copy"
  end

  test "nested block ids are dropped too, not just top-level ones" do
    actor = user(:admin)
    child_id = Ash.UUID.generate()

    source =
      CMS.create_page!(
        %{
          title: "Nested",
          slug: slug(),
          blocks: [
            %{
              "_type" => "columns",
              "columns" => [
                %{"blocks" => [%{"_type" => "heading", "id" => child_id, "text" => "Child"}]}
              ]
            }
          ]
        },
        actor: actor
      )

    source = CMS.get_page!(source.id, actor: actor)
    copy = Duplication.duplicate!(:page, source, actor: actor)

    # The editor assigns nested children their ids client-side; the source keeps
    # the one it was authored with, and the copy must not share it.
    assert child_ids(source) == [child_id]
    refute child_id in child_ids(copy)
    # …while the nested content itself survives.
    assert [%Ash.Union{value: %{columns: [%{"blocks" => [child]}]}}] = copy.blocks
    assert child["text"] == "Child"
  end

  # Nested `columns` children are raw maps, not union structs.
  defp child_ids(record) do
    for %Ash.Union{value: %{columns: columns}} <- record.blocks,
        column <- List.wrap(columns),
        child <- List.wrap(column["blocks"] || column[:blocks]),
        id = child["id"] || child[:id] do
      id
    end
  end

  test "duplicating twice dedupes the slug instead of colliding" do
    actor = user(:admin)
    source = CMS.create_page!(%{title: "Guide", slug: slug()}, actor: actor)

    first = Duplication.duplicate!(:page, source, actor: actor)
    second = Duplication.duplicate!(:page, source, actor: actor)

    assert first.slug != second.slug
  end

  test "related content links are carried over" do
    actor = user(:admin)
    other = CMS.create_page!(%{title: "Other", slug: slug()}, actor: actor)

    source =
      CMS.create_page!(
        %{title: "Hub", slug: slug(), related_page_ids: [other.id]},
        actor: actor
      )

    copy = Duplication.duplicate!(:page, source, actor: actor)
    related = CMS.get_page!(copy.id, actor: actor, load: [:related_pages]).related_pages

    assert Enum.map(related, & &1.id) == [other.id]
  end

  # The `related_<type>_ids` argument is a bare id set: routing the copy through
  # it would re-create every link with the resource defaults, flattening the
  # payload that data-carrying relations exist to hold.
  test "a link's kind, position, label and metadata survive the copy" do
    actor = user(:admin)
    target = CMS.create_page!(%{title: "Ingredient", slug: slug()}, actor: actor)
    source = CMS.create_page!(%{title: "Formula", slug: slug()}, actor: actor)

    CMS.create_content_link!(
      %{
        source_id: source.id,
        target_id: target.id,
        kind: :see_also,
        position: 3,
        label: "Chief herb",
        metadata: %{"dosage" => "9g"}
      },
      actor: actor
    )

    copy = Duplication.duplicate!(:page, source, actor: actor)

    assert [link] = CMS.get_page!(copy.id, actor: actor, load: [:content_links]).content_links
    assert link.target_id == target.id
    assert link.kind == :see_also
    assert link.position == 3
    assert link.label == "Chief herb"
    assert link.metadata == %{"dosage" => "9g"}
  end

  test "two links to one target under different kinds both survive" do
    actor = user(:admin)
    target = CMS.create_page!(%{title: "Target", slug: slug()}, actor: actor)
    source = CMS.create_page!(%{title: "Source", slug: slug()}, actor: actor)

    for kind <- [:related, :see_also] do
      CMS.create_content_link!(
        %{source_id: source.id, target_id: target.id, kind: kind},
        actor: actor
      )
    end

    copy = Duplication.duplicate!(:page, source, actor: actor)
    links = CMS.get_page!(copy.id, actor: actor, load: [:content_links]).content_links

    assert Enum.sort(Enum.map(links, & &1.kind)) == [:related, :see_also]
  end

  test "links pointing AT the source stay with the source" do
    actor = user(:admin)
    source = CMS.create_page!(%{title: "Linked to", slug: slug()}, actor: actor)

    _linker =
      CMS.create_page!(%{title: "Linker", slug: slug(), related_page_ids: [source.id]},
        actor: actor
      )

    copy = Duplication.duplicate!(:page, source, actor: actor)

    assert CMS.get_page!(copy.id, actor: actor, load: [:incoming_links]).incoming_links == []
  end

  test "works from a partially-selected record (the content list's projection)" do
    actor = user(:admin)

    source =
      CMS.create_page!(
        %{title: "Sparse", slug: slug(), blocks: [%{"_type" => "heading", "text" => "Kept"}]},
        actor: actor
      )

    # The content list selects a handful of columns; blocks aren't among them.
    [listed] =
      CMS.list_pages!(
        actor: actor,
        query: [filter: [id: source.id], select: [:id, :title, :slug]]
      )

    copy = Duplication.duplicate!(:page, listed, actor: actor)

    assert [%Ash.Union{value: %{text: "Kept"}}] = copy.blocks
  end

  test "dynamic entries duplicate through the same dispatch" do
    actor = user(:admin)

    definition =
      CMS.create_type_definition!(
        %{name: "dup#{System.unique_integer([:positive])}", label: "Dup"},
        actor: actor
      )

    source =
      ContentTypes.create!(
        definition.name,
        %{title: "Recipe", slug: slug(), locale: "en"},
        actor: actor
      )

    copy = Duplication.duplicate!(definition.name, source, actor: actor)

    assert copy.title == "Recipe (copy)"
    assert copy.state == :draft
    assert copy.type_definition_id == definition.id
    assert copy.slug != source.slug
  end

  test "create policies apply — an out-of-scope editor cannot duplicate" do
    admin = user(:admin)
    page = CMS.create_page!(%{title: "Pg", slug: slug()}, actor: admin)
    editor = user(:editor, %{editable_types: ["post"]})

    assert {:error, %Ash.Error.Forbidden{}} = Duplication.duplicate(:page, page, actor: editor)
  end

  # The flash named attributes the copy actually carried: `withheld` was derived
  # from every copyable attr the grant didn't name, without subtracting the ones
  # that are exempt from the grant in the first place (#1157 review).
  test "the withheld list does not name attributes the copy carried" do
    admin = user(:admin)

    source =
      CMS.create_post!(
        %{title: "Gated", slug: slug(), audience: :member, blocks: []},
        actor: admin
      )

    # Names NEITHER exempt attribute, which is the whole point: a grant that
    # already names them could not tell the exemption from the grant.
    editor = user(:editor, %{field_grants: %{"post" => ["blocks"]}})

    assert {:ok, copy, withheld} = Duplication.duplicate(:post, source, actor: editor)

    # Both are exempt and both travelled, so neither may be reported.
    assert copy.audience == :member
    assert copy.title == "Gated (copy)"
    refute "audience" in withheld
    refute "title" in withheld
  end

  test "a field-granted editor's copy carries only the granted attributes" do
    admin = user(:admin)

    source =
      CMS.create_post!(
        %{
          title: "Original",
          slug: slug(),
          excerpt: "Not yours to steward",
          seo_title: "SEO",
          blocks: [%{"_type" => "heading", "text" => "Body"}]
        },
        actor: admin
      )

    editor = user(:editor, %{field_grants: %{"post" => ["title", "blocks"]}})

    copy = Duplication.duplicate!(:post, source, actor: editor)

    assert copy.title == "Original (copy)"
    # Granted: blocks travel.
    assert [%Ash.Union{value: %{text: "Body"}}] = copy.blocks
    # Not granted: dropped rather than cloned past the grant.
    assert is_nil(copy.excerpt)
    assert is_nil(copy.seo_title)
  end

  # Dropping `audience` would fall back to the attribute default (`:public`) —
  # strictly less restrictive than the source, i.e. a gated body copied into a
  # public draft.
  test "audience survives a field grant that doesn't name it" do
    admin = user(:admin)

    source =
      CMS.create_post!(
        %{title: "Gated", slug: slug(), audience: :member, blocks: []},
        actor: admin
      )

    assert source.audience == :member

    editor = user(:editor, %{field_grants: %{"post" => ["title", "blocks"]}})

    assert Duplication.duplicate!(:post, source, actor: editor).audience == :member
  end

  test "an editor with no field grant gets a complete copy" do
    admin = user(:admin)

    source =
      CMS.create_post!(
        %{title: "Original", slug: slug(), excerpt: "Carried", seo_title: "SEO"},
        actor: admin
      )

    copy = Duplication.duplicate!(:post, source, actor: user(:editor))

    assert copy.excerpt == "Carried"
    assert copy.seo_title == "SEO"
  end

  test "duplicate/3 reports failure instead of raising" do
    admin = user(:admin)
    page = CMS.create_page!(%{title: "Pg", slug: slug()}, actor: admin)

    assert {:error, _} = Duplication.duplicate(:page, page, actor: user(:viewer))
  end

  test "copy_title/1 appends the suffix to a trimmed title" do
    assert Duplication.copy_title("Guide ") == "Guide (copy)"
    assert Duplication.copy_title("") == "(copy)"
  end

  # `EnforceBlockFieldPolicy` runs on create as well as update, and on a create
  # there is no stored tree to diff against — so every restricted field is
  # judged against its DECLARED DEFAULT and any admin-set value trips it. An
  # editor duplicating a page they were allowed to read got a refusal they could
  # do nothing about (#890). The existing tests could not catch it: they use
  # only `heading` blocks, and every block test runs as an admin, who is exempt.
  describe "admin-restricted block fields (#890)" do
    defp featured_quote_page!(admin) do
      CMS.create_page!(
        %{
          title: "Quoted",
          slug: slug(),
          block_tree: [%{"_type" => "quote", "text" => "Wisdom", "featured" => true}]
        },
        actor: admin
      )
    end

    defp quote_block(page) do
      Enum.find_value(page.blocks, fn
        %Ash.Union{type: :quote, value: value} -> value
        _ -> nil
      end)
    end

    test "an editor can duplicate a page carrying an admin-only field value" do
      admin = user(:admin)
      editor = user(:editor)
      page = featured_quote_page!(admin)

      assert {:ok, copy, withheld} = Duplication.duplicate(:page, page, actor: editor)

      # The copy exists — that is the dead-end this fixes.
      assert copy.id != page.id
      # And the restricted flag came back to its default rather than travelling.
      assert quote_block(copy).featured == false
      assert quote_block(page).featured == true
      # And the editor is told, rather than wondering where it went (#929).
      assert "quote.featured" in withheld
    end

    test "an admin's duplicate keeps the restricted value" do
      admin = user(:admin)
      page = featured_quote_page!(admin)

      assert {:ok, copy, withheld} = Duplication.duplicate(:page, page, actor: admin)

      assert quote_block(copy).featured == true
      assert withheld == []
    end

    test "an editor can translate one too" do
      admin = user(:admin)
      editor = user(:editor)
      page = featured_quote_page!(admin)

      assert %{} = translated = Translations.create_translation!(:page, page, "fr", actor: editor)
      assert translated.locale == "fr"
      assert quote_block(translated).featured == false
    end

    # #1157. `_type`, `_version` and `id` share the stored map with the authored
    # fields but are the union's envelope, not fields anyone declares. Asking a
    # FIELD policy about them answered "no" for every non-admin, so a plain
    # editor duplicating a plain page had them overwritten with `nil` and was
    # told their role could not set `heading._type`.
    test "the block envelope is not mistaken for a restricted field" do
      admin = user(:admin)
      editor = user(:editor)

      page =
        CMS.create_page!(
          %{
            title: "Plain",
            slug: slug(),
            blocks: [%{"_type" => "heading", "text" => "Top"}]
          },
          actor: admin
        )

      assert {:ok, copy, withheld} = Duplication.duplicate(:page, page, actor: editor)

      # Nothing to report: this page has no restricted field on it at all.
      assert withheld == []

      # And the envelope survived rather than being nulled and re-derived.
      assert [%Ash.Union{type: :heading, value: heading}] = copy.blocks
      assert heading.text == "Top"
    end

    test "an unrestricted block field is untouched" do
      admin = user(:admin)
      editor = user(:editor)
      page = featured_quote_page!(admin)

      {:ok, copy, _} = Duplication.duplicate(:page, page, actor: editor)

      assert quote_block(copy).text == "Wisdom"
    end
  end

  describe "atomicity (#925)" do
    # The links used to be cloned after the create with nothing tying them
    # together, so a mid-loop failure left a committed copy the caller was told
    # did not exist.
    test "a copy and its links land together or not at all" do
      admin = user(:admin)
      target = CMS.create_page!(%{title: "Target", slug: slug()}, actor: admin)
      source = CMS.create_page!(%{title: "Hub", slug: slug()}, actor: admin)

      {:ok, _link} =
        CMS.create_content_link(
          %{source_id: source.id, target_id: target.id, kind: "related"},
          actor: admin
        )

      before = CMS.list_pages!(actor: admin) |> length()

      assert {:ok, copy, _} = Duplication.duplicate(:page, source, actor: admin)

      assert CMS.list_pages!(actor: admin) |> length() == before + 1

      links =
        CMS.list_content_links!(actor: admin, query: [filter: [source_id: copy.id]])

      assert length(links) == 1
    end
  end
end
