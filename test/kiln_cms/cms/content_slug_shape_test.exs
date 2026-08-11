defmodule KilnCMS.CMS.ContentSlugShapeTest do
  @moduledoc """
  A content slug has to be usable as a URL component (#1062).

  Taxonomy got this in #1044. Content slugs hit far more URLs and had no shape
  rule at all — `SlugAvailable` checks uniqueness and reserved segments,
  `DeriveSlug` only fills a blank, and an explicit `a/b` persisted. Same charset
  as taxonomy: lowercase letters, digits, and single hyphens between them.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "contentslug-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # Page and post both come from `KilnCMS.CMS.Content`; asserting both catches a
  # resource that somehow skipped the macro's validations block.
  defp creators do
    [
      {"page", &CMS.create_page/2},
      {"post", &CMS.create_post/2}
    ]
  end

  @rejected [
    "news/locale/fr",
    "news%2Flocale%2Ffr",
    "has space",
    "Uppercase",
    "trailing-",
    "-leading",
    "double--hyphen",
    "under_score",
    "dot.separated",
    "question?mark"
  ]

  @accepted ["news", "long-form-essays", "v2", "2026-review"]

  describe "a slug that cannot appear in a URL unescaped" do
    test "is refused, with a message that says what is allowed" do
      actor = admin()

      for {label, create} <- creators(), slug <- @rejected do
        assert {:error, error} = create.(%{title: "T", slug: slug}, actor: actor),
               "#{label} accepted #{inspect(slug)}"

        assert Exception.message(error) =~ "lowercase",
               "#{label} refused #{inspect(slug)} for the wrong reason: " <>
                 Exception.message(error)
      end
    end
  end

  describe "an ordinary slug" do
    test "is accepted on page and post" do
      actor = admin()

      for {label, create} <- creators(), slug <- @accepted do
        unique = "#{slug}-#{System.unique_integer([:positive])}"

        assert {:ok, _record} = create.(%{title: "T", slug: unique}, actor: actor),
               "#{label} rejected #{inspect(unique)}"
      end
    end
  end

  describe "rows that predate the validation" do
    test "can still be edited without being forced to change their public URL" do
      # The rule applies `where changing(:slug)`, and that is not a nicety —
      # see TaxonomySlugShapeTest for the same trap.
      legacy =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Legacy",
          slug: "news/locale/fr",
          org_id: KilnCMS.Accounts.default_org_id(),
          blocks: []
        })

      assert {:ok, renamed} =
               CMS.update_page(legacy, %{title: "Renamed"}, actor: admin())

      assert renamed.title == "Renamed"
      assert renamed.slug == "news/locale/fr"

      assert {:error, error} =
               CMS.update_page(legacy, %{slug: "still/bad"}, actor: admin())

      assert Exception.message(error) =~ "lowercase"
    end
  end
end
