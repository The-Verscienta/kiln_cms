defmodule KilnCMS.Accounts.LegacyAffiliationTest do
  @moduledoc """
  `KilnCMS.Accounts.LegacyAffiliation` — the one "carry a legacy account onto
  the default org" step shared by the console (#1646) and billing (#1649).

  The callers' behaviour (tiers and reads through real policies) is pinned in
  `site_audiences_test.exs` and `billing/entitlements_test.exs`; this file pins
  the helper's own contract, above all that a second writer who also saw "no
  memberships" gets the existing row back instead of an error or an overwrite.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.{LegacyAffiliation, OrgMembership, Scoping, User}
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())

  defp default_org_id, do: Accounts.default_org_id()

  defp user(attrs) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "legacyaff-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :viewer
        },
        attrs
      )
    )
  end

  defp memberships(user), do: Accounts.list_memberships_for_user!(user.id, authorize?: false)

  test "unaffiliated?/1 is true only for an account with no memberships" do
    assert LegacyAffiliation.unaffiliated?([])
    refute LegacyAffiliation.unaffiliated?([%OrgMembership{}])
  end

  test "carries the standing role and User.audiences onto the default org" do
    editor = user(%{role: :editor, audiences: [@gated]})

    assert {:ok, membership} =
             LegacyAffiliation.ensure_default_membership(editor, authorize?: false)

    assert membership.organization_id == default_org_id()
    assert membership.role == :editor
    assert membership.audiences == [@gated]
    assert membership.granted_role == nil
    assert Scoping.effective_tier(editor, default_org_id()) == :editor
  end

  test ":audiences overrides the column" do
    editor = user(%{role: :editor, audiences: [@gated]})

    assert {:ok, membership} =
             LegacyAffiliation.ensure_default_membership(editor,
               audiences: [],
               authorize?: false
             )

    assert membership.audiences == []
  end

  test "a live temporary role becomes a grant on the membership, not its standing role" do
    expires = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)
    viewer = user(%{granted_role: :admin, granted_role_expires_at: expires})

    assert {:ok, membership} =
             LegacyAffiliation.ensure_default_membership(viewer, authorize?: false)

    assert membership.role == :viewer
    assert membership.granted_role == :admin
    assert DateTime.compare(membership.granted_role_expires_at, expires) == :eq
  end

  test "an expired temporary role is not carried" do
    expired = DateTime.utc_now() |> DateTime.add(-1, :hour)
    viewer = user(%{granted_role: :editor, granted_role_expires_at: expired})

    assert {:ok, membership} =
             LegacyAffiliation.ensure_default_membership(viewer, authorize?: false)

    assert membership.granted_role == nil
  end

  describe "a second writer that also saw no memberships (the race)" do
    test "gets the existing row back: no error, no duplicate, nothing overwritten" do
      editor = user(%{role: :editor, audiences: [@gated]})

      {:ok, first} = LegacyAffiliation.ensure_default_membership(editor, authorize?: false)

      # Someone changes the row between the two writers' reads.
      {:ok, _changed} =
        Accounts.update_org_membership(first, %{role: :admin, audiences: []}, authorize?: false)

      assert {:ok, second} =
               LegacyAffiliation.ensure_default_membership(editor, authorize?: false)

      assert second.id == first.id
      assert second.role == :admin
      assert second.audiences == []
      assert [%{id: id}] = memberships(editor)
      assert id == first.id
    end

    test "does not overwrite a temporary role already on the row" do
      expires = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)
      viewer = user(%{granted_role: :editor, granted_role_expires_at: expires})

      {:ok, first} = LegacyAffiliation.ensure_default_membership(viewer, authorize?: false)
      assert first.granted_role == :editor

      # An admin changed the winner's grant; the loser must not put its own back.
      {:ok, _ended} =
        Accounts.grant_membership_temporary_role(
          first,
          %{granted_role: :admin, granted_role_expires_at: expires},
          authorize?: false
        )

      {:ok, second} = LegacyAffiliation.ensure_default_membership(viewer, authorize?: false)
      assert second.granted_role == :admin
    end
  end
end
