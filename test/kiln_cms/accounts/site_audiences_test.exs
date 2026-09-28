defmodule KilnCMS.Accounts.SiteAudiencesTest do
  @moduledoc """
  `KilnCMS.Accounts.SiteAudiences` — the console's audience write lands on the
  membership the read policy consults, never on the deprecated global column
  (#1646).

  Every "can it read" assertion goes through a real `CMS.get_page` under the
  content read policy, not the stored value: the bug this closes was a write that
  stored fine and changed nothing.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.{Organization, OrgMembership, Scoping, SiteAudiences, User}
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())

  defp default_org_id, do: Accounts.default_org_id()

  defp org do
    Ash.Seed.seed!(Organization, %{
      name: "Audience Site",
      slug: "siteaud-#{System.unique_integer([:positive])}"
    })
  end

  defp user(attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "siteaud-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :viewer
        },
        attrs
      )
    )
  end

  defp membership(user, org_id, attrs) do
    Ash.Seed.seed!(
      OrgMembership,
      Map.merge(%{organization_id: org_id, user_id: user.id, role: :viewer}, attrs)
    )
  end

  defp admin, do: user(%{role: :admin})

  defp gated_page(org_id) do
    actor = admin()

    {:ok, page} =
      CMS.create_page(
        %{title: "Gated", slug: "gated-#{System.unique_integer([:positive])}", audience: @gated},
        actor: actor,
        tenant: org_id
      )

    {:ok, published} = CMS.publish_page(page, %{}, actor: actor, tenant: org_id)
    published
  end

  # Through the real read policy — a stored value proves nothing on its own.
  defp can_read?(reader, page, org_id) do
    reader = Accounts.get_user!(reader.id, authorize?: false)

    case CMS.get_page(page.id, actor: reader, tenant: org_id, not_found_error?: false) do
      {:ok, %{id: id}} -> id == page.id
      _ -> false
    end
  end

  defp memberships(user),
    do: Accounts.list_memberships_for_user!(user.id, authorize?: false)

  defp membership_on(user, org_id),
    do: Enum.find(memberships(user), &(&1.organization_id == org_id))

  describe "for_site/3" do
    test "answers what Scoping.audiences/2 answers, for a member and a foreign account" do
      other = org()

      member = user()
      membership(member, default_org_id(), %{audiences: [@gated]})

      foreign = user(%{audiences: [@gated]})
      membership(foreign, other.id, %{audiences: [@gated]})

      for {account, source} <- [{member, :membership}, {foreign, :none}] do
        assert {^source, audiences} =
                 SiteAudiences.for_site(account, memberships(account), default_org_id())

        assert audiences == Scoping.audiences(account, default_org_id())
      end
    end

    test "shows a membership-less account's column — what a save carries — which grants nothing" do
      legacy = user(%{audiences: [@gated]})

      assert {:legacy, [@gated]} = SiteAudiences.for_site(legacy, [], default_org_id())
      # 1.0 removed the fallback (#1543): until a membership exists, nothing.
      assert Scoping.audiences(legacy, default_org_id()) == []
    end
  end

  describe "an account with a membership on the site" do
    test "ticking an audience lets it read gated content there, and unticking takes it away" do
      reader = user()
      membership(reader, default_org_id(), %{})
      page = gated_page(default_org_id())

      refute can_read?(reader, page, default_org_id())

      assert {:ok, :updated} =
               SiteAudiences.set(reader, default_org_id(), [@gated], actor: admin())

      assert can_read?(reader, page, default_org_id())

      assert {:ok, :updated} = SiteAudiences.set(reader, default_org_id(), [], actor: admin())
      refute can_read?(reader, page, default_org_id())
    end

    test "never writes the global column" do
      reader = user()
      membership(reader, default_org_id(), %{})

      {:ok, :updated} = SiteAudiences.set(reader, default_org_id(), [@gated], actor: admin())

      assert membership_on(reader, default_org_id()).audiences == [@gated]
      assert Accounts.get_user!(reader.id, authorize?: false).audiences == []
    end

    test "edits only this site's membership" do
      other = org()
      reader = user()
      membership(reader, default_org_id(), %{})
      membership(reader, other.id, %{})
      page_b = gated_page(other.id)

      {:ok, :updated} = SiteAudiences.set(reader, default_org_id(), [@gated], actor: admin())

      assert membership_on(reader, other.id).audiences == []
      refute can_read?(reader, page_b, other.id)
    end

    test "drops an audience that is not configured" do
      reader = user()
      membership(reader, default_org_id(), %{})

      {:ok, :updated} =
        SiteAudiences.set(reader, default_org_id(), [@gated, :nonsense, @gated], actor: admin())

      assert membership_on(reader, default_org_id()).audiences == [@gated]
    end
  end

  describe "an account with no membership on the site" do
    test "a membership-less account on the default org keeps its tier and gains the audience" do
      editor = user(%{role: :editor})
      page = gated_page(default_org_id())
      tier_before = Scoping.effective_tier(editor, default_org_id())

      assert {:ok, :created} =
               SiteAudiences.set(editor, default_org_id(), [@gated], actor: admin())

      created = membership_on(editor, default_org_id())
      assert created.role == :editor
      assert created.audiences == [@gated]
      assert Scoping.effective_tier(editor, default_org_id()) == tier_before
      assert can_read?(editor, page, default_org_id())
      assert Accounts.get_user!(editor.id, authorize?: false).audiences == []
    end

    test "a live temporary role moves onto the membership, not into its standing role" do
      expires = DateTime.add(DateTime.utc_now(), 2, :hour)
      viewer = user(%{granted_role: :editor, granted_role_expires_at: expires})

      assert Scoping.effective_tier(viewer, default_org_id()) == :editor

      {:ok, :created} = SiteAudiences.set(viewer, default_org_id(), [], actor: admin())

      created = membership_on(viewer, default_org_id())
      assert created.role == :viewer
      assert created.granted_role == :editor
      assert Scoping.effective_tier(viewer, default_org_id()) == :editor
    end

    test "edited from another site, a legacy account is carried onto the default org first" do
      other = org()
      editor = user(%{role: :editor, audiences: [@gated]})
      default_page = gated_page(default_org_id())
      other_page = gated_page(other.id)

      assert Scoping.effective_tier(editor, default_org_id()) == :editor
      assert can_read?(editor, default_page, default_org_id())

      {:ok, :created} = SiteAudiences.set(editor, other.id, [@gated], actor: admin())

      carried = membership_on(editor, default_org_id())
      assert carried.role == :editor
      assert carried.audiences == [@gated]

      here = membership_on(editor, other.id)
      assert here.role == :viewer
      assert here.audiences == [@gated]

      # Nothing it held on the default site was lost, and the new site reads.
      assert Scoping.effective_tier(editor, default_org_id()) == :editor
      assert can_read?(editor, default_page, default_org_id())
      assert Scoping.effective_tier(editor, other.id) == :viewer
      assert can_read?(editor, other_page, other.id)
    end

    test "a member of another site joins this one as a viewer" do
      other = org()
      editor = user()
      membership(editor, other.id, %{role: :editor})
      page = gated_page(default_org_id())

      assert Scoping.effective_tier(editor, default_org_id()) == :none

      {:ok, :created} = SiteAudiences.set(editor, default_org_id(), [@gated], actor: admin())

      assert membership_on(editor, default_org_id()).role == :viewer
      assert membership_on(editor, other.id).role == :editor
      assert can_read?(editor, page, default_org_id())
    end
  end

  describe "authorization" do
    setup do
      reader = user()
      membership(reader, default_org_id(), %{})
      %{reader: reader}
    end

    test "an editor of the site is refused", %{reader: reader} do
      editor = user()
      membership(editor, default_org_id(), %{role: :editor})

      assert {:error, %Ash.Error.Forbidden{}} =
               SiteAudiences.set(reader, default_org_id(), [@gated], actor: editor)

      assert membership_on(reader, default_org_id()).audiences == []
    end

    test "an admin of another site is refused", %{reader: reader} do
      other_admin = user()
      membership(other_admin, org().id, %{role: :admin})

      assert {:error, %Ash.Error.Forbidden{}} =
               SiteAudiences.set(reader, default_org_id(), [@gated], actor: other_admin)

      assert membership_on(reader, default_org_id()).audiences == []
    end

    test "creating a membership is refused too", %{reader: _reader} do
      editor = user()
      membership(editor, default_org_id(), %{role: :editor})
      stranger = user()

      assert {:error, %Ash.Error.Forbidden{}} =
               SiteAudiences.set(stranger, default_org_id(), [@gated], actor: editor)

      assert memberships(stranger) == []
    end
  end
end
