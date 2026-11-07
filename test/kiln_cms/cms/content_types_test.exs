defmodule KilnCMS.CMS.ContentTypesTest do
  @moduledoc """
  The content-type registry: auto-discovery, public-path metadata, and generic
  dispatch to the per-type `CMS.*` code interfaces.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  defp slug, do: "ct-#{System.unique_integer([:positive])}"

  describe "discovery" do
    test "finds the content types (and not taxonomy/join resources)" do
      types = ContentTypes.types()
      assert :page in types
      assert :post in types
      refute :tag in types
      refute :category in types
    end

    test "describes each type with label, plural and excerpt flag" do
      post = ContentTypes.get(:post)
      assert post.label == "Post"
      assert post.plural == "posts"
      assert post.excerpt? == true

      page = ContentTypes.get(:page)
      assert page.excerpt? == false
    end

    test "get/1 accepts a string and returns nil for unknown types" do
      assert ContentTypes.get("page").type == :page
      assert ContentTypes.get("widget") == nil
      refute ContentTypes.type?("widget")
    end
  end

  describe "public paths" do
    test "pages serve at the root, posts under /blog" do
      assert ContentTypes.public_prefix(ContentTypes.get(:page)) == ""
      assert ContentTypes.public_prefix(ContentTypes.get(:post)) == "/blog"
    end

    test "get_by_path resolves the URL segment to a content type" do
      assert ContentTypes.get_by_path("blog").type == :post
      # Pages have no segment (served at root), so they aren't matched here.
      assert ContentTypes.get_by_path("pages") == nil
      assert ContentTypes.get_by_path("widgets") == nil
    end
  end

  describe "dispatch" do
    test "create!/get_record!/list! go through the code interfaces" do
      page = ContentTypes.create!(:page, %{title: "T", slug: slug()}, authorize?: false)
      assert ContentTypes.get_record!(:page, page.id, authorize?: false).id == page.id
      assert Enum.any?(ContentTypes.list!(:page, authorize?: false), &(&1.id == page.id))
    end

    test "get_published_by_slug returns published content only" do
      s = slug()
      post = CMS.create_post!(%{title: "P", slug: s}, authorize?: false)

      # Draft: not delivered.
      assert ContentTypes.get_published_by_slug(:post, s, "en",
               authorize?: false,
               not_found_error?: false
             ) == nil

      CMS.publish_post!(post, %{}, authorize?: false)

      assert ContentTypes.get_published_by_slug(:post, s, "en",
               authorize?: false,
               not_found_error?: false
             ).id == post.id
    end

    test "transition runs a workflow action" do
      page = ContentTypes.create!(:page, %{title: "T", slug: slug()}, authorize?: false)
      {:ok, published} = ContentTypes.transition(:page, "publish", page, authorize?: false)
      assert published.state == :published
    end
  end

  # #527: `all_for_org/1` and `options/2` replace ~20 hand-rolled
  # `all() ++ dynamic_all(org_id(...))` expressions, whose per-call-site `org_id`
  # helpers disagreed on `nil` — several raised where the rest fell back.
  describe "per-organization enumeration" do
    defp define_type!(label) do
      admin =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "ct-admin-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      CMS.create_type_definition!(
        %{name: "t#{System.unique_integer([:positive])}", label: label},
        actor: admin
      )
    end

    test "all_for_org/1 takes an org struct, a bare id, or nil" do
      org =
        KilnCMS.Accounts.get_organization!(KilnCMS.Accounts.default_org_id(), authorize?: false)

      expected = ContentTypes.all_for_org(org.id)
      assert ContentTypes.all_for_org(org) == expected
      assert ContentTypes.all_for_org(nil) == expected
    end

    test "all_for_org/1 lists the compiled types, then the org's dynamic ones" do
      definition = define_type!("Zebra")
      descriptors = ContentTypes.all_for_org(nil)

      compiled = Enum.filter(descriptors, &(&1.source == :compiled))
      assert Enum.map(compiled, & &1.type) == Enum.map(ContentTypes.all(), & &1.type)

      # Sorted by label within each half, and NOT resorted across the seam —
      # "Zebra" stays after every compiled type despite sorting last overall.
      assert List.last(descriptors).type == definition.name
    end

    # The pick-list agrees with `all_for_org/1`, and with the grouped
    # "Built-in"/"Custom" pickers: compiled first, then the org's own. Guarded
    # with a label that sorts before every compiled one, so a sort across the
    # seam would move it to the front.
    test "options/2 keeps the compiled/dynamic seam, it does not sort across it" do
      definition = define_type!("Aardvark")
      options = ContentTypes.options(nil)

      assert Enum.map(options, &elem(&1, 0)) ==
               Enum.map(ContentTypes.all_for_org(nil), & &1.label)

      assert List.last(options) == {"Aardvark", definition.name}
    end

    test "options/2 returns {label, type-name string} pairs" do
      definition = define_type!("Recipe")
      options = ContentTypes.options(nil)

      assert {"Page", "page"} in options
      assert {"Recipe", definition.name} in options
    end

    test "options/2 puts :prompt first and never sorts it into the list" do
      [first | rest] = ContentTypes.options(nil, prompt: {"— Zzz —", ""})

      assert first == {"— Zzz —", ""}
      assert rest == ContentTypes.options(nil)
    end
  end

  # "Move to trash" (#2137) offers the control from this, and its handlers ask
  # it again before writing — so it must give the destroy policy's answer:
  # admin of the RECORD's org, whatever the state, and nobody else.
  describe "can_destroy?/4" do
    defp user(role) do
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "ct-trash-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: role
      })
    end

    defp membership(user, org, tier) do
      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: user.id,
        organization_id: org.id,
        role: tier
      })
    end

    test "an admin may trash a page, draft or published; an editor may not" do
      admin = user(:admin)
      editor = user(:editor)
      draft = CMS.create_page!(%{title: "D", slug: slug()}, actor: admin)
      page = CMS.create_page!(%{title: "P", slug: slug()}, actor: admin)
      published = CMS.publish_page!(page, %{}, actor: admin)

      assert ContentTypes.can_destroy?(:page, draft, admin)
      assert ContentTypes.can_destroy?("page", published, admin)
      refute ContentTypes.can_destroy?(:page, draft, editor)
      refute ContentTypes.can_destroy?("page", published, editor)
    end

    test "a membership admin may trash on their org despite a global editor role" do
      site = KilnCMS.OrgFixtures.org("ct-trash")
      site_admin = user(:editor)
      membership(site_admin, site, :admin)
      post = CMS.create_post!(%{title: "P", slug: slug()}, actor: site_admin, tenant: site)

      assert ContentTypes.can_destroy?(:post, post, site_admin, tenant: site)
    end

    test "admin of another org is not admin here" do
      site = KilnCMS.OrgFixtures.org("ct-trash-here")
      elsewhere = KilnCMS.OrgFixtures.org("ct-trash-there")
      user = user(:editor)
      membership(user, site, :editor)
      membership(user, elsewhere, :admin)

      here = CMS.create_page!(%{title: "Here", slug: slug()}, actor: user, tenant: site)
      there = CMS.create_page!(%{title: "There", slug: slug()}, actor: user, tenant: elsewhere)

      refute ContentTypes.can_destroy?(:page, here, user, tenant: site)
      assert ContentTypes.can_destroy?(:page, there, user, tenant: elsewhere)
    end

    test "a dynamic type routes to the entry policy" do
      admin = user(:admin)
      editor = user(:editor)

      definition =
        CMS.create_type_definition!(
          %{name: "t#{System.unique_integer([:positive])}", label: "Trashable"},
          actor: admin
        )

      entry = ContentTypes.create!(definition.name, %{title: "E", slug: slug()}, actor: admin)

      assert ContentTypes.can_destroy?(definition.name, entry, admin)
      refute ContentTypes.can_destroy?(definition.name, entry, editor)
    end
  end
end
