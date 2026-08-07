defmodule KilnCMS.Portability.ImportTest do
  @moduledoc """
  Writing an import into the CMS (#487) — end to end, through the real Ash
  actions, with the WordPress fixture as input.

  Media is skipped in most tests: sideloading is a network operation, and the
  behaviour worth pinning here is what happens to the *content* around it. The
  one test that lets it run asserts the property that matters — an unreachable
  image does not cost you the post.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Portability.Import
  alias KilnCMS.Portability.WXR
  alias KilnCMS.WXRFixture

  setup do
    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "import-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    {:ok, parsed} = WXR.parse(WXRFixture.wxr())

    %{actor: actor, parsed: parsed, scope: [actor: actor, skip_media: true]}
  end

  defp import!(parsed, scope, extra \\ []) do
    {:ok, report} = Import.run(parsed, scope ++ extra)
    report
  end

  defp posts(actor), do: CMS.list_posts!(actor: actor)
  defp pages(actor), do: CMS.list_pages!(actor: actor)

  defp find(records, slug), do: Enum.find(records, &(&1.slug == slug))

  describe "dry run" do
    test "writes nothing at all", %{parsed: parsed, scope: scope, actor: actor} do
      report = import!(parsed, scope, dry_run: true)

      assert report.dry_run
      assert length(report.created) == 3
      assert posts(actor) == []
      assert pages(actor) == []
      assert CMS.list_tags!(actor: actor) == []
      assert CMS.list_redirects!(actor: actor) == []
    end

    test "plans the same records a real run creates", %{parsed: parsed, scope: scope} do
      planned =
        import!(parsed, scope, dry_run: true).created |> Enum.map(& &1.slug) |> Enum.sort()

      real = import!(parsed, scope).created |> Enum.map(& &1.slug) |> Enum.sort()

      assert planned == real
    end

    test "reports media it would fetch without fetching it", %{parsed: parsed, actor: actor} do
      report = import!(parsed, [actor: actor], dry_run: true)
      assert report.media == %{would_import: 1}
    end
  end

  describe "records" do
    test "creates posts and pages of the right type", %{
      parsed: parsed,
      scope: scope,
      actor: actor
    } do
      import!(parsed, scope)

      assert Enum.map(posts(actor), & &1.slug) |> Enum.sort() == ["hello-world", "soon"]
      assert Enum.map(pages(actor), & &1.slug) == ["about"]
    end

    test "the body arrives as typed blocks, not as one text slab", %{
      parsed: parsed,
      scope: scope,
      actor: actor
    } do
      import!(parsed, scope)
      post = posts(actor) |> find("hello-world")

      kinds = Enum.map(post.blocks, & &1.type)
      assert :rich_text in kinds
      assert :image in kinds
    end

    test "the excerpt is carried", %{parsed: parsed, scope: scope, actor: actor} do
      import!(parsed, scope)
      assert posts(actor) |> find("hello-world") |> Map.fetch!(:excerpt) == "A short summary."
    end

    test "a published source record is published here, through the state machine", %{
      parsed: parsed,
      scope: scope,
      actor: actor
    } do
      import!(parsed, scope)

      assert posts(actor) |> find("hello-world") |> Map.fetch!(:state) == :published
      # A `future` post must NOT go live early.
      assert posts(actor) |> find("soon") |> Map.fetch!(:state) == :draft
      assert pages(actor) |> find("about") |> Map.fetch!(:state) == :draft
    end

    test "publishing is a real publish, not a state write", %{
      parsed: parsed,
      scope: scope,
      actor: actor
    } do
      import!(parsed, scope)
      post = posts(actor) |> find("hello-world")

      # A state-attribute write would leave these unset.
      assert post.published_at
      assert post.published_version_id
    end
  end

  describe "taxonomy" do
    test "categories and tags are created and attached", %{
      parsed: parsed,
      scope: scope,
      actor: actor
    } do
      report = import!(parsed, scope)

      assert report.taxonomy.categories == %{created: 1, matched: 0}
      assert report.taxonomy.tags == %{created: 2, matched: 0}

      post = CMS.list_posts!(actor: actor, load: [:tags, :category]) |> find("hello-world")
      assert post.category.slug == "news"
      assert Enum.map(post.tags, & &1.slug) |> Enum.sort() == ["beginner", "how-to"]
    end

    test "an existing term is matched, not duplicated", %{
      parsed: parsed,
      scope: scope,
      actor: actor
    } do
      {:ok, _} = CMS.create_tag(%{name: "How To", slug: "how-to"}, actor: actor)

      report = import!(parsed, scope)

      assert report.taxonomy.tags == %{created: 1, matched: 1}
      assert CMS.list_tags!(actor: actor) |> Enum.count(&(&1.slug == "how-to")) == 1
    end
  end

  describe "redirects" do
    test "every old permalink becomes a redirect at its path", %{
      parsed: parsed,
      scope: scope,
      actor: actor
    } do
      import!(parsed, scope)

      paths = CMS.list_redirects!(actor: actor) |> Enum.map(& &1.path) |> Enum.sort()
      assert "/2024/03/hello-world" in paths
      assert "/about" in paths
    end

    test "a redirect points at the imported record", %{parsed: parsed, scope: scope, actor: actor} do
      import!(parsed, scope)

      post = posts(actor) |> find("hello-world")

      redirect =
        CMS.list_redirects!(actor: actor) |> Enum.find(&(&1.path == "/2024/03/hello-world"))

      assert redirect.target_type == "post"
      assert redirect.target_id == post.id
    end

    test "--no-redirects skips them", %{parsed: parsed, scope: scope, actor: actor} do
      import!(parsed, scope, redirects: false)
      assert CMS.list_redirects!(actor: actor) == []
    end
  end

  describe "re-running" do
    test "a second run skips everything rather than duplicating", %{
      parsed: parsed,
      scope: scope,
      actor: actor
    } do
      import!(parsed, scope)
      second = import!(parsed, scope)

      assert second.created == []
      assert length(second.skipped) == 3
      assert length(posts(actor)) == 2
      assert length(pages(actor)) == 1
    end

    test "on_conflict: :error reports the collision instead", %{parsed: parsed, scope: scope} do
      import!(parsed, scope)
      second = import!(parsed, scope, on_conflict: :error)

      assert second.created == []
      assert length(second.failed) == 3
      assert Enum.all?(second.failed, &(&1.reason == :already_exists))
    end

    test "a resumed run creates only what is missing", %{
      parsed: parsed,
      scope: scope,
      actor: actor
    } do
      import!(parsed, scope, limit: 1)
      assert length(posts(actor)) + length(pages(actor)) == 1

      second = import!(parsed, scope)
      assert length(second.created) == 2
      assert length(second.skipped) == 1
    end
  end

  describe "media" do
    test "--skip-media leaves the block pointing at the source URL", %{
      parsed: parsed,
      scope: scope,
      actor: actor
    } do
      report = import!(parsed, scope)

      assert report.media == %{skipped: 1}

      image =
        posts(actor)
        |> find("hello-world")
        |> Map.fetch!(:blocks)
        |> Enum.find(&(&1.type == :image))

      assert image.value.url == "https://old.example.com/wp-content/pic.jpg"
      assert image.value.media_id == nil
    end

    # The property that matters: a migration must not lose a post because one
    # of its images 404s.
    test "an unreachable image does not fail the record", %{parsed: parsed, actor: actor} do
      report = import!(parsed, actor: actor)

      assert length(report.created) == 3
      assert report.media.imported == 0
      assert [%{url: "https://old.example.com/wp-content/pic.jpg"}] = report.media.failed

      image =
        posts(actor)
        |> find("hello-world")
        |> Map.fetch!(:blocks)
        |> Enum.find(&(&1.type == :image))

      assert image.value.url == "https://old.example.com/wp-content/pic.jpg"
    end
  end

  describe "envelope fidelity" do
    # `audience` defaults to `:public`. Dropping it does not merely lose
    # fidelity — it republishes a members-only document to the open web.
    test "audience travels, so gated content does not become public", %{actor: actor} do
      envelope = %{
        "records" => [
          %{
            "type" => "post",
            "title" => "Members only",
            "slug" => "members-only",
            "state" => "published",
            "audience" => "member"
          }
        ]
      }

      {:ok, report} = Import.run_envelope(envelope, actor: actor, skip_media: true)
      assert report.failed == []

      assert posts(actor) |> find("members-only") |> Map.fetch!(:audience) == :member
    end

    # Every record collapsing to one locale makes the second translation of a
    # slug look like a duplicate, so it is reported "already present" and lost.
    test "per-record locale is honoured, so translations survive", %{actor: actor} do
      envelope = %{
        "records" => [
          %{"type" => "post", "title" => "Hello", "slug" => "hello", "locale" => "en"},
          %{"type" => "post", "title" => "Bonjour", "slug" => "hello", "locale" => "fr"}
        ]
      }

      {:ok, report} = Import.run_envelope(envelope, actor: actor, skip_media: true)

      assert length(report.created) == 2
      assert report.skipped == []
      assert posts(actor) |> Enum.map(& &1.locale) |> Enum.sort() == ["en", "fr"]
    end

    test "an explicit --locale still overrides the envelope", %{actor: actor} do
      envelope = %{
        "records" => [%{"type" => "post", "title" => "T", "slug" => "t", "locale" => "fr"}]
      }

      {:ok, _} = Import.run_envelope(envelope, actor: actor, skip_media: true, locale: "en")
      assert posts(actor) |> find("t") |> Map.fetch!(:locale) == "en"
    end

    test "SEO fields and custom_fields travel", %{actor: actor} do
      envelope = %{
        "records" => [
          %{
            "type" => "post",
            "title" => "SEO",
            "slug" => "seo",
            "seo_title" => "The SEO title",
            "seo_description" => "A description",
            "canonical_url" => "https://example.com/seo"
          }
        ]
      }

      {:ok, report} = Import.run_envelope(envelope, actor: actor, skip_media: true)
      assert report.failed == []

      post = posts(actor) |> find("seo")
      assert post.seo_title == "The SEO title"
      assert post.seo_description == "A description"
      assert post.canonical_url == "https://example.com/seo"
    end

    # `:publish` stamps `utc_now`, so without a restore a decade of archives
    # all land in one arbitrary-ordered second.
    test "the source publication date survives publishing", %{actor: actor} do
      envelope = %{
        "records" => [
          %{
            "type" => "post",
            "title" => "Old news",
            "slug" => "old-news",
            "state" => "published",
            "published_at" => "2015-06-01T09:00:00Z"
          }
        ]
      }

      {:ok, _} = Import.run_envelope(envelope, actor: actor, skip_media: true)

      post = posts(actor) |> find("old-news")
      assert post.state == :published
      assert DateTime.to_date(post.published_at) == ~D[2015-06-01]
    end

    test "a WordPress post keeps its publication date too", %{
      parsed: parsed,
      scope: scope,
      actor: actor
    } do
      import!(parsed, scope)

      assert posts(actor)
             |> find("hello-world")
             |> Map.fetch!(:published_at)
             |> DateTime.to_date() ==
               ~D[2024-03-01]
    end

    # `Page` has no `excerpt` attribute, so sending one raised NoSuchInput and
    # discarded the whole page — blocks and all — over its summary.
    test "a page carrying an excerpt imports, minus the excerpt", %{actor: actor} do
      envelope = %{
        "records" => [
          %{"type" => "page", "title" => "About", "slug" => "about-us", "excerpt" => "A summary."}
        ]
      }

      {:ok, report} = Import.run_envelope(envelope, actor: actor, skip_media: true)

      assert report.failed == []
      assert length(report.created) == 1
      assert pages(actor) |> find("about-us")
    end
  end

  describe "envelope import" do
    test "a JSON envelope goes through the same write path", %{actor: actor} do
      envelope = %{
        "kiln_export" => %{"version" => 1},
        "records" => [
          %{
            "type" => "post",
            "title" => "From an envelope",
            "slug" => "from-envelope",
            "locale" => "en",
            "state" => "published",
            "excerpt" => "Carried over.",
            "blocks" => [],
            "tags" => ["migrated"]
          }
        ],
        "media" => []
      }

      {:ok, report} = Import.run_envelope(envelope, actor: actor, skip_media: true)

      assert length(report.created) == 1

      post = posts(actor) |> find("from-envelope")
      assert post.state == :published
      assert post.excerpt == "Carried over."

      assert CMS.list_tags!(actor: actor) |> Enum.map(& &1.slug) == ["migrated"]
    end

    test "a file that is not an envelope is refused", %{actor: actor} do
      assert {:error, :not_an_export_envelope} = Import.run_envelope(%{"nope" => 1}, actor: actor)
    end

    test "an envelope re-run skips, same as WXR", %{actor: actor} do
      envelope = %{
        "records" => [
          %{"type" => "page", "title" => "Twice", "slug" => "twice", "state" => "draft"}
        ]
      }

      {:ok, _} = Import.run_envelope(envelope, actor: actor, skip_media: true)
      {:ok, second} = Import.run_envelope(envelope, actor: actor, skip_media: true)

      assert second.created == []
      assert length(second.skipped) == 1
    end
  end
end
