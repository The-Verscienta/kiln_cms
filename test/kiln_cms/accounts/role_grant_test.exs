defmodule KilnCMS.Accounts.RoleGrantTest do
  @moduledoc """
  Time-boxed capability tiers: a grant shadows the standing role while it is
  live, stops applying the moment it expires without anything running, and cannot
  be written as a demotion, a permanent elevation, or a date in the past.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.{OrgMembership, Role, RoleGrant, User}

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "grant-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp in_hours(hours), do: DateTime.add(DateTime.utc_now(), hours, :hour)

  defp reread(user), do: Accounts.get_user!(user.id, authorize?: false)

  defp reread_unfolded(user),
    do: Accounts.get_user!(user.id, RoleGrant.unfolded() ++ [authorize?: false])

  describe "effective_role/1" do
    test "a live grant shadows the standing role" do
      record = %{role: :editor, granted_role: :admin, granted_role_expires_at: in_hours(1)}
      assert RoleGrant.effective_role(record) == :admin
      assert RoleGrant.live?(record)
    end

    test "an expired grant does not" do
      record = %{role: :editor, granted_role: :admin, granted_role_expires_at: in_hours(-1)}
      assert RoleGrant.effective_role(record) == :editor
      refute RoleGrant.live?(record)
    end

    test "a grant with no expiry is no grant at all" do
      record = %{role: :viewer, granted_role: :admin, granted_role_expires_at: nil}
      assert RoleGrant.effective_role(record) == :viewer
    end

    # A read with a narrowed select, or one whose field policy withheld the
    # columns, must fall back to the standing tier rather than to whatever
    # `%Ash.NotLoaded{}` compares as.
    test "unreadable grant columns read as no grant" do
      record = %{
        role: :editor,
        granted_role: %Ash.NotLoaded{field: :granted_role},
        granted_role_expires_at: %Ash.NotLoaded{field: :granted_role_expires_at}
      }

      assert RoleGrant.effective_role(record) == :editor
    end

    test "only an elevation counts as one" do
      assert RoleGrant.elevation?(:admin, :editor)
      assert RoleGrant.elevation?(:editor, :viewer)
      refute RoleGrant.elevation?(:editor, :admin)
      refute RoleGrant.elevation?(:admin, :admin)
      refute RoleGrant.elevation?(nil, :viewer)
    end
  end

  describe "the fold on read" do
    setup do
      admin = user(:admin)
      subject = user(:editor)

      {:ok, _} =
        Accounts.grant_user_temporary_role(
          subject,
          %{granted_role: :admin, granted_role_expires_at: in_hours(4)},
          actor: admin
        )

      %{admin: admin, subject: subject}
    end

    test "presents the granted tier as `role`", %{subject: subject} do
      folded = reread(subject)

      assert folded.role == :admin
      # The standing tier is still what the column holds, and still reachable.
      assert RoleGrant.standing_role(folded) == :editor
      assert RoleGrant.folded?(folded)
    end

    test "`unfolded/0` returns the row as stored", %{subject: subject} do
      raw = reread_unfolded(subject)

      assert raw.role == :editor
      assert raw.granted_role == :admin
      refute RoleGrant.folded?(raw)
    end

    # The whole point of folding rather than sweeping: nothing has to run for the
    # elevation to end.
    test "stops folding the instant the grant expires", %{admin: admin, subject: subject} do
      subject = reread_unfolded(subject)

      # Seeded past the expiry rather than written through the action, which
      # (correctly) refuses a past date.
      Ash.Seed.update!(subject, %{granted_role_expires_at: in_hours(-1)})

      assert reread(subject).role == :editor
      assert admin.role == :admin
    end
  end

  describe "grant_temporary_role" do
    setup do: %{admin: user(:admin), subject: user(:viewer)}

    test "an admin grants and revokes", %{admin: admin, subject: subject} do
      assert {:ok, granted} =
               Accounts.grant_user_temporary_role(
                 subject,
                 %{granted_role: :editor, granted_role_expires_at: in_hours(24)},
                 actor: admin
               )

      assert granted.granted_role == :editor
      # The standing tier is untouched — that is what makes expiry a comparison.
      assert granted.role == :viewer

      assert {:ok, revoked} =
               Accounts.grant_user_temporary_role(
                 reread_unfolded(granted),
                 %{granted_role: nil, granted_role_expires_at: nil},
                 actor: admin
               )

      assert is_nil(revoked.granted_role)
      assert is_nil(revoked.granted_role_expires_at)
      assert revoked.role == :viewer
    end

    test "a non-admin cannot grant themselves anything", %{subject: subject} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.grant_user_temporary_role(
                 subject,
                 %{granted_role: :admin, granted_role_expires_at: in_hours(1)},
                 actor: subject
               )
    end

    test "a demotion is refused", %{admin: admin} do
      editor = user(:editor)

      assert {:error, error} =
               Accounts.grant_user_temporary_role(
                 editor,
                 %{granted_role: :viewer, granted_role_expires_at: in_hours(1)},
                 actor: admin
               )

      assert Exception.message(error) =~ "higher than the standing role"
    end

    test "a past expiry is refused", %{admin: admin, subject: subject} do
      assert {:error, error} =
               Accounts.grant_user_temporary_role(
                 subject,
                 %{granted_role: :editor, granted_role_expires_at: in_hours(-1)},
                 actor: admin
               )

      assert Exception.message(error) =~ "must be in the future"
    end

    test "a role with no expiry is refused", %{admin: admin, subject: subject} do
      assert {:error, error} =
               Accounts.grant_user_temporary_role(
                 subject,
                 %{granted_role: :editor},
                 actor: admin
               )

      assert Exception.message(error) =~ "is required"
    end

    # Extending a live grant compares against the STANDING tier, not the folded
    # one — otherwise "admin until Friday" could never be extended, because the
    # record would already read as an admin.
    test "a live grant can be extended from a folded record", %{admin: admin, subject: subject} do
      {:ok, _} =
        Accounts.grant_user_temporary_role(
          subject,
          %{granted_role: :editor, granted_role_expires_at: in_hours(2)},
          actor: admin
        )

      folded = reread(subject)
      assert folded.role == :editor

      assert {:ok, extended} =
               Accounts.grant_user_temporary_role(
                 folded,
                 %{granted_role: :editor, granted_role_expires_at: in_hours(48)},
                 actor: admin
               )

      assert DateTime.diff(extended.granted_role_expires_at, DateTime.utc_now(), :hour) >= 47
    end
  end

  describe "writing the standing role beside a grant" do
    setup do
      admin = user(:admin)
      subject = user(:editor)

      {:ok, _} =
        Accounts.grant_user_temporary_role(
          subject,
          %{granted_role: :admin, granted_role_expires_at: in_hours(6)},
          actor: admin
        )

      %{admin: admin, subject: subject}
    end

    # The bug the fold could have introduced: Ash discards a submitted attribute
    # equal to `changeset.data` at cast time, so promoting a temporary admin from
    # a FOLDED record would silently write nothing.
    test "a folded record is refused rather than silently dropped", %{
      admin: admin,
      subject: subject
    } do
      folded = reread(subject)

      assert {:error, error} =
               Accounts.manage_user_access(folded, %{role: :admin}, actor: admin)

      assert Exception.message(error) =~ "folded"
      # And the column really did not move.
      assert reread_unfolded(subject).role == :editor
    end

    test "an unfolded record promotes permanently and clears the grant", %{
      admin: admin,
      subject: subject
    } do
      assert {:ok, promoted} =
               Accounts.manage_user_access(reread_unfolded(subject), %{role: :admin},
                 actor: admin
               )

      assert promoted.role == :admin
      # A standing tier at or above the grant makes it meaningless — see
      # Changes.ClearRedundantRoleGrant.
      assert is_nil(promoted.granted_role)
      assert is_nil(promoted.granted_role_expires_at)
    end

    test "a grant that still outranks the new standing tier survives", %{
      admin: admin,
      subject: subject
    } do
      assert {:ok, demoted} =
               Accounts.manage_user_access(reread_unfolded(subject), %{role: :viewer},
                 actor: admin
               )

      assert demoted.role == :viewer
      assert demoted.granted_role == :admin
    end
  end

  describe "the expiry sweep" do
    # The trigger's WIRING, not a run of it: the sweep is what evicts a
    # grant-holder's live sockets, and a scheduler pointed at the wrong action (or
    # a `where` that never matches) would fail silently — authorization is already
    # correct without it, so nothing else would go red.
    #
    # Structural rather than executed, because an AshOban scheduler runs in its own
    # process and so cannot see this test's sandbox transaction; the action's own
    # behaviour is covered below.
    test "both resources register an hourly trigger on the expiry action" do
      for resource <- [User, OrgMembership] do
        assert [trigger] = AshOban.Info.oban_triggers(resource)
        assert trigger.name == :expire_role_grants
        assert trigger.action == :expire_role_grant
        # Hourly, not nightly: a grant that ran out at 09:00 must not leave its
        # holder's open console authorized until tomorrow morning.
        assert trigger.scheduler_cron =~ ~r/^\d+ \* \* \* \*$/
      end
    end

    # The `where` the scheduler filters on, asserted against real rows rather than
    # by reading the expression back — a filter that matched everything, or
    # nothing, would look identical in the DSL.
    test "the trigger's filter matches an expired grant and not a live one" do
      admin = user(:admin)
      expired = user(:viewer)
      live = user(:viewer)

      for {subject, hours} <- [{expired, 2}, {live, 6}] do
        {:ok, _} =
          Accounts.grant_user_temporary_role(
            subject,
            %{granted_role: :editor, granted_role_expires_at: in_hours(hours)},
            actor: admin
          )
      end

      Ash.Seed.update!(reread_unfolded(expired), %{granted_role_expires_at: in_hours(-1)})

      [trigger] = AshOban.Info.oban_triggers(User)

      matching =
        User
        |> Ash.Query.do_filter(trigger.where)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      assert expired.id in matching
      refute live.id in matching
      refute admin.id in matching
    end

    test "clears an expired grant and leaves a live one alone" do
      admin = user(:admin)
      expired = user(:viewer)
      live = user(:viewer)

      for {subject, hours} <- [{expired, 2}, {live, 6}] do
        {:ok, _} =
          Accounts.grant_user_temporary_role(
            subject,
            %{granted_role: :editor, granted_role_expires_at: in_hours(hours)},
            actor: admin
          )
      end

      Ash.Seed.update!(reread_unfolded(expired), %{granted_role_expires_at: in_hours(-1)})

      assert {:ok, swept} =
               Accounts.expire_user_role_grant(reread_unfolded(expired), authorize?: false)

      assert is_nil(swept.granted_role)
      assert is_nil(swept.granted_role_expires_at)
      # The standing tier is what it always was.
      assert swept.role == :viewer

      assert reread_unfolded(live).granted_role == :editor
    end
  end

  describe "per-site grants on a membership" do
    setup do
      admin = user(:admin)
      member = user(:viewer)

      membership =
        Ash.Seed.seed!(OrgMembership, %{
          user_id: member.id,
          organization_id: Accounts.default_org_id(),
          role: :viewer
        })

      %{admin: admin, member: member, membership: membership}
    end

    test "a live grant is the member's effective tier on that site", %{
      admin: admin,
      member: member,
      membership: membership
    } do
      {:ok, _} =
        Accounts.grant_membership_temporary_role(
          membership,
          %{granted_role: :editor, granted_role_expires_at: in_hours(3)},
          actor: admin
        )

      assert KilnCMS.Accounts.Scoping.effective_tier(member, Accounts.default_org_id()) ==
               :editor
    end

    test "and stops being it once it expires", %{
      admin: admin,
      member: member,
      membership: membership
    } do
      {:ok, granted} =
        Accounts.grant_membership_temporary_role(
          membership,
          %{granted_role: :editor, granted_role_expires_at: in_hours(3)},
          actor: admin
        )

      Ash.Seed.update!(granted, %{granted_role_expires_at: in_hours(-1)})

      assert KilnCMS.Accounts.Scoping.effective_tier(member, Accounts.default_org_id()) ==
               :viewer
    end

    # A grant is a tier, not a scope bundle: the custom role and the type scopes
    # are untouched by one, which the team page relies on.
    test "leaves the custom role and scopes alone", %{admin: admin, membership: membership} do
      role =
        Ash.Seed.seed!(Role, %{
          name: "Blog editor #{System.unique_integer([:positive])}",
          org_id: Accounts.default_org_id(),
          editable_types: ["post"]
        })

      {:ok, scoped} =
        Accounts.update_org_membership(membership, %{role_id: role.id}, actor: admin)

      {:ok, granted} =
        Accounts.grant_membership_temporary_role(
          scoped,
          %{granted_role: :editor, granted_role_expires_at: in_hours(3)},
          actor: admin
        )

      assert granted.role_id == role.id
    end
  end

  describe "users_with_tier/2" do
    test "includes a live temporary admin and excludes an expired one" do
      admin = user(:admin)
      temp = user(:editor)
      lapsed = user(:editor)

      for subject <- [temp, lapsed] do
        {:ok, _} =
          Accounts.grant_user_temporary_role(
            subject,
            %{granted_role: :admin, granted_role_expires_at: in_hours(3)},
            actor: admin
          )
      end

      Ash.Seed.update!(reread_unfolded(lapsed), %{granted_role_expires_at: in_hours(-1)})

      ids =
        KilnCMS.Accounts.Scoping.users_with_tier(Accounts.default_org_id(), [:admin])
        |> Enum.map(& &1.id)

      assert temp.id in ids
      refute lapsed.id in ids
      assert admin.id in ids
    end

    # The membership branch of the same expression — resolved inside `exists/2`
    # against the membership's own identically-named columns, which is the whole
    # reason they are named that way.
    test "includes a member whose SITE tier is temporarily elevated" do
      admin = user(:admin)
      member = user(:viewer)

      membership =
        Ash.Seed.seed!(OrgMembership, %{
          user_id: member.id,
          organization_id: Accounts.default_org_id(),
          role: :viewer
        })

      before =
        KilnCMS.Accounts.Scoping.users_with_tier(Accounts.default_org_id(), [:editor])
        |> Enum.map(& &1.id)

      refute member.id in before

      {:ok, granted} =
        Accounts.grant_membership_temporary_role(
          membership,
          %{granted_role: :editor, granted_role_expires_at: in_hours(3)},
          actor: admin
        )

      ids =
        KilnCMS.Accounts.Scoping.users_with_tier(Accounts.default_org_id(), [:editor])
        |> Enum.map(& &1.id)

      assert member.id in ids

      # And drops out again the moment it lapses, with no sweep in between.
      Ash.Seed.update!(granted, %{granted_role_expires_at: in_hours(-1)})

      lapsed =
        KilnCMS.Accounts.Scoping.users_with_tier(Accounts.default_org_id(), [:editor])
        |> Enum.map(& &1.id)

      refute member.id in lapsed
    end

    # The reverted side of the same expression: an account whose elevation lapsed
    # must be found by its STANDING tier, which the naive `role in ^tiers` filter
    # would have missed while the dead grant columns were still on the row.
    test "finds a lapsed grant holder by their standing tier" do
      admin = user(:admin)
      subject = user(:editor)

      {:ok, granted} =
        Accounts.grant_user_temporary_role(
          subject,
          %{granted_role: :admin, granted_role_expires_at: in_hours(3)},
          actor: admin
        )

      Ash.Seed.update!(granted, %{granted_role_expires_at: in_hours(-1)})

      ids =
        KilnCMS.Accounts.Scoping.users_with_tier(Accounts.default_org_id(), [:editor])
        |> Enum.map(& &1.id)

      assert subject.id in ids
    end
  end
end
