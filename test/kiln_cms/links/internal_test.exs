defmodule KilnCMS.Links.InternalTest do
  @moduledoc """
  Internal link resolution (#474).

  The thing worth testing here is agreement with *delivery*: a checker that
  disagrees with what a visitor actually gets is worse than no checker, because
  it reports working links and misses broken ones until an editor stops reading
  the panel.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Links.Internal

  @locale "en"

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "links-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    %{admin: admin, org: KilnCMS.Accounts.default_org_id()}
  end

  defp slug, do: "lnk-#{System.unique_integer([:positive])}"

  defp post(attrs, admin) do
    CMS.create_post!(Map.merge(%{title: "T", slug: slug()}, attrs), actor: admin)
  end

  # As an admin, who reads every state: most of these tests are about paths,
  # not permissions. What a narrower reader sees is its own describe below.
  defp resolve(path, org, actor), do: Internal.resolve(path, @locale, org, actor)

  describe "a flat /prefix/slug path" do
    test "a published post resolves", %{admin: admin, org: org} do
      p = %{slug: slug()} |> post(admin) |> then(&CMS.publish_post!(&1, actor: admin))

      assert resolve("/blog/#{p.slug}", org, admin) == :published
    end

    test "a draft is unpublished, not missing", %{admin: admin, org: org} do
      p = post(%{slug: slug()}, admin)

      # Delivery cannot tell these apart — both 404 — but they need opposite
      # actions. Collapsing them sends an editor hunting for a typo in a link
      # that is perfectly correct.
      assert resolve("/blog/#{p.slug}", org, admin) == {:unpublished, :draft}
    end

    test "an archived post is unpublished, and names the state", %{admin: admin, org: org} do
      p = %{slug: slug()} |> post(admin) |> then(&CMS.publish_post!(&1, actor: admin))
      CMS.archive_post!(p, actor: admin)

      assert {:unpublished, :archived} = resolve("/blog/#{p.slug}", org, admin)
    end

    test "an unknown slug under a known prefix is missing", %{admin: admin, org: org} do
      assert resolve("/blog/nothing-here-#{System.unique_integer([:positive])}", org, admin) ==
               :missing
    end

    test "an unknown prefix is UNKNOWN, not missing", %{admin: admin, org: org} do
      # The prefix names no content type, so this is not a namespace we own —
      # it could be a plugin route, a static page, anything. Calling it broken
      # is the false positive that makes a link checker useless.
      assert resolve("/nope/whatever", org, admin) == :unknown
    end
  end

  # Each of these was a false `:error` in the first draft, and one `:error`
  # grades a whole document Poor — so a single "read more on our blog" link
  # would have marked every page on the site as failing.
  describe "paths the router serves that this module does not own" do
    test "the home page, section indexes and static routes are unknown", %{admin: admin, org: org} do
      for path <- ["/", "/blog", "/search", "/developers", "/feed.xml", "/uploads/a.png"] do
        assert resolve(path, org, admin) == :unknown, "expected #{path} to be :unknown"
      end
    end

    test "a single segment is never called missing, even unrecognised", %{admin: admin, org: org} do
      # `/about` is as likely a plugin route or a static page as a root-served
      # document, and a wrong `:missing` costs far more than a missed one.
      assert resolve("/about-#{System.unique_integer([:positive])}", org, admin) == :unknown
    end

    test "a deep path with no alias is unknown — deep paths are redirect sources",
         %{admin: admin, org: org} do
      assert resolve("/2019/05/an-old-post", org, admin) == :unknown
    end
  end

  describe "locales" do
    test "a locale-prefixed URL resolves, because SetLocale strips it", %{admin: admin, org: org} do
      p = %{slug: slug()} |> post(admin) |> then(&CMS.publish_post!(&1, actor: admin))

      # Every hreflang link and the locale switcher emit exactly this shape, so
      # an author copying a live URL gets one. Splitting it into three segments
      # and finding nothing would report it broken.
      assert resolve("/en/blog/#{p.slug}", org, admin) == :published
      assert resolve("/fr/blog/#{p.slug}", org, admin) == :published
    end

    test "a link written in another locale falls back to the default", %{admin: admin, org: org} do
      p = %{slug: slug()} |> post(admin) |> then(&CMS.publish_post!(&1, actor: admin))

      # Delivery retries in the default locale when a localized lookup misses
      # (`ContentController.localized/2`). Without the same retry, every link in
      # a translated document on a partially translated site reads as broken.
      assert Internal.resolve("/blog/#{p.slug}", "fr", org, admin) == :published
    end
  end

  describe "normalization" do
    test "a query string and a fragment name the same document", %{admin: admin, org: org} do
      p = %{slug: slug()} |> post(admin) |> then(&CMS.publish_post!(&1, actor: admin))

      # An anchor into a page that exists is not a broken link.
      assert resolve("/blog/#{p.slug}#section", org, admin) == :published
      assert resolve("/blog/#{p.slug}?utm=x", org, admin) == :published
      assert resolve("/blog/#{p.slug}/", org, admin) == :published
    end

    test "resolve_all keys by the caller's paths, not the normalized ones",
         %{admin: admin, org: org} do
      p = %{slug: slug()} |> post(admin) |> then(&CMS.publish_post!(&1, actor: admin))
      path = "/blog/#{p.slug}"
      variants = [path, path <> "#a", path <> "?b=1"]

      resolved = Internal.resolve_all(variants, @locale, org, admin)

      # Every path the caller passed is a key it can look up. Keying on the
      # normalized form would hand back a map whose keys the caller does not
      # hold — and the advisory check looks up the raw body paths.
      assert Enum.sort(Map.keys(resolved)) == Enum.sort(variants)
      assert Enum.all?(variants, &(resolved[&1] == :published))
    end

    test "resolve_all mixes internal and external without confusing them", %{org: org} do
      resolved =
        Internal.resolve_all(
          [
            "https://example.com/x",
            "//evil.example/y",
            "/nope-#{System.unique_integer([:positive])}"
          ],
          @locale,
          org,
          nil
        )

      assert resolved["https://example.com/x"] == :external
      assert resolved["//evil.example/y"] == :external
      assert map_size(resolved) == 3
    end
  end

  describe "what is not an internal path" do
    test "an absolute URL is external, never resolved against our content", %{org: org} do
      assert resolve("https://example.com/blog/x", org, nil) == :external
      assert resolve("mailto:a@example.com", org, nil) == :external
      assert resolve("#anchor-only", org, nil) == :external
    end

    test "a protocol-relative URL is external, not a path", %{org: org} do
      # `//evil.example/x` is an absolute URL wearing a leading slash. Treating
      # it as a path is how a checker starts resolving other people's hostnames
      # against its own content — and would report someone else's site as a
      # broken link on yours.
      assert resolve("//evil.example/blog/x", org, nil) == :external
      assert resolve("//evil.example", org, nil) == :external
    end
  end

  describe "dynamic types share one storage table" do
    test "a slug only resolves under its own type's prefix", %{admin: admin, org: org} do
      one = "lt#{System.unique_integer([:positive])}"
      two = "lt#{System.unique_integer([:positive])}"

      td_one =
        CMS.create_type_definition!(%{name: one, label: "One", path_segment: one}, actor: admin)

      CMS.create_type_definition!(%{name: two, label: "Two", path_segment: two}, actor: admin)

      shared = slug()

      entry =
        CMS.create_entry!(
          %{title: "E", slug: shared, type_definition_id: td_one.id},
          actor: admin
        )

      CMS.publish_entry!(entry, actor: admin)

      # Every dynamic type lives in `KilnCMS.CMS.Entry`, so a filter on slug
      # alone resolves one type's URL against another's content — dialyzer
      # caught the original attempt matching a `:name` key the descriptor has
      # never had, which would have silently done exactly that.
      assert resolve("/#{one}/#{shared}", org, admin) == :published
      assert resolve("/#{two}/#{shared}", org, admin) == :missing
    end
  end

  describe "redirects" do
    test "a renamed post's old path is redirected, not broken", %{admin: admin, org: org} do
      original = slug()
      p = %{slug: original} |> post(admin) |> then(&CMS.publish_post!(&1, actor: admin))
      CMS.update_post!(p, %{slug: slug()}, actor: admin)

      # A published rename leaves a Redirect behind and delivery serves a 301.
      # Reporting that would flag a working feature as a fault, which is the
      # fastest way to make an advisory panel something authors ignore.
      assert resolve("/blog/#{original}", org, admin) == :redirected
      refute Internal.problem?(resolve("/blog/#{original}", org, admin))
    end
  end

  # The advisory runs on the editor's own request, so it answers only what that
  # editor may read. Looking in every state as the system would tell a scoped
  # editor that a draft exists at a guessed path, and what state it is in.
  describe "it reads as the caller" do
    setup do
      restricted =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "links-restricted-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :editor,
          # Granular RBAC (#332): drafts in "page" only, published posts as
          # any signed-in reader sees them.
          readable_types: ["page"]
        })

      %{restricted: restricted}
    end

    test "a draft outside the editor's read scope is missing, not unpublished",
         %{admin: admin, org: org, restricted: restricted} do
      p = post(%{slug: slug()}, admin)

      assert resolve("/blog/#{p.slug}", org, admin) == {:unpublished, :draft}
      assert resolve("/blog/#{p.slug}", org, restricted) == :missing
    end

    test "published content outside the scope still resolves",
         %{admin: admin, org: org, restricted: restricted} do
      p = %{slug: slug()} |> post(admin) |> then(&CMS.publish_post!(&1, actor: admin))

      # The scope narrows editorial visibility only; a published post is one
      # this editor could open on the site, so its link is fine.
      assert resolve("/blog/#{p.slug}", org, restricted) == :published
    end

    test "resolve_all hides the same targets", %{admin: admin, org: org, restricted: restricted} do
      draft = post(%{slug: slug()}, admin)
      path = "/blog/#{draft.slug}"

      assert Internal.resolve_all([path], @locale, org, restricted) == %{path => :missing}
    end

    test "with no actor, only public published content exists", %{admin: admin, org: org} do
      draft = post(%{slug: slug()}, admin)
      live = %{slug: slug()} |> post(admin) |> then(&CMS.publish_post!(&1, actor: admin))

      assert resolve("/blog/#{draft.slug}", org, nil) == :missing
      assert resolve("/blog/#{live.slug}", org, nil) == :published
    end
  end

  describe "problem?/1 is the single definition of a fault" do
    test "only missing and unpublished are worth telling an author about" do
      assert Internal.problem?(:missing)
      assert Internal.problem?({:unpublished, :draft})
      refute Internal.problem?(:published)
      refute Internal.problem?(:redirected)
      refute Internal.problem?(:external)
      # The one that matters most: "I could not judge this" is not a fault.
      refute Internal.problem?(:unknown)
    end
  end
end
