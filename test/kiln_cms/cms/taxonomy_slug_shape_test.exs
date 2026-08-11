defmodule KilnCMS.CMS.TaxonomySlugShapeTest do
  @moduledoc """
  A taxonomy slug has to be usable as a URL component (#1044).

  It already is one, in several places that each have to remember to encode it:
  the feed cache key and advertised `<id>`, the tag calendar route, the delivery
  index's `?category=` filter, the taxonomy editor's links. #1030 fixed the feed
  after a slug carrying `/` folded two different URLs onto one cache key and
  served each other's document to anonymous readers for the TTL. This is the
  root cause, and the point of a validation over more encoding is that the next
  surface to forget fails loudly instead of quietly.

  Asserted for all three taxonomy resources, because the rule lives in the
  `KilnCMS.CMS.Taxonomy` macro and "it is in the macro" is not the same as "it
  reached every user of the macro".
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "taxslug-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # The three writers, so a resource that skipped the macro's validations block
  # is caught rather than assumed.
  defp creators do
    [
      {"category", &CMS.create_category/2},
      {"tag", &CMS.create_tag/2},
      {"tag group", &CMS.create_tag_group/2}
    ]
  end

  @rejected [
    # The one that caused #1030: a separator turns one slug into several path
    # segments, and every consumer has to encode it or collide.
    "news/locale/fr",
    # Already-encoded input is its own trap: it round-trips to a slug
    # containing a literal `%2F`.
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
        assert {:error, error} = create.(%{name: "T", slug: slug}, actor: actor),
               "#{label} accepted #{inspect(slug)}"

        # The shape message specifically. Accepting "required" as well would
        # let a slug that failed for some *other* reason — a nil cast, a length
        # constraint — pass as if this rule had fired.
        assert Exception.message(error) =~ "lowercase",
               "#{label} refused #{inspect(slug)} for the wrong reason: " <>
                 Exception.message(error)
      end
    end

    test "an empty slug is still refused, but as a missing value" do
      # Not a shape failure: Ash casts "" to nil before any validation runs, so
      # this is `allow_nil?: false` and would read identically with the shape
      # rule deleted. Separated so neither claim borrows the other's evidence.
      assert {:error, error} = CMS.create_category(%{name: "T", slug: ""}, actor: admin())
      assert Exception.message(error) =~ "required"
    end
  end

  describe "an ordinary slug" do
    test "is accepted by every taxonomy resource" do
      actor = admin()

      for {label, create} <- creators(), slug <- @accepted do
        unique = "#{slug}-#{System.unique_integer([:positive])}"

        assert {:ok, _record} = create.(%{name: "T", slug: unique}, actor: actor),
               "#{label} rejected #{inspect(unique)}"
      end
    end
  end

  describe "rows that predate the validation" do
    test "can still be edited without being forced to change their public URL" do
      # The rule applies `where changing(:slug)`, and that is not a nicety. A
      # bare `validate match` reads the attribute's current value on every
      # update, so a legacy row would be frozen: renaming a category, or moving
      # a tag between groups, would fail on a slug field nobody touched, and the
      # only escape would be changing a live URL. Declining to migrate these
      # rows and then freezing them is the worst of both.
      legacy =
        Ash.Seed.seed!(KilnCMS.CMS.Category, %{
          name: "Legacy",
          slug: "news/locale/fr",
          org_id: KilnCMS.Accounts.default_org_id()
        })

      assert {:ok, renamed} =
               CMS.update_category(legacy, %{name: "Renamed"}, actor: admin())

      assert renamed.name == "Renamed"
      assert renamed.slug == "news/locale/fr"

      # But writing a bad slug is still refused, on a legacy row as anywhere.
      assert {:error, error} =
               CMS.update_category(legacy, %{slug: "still/bad"}, actor: admin())

      assert Exception.message(error) =~ "lowercase"
    end

    test "still read and still need encoding at the point of use" do
      # A validation guards new writes and does nothing for what is already
      # stored, so the encoding fixes stay load-bearing. Seeding is how the
      # feed-collision regression test reaches this state too.
      legacy =
        Ash.Seed.seed!(KilnCMS.CMS.Category, %{
          name: "Legacy",
          slug: "news/locale/fr",
          org_id: KilnCMS.Accounts.default_org_id()
        })

      assert legacy.slug == "news/locale/fr"

      assert {:ok, found} =
               CMS.get_category_by_slug("news/locale/fr",
                 authorize?: false,
                 tenant: legacy.org_id
               )

      assert found.id == legacy.id
    end
  end
end
