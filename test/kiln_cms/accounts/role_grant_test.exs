defmodule KilnCMS.Accounts.RoleGrantTest do
  @moduledoc """
  Time-boxed capability tiers: a grant shadows the standing role while it is
  live, stops applying the moment it expires without anything running, and cannot
  be written as a demotion, a permanent elevation, or a date in the past.
  """
  use KilnCMS.DataCase, async: true

  require Ash.Query

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

  describe "a read" do
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

    # `role` is the column, always; the grant is applied where a tier is decided.
    test "returns the row as stored, the grant beside the standing role", %{subject: subject} do
      read = reread(subject)

      assert read.role == :editor
      assert read.granted_role == :admin
      assert RoleGrant.effective_role(read) == :admin
    end

    # Nothing has to run for the elevation to end.
    test "stops applying the grant the instant it expires", %{subject: subject} do
      subject = reread(subject)

      # Seeded past the expiry rather than written through the action, which
      # (correctly) refuses a past date.
      Ash.Seed.update!(subject, %{granted_role_expires_at: in_hours(-1)})

      assert RoleGrant.effective_role(reread(subject)) == :editor
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
                 reread(granted),
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

    # Extending a live grant compares against the STANDING tier, not the granted
    # one — otherwise "admin until Friday" could never be extended.
    test "a live grant can be extended", %{admin: admin, subject: subject} do
      {:ok, _} =
        Accounts.grant_user_temporary_role(
          subject,
          %{granted_role: :editor, granted_role_expires_at: in_hours(2)},
          actor: admin
        )

      assert {:ok, extended} =
               Accounts.grant_user_temporary_role(
                 reread(subject),
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

    # Straight off an ordinary read. When reads presented a live grant as `role`,
    # Ash dropped this `role: :admin` as equal to the record's and wrote nothing,
    # and every writer had to ask for the row "unfolded" first.
    test "promotes permanently from an ordinary read and clears the grant", %{
      admin: admin,
      subject: subject
    } do
      assert {:ok, promoted} =
               Accounts.manage_user_access(reread(subject), %{role: :admin}, actor: admin)

      assert promoted.role == :admin
      assert reread(subject).role == :admin
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
               Accounts.manage_user_access(reread(subject), %{role: :viewer}, actor: admin)

      assert demoted.role == :viewer
      assert demoted.granted_role == :admin
    end
  end

  describe "the expiry sweep" do
    # Executed in-band, the way `trash_purge_test.exs` runs its trigger. The
    # sweep's own action behaviour is covered below; this is the part that was
    # broken — AshOban's scheduler READS the rows with `authorize?: true` and no
    # actor, and a grant scoped to the write action let that read see nothing.
    test "the AshOban trigger actually runs: expired grants cleared, live ones kept" do
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

      Ash.Seed.update!(reread(expired), %{granted_role_expires_at: in_hours(-1)})

      assert %{success: success, failure: 0} =
               AshOban.schedule_and_run_triggers({User, :expire_role_grants},
                 drain_queues?: true,
                 with_recursion: true,
                 with_scheduled: true
               )

      assert success >= 1
      assert is_nil(reread(expired).granted_role)
      assert reread(live).granted_role == :editor
    end

    test "the membership trigger actually runs too" do
      admin = user(:admin)
      member = user(:viewer)

      membership =
        Ash.Seed.seed!(OrgMembership, %{
          user_id: member.id,
          organization_id: Accounts.default_org_id(),
          role: :viewer
        })

      {:ok, granted} =
        Accounts.grant_membership_temporary_role(
          membership,
          %{granted_role: :editor, granted_role_expires_at: in_hours(2)},
          actor: admin
        )

      Ash.Seed.update!(granted, %{granted_role_expires_at: in_hours(-1)})

      AshOban.schedule_and_run_triggers({OrgMembership, :expire_role_grants},
        drain_queues?: true,
        with_recursion: true,
        with_scheduled: true
      )

      assert is_nil(
               Accounts.get_org_membership!(member.id, Accounts.default_org_id(),
                 authorize?: false
               ).granted_role
             )
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

      Ash.Seed.update!(reread(expired), %{granted_role_expires_at: in_hours(-1)})

      assert {:ok, swept} = Accounts.expire_user_role_grant(reread(expired), authorize?: false)

      assert is_nil(swept.granted_role)
      assert is_nil(swept.granted_role_expires_at)
      # The standing tier is what it always was.
      assert swept.role == :viewer

      assert reread(live).granted_role == :editor
    end
  end

  describe "an actor that outlives its grant" do
    # A LiveView assigns `current_user` once at mount. The grant on that struct
    # must stop authorizing the moment it expires — the expiry is compared at the
    # decision, not trusted from the load.
    setup do
      admin = user(:admin)
      subject = user(:editor)

      {:ok, _} =
        Accounts.grant_user_temporary_role(
          subject,
          %{granted_role: :admin, granted_role_expires_at: in_hours(1)},
          actor: admin
        )

      # Mount-time actor, read while the grant was live...
      actor = reread(subject)
      assert KilnCMS.Accounts.Checks.PlatformAdmin.match?(actor, %{}, [])

      # ...and then the clock moves past the expiry, with the struct unchanged.
      stale = %{actor | granted_role_expires_at: in_hours(-1)}
      %{admin: admin, stale: stale, subject: subject}
    end

    test "PlatformAdmin refuses it", %{stale: stale} do
      refute KilnCMS.Accounts.Checks.PlatformAdmin.match?(stale, %{}, [])
    end

    test "effective_tier and the console gate refuse it", %{stale: stale} do
      assert KilnCMS.Accounts.Scoping.effective_tier(stale, Accounts.default_org_id()) == :editor
      refute KilnCMSWeb.LiveUserAuth.platform_admin_user?(stale)
    end

    test "a policy guarded by the admin bypass refuses it", %{stale: stale} do
      other = user(:viewer)
      assert {:error, %Ash.Error.Forbidden{}} = Accounts.anonymize_user(other, actor: stale)
    end

    test "a live grant still authorizes", %{subject: subject} do
      assert KilnCMS.Accounts.Checks.PlatformAdmin.match?(reread(subject), %{}, [])
    end
  end

  describe "ClearRedundantRoleGrant" do
    # A narrowed select leaves the grant columns unloaded; that is not a grant.
    test "does not revoke a grant whose columns were not selected" do
      admin = user(:admin)
      subject = user(:viewer)

      {:ok, _} =
        Accounts.grant_user_temporary_role(
          subject,
          %{granted_role: :admin, granted_role_expires_at: in_hours(3)},
          actor: admin
        )

      # Only the two grant columns are left out; the action's other validations
      # read the rest.
      narrowed =
        User
        |> Ash.Query.deselect([:granted_role, :granted_role_expires_at])
        |> Ash.Query.filter(id == ^subject.id)
        |> Ash.read_one!(authorize?: false)

      assert %Ash.NotLoaded{} = narrowed.granted_role

      {:ok, _} = Accounts.manage_user_access(narrowed, %{audiences: [:member]}, actor: admin)

      assert reread(subject).granted_role == :admin
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

      Ash.Seed.update!(reread(lapsed), %{granted_role_expires_at: in_hours(-1)})

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
