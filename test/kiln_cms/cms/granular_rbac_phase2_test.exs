defmodule KilnCMS.CMS.GranularRbacPhase2Test do
  @moduledoc """
  Granular RBAC phase 2 (#332, slices 1+2): membership-resolved scoping and
  the `readable_types` editorial read axis.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.Organization
  alias KilnCMS.CMS

  require Ash.Query

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "rbac2-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp org do
    Ash.Seed.seed!(Organization, %{
      name: "RBAC2 #{System.unique_integer([:positive])}",
      slug: "rbac2-#{System.unique_integer([:positive])}"
    })
  end

  defp membership(user, org, attrs) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.OrgMembership,
      Map.merge(%{user_id: user.id, organization_id: org.id, role: :editor}, attrs)
    )
  end

  defp slug, do: "rbac2-#{System.unique_integer([:positive])}"

  describe "slice 1 — membership-resolved editable_types" do
    test "a membership scope restricts authoring on that org only" do
      editor = user(:editor)
      restricted_org = org()
      free_org = org()
      membership(editor, restricted_org, %{editable_types: ["post"]})
      membership(editor, free_org, %{})

      # Under the restricted org: posts yes, pages no.
      assert {:ok, _} =
               CMS.create_post(%{title: "P", slug: slug()}, actor: editor, tenant: restricted_org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_page(%{title: "Pg", slug: slug()},
                 actor: editor,
                 tenant: restricted_org
               )

      # The same account under the other org is unrestricted (its membership
      # has no scope, and the user column is empty).
      assert {:ok, _} =
               CMS.create_page(%{title: "Pg", slug: slug()}, actor: editor, tenant: free_org)
    end

    test "with no membership scope the user column still applies (fallback)" do
      editor = user(:editor, %{editable_types: ["post"]})
      some_org = org()
      membership(editor, some_org, %{})

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_page(%{title: "Pg", slug: slug()}, actor: editor, tenant: some_org)

      assert {:ok, _} =
               CMS.create_post(%{title: "P", slug: slug()}, actor: editor, tenant: some_org)
    end

    test "a tenant-less write resolves the default-org membership" do
      editor = user(:editor)

      membership(editor, %{id: KilnCMS.Accounts.default_org_id()}, %{editable_types: ["post"]})

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_page(%{title: "Pg", slug: slug()}, actor: editor)

      assert {:ok, _} = CMS.create_post(%{title: "P", slug: slug()}, actor: editor)
    end
  end

  describe "slice 2 — readable_types (editorial read axis)" do
    test "a restricted editor sees only published content of out-of-scope types" do
      admin = user(:admin)
      draft = CMS.create_page!(%{title: "Draft page", slug: slug()}, actor: admin)

      published =
        CMS.create_page!(%{title: "Live page", slug: slug()}, actor: admin)
        |> CMS.publish_page!(actor: admin)

      editor = user(:editor, %{readable_types: ["post"]})

      visible_ids = CMS.list_pages!(actor: editor) |> Enum.map(& &1.id)
      assert published.id in visible_ids
      refute draft.id in visible_ids

      # In-scope types keep full editorial visibility.
      post_draft = CMS.create_post!(%{title: "Draft post", slug: slug()}, actor: admin)
      assert post_draft.id in (CMS.list_posts!(actor: editor) |> Enum.map(& &1.id))
    end

    test "an unscoped editor still sees everything (phase-1 behavior)" do
      admin = user(:admin)
      draft = CMS.create_page!(%{title: "Draft page", slug: slug()}, actor: admin)

      editor = user(:editor)
      assert draft.id in (CMS.list_pages!(actor: editor) |> Enum.map(& &1.id))
    end

    test "the read scope resolves through the membership per-org" do
      admin = user(:admin)
      scoped_org = org()

      draft =
        CMS.create_page!(%{title: "Org draft", slug: slug()}, actor: admin, tenant: scoped_org)

      editor = user(:editor)
      membership(editor, scoped_org, %{readable_types: ["post"]})
      # The default-org membership every backfilled account has (unscoped).
      membership(editor, %{id: KilnCMS.Accounts.default_org_id()}, %{})

      refute draft.id in (CMS.list_pages!(actor: editor, tenant: scoped_org) |> Enum.map(& &1.id))

      # The same editor on the default org (membership with no scope) is
      # unrestricted.
      default_draft = CMS.create_page!(%{title: "Default draft", slug: slug()}, actor: admin)
      assert default_draft.id in (CMS.list_pages!(actor: editor) |> Enum.map(& &1.id))
    end

    test "restricting read never revokes drafts of editable types (union)" do
      admin = user(:admin)
      draft = CMS.create_page!(%{title: "Editable draft", slug: slug()}, actor: admin)

      # Reads scoped to posts only, but pages remain editable — the write axis
      # is unioned into editorial visibility, so the draft stays reachable.
      editor = user(:editor, %{readable_types: ["post"], editable_types: ["page", "post"]})

      assert draft.id in (CMS.list_pages!(actor: editor) |> Enum.map(& &1.id))
    end

    test "version history follows the editorial read scope" do
      admin = user(:admin)
      draft = CMS.create_page!(%{title: "Secret draft", slug: slug()}, actor: admin)

      restricted = user(:editor, %{readable_types: ["post"]})
      unrestricted = user(:editor)

      version_ids = fn actor ->
        KilnCMS.CMS.Page.Version
        |> Ash.Query.filter(version_source_id == ^draft.id)
        |> Ash.read!(actor: actor)
        |> Enum.map(& &1.id)
      end

      assert version_ids.(unrestricted) != []
      # The draft's snapshot must not leak through its history.
      assert version_ids.(restricted) == []
    end
  end

  describe "fail-closed affiliation (#336 interplay)" do
    test "an editor with memberships gets no editorial scope on a foreign org" do
      admin = user(:admin)
      home_org = org()
      foreign_org = org()

      draft =
        CMS.create_page!(%{title: "Foreign draft", slug: slug()},
          actor: admin,
          tenant: foreign_org
        )

      editor = user(:editor)
      membership(editor, home_org, %{editable_types: ["post"]})

      # No membership on foreign_org: no authoring, and drafts are invisible —
      # switching hosts must not escape the home-org restriction.
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_post(%{title: "P", slug: slug()}, actor: editor, tenant: foreign_org)

      refute draft.id in (CMS.list_pages!(actor: editor, tenant: foreign_org)
                          |> Enum.map(& &1.id))
    end

    test "a user with no memberships keeps the user-column behavior on the default org" do
      # Legacy (membership-less) accounts keep their global role — but only on
      # the default org (single-org installs). On a *foreign* org a
      # membership-less editor is fail-closed (#419 review hardening), so it
      # can't reach a second site by switching hosts.
      editor = user(:editor)

      assert {:ok, _} =
               CMS.create_post(%{title: "P", slug: slug()},
                 actor: editor,
                 tenant: KilnCMS.Accounts.default_org_id()
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_post(%{title: "P", slug: slug()}, actor: editor, tenant: org())
    end

    test "admins and manage_access carry the new axis" do
      admin = user(:admin)
      editor = user(:editor)

      {:ok, editor} =
        KilnCMS.Accounts.manage_user_access(editor, %{readable_types: ["post"]}, actor: admin)

      assert editor.readable_types == ["post"]

      # Admins bypass the read scope entirely.
      admin_scoped = user(:admin, %{readable_types: ["post"]})
      draft = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: admin)
      assert draft.id in (CMS.list_pages!(actor: admin_scoped) |> Enum.map(& &1.id))
    end
  end
end
