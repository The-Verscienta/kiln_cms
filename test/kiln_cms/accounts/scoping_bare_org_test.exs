defmodule KilnCMS.Accounts.ScopingBareOrgTest do
  @moduledoc """
  `Scoping.permitted?/4` and `explicitly_permits?/4` judge a bare org id, an
  `%Organization{}`, a query/changeset and a plain `%{tenant: org}` map on the
  SAME org (#2599). A bare id used to resolve to the default site, so a member
  of another site was judged on the wrong one.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Checks.ReadableContentType

  defp user do
    Ash.Seed.seed!(User, %{
      email: "bare-org-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  defp membership(user, org_id, attrs) do
    Ash.Seed.seed!(
      OrgMembership,
      Map.merge(
        %{user_id: user.id, organization_id: org_id, role: :editor, status: :active},
        Map.new(attrs)
      )
    )
  end

  setup do
    org_b = org("bare-b")
    default = Accounts.default_org_id()
    %{org_b: org_b, default: default}
  end

  describe "member narrow on org B, unrestricted on the default site" do
    setup %{org_b: org_b, default: default} do
      actor = user()
      membership(actor, default, editable_types: [], readable_types: [])
      membership(actor, org_b.id, editable_types: ["post"], readable_types: ["post"])
      %{actor: actor}
    end

    test "a bare id is judged on that org, as an Organization and a query are", ctx do
      query = Ash.Query.new(CMS.Page) |> Ash.Query.set_tenant(ctx.org_b.id)

      for subject <- [ctx.org_b.id, ctx.org_b, query, %{tenant: ctx.org_b.id}] do
        assert Scoping.permitted?(ctx.actor, subject, :editable_types, "post")
        refute Scoping.permitted?(ctx.actor, subject, :editable_types, "page")
        assert Scoping.explicitly_permits?(ctx.actor, subject, :editable_types, "post")
        refute Scoping.explicitly_permits?(ctx.actor, subject, :editable_types, "page")
      end
    end

    test "nil and a tenant-less subject are the default site", ctx do
      for subject <- [nil, %{}, Ash.Query.new(CMS.Page), %{tenant: nil}] do
        assert Scoping.permitted?(ctx.actor, subject, :editable_types, "page")
        refute Scoping.explicitly_permits?(ctx.actor, subject, :editable_types, "page")
      end
    end

    test "the default id names the default site", ctx do
      assert Scoping.permitted?(ctx.actor, ctx.default, :editable_types, "page")
    end
  end

  test "the inverse: narrow on the default site, open on B is judged on B", ctx do
    actor = user()
    membership(actor, ctx.default, editable_types: ["post"])
    membership(actor, ctx.org_b.id, editable_types: [])

    assert Scoping.permitted?(actor, ctx.org_b.id, :editable_types, "page")
    refute Scoping.explicitly_permits?(actor, ctx.org_b.id, :editable_types, "page")
    refute Scoping.permitted?(actor, ctx.default, :editable_types, "page")
  end

  test "an actor with no membership on the named org is denied by a bare id", ctx do
    foreign = user()
    membership(foreign, ctx.default, editable_types: [])

    refute Scoping.permitted?(foreign, ctx.org_b.id, :editable_types, "post")
    refute Scoping.explicitly_permits?(foreign, ctx.org_b.id, :editable_types, "post")
  end

  test "a pending registration grants nothing, by bare id", ctx do
    pending = user()
    membership(pending, ctx.org_b.id, status: :pending, editable_types: ["post"])

    refute Scoping.permitted?(pending, ctx.org_b.id, :editable_types, "post")
    refute Scoping.explicitly_permits?(pending, ctx.org_b.id, :editable_types, "post")
  end

  test "a shape that cannot name an org raises instead of judging the default site", ctx do
    actor = user()

    for bad <- [42, :org, ["x"], {:tenant, ctx.org_b.id}] do
      assert_raise ArgumentError, ~r/cannot resolve an org/, fn ->
        Scoping.permitted?(actor, bad, :editable_types, "post")
      end

      assert_raise ArgumentError, ~r/cannot resolve an org/, fn ->
        Scoping.explicitly_permits?(actor, bad, :readable_types, "post")
      end
    end
  end

  describe "ReadableContentType with a plain-map subject (the preview token's shape)" do
    setup %{org_b: org_b, default: default} do
      actor = user()
      membership(actor, default, readable_types: [])
      membership(actor, org_b.id, readable_types: ["post"])
      %{actor: actor}
    end

    test "%{tenant: org_b} is judged on org B", %{actor: actor, org_b: org_b} do
      subject = %{tenant: org_b.id}

      assert ReadableContentType.match?(actor, %{resource: CMS.Post, subject: subject}, [])
      refute ReadableContentType.match?(actor, %{resource: CMS.Page, subject: subject}, [])
    end

    test "a tenant-less plain map is the default site", %{actor: actor} do
      assert ReadableContentType.match?(actor, %{resource: CMS.Page, subject: %{}}, [])
    end
  end

  describe "EditableReleaseContent carries the changeset tenant (strict-tenancy leg)" do
    test "an org B editor scoped to posts may add a post but not a page to an org B release",
         ctx do
      admin =
        Ash.Seed.seed!(User, %{
          email: "bare-admin-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      actor = user()
      membership(actor, ctx.default, editable_types: [])
      membership(actor, ctx.org_b.id, editable_types: ["post"])

      release =
        CMS.create_release!(%{name: "Bare #{System.unique_integer([:positive])}"},
          actor: admin,
          tenant: ctx.org_b.id
        )

      page =
        Ash.Seed.seed!(CMS.Page, %{
          title: "P",
          slug: "bp-#{System.unique_integer([:positive])}",
          locale: "en",
          org_id: ctx.org_b.id
        })

      post =
        Ash.Seed.seed!(CMS.Post, %{
          title: "Q",
          slug: "bq-#{System.unique_integer([:positive])}",
          locale: "en",
          org_id: ctx.org_b.id
        })

      assert {:error, error} =
               CMS.add_release_item(
                 %{release_id: release.id, content_type: "page", content_id: page.id},
                 actor: actor,
                 tenant: ctx.org_b.id
               )

      assert Exception.message(error) =~ "outside your content-type scope"

      assert {:ok, _} =
               CMS.add_release_item(
                 %{release_id: release.id, content_type: "post", content_id: post.id},
                 actor: actor,
                 tenant: ctx.org_b.id
               )
    end
  end
end
