defmodule KilnCMS.FeedsTest do
  @moduledoc """
  The syndication resolve chain (#719): per-site `FeedSettings` row -> operator
  `config :kiln_cms, :feeds` -> nothing excluded and nothing full-content.

  The point of the issue is the *inversion* a config-only policy produced: one
  tenant asking for a newsletter built from the feed body turned full-text
  syndication on for every other tenant sharing the compiled `post` type, and
  none of them could opt out. So the tests that matter here are the cross-org
  ones — a green single-org suite is exactly what the old shape had.

  `async: false` — these mutate application env and the shared Cachex.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Feeds

  setup do
    original = Application.get_env(:kiln_cms, :feeds, [])
    Application.put_env(:kiln_cms, :feeds, [])

    on_exit(fn ->
      Application.put_env(:kiln_cms, :feeds, original)
      KilnCMS.Cache.bust_feed_policy(Accounts.default_org_id())
    end)

    org = seed_org()
    on_exit(fn -> KilnCMS.Cache.bust_feed_policy(org.id) end)

    %{org: org, admin: admin()}
  end

  describe "fallback chain" do
    test "nothing is excluded and nothing is full-content out of the box", %{org: org} do
      assert Feeds.policy(org) == %{exclude: [], full_content: []}
    end

    test "the operator config is the layer beneath a site", %{org: org} do
      put_config(exclude: ["page"], full_content: ["post"])

      assert Feeds.policy(org) == %{exclude: ["page"], full_content: ["post"]}
      assert Feeds.full_content?(descriptor(:post), org)
      refute Feeds.syndicated?(descriptor(:page), org)
    end

    test "a per-site row overrides the operator config", ctx do
      put_config(full_content: ["post"])
      save(ctx, %{full_content_types: ["page"]})

      policy = Feeds.policy(ctx.org)

      assert policy.full_content == ["page"]
      refute Feeds.full_content?(descriptor(:post), policy)
      assert Feeds.full_content?(descriptor(:page), policy)
    end

    test "the fallback is per field, not all-or-nothing", ctx do
      put_config(exclude: ["page"], full_content: ["post"])
      save(ctx, %{full_content_types: []})

      policy = Feeds.policy(ctx.org)

      # Only full content was said; the exclusion list still inherits.
      assert policy.full_content == []
      assert policy.exclude == ["page"]
    end

    test "an empty list means NONE, not 'unset'", ctx do
      # The distinction the nullable columns exist for. Collapsing `[]` into
      # "inherit" would make an admin who cleared the full-content list fall
      # back to a config that turns it on — the inversion #719 exists to remove.
      put_config(full_content: ["post"])
      save(ctx, %{full_content_types: []})

      refute Feeds.full_content?(descriptor(:post), Feeds.policy(ctx.org))
    end

    test "a site may syndicate a type the operator excluded deployment-wide", ctx do
      # The inversion runs both ways: an operator-wide `exclude` silenced a
      # tenant that wanted the type, with no way for its admin to say otherwise.
      put_config(exclude: ["page"])
      save(ctx, %{excluded_types: []})

      assert Feeds.syndicated?(descriptor(:page), Feeds.policy(ctx.org))
    end

    test "accepts an org struct, a bare id, or nil, and always returns both keys", %{org: org} do
      for arg <- [org, org.id, nil] do
        assert %{exclude: exclude, full_content: full_content} = Feeds.policy(arg)
        assert is_list(exclude) and is_list(full_content)
      end
    end
  end

  describe "cross-org isolation" do
    test "one site's full-content choice never reaches another's feed", ctx do
      # The scenario in the issue, in one test. Tenant A wants the whole body;
      # B and C share the compiled `post` type and must not be opted in for it.
      other = seed_org()
      on_exit(fn -> KilnCMS.Cache.bust_feed_policy(other.id) end)

      save(ctx, %{full_content_types: ["post"]})

      assert Feeds.full_content?(descriptor(:post), Feeds.policy(ctx.org))
      refute Feeds.full_content?(descriptor(:post), Feeds.policy(other))
    end

    test "one site's exclusion never removes another's feed", ctx do
      other = seed_org()
      on_exit(fn -> KilnCMS.Cache.bust_feed_policy(other.id) end)

      save(ctx, %{excluded_types: ["post"]})

      refute Feeds.syndicated?(descriptor(:post), Feeds.policy(ctx.org))
      assert Feeds.syndicated?(descriptor(:post), Feeds.policy(other))
    end

    test "saving twice for one site upserts rather than creating a second row", ctx do
      save(ctx, %{excluded_types: ["post"]})
      save(ctx, %{excluded_types: ["page"]})

      assert {:ok, [row]} = CMS.list_feed_settings(tenant: ctx.org, authorize?: false)
      assert row.excluded_types == ["page"]
    end
  end

  describe "read path" do
    test "never creates a row — an anonymous feed fetch must not INSERT", ctx do
      Feeds.policy(ctx.org)
      Feeds.policy(ctx.org)

      assert {:ok, []} = CMS.list_feed_settings(tenant: ctx.org, authorize?: false)
    end

    test "caches the resolved policy even when the site has no row", ctx do
      Feeds.policy(ctx.org)

      # `KilnCMS.Cache.fetch/3` never caches a nil, so caching the row lookup
      # would mean a DB hit on every feed fetch forever for the (common) site
      # with no settings of its own.
      assert {:ok, %{exclude: _, full_content: _}} =
               Cachex.get(KilnCMS.Cache.cache_name(), KilnCMS.Cache.feed_policy_key(ctx.org.id))
    end

    test "a save is visible immediately, not after the TTL", ctx do
      assert Feeds.policy(ctx.org).full_content == []

      save(ctx, %{full_content_types: ["post"]})

      assert Feeds.policy(ctx.org).full_content == ["post"]
    end

    test "a save also drops this site's cached feed documents", ctx do
      key = KilnCMS.Cache.feed_key(ctx.org.id, "post/category/news", :atom)
      other_key = KilnCMS.Cache.feed_key(seed_org().id, nil, :atom)
      Cachex.put(KilnCMS.Cache.cache_name(), key, "<feed/>")
      Cachex.put(KilnCMS.Cache.cache_name(), other_key, "<feed/>")

      save(ctx, %{full_content_types: ["post"]})

      # Full content decides what is IN a cached body, so leaving the documents
      # cached would keep handing out complete articles for the whole TTL after
      # an admin turned it off — the one setting to be unsure about.
      assert {:ok, nil} = Cachex.get(KilnCMS.Cache.cache_name(), key)
      # Including the taxonomy scopes a publish deliberately leaves to the TTL:
      # this runs on a rare admin save, not inside a publish transaction.
      assert {:ok, "<feed/>"} = Cachex.get(KilnCMS.Cache.cache_name(), other_key)
    end

    test "resetting the row returns the site to the operator defaults", ctx do
      put_config(full_content: ["post"])
      save(ctx, %{full_content_types: []})
      assert Feeds.policy(ctx.org).full_content == []

      {:ok, [row]} = CMS.list_feed_settings(tenant: ctx.org, authorize?: false)
      CMS.reset_feed_settings!(row, actor: ctx.admin, tenant: ctx.org)

      assert Feeds.policy(ctx.org).full_content == ["post"]
    end
  end

  describe "syndicated_types/1" do
    test "filters the org's registry by the resolved policy", ctx do
      save(ctx, %{excluded_types: ["page"]})

      names = ctx.org |> Feeds.syndicated_types() |> Enum.map(&to_string(&1.type))

      assert "post" in names
      refute "page" in names
    end
  end

  describe "malformed configuration" do
    test "atoms in the config still compare against a descriptor's name", %{org: org} do
      # A descriptor's `type` is an atom for a compiled type and a string for a
      # dynamic one, and both are compared as strings. A config written with
      # atoms used to match nothing at all, silently.
      put_config(exclude: [:page], full_content: [:post])

      assert Feeds.policy(org) == %{exclude: ["page"], full_content: ["post"]}
    end

    test "a config value that is not a list degrades to empty, not a crash", %{org: org} do
      put_config(exclude: "page", full_content: nil)

      assert Feeds.policy(org) == %{exclude: [], full_content: []}
    end
  end

  describe "entry_limit/0" do
    test "stays deployment-wide: it bounds server work, not a publishing choice" do
      put_config(entry_limit: 5)
      assert Feeds.entry_limit() == 5

      put_config(entry_limit: 10_000)
      assert Feeds.entry_limit() == 200

      put_config(entry_limit: "lots")
      assert Feeds.entry_limit() == 50
    end
  end

  describe "authorization" do
    test "a non-admin can neither read nor write a site's syndication policy", ctx do
      editor =
        Ash.Seed.seed!(Accounts.User, %{
          email: "feeds-editor-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password1234!"),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        })

      save(ctx, %{full_content_types: ["post"]})

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_feed_settings(%{full_content_types: []},
                 actor: editor,
                 tenant: ctx.org
               )

      # A read a policy declines resolves to *no rows* rather than an error, so
      # assert on the rows: an editor sees none even though one exists.
      assert {:ok, []} = CMS.list_feed_settings(actor: editor, tenant: ctx.org)
      assert {:ok, [_row]} = CMS.list_feed_settings(actor: ctx.admin, tenant: ctx.org)
    end
  end

  defp descriptor(type), do: ContentTypes.get!(type)

  defp save(%{org: org, admin: admin}, attrs) do
    CMS.save_feed_settings!(attrs, actor: admin, tenant: org)
  end

  defp put_config(opts), do: Application.put_env(:kiln_cms, :feeds, opts)

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Feeds Org",
      slug: "feeds-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp admin do
    Ash.Seed.seed!(Accounts.User, %{
      email: "feeds-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password1234!"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end
end
