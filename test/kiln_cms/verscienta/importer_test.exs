defmodule KilnCMS.Verscienta.ImporterTest do
  @moduledoc "Full ETL pipeline against the bundled JSON fixtures."
  use KilnCMS.DataCase, async: true

  require Ash.Query

  alias KilnCMS.Verscienta.Importer

  @fixtures Path.join(File.cwd!(), "priv/verscienta_fixtures")

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp one(resource, slug) do
    resource
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read_one!(authorize?: false, load: [:tags, :featured_image, :content_links])
  end

  test "imports content, taxonomy, media and relations, and is idempotent" do
    actor = admin()

    assert {:ok, stats} = Importer.run({:fixtures, @fixtures}, actor: actor, quiet: true)
    assert stats.content == 8
    assert stats.tags == 3
    assert stats.media == 4
    assert stats.links == 11
    assert stats.skipped_links == 0

    # Content type + state
    ginseng = one(KilnCMS.CMS.Herb, "ginseng")
    assert ginseng.title == "Ginseng"
    assert ginseng.state == :published

    # Rich-text sections became heading + rich_text blocks
    block_types = Enum.map(ginseng.blocks, & &1.value._type)
    assert "heading" in block_types and "rich_text" in block_types

    # Scalars preserved; JSON arrays encoded losslessly
    assert ginseng.custom_fields["sourcing_organic"] == true
    assert Jason.decode!(ginseng.custom_fields["synonyms"]) == ["Asian ginseng", "Ren shen"]

    # Both taxonomy vocabularies, namespaced
    tag_slugs = Enum.map(ginseng.tags, & &1.slug)
    assert "herb-tag-adaptogen" in tag_slugs
    assert "tcm-tonifying" in tag_slugs

    # Cloudflare image became the featured image
    assert ginseng.featured_image.url == "https://imagedelivery.net/acc/ginseng/public"

    # Self-referential herb relation resolved across the two passes
    assert Enum.any?(ginseng.content_links, &(&1.kind == :related_species))

    # O2M child carried its data onto the link metadata
    formula = one(KilnCMS.CMS.Formula, "si-jun-zi-tang")
    ingredient = Enum.find(formula.content_links, &(&1.kind == :ingredient))
    assert ingredient.metadata["quantity"] == 9
    assert ingredient.metadata["role"] == "Chief (Jun)"

    # Idempotent: a second run creates nothing new
    assert {:ok, again} = Importer.run({:fixtures, @fixtures}, actor: actor, quiet: true)
    assert again.content == 0
    assert again.tags == 0
    assert again.links == 0
    assert Ash.count!(KilnCMS.CMS.Herb, authorize?: false) == 2
  end
end
