defmodule KilnCMS.CMS.TranslationsTest do
  @moduledoc """
  The localization workflow core (`KilnCMS.CMS.Translations`): per-locale
  coverage with staleness detection, and one-click draft translations that
  carry the source's content (blocks, custom fields, taxonomy) into the
  target locale.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Translations

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "tr-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "tr-#{System.unique_integer([:positive])}"

  test "coverage reports every configured locale with status and staleness" do
    actor = admin()
    shared = slug()

    en = CMS.create_page!(%{title: "Hello", slug: shared, locale: "en"}, actor: actor)
    en = CMS.publish_page!(en, %{}, actor: actor)

    _fr =
      CMS.create_page!(%{title: "Bonjour", slug: shared, locale: "fr"}, actor: actor)

    coverage = Translations.coverage(:page, en, actor: actor)

    assert [%{locale: "en", status: :published, stale?: false}, fr_cov, es_cov] = coverage
    assert %{locale: "fr", status: :draft} = fr_cov
    assert %{locale: "es", status: :missing, stale?: false, record: nil} = es_cov
  end

  test "a translation goes stale when the source is edited after it — and recovers on edit" do
    actor = admin()
    shared = slug()

    en = CMS.create_page!(%{title: "Source", slug: shared, locale: "en"}, actor: actor)
    fr = CMS.create_page!(%{title: "Traduction", slug: shared, locale: "fr"}, actor: actor)

    # Fresh translation: not stale.
    refute coverage_for(en, "fr", actor).stale?

    # The source moves on; the translation is now outdated.
    CMS.update_page!(en, %{title: "Source v2"}, actor: actor)
    assert coverage_for(en, "fr", actor).stale?

    # Updating the translation clears it.
    CMS.update_page!(fr, %{title: "Traduction v2"}, actor: actor)
    refute coverage_for(en, "fr", actor).stale?
  end

  test "the default locale is never stale" do
    actor = admin()
    en = CMS.create_page!(%{title: "Only", slug: slug(), locale: "en"}, actor: actor)

    assert [%{locale: "en", stale?: false} | _] = Translations.coverage(:page, en, actor: actor)
  end

  test "create_translation! copies content into a draft in the target locale" do
    actor = admin()

    field =
      CMS.create_field_definition!(
        %{content_type: :page, name: "region", label: "Region"},
        actor: actor
      )

    category = CMS.create_category!(%{name: "Cat #{slug()}", slug: slug()}, actor: actor)
    tag = CMS.create_tag!(%{name: "tag-#{slug()}", slug: slug()}, actor: actor)

    en =
      CMS.create_page!(
        %{
          title: "Guide",
          slug: slug(),
          locale: "en",
          blocks: [%{"_type" => "heading", "text" => "Top"}],
          seo_title: "Guide SEO",
          custom_fields: %{field.name => "alsace"},
          category_id: category.id,
          tag_ids: [tag.id]
        },
        actor: actor
      )

    fr = Translations.create_translation!(:page, en, "fr", actor: actor)

    assert fr.locale == "fr"
    assert fr.slug == en.slug
    assert fr.state == :draft
    assert fr.title == "Guide"
    assert fr.seo_title == "Guide SEO"
    assert fr.custom_fields == %{field.name => "alsace"}
    assert fr.category_id == category.id

    # Blocks copied through the storage shape, with fresh stable ids.
    assert [%Ash.Union{type: :heading, value: heading}] = fr.blocks
    assert heading.text == "Top"
    [%Ash.Union{value: source_heading}] = CMS.get_page!(en.id, actor: actor).blocks
    refute heading.id == source_heading.id

    # Tags carried over.
    fr_tags = CMS.get_page!(fr.id, actor: actor, load: [:tags]).tags
    assert Enum.map(fr_tags, & &1.id) == [tag.id]
  end

  test "dynamic entries translate through the same dispatch" do
    actor = admin()

    definition =
      CMS.create_type_definition!(
        %{name: "tr#{System.unique_integer([:positive])}", label: "Tr"},
        actor: actor
      )

    en =
      KilnCMS.CMS.ContentTypes.create!(
        definition.name,
        %{title: "Recipe", slug: slug(), locale: "en"},
        actor: actor
      )

    fr = Translations.create_translation!(definition.name, en, "fr", actor: actor)

    assert fr.locale == "fr"
    assert fr.type_definition_id == definition.id

    coverage = Translations.coverage(definition.name, en, actor: actor)
    assert %{locale: "fr", status: :draft} = Enum.find(coverage, &(&1.locale == "fr"))
  end

  test "creating a translation that already exists raises on the [slug, locale] identity" do
    actor = admin()
    shared = slug()

    en = CMS.create_page!(%{title: "One", slug: shared, locale: "en"}, actor: actor)
    _fr = CMS.create_page!(%{title: "Un", slug: shared, locale: "fr"}, actor: actor)

    assert_raise Ash.Error.Invalid, fn ->
      Translations.create_translation!(:page, en, "fr", actor: actor)
    end
  end

  defp coverage_for(record, locale, actor) do
    :page
    |> Translations.coverage(record, actor: actor)
    |> Enum.find(&(&1.locale == locale))
  end
end
