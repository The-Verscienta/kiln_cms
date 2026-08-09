defmodule KilnCMSWeb.SeoPatternTest do
  @moduledoc """
  Per-content-type default SEO patterns (#805), end to end.

  The claims worth a test are the ones the design rests on: the pattern reaches
  the rendered `<title>` and meta description; a record that wrote its own keeps
  it; nothing is written to the record, so changing the type's pattern re-titles
  existing records with no backfill; and a typo is rejected when the type is
  saved rather than discovered in a search result.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Seo.Patterns

  defp uniq, do: System.unique_integer([:positive])

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "seopat-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp patterned_type(actor, attrs) do
    CMS.create_type_definition!(
      Map.merge(%{name: "guide#{uniq()}", label: "Guide"}, attrs),
      actor: actor
    )
  end

  defp publish!(type, actor, attrs) do
    entry = ContentTypes.create!(type.name, attrs, actor: actor)
    {:ok, published} = ContentTypes.transition(type.name, "publish", entry, actor: actor)
    published
  end

  defp title_of(html) do
    case Regex.run(~r{<title[^>]*>(.*?)</title>}s, html, capture: :all_but_first) do
      [title] -> title |> String.replace(~r/\s+/, " ") |> String.trim()
      nil -> nil
    end
  end

  defp description_of(html) do
    case Regex.run(~r/<meta name="description" content="([^"]*)"/, html, capture: :all_but_first) do
      [description] -> description
      nil -> nil
    end
  end

  describe "delivery" do
    test "a type's pattern supplies the title an entry never typed", %{conn: conn} do
      actor = admin()
      type = patterned_type(actor, %{seo_title_pattern: "[title] | [site-name]"})
      entry = publish!(type, actor, %{title: "Kiln Care"})

      html = conn |> get("/#{type.path_segment}/#{entry.slug}") |> html_response(200)

      assert title_of(html) =~ "Kiln Care | KilnCMS"
    end

    test "an entry's own SEO title wins over the pattern", %{conn: conn} do
      actor = admin()
      type = patterned_type(actor, %{seo_title_pattern: "[title] | [site-name]"})
      entry = publish!(type, actor, %{title: "Kiln Care", seo_title: "Chosen by hand"})

      html = conn |> get("/#{type.path_segment}/#{entry.slug}") |> html_response(200)

      assert title_of(html) =~ "Chosen by hand"
      # The pattern's own expansion is nowhere in it. (The layout appends its
      # own " · <site name>" suffix, which is not what this is about.)
      refute title_of(html) =~ "Kiln Care"
    end

    test "the description pattern reaches the meta tag", %{conn: conn} do
      actor = admin()

      type =
        patterned_type(actor, %{
          has_excerpt: true,
          seo_description_pattern: "[excerpt] — from [site-name]"
        })

      entry = publish!(type, actor, %{title: "Firing", excerpt: "How to fire a kiln"})

      html = conn |> get("/#{type.path_segment}/#{entry.slug}") |> html_response(200)

      assert description_of(html) == "How to fire a kiln — from KilnCMS"
    end

    # The whole point of resolving at read time. Nothing is written to the row,
    # so the operator's edit is the only change needed.
    test "changing the pattern re-titles existing entries with no backfill", %{conn: conn} do
      actor = admin()
      type = patterned_type(actor, %{seo_title_pattern: "[title] | [site-name]"})
      entry = publish!(type, actor, %{title: "Kiln Care"})

      url = "/#{type.path_segment}/#{entry.slug}"
      assert conn |> get(url) |> html_response(200) |> title_of() =~ "Kiln Care | KilnCMS"

      CMS.update_type_definition!(type, %{seo_title_pattern: "Guides: [title]"}, actor: actor)

      assert conn |> get(url) |> html_response(200) |> title_of() =~ "Guides: Kiln Care"

      # And the row itself never learned about either pattern.
      assert ContentTypes.get_record!(type.name, entry.id, actor: actor).seo_title == nil
    end

    test "a type with no pattern renders exactly as before", %{conn: conn} do
      actor = admin()
      type = patterned_type(actor, %{})
      entry = publish!(type, actor, %{title: "Plain"})

      html = conn |> get("/#{type.path_segment}/#{entry.slug}") |> html_response(200)

      assert title_of(html) =~ "Plain"
      assert description_of(html) in [nil, ""]
    end

    # `[category]` resolves off the loaded relationship; the delivery read loads
    # it, so this is the token's real path rather than a context-map unit test.
    test "the category token uses the category's name", %{conn: conn} do
      actor = admin()
      type = patterned_type(actor, %{seo_title_pattern: "[category]: [title]"})

      category =
        CMS.create_category!(%{name: "Kiln Care #{uniq()}", slug: "kc-#{uniq()}"}, actor: actor)

      entry = publish!(type, actor, %{title: "Firing", category_id: category.id})

      html = conn |> get("/#{type.path_segment}/#{entry.slug}") |> html_response(200)

      assert title_of(html) =~ "#{category.name}: Firing"
    end
  end

  describe "validation" do
    test "a typo is rejected when the type is saved" do
      actor = admin()

      assert {:error, error} =
               CMS.create_type_definition(
                 %{name: "typo#{uniq()}", label: "Typo", seo_title_pattern: "[titel]"},
                 actor: actor
               )

      assert Exception.message(error) =~ "unknown token"
    end

    test "the description pattern is validated too" do
      actor = admin()
      type = patterned_type(actor, %{})

      assert {:error, _error} =
               CMS.update_type_definition(
                 type,
                 %{seo_description_pattern: "[nope]"},
                 actor: actor
               )
    end

    test "the whole vocabulary is accepted" do
      actor = admin()

      assert {:ok, _type} =
               CMS.create_type_definition(
                 %{
                   name: "ok#{uniq()}",
                   label: "Ok",
                   seo_title_pattern: "[title] [excerpt] [category] [site-name]",
                   seo_description_pattern: "[yyyy]-[mm]-[dd] [field:anything]"
                 },
                 actor: actor
               )
    end
  end

  describe "apply_to/3" do
    test "leaves a record alone when the type has no patterns" do
      record = %{seo_title: nil, seo_description: nil, title: "T"}

      assert Patterns.apply_to(record, %{seo_title_pattern: nil, seo_description_pattern: nil}) ==
               record
    end

    test "leaves a record alone when its type is unknown" do
      record = %{seo_title: nil, title: "T"}

      assert Patterns.apply_to(record, nil) == record
    end

    # A blank string is what a cleared editor field leaves behind, and it means
    # the same thing as nil: nobody wrote one.
    test "treats a blank stored value as unwritten" do
      ct = %{seo_title_pattern: "[title]!", seo_description_pattern: nil}
      record = %{seo_title: "  ", seo_description: nil, title: "T", org_id: nil}

      assert Patterns.apply_to(record, ct).seo_title == "T!"
    end

    # A resource that has no such attribute must not grow one — `Map.put/3` on a
    # struct would raise, and on a bare map would invent a key downstream code
    # never expects.
    test "never adds a field the record doesn't have" do
      ct = %{seo_title_pattern: "[title]", seo_description_pattern: "[title]"}
      record = %{seo_title: nil, title: "T", org_id: nil}

      result = Patterns.apply_to(record, ct)

      assert result.seo_title == "T"
      refute Map.has_key?(result, :seo_description)
    end

    test "a pattern that expands to nothing leaves the field blank" do
      ct = %{seo_title_pattern: "[category]", seo_description_pattern: nil}
      record = %{seo_title: nil, title: "T", org_id: nil}

      assert Patterns.apply_to(record, ct).seo_title == nil
    end
  end
end
