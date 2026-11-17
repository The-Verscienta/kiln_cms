defmodule KilnCMS.Accounts.ErasureGrantsTest do
  @moduledoc """
  What an erased account's site memberships still grant (#2774): erasure
  demotes them (`OrgMembership.:erase`), the rosters and the tier decision
  leave an erased account out whatever its rows say, nothing is sent to it,
  and no write may give it a tier back.

  A "pre-fix tombstone" is an account erased by a release before #2774: its
  row is tombstoned and its memberships were left as they were. The roster
  and tier tests use one, so they prove the filters on their own, not the
  demotion.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  require Ash.Query

  import Ecto.Query, only: [from: 2]
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.AccountErased
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Accounts.SiteAudiences
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Entitlements
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.Notifications.TaskDigestWorker
  alias KilnCMS.Notifications.TaskMailWorker
  alias KilnCMS.Notifications.Tasks, as: TaskNotifications
  alias KilnCMS.Notifications.WorkflowMailWorker
  alias KilnCMS.Repo

  @gated hd(Audiences.gated())

  defp user(role \\ :viewer) do
    Ash.Seed.seed!(User, %{
      email: "erasure-grants-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp membership(user, org, attrs) do
    Ash.Seed.seed!(
      OrgMembership,
      Map.merge(%{user_id: user.id, organization_id: org_id(org)}, Map.new(attrs))
    )
  end

  defp org_id(%{id: id}), do: id
  defp org_id(id) when is_binary(id), do: id

  defp member(org, role) do
    user = user()
    membership(user, org, role: role)
    user
  end

  defp erase!(user), do: Accounts.anonymize_user!(user, actor: user(:admin))

  # Tombstoned the way an earlier release left it: the account row scrubbed,
  # every membership untouched.
  defp pre_fix_tombstone(user) do
    Ash.Seed.update!(user, %{
      email: "anonymized-#{user.id}@deleted.invalid",
      name: nil,
      role: :viewer,
      anonymized_at: DateTime.utc_now()
    })
  end

  defp reload_membership(user, org),
    do: Accounts.get_org_membership!(user.id, org_id(org), authorize?: false)

  defp in_hours(n), do: DateTime.add(DateTime.utc_now(), n * 3_600)

  defp ids(users), do: users |> Enum.map(& &1.id) |> Enum.sort()

  defp erased_error?({:error, error}), do: Enum.any?(error.errors, &match?(%AccountErased{}, &1))
  defp erased_error?(_result), do: false

  defp role_events do
    Repo.aggregate(
      from(e in "security_events", where: e.type in ["role_granted", "role_revoked"]),
      :count
    )
  end

  describe "erasure demotes every membership" do
    test "to a bare viewer row, keeping its restrictions and its status" do
      site = org("erasure-grants-a")
      other = org("erasure-grants-b")
      pending_site = org("erasure-grants-c")
      person = user()

      role =
        Ash.Seed.seed!(KilnCMS.Accounts.Role, %{
          org_id: site.id,
          name: "Blog editor #{System.unique_integer([:positive])}",
          editable_types: ["post"]
        })

      membership(person, site,
        role: :editor,
        granted_role: :admin,
        granted_role_expires_at: in_hours(24),
        audiences: [@gated],
        editable_types: ["post"],
        readable_types: ["page"],
        field_grants: %{"post" => ["title"]},
        field_read_grants: %{"post" => []},
        role_id: role.id
      )

      membership(person, other, role: :admin)
      membership(person, pending_site, role: :viewer, status: :pending)

      events = role_events()
      erase!(person)

      on_site = reload_membership(person, site)
      assert %{role: :viewer, granted_role: nil, granted_role_expires_at: nil} = on_site
      assert on_site.audiences == []
      assert on_site.status == :active
      # Restrictions: emptying them would widen the row.
      assert on_site.editable_types == ["post"]
      assert on_site.readable_types == ["page"]
      assert on_site.field_grants == %{"post" => ["title"]}
      assert on_site.field_read_grants == %{"post" => []}
      assert on_site.role_id == role.id

      assert %{role: :viewer, status: :active} = reload_membership(person, other)
      assert %{role: :viewer, status: :pending} = reload_membership(person, pending_site)

      # No role-change audit events: erasure is not an admin's demotion.
      assert role_events() == events
    end

    # The validations of an admin's edit do not run on `:erase`: a stored value
    # an earlier release let through must not fail the erasure.
    test "a row with a malformed grant map and a foreign custom role is still demoted" do
      site = org("erasure-grants-malformed")
      elsewhere = org("erasure-grants-elsewhere")
      person = user()

      foreign_role =
        Ash.Seed.seed!(KilnCMS.Accounts.Role, %{
          org_id: elsewhere.id,
          name: "Foreign #{System.unique_integer([:positive])}"
        })

      membership(person, site,
        role: :admin,
        audiences: [@gated],
        field_grants: %{"post" => "not-a-list"},
        field_read_grants: %{"post" => 42},
        role_id: foreign_role.id
      )

      assert {:ok, _erased} = Accounts.anonymize_user(person, actor: user(:admin))
      assert %{role: :viewer, audiences: []} = reload_membership(person, site)
    end

    test ":erase takes the atomic strategy: one UPDATE, malformed rows included" do
      site = org("erasure-grants-atomic")
      person = user()
      membership(person, site, role: :admin, field_grants: %{"post" => "not-a-list"})
      tombstone = pre_fix_tombstone(person)

      query =
        OrgMembership
        |> Ash.Query.filter(user_id == ^tombstone.id)

      # `strategy: [:atomic]` alone fails rather than fall back when the
      # action cannot run as one statement.
      assert %Ash.BulkResult{status: :success} =
               Ash.bulk_update(query, :erase, %{},
                 authorize?: false,
                 strategy: [:atomic],
                 return_errors?: true
               )

      assert %{role: :viewer} = reload_membership(person, site)
    end

    test "a paying member's audiences go, and a later recompute puts none back" do
      sites = [org("erasure-grants-pay-a"), org("erasure-grants-pay-b")]
      person = user()

      for site <- sites do
        membership(person, site, role: :viewer)

        tier =
          Ash.Seed.seed!(Billing.MembershipTier, %{
            org_id: site.id,
            name: "Tier #{System.unique_integer([:positive])}",
            slug: "erasure-tier-#{System.unique_integer([:positive])}",
            audience: @gated,
            provider_price_id: "price_#{System.unique_integer([:positive])}"
          })

        Ash.Seed.seed!(Billing.Membership, %{
          org_id: site.id,
          user_id: person.id,
          tier_id: tier.id,
          status: :active
        })
      end

      assert {:ok, _delta} = Entitlements.recompute(person.id)
      for site <- sites, do: assert(%{audiences: [@gated]} = reload_membership(person, site))

      erase!(person)
      for site <- sites, do: assert(%{audiences: []} = reload_membership(person, site))

      assert {:ok, _delta} = Entitlements.recompute(person.id)
      for site <- sites, do: assert(%{audiences: []} = reload_membership(person, site))
    end
  end

  describe "an erased account on the rosters and in the tier decision" do
    test "an account erased now is on no roster and has no tier" do
      site = org("erasure-grants-roster")
      admin = member(site, :admin)
      erase!(admin)

      for tiers <- [[:admin], [:editor], [:viewer], [:admin, :editor, :viewer]] do
        refute admin.id in ids(Scoping.users_with_tier(site, tiers))
      end

      assert Scoping.effective_tier(Accounts.get_user!(admin.id, authorize?: false), site.id) ==
               :none
    end

    test "a pre-fix tombstone is left out whatever its membership still says" do
      site = org("erasure-grants-prefix")
      person = user()

      membership(person, site,
        role: :admin,
        granted_role: :admin,
        granted_role_expires_at: in_hours(24),
        audiences: [@gated]
      )

      # Not vacuous: the live account is on every roster asked below.
      assert person.id in ids(Scoping.users_with_tier(site, [:admin]))

      tombstone = pre_fix_tombstone(person)

      for tiers <- [[:admin], [:viewer], [:admin, :editor, :viewer]] do
        refute person.id in ids(Scoping.users_with_tier(site, tiers))
      end

      assert Scoping.effective_tier(tombstone, site.id) == :none
      assert Scoping.tier_source(tombstone, site.id) == {:none, :none, nil}
      assert Scoping.audiences(tombstone, site.id) == []
      refute person.id in ids(KilnCMS.Notifications.Registrations.recipients(site))
    end

    test "a legacy membership-less tombstone is not on the default org's rosters" do
      legacy = user(:editor)
      default = Accounts.default_org_id()
      assert legacy.id in ids(Scoping.users_with_tier(default, [:editor]))

      Ash.Seed.update!(legacy, %{anonymized_at: DateTime.utc_now()})

      for tiers <- [[:editor], [:viewer], [:admin, :editor, :viewer]] do
        refute legacy.id in ids(Scoping.users_with_tier(default, tiers))
      end
    end

    test "the assignee picker and the :user field roster leave it out" do
      site = org("erasure-grants-pickers")
      editor = member(site, :editor)
      pre_fix_tombstone(editor)

      user_field = [%{field_type: :user}]

      refute Enum.any?(KilnCMSWeb.ContentEditor.Shared.assignable_users(site), fn {_, id} ->
               id == editor.id
             end)

      refute Enum.any?(KilnCMSWeb.ContentEditor.Shared.site_people(site, user_field), fn {_, id} ->
               id == editor.id
             end)
    end

    test "a task cannot be assigned to an erased former editor" do
      site = org("erasure-grants-task")
      assigner = member(site, :editor)
      erased_now = member(site, :editor)
      erase!(erased_now)
      pre_fix = site |> member(:editor) |> pre_fix_tombstone()

      for assignee <- [erased_now, pre_fix] do
        assert {:error, error} =
                 CMS.assign_task(
                   %{
                     content_type: "page",
                     content_id: Ecto.UUID.generate(),
                     assignee_id: assignee.id
                   },
                   actor: assigner,
                   tenant: site
                 )

        assert Exception.message(error) =~ "must be an editor or admin"
      end
    end
  end

  describe "nothing is sent to an erased account" do
    # By account id: the jobs carry no address since #3019.
    defp workflow_jobs_to(user) do
      Enum.filter(all_enqueued(worker: WorkflowMailWorker), &(&1.args["user_id"] == user.id))
    end

    defp inbox_rows(user) do
      Repo.aggregate(
        from(n in "notifications", where: n.user_id == type(^user.id, Ecto.UUID)),
        :count
      )
    end

    test "a review request does not reach a pre-fix tombstone admin" do
      site = org("erasure-grants-review")
      tombstone = site |> member(:admin) |> pre_fix_tombstone()
      live_admin = member(site, :admin)
      editor = member(site, :editor)

      page =
        CMS.create_page!(
          %{title: "Erased review", slug: "erased-review-#{System.unique_integer([:positive])}"},
          actor: editor,
          tenant: site
        )

      CMS.submit_page_for_review!(page, %{}, actor: editor, tenant: site)

      # Not vacuous: the site's live admin is asked.
      assert [_job] = workflow_jobs_to(live_admin)
      assert workflow_jobs_to(tombstone) == []
      assert inbox_rows(tombstone) == 0
    end

    test "an erased author is not told their page was published" do
      site = org("erasure-grants-author")
      author = member(site, :editor)
      admin = member(site, :admin)

      page =
        CMS.create_page!(
          %{title: "Erased author", slug: "erased-author-#{System.unique_integer([:positive])}"},
          actor: author,
          tenant: site
        )

      # Not vacuous: a live author of another page is told.
      live_author = member(site, :editor)

      control =
        CMS.create_page!(
          %{title: "Live author", slug: "live-author-#{System.unique_integer([:positive])}"},
          actor: live_author,
          tenant: site
        )

      author = erase!(author)
      CMS.publish_page!(page, %{}, actor: admin, tenant: site)
      CMS.publish_page!(control, %{}, actor: admin, tenant: site)

      assert [_job] = workflow_jobs_to(live_author)
      assert workflow_jobs_to(author) == []
      assert inbox_rows(author) == 0
    end

    # Seeded: `assign_task` refuses an erased assignee (above), so the task
    # is one assigned before the erasure.
    defp task_for(assignee, site, due_on) do
      Ash.Seed.seed!(CMS.Task, %{
        org_id: site.id,
        content_type: "page",
        content_id: Ecto.UUID.generate(),
        assignee_id: assignee.id,
        due_on: due_on
      })
    end

    test "no task-assigned mail or inbox row for an erased assignee" do
      site = org("erasure-grants-assigned")
      assignee = site |> member(:editor) |> erase!()
      task = task_for(assignee, site, nil)

      live = member(site, :editor)
      control = task_for(live, site, nil)

      assert :ok = TaskNotifications.dispatch_assigned(task, nil)
      assert :ok = TaskNotifications.dispatch_assigned(control, nil)

      # Not vacuous: the live assignee is mailed and has an inbox row.
      assert_enqueued(
        worker: TaskMailWorker,
        args: %{"event" => "assigned", "task_id" => control.id}
      )

      assert inbox_rows(live) == 1

      refute_enqueued(
        worker: TaskMailWorker,
        args: %{"event" => "assigned", "task_id" => task.id}
      )

      assert inbox_rows(assignee) == 0
    end

    test "no task digest for an erased assignee" do
      site = org("erasure-grants-digest")
      assignee = site |> member(:editor) |> erase!()
      live = member(site, :editor)
      task_for(assignee, site, Date.utc_today())
      task_for(live, site, Date.utc_today())

      assert :ok = TaskDigestWorker.send_digests(site.id, Date.add(Date.utc_today(), 3))

      digests = all_enqueued(worker: TaskMailWorker) |> Enum.map(& &1.args["user_id"])
      assert live.id in digests
      refute assignee.id in digests
    end
  end

  describe "no write gives an erased account a tier back" do
    setup do
      site = org("erasure-grants-regrant")
      person = member(site, :editor)
      erase!(person)

      %{site: site, person: person, row: reload_membership(person, site), admin: user(:admin)}
    end

    test "a membership edit is refused", ctx do
      assert erased_error?(
               Accounts.update_org_membership(ctx.row, %{role: :admin}, actor: ctx.admin)
             )

      assert erased_error?(
               Accounts.update_org_membership(ctx.row, %{audiences: [@gated]}, actor: ctx.admin)
             )

      assert %{role: :viewer, audiences: []} = reload_membership(ctx.person, ctx.site)
    end

    test "a temporary tier is refused", ctx do
      assert erased_error?(
               Accounts.grant_membership_temporary_role(
                 ctx.row,
                 %{granted_role: :admin, granted_role_expires_at: in_hours(24)},
                 actor: ctx.admin
               )
             )

      assert %{granted_role: nil} = reload_membership(ctx.person, ctx.site)
    end

    test "audiences from the accounts console are refused", ctx do
      tombstone = Accounts.get_user!(ctx.person.id, authorize?: false)

      assert erased_error?(SiteAudiences.set(tombstone, ctx.site.id, [@gated], actor: ctx.admin))
      assert %{audiences: []} = reload_membership(ctx.person, ctx.site)
    end

    test "the row can still be removed", ctx do
      assert :ok = Accounts.remove_org_membership(ctx.row, actor: ctx.admin)

      assert {:ok, nil} =
               Accounts.get_org_membership(ctx.person.id, ctx.site.id,
                 authorize?: false,
                 not_found_error?: false
               )
    end

    test "a platform tier or audiences on the account itself are refused (#3010)", ctx do
      tombstone = Accounts.get_user!(ctx.person.id, authorize?: false)

      assert erased_error?(
               Accounts.manage_user_access(tombstone, %{role: :admin}, actor: ctx.admin)
             )

      assert erased_error?(
               Accounts.manage_user_access(tombstone, %{audiences: [@gated]}, actor: ctx.admin)
             )

      assert %{role: :viewer, audiences: []} =
               Accounts.get_user!(ctx.person.id, authorize?: false)
    end

    test "a platform temporary tier is refused, granted or revoked (#3010)", ctx do
      tombstone = Accounts.get_user!(ctx.person.id, authorize?: false)

      assert erased_error?(
               Accounts.grant_user_temporary_role(
                 tombstone,
                 %{granted_role: :admin, granted_role_expires_at: in_hours(24)},
                 actor: ctx.admin
               )
             )

      assert %{granted_role: nil} = Accounts.get_user!(ctx.person.id, authorize?: false)

      # Revoking is refused too: the lever is closed to an erased account
      # whatever it writes. Erasure clears the grant itself, and the expiry
      # sweep (`:expire_role_grant`) clears one left on a row by hand.
      held =
        Ash.Seed.update!(tombstone, %{
          granted_role: :editor,
          granted_role_expires_at: in_hours(24)
        })

      assert erased_error?(
               Accounts.grant_user_temporary_role(
                 held,
                 %{granted_role: nil, granted_role_expires_at: nil},
                 actor: ctx.admin
               )
             )
    end

    test "the same platform writes still reach a live account", ctx do
      live = user()

      assert {:ok, %{role: :editor}} =
               Accounts.manage_user_access(live, %{role: :editor}, actor: ctx.admin)

      assert {:ok, %{granted_role: :admin}} =
               Accounts.grant_user_temporary_role(
                 live,
                 %{granted_role: :admin, granted_role_expires_at: in_hours(24)},
                 actor: ctx.admin
               )
    end

    test "nobody may call :erase, a platform admin included", ctx do
      live = reload_membership(member(ctx.site, :admin), ctx.site)

      for actor <- [ctx.admin, Accounts.get_user!(live.user_id, authorize?: false)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.erase_org_membership(live, actor: actor)
      end

      assert %{role: :admin} =
               Accounts.get_org_membership!(live.user_id, ctx.site.id, authorize?: false)
    end
  end
end
