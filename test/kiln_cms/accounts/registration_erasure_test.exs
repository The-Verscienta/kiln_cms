defmodule KilnCMS.Accounts.RegistrationErasureTest do
  @moduledoc """
  Erasing an unconfirmed, rejected registration (#2514), in the sandbox: when
  a rejection erases and when it keeps, the guard on the registrations system
  actor's erasure, who may run `:anonymize`, what erasure now deletes, the
  account lock's refusals, and the pin that keeps `Registrations.Erasure`'s
  static lists honest against the schema.

  The races — an erasure against a membership, a paid membership, an API key
  or a confirmation committed by another transaction at the same moment —
  need real connections and are `KilnCMS.Accounts.RegistrationErasureRaceTest`.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountLock
  alias KilnCMS.Accounts.Errors.AccountErased
  alias KilnCMS.Accounts.Errors.ErasureRefused
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.Registrations.Erasure
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.CMS
  alias KilnCMS.Notifications
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.SystemActor

  @moduletag :capture_log

  @password "registration-erasure-123"

  defp uniq, do: System.unique_integer([:positive])

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "erase-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp member!(user, org_id, role, attrs \\ %{}) do
    Ash.Seed.seed!(
      OrgMembership,
      Map.merge(%{user_id: user.id, organization_id: org_id, role: role}, attrs)
    )
  end

  # An unconfirmed applicant whose registration created the account, waiting
  # on `org_id`: the account a rejection may erase.
  defp applicant(org_id, user_attrs \\ %{}, row_attrs \\ %{}) do
    applicant = user(:viewer, Map.merge(%{confirmed_at: nil}, user_attrs))

    row =
      member!(
        applicant,
        org_id,
        :viewer,
        Map.merge(%{status: :pending, created_account: true}, row_attrs)
      )

    {applicant, row}
  end

  defp rejected_accounts!(org_id, value) do
    CMS.save_site_registration!(%{approval_required: true, rejected_accounts: value},
      actor: user(:admin),
      tenant: org_id
    )
  end

  defp reject(row, actor, erase? \\ true),
    do: Accounts.reject_registration(row, %{erase: erase?}, actor: actor)

  defp reload_user(user), do: Accounts.get_user!(user.id, authorize?: false)

  defp reload(row),
    do: Accounts.get_org_membership!(row.user_id, row.organization_id, authorize?: false)

  defp erased?(user), do: match?(%{anonymized_at: %DateTime{}}, reload_user(user))

  defp rejections(org_id) do
    Security.list_events!(actor: user(:admin), tenant: org_id, page: [limit: 200])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == :registration_rejected))
  end

  # `Erasure.check/1` as the rejection runs it: in a transaction, under the lock.
  defp check(row) do
    {:ok, result} =
      Repo.transaction(fn ->
        {:ok, _state} = AccountLock.exclusive(row.user_id)
        Erasure.check(row)
      end)

    result
  end

  setup do
    site = org("erase")
    site_admin = user(:viewer)
    member!(site_admin, site.id, :admin)
    rejected_accounts!(site.id, :erase_unconfirmed)
    %{site: site, site_admin: site_admin}
  end

  describe "a rejection on a site that erases unconfirmed accounts" do
    test "erases an unconfirmed account that is nothing but the application, and says so",
         %{site: site, site_admin: site_admin} do
      {applicant, row} = applicant(site.id)
      address = to_string(applicant.email)

      assert {:ok, rejected} = reject(row, site_admin)
      assert rejected.status == :rejected
      assert rejected.__metadata__[:registration_outcome] == :erased

      erased = reload_user(applicant)
      assert %DateTime{} = erased.anonymized_at
      refute to_string(erased.email) == address
      assert reload(row).status == :rejected

      # Recorded after the erasure, by the deciding admin, naming no target.
      assert [event] = rejections(site.id)
      assert event.metadata == %{"outcome" => "erased"}
      assert event.target_id == nil
      assert event.actor_id == site_admin.id

      # The address is free again.
      refute Enum.any?(
               Accounts.list_users!(authorize?: false),
               &(to_string(&1.email) == address)
             )
    end

    test "a standing platform admin erases too", %{site: site} do
      {applicant, row} = applicant(site.id)
      assert {:ok, _rejected} = reject(row, user(:admin))
      assert erased?(applicant)
    end

    test "a confirmed rejection is never erased", %{site: site, site_admin: site_admin} do
      {applicant, row} = applicant(site.id, %{confirmed_at: DateTime.utc_now()})

      assert {:ok, rejected} = reject(row, site_admin)
      assert rejected.__metadata__[:registration_outcome] == :kept
      refute erased?(applicant)

      assert [event] = rejections(site.id)
      assert event.metadata == %{"outcome" => "kept"}
      assert event.target_id == applicant.id
    end

    test "nothing is erased unless the dialog asked for it", %{
      site: site,
      site_admin: site_admin
    } do
      {applicant, row} = applicant(site.id)
      assert {:ok, %{status: :rejected}} = reject(row, site_admin, false)
      refute erased?(applicant)
      assert [%{metadata: %{"outcome" => "kept"}}] = rejections(site.id)
    end

    test "a temporary site admin may reject, and the account is kept", %{site: site} do
      temporary = user(:viewer)

      member!(temporary, site.id, :editor, %{
        granted_role: :admin,
        granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

      {applicant, row} = applicant(site.id)

      assert {:ok, rejected} = reject(row, temporary)
      assert rejected.status == :rejected
      assert rejected.__metadata__[:registration_outcome] == :kept
      refute erased?(applicant)
    end

    test "a setting that cannot be read keeps the account", %{
      site: site,
      site_admin: site_admin
    } do
      {applicant, row} = applicant(site.id)

      assert {:ok, %{status: :rejected} = rejected} =
               KilnCMS.OrgSettings.with_actor(nil, fn -> reject(row, site_admin) end)

      assert rejected.__metadata__[:registration_outcome] == :kept
      refute erased?(applicant)
    end

    test "a failed erasure rolls the whole rejection back", %{
      site: site,
      site_admin: site_admin
    } do
      {applicant, row} = applicant(site.id)

      # The tombstone address erasure would write is taken, so its write fails.
      user(:viewer, %{email: "anonymized-#{applicant.id}@deleted.invalid"})

      assert {:error, error} = reject(row, site_admin)
      assert Exception.message(error) =~ "email: has already been taken"
      assert reload(row).status == :pending
      assert reload(row).decided_at == nil
      refute erased?(applicant)
      assert rejections(site.id) == []
    end
  end

  describe "a site that keeps rejected accounts" do
    test "keeps an erasable account, even when asked", %{site_admin: site_admin} do
      site = org("keep")
      member!(site_admin, site.id, :admin)
      rejected_accounts!(site.id, :keep)
      {applicant, row} = applicant(site.id)

      assert {:ok, %{status: :rejected}} = reject(row, site_admin)
      refute erased?(applicant)
      assert [%{metadata: %{"outcome" => "kept"}}] = rejections(site.id)
    end

    test "a site with no settings row keeps", %{site_admin: site_admin} do
      site = org("no-row")
      member!(site_admin, site.id, :admin)
      {applicant, row} = applicant(site.id)

      assert {:ok, _rejected} = reject(row, site_admin)
      refute erased?(applicant)
    end
  end

  describe "the erasable check keeps an account that is more than its application" do
    setup %{site: site} do
      tier =
        Billing.create_tier!(
          %{
            name: "Members #{uniq()}",
            slug: "members-#{uniq()}",
            audience: :member,
            provider_price_id: "price_#{uniq()}"
          },
          actor: user(:admin),
          tenant: site.id
        )

      %{tier: tier}
    end

    test "an erasable account passes", %{site: site} do
      {_applicant, row} = applicant(site.id)
      assert check(row) == :erasable
    end

    test "each blocker keeps it, and the rejection keeps it", %{
      site: site,
      site_admin: site_admin,
      tier: tier
    } do
      future = DateTime.add(DateTime.utc_now(), 3600)
      other_site = org("erase-other")

      blockers = [
        {:confirmed, fn -> applicant(site.id, %{confirmed_at: DateTime.utc_now()}) end},
        {:not_created_here, fn -> applicant(site.id, %{}, %{created_account: false}) end},
        {:erased, fn -> applicant(site.id, %{anonymized_at: DateTime.utc_now()}) end},
        {:not_viewer, fn -> applicant(site.id, %{role: :editor}) end},
        {:live_grant,
         fn -> applicant(site.id, %{granted_role: :editor, granted_role_expires_at: future}) end},
        {:live_grant,
         fn ->
           applicant(site.id, %{}, %{granted_role: :editor, granted_role_expires_at: future})
         end},
        {:audiences, fn -> applicant(site.id, %{audiences: [:member]}) end},
        {:other_membership,
         fn ->
           {applicant, row} = applicant(site.id)
           member!(applicant, other_site.id, :viewer)
           {applicant, row}
         end},
        {:other_membership,
         fn ->
           {applicant, row} = applicant(site.id)
           member!(applicant, other_site.id, :viewer, %{status: :rejected})
           {applicant, row}
         end},
        {{:referenced, "api_keys.user_id"},
         fn ->
           {applicant, row} = applicant(site.id)
           expires = DateTime.add(DateTime.utc_now(), 86_400)
           {:ok, key} = Accounts.mint_api_key(applicant.id, "ci", expires, authorize?: false)
           {:ok, _revoked} = Accounts.revoke_api_key(key, authorize?: false)
           {applicant, row}
         end},
        {{:referenced, "billing_memberships.user_id"},
         fn ->
           {applicant, row} = applicant(site.id)

           Ash.Seed.seed!(Billing.Membership, %{
             org_id: site.id,
             user_id: applicant.id,
             tier_id: tier.id,
             status: :canceled
           })

           {applicant, row}
         end},
        {{:referenced, "notifications.actor_id"},
         fn ->
           {applicant, row} = applicant(site.id)

           {:ok, _notification} =
             Notifications.record_notification(
               %{
                 user_id: site_admin.id,
                 actor_id: applicant.id,
                 event: :comment_mention,
                 content_type: "page",
                 content_id: Ecto.UUID.generate(),
                 title: "A draft"
               },
               tenant: site.id
             )

           {applicant, row}
         end},
        {{:referenced, "invitations.invited_by_id"},
         fn ->
           {applicant, row} = applicant(site.id)

           Ash.Seed.seed!(KilnCMS.Accounts.Invitation, %{
             organization_id: site.id,
             email: "invited-#{uniq()}@example.com",
             role: :viewer,
             invited_by_id: applicant.id,
             token_hash: "hash-#{uniq()}",
             expires_at: future
           })

           {applicant, row}
         end}
      ]

      for {reason, build} <- blockers do
        {applicant, row} = build.()

        assert check(row) == {:keep, reason}, "expected #{inspect(reason)}"
        assert {:ok, rejected} = reject(row, site_admin)
        assert rejected.__metadata__[:registration_outcome] == :kept, inspect(reason)
        assert reload_user(applicant).anonymized_at == applicant.anonymized_at
      end
    end
  end

  describe "the guard on the registrations system actor's erasure" do
    defp system_erase(user, context),
      do:
        Accounts.anonymize_user(user,
          actor: SystemActor.new(:registrations),
          context: %{registration_erasure: context}
        )

    test "refuses without a rejection to name", %{site: site} do
      {applicant, _row} = applicant(site.id)

      assert {:error, %Ash.Error.Forbidden{} = error} =
               Accounts.anonymize_user(applicant, actor: SystemActor.new(:registrations))

      assert Enum.any?(error.errors, &match?(%ErasureRefused{}, &1))
      refute erased?(applicant)
    end

    test "refuses a still-pending row", %{site: site} do
      {applicant, row} = applicant(site.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               system_erase(applicant, %{
                 membership_id: row.id,
                 organization_id: site.id,
                 decided_at: DateTime.utc_now()
               })

      refute erased?(applicant)
    end

    test "refuses a rejection other than the one named", %{site: site, site_admin: site_admin} do
      {applicant, row} = applicant(site.id)
      {:ok, rejected} = reject(row, site_admin, false)

      assert {:error, %Ash.Error.Forbidden{}} =
               system_erase(applicant, %{
                 membership_id: rejected.id,
                 organization_id: site.id,
                 decided_at: DateTime.add(rejected.decided_at, -60)
               })

      refute erased?(applicant)
    end

    test "refuses another account's registration", %{site: site, site_admin: site_admin} do
      {applicant, _row} = applicant(site.id)
      {_other, other_row} = applicant(site.id)
      {:ok, rejected} = reject(other_row, site_admin, false)

      assert {:error, %Ash.Error.Forbidden{}} =
               system_erase(applicant, %{
                 membership_id: rejected.id,
                 organization_id: site.id,
                 decided_at: rejected.decided_at
               })

      refute erased?(applicant)
    end

    test "refuses an account the erasable check keeps", %{site: site, site_admin: site_admin} do
      {applicant, row} = applicant(site.id, %{confirmed_at: DateTime.utc_now()})
      {:ok, rejected} = reject(row, site_admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               system_erase(applicant, %{
                 membership_id: rejected.id,
                 organization_id: site.id,
                 decided_at: rejected.decided_at
               })

      refute erased?(applicant)
    end
  end

  describe "who may run :anonymize" do
    test "refused: a site admin, an editor, a viewer, the account itself, anonymous, other system actors",
         %{site: site, site_admin: site_admin} do
      {applicant, _row} = applicant(site.id)

      for actor <- [
            site_admin,
            user(:editor),
            user(:viewer),
            applicant,
            nil,
            SystemActor.new(:billing),
            SystemActor.new(:invitations)
          ] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.anonymize_user(applicant, actor: actor),
               "expected #{inspect(actor)} to be refused"
      end

      refute erased?(applicant)
    end

    test "allowed: a standing platform admin, whatever the account", %{site: site} do
      {applicant, _row} = applicant(site.id, %{confirmed_at: DateTime.utc_now()})
      assert {:ok, _erased} = Accounts.anonymize_user(applicant, actor: user(:admin))
      assert erased?(applicant)
    end
  end

  describe "what erasure deletes (#2514)" do
    test "push subscriptions, private saved views and the account's own notifications" do
      org_id = Accounts.default_org_id()
      person = user(:editor)
      bystander = user(:editor)

      push =
        Ash.Seed.seed!(KilnCMS.Accounts.PushSubscription, %{
          user_id: person.id,
          org_id: org_id,
          endpoint: "https://push.example.com/x/#{uniq()}",
          p256dh: "key",
          auth: "auth",
          label: "iOS · Safari",
          vapid_public_key: "vapid"
        })

      private_view =
        Ash.Seed.seed!(CMS.SavedView, %{
          owner_id: person.id,
          org_id: org_id,
          name: "Mine",
          params: %{},
          shared: false
        })

      shared_view =
        Ash.Seed.seed!(CMS.SavedView, %{
          owner_id: person.id,
          org_id: org_id,
          name: "Team",
          params: %{},
          shared: true
        })

      notify = fn recipient ->
        {:ok, notification} =
          Notifications.record_notification(
            %{
              user_id: recipient.id,
              event: :comment_mention,
              content_type: "page",
              content_id: Ecto.UUID.generate(),
              title: "A draft"
            },
            tenant: org_id
          )

        notification
      end

      own = notify.(person)
      theirs = notify.(bystander)

      assert {:ok, _erased} = Accounts.anonymize_user(person, actor: user(:admin))

      gone? = fn resource, id ->
        Ash.get(resource, id, authorize?: false, tenant: org_id, not_found_error?: false) ==
          {:ok, nil}
      end

      assert gone?.(KilnCMS.Accounts.PushSubscription, push.id)
      assert gone?.(CMS.SavedView, private_view.id)
      refute gone?.(CMS.SavedView, shared_view.id)
      assert gone?.(Notifications.Notification, own.id)
      refute gone?.(Notifications.Notification, theirs.id)
    end
  end

  describe "the account lock refuses an erased account" do
    setup %{site: site} do
      erased = user(:viewer, %{anonymized_at: DateTime.utc_now()})
      %{erased: erased, site: site}
    end

    test "a membership", %{erased: erased, site: site} do
      assert {:error, error} =
               Accounts.create_org_membership(
                 %{organization_id: site.id, user_id: erased.id, role: :viewer},
                 authorize?: false
               )

      assert Enum.any?(error.errors, &match?(%AccountErased{}, &1))
    end

    test "an API key", %{erased: erased} do
      expires = DateTime.add(DateTime.utc_now(), 86_400)

      assert {:error, error} = Accounts.mint_api_key(erased.id, "ci", expires, authorize?: false)
      assert Enum.any?(error.errors, &match?(%AccountErased{}, &1))
    end

    test "a paid membership", %{erased: erased, site: site} do
      tier =
        Billing.create_tier!(
          %{
            name: "Members #{uniq()}",
            slug: "members-#{uniq()}",
            audience: :member,
            provider_price_id: "price_#{uniq()}"
          },
          actor: user(:admin),
          tenant: site.id
        )

      assert {:error, error} =
               Billing.comp_membership(%{user_id: erased.id, tier_id: tier.id},
                 actor: user(:admin),
                 tenant: site.id
               )

      assert Enum.any?(error.errors, &match?(%AccountErased{}, &1))
    end
  end

  describe "Registrations.Erasure's static lists" do
    # Every foreign key to `users` must be classified: a new table that
    # references accounts either stops an erasure or is one the erasure itself
    # handles. The rejected membership's own table is the one exception.
    test "classify every foreign key to users" do
      %{rows: rows} =
        Repo.query!("""
        SELECT c.conrelid::regclass::text, a.attname::text
        FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        WHERE c.contype = 'f' AND c.confrelid = 'users'::regclass
        """)

      classified =
        MapSet.new(Erasure.blocking() ++ Erasure.handled() ++ [{"org_memberships", "user_id"}])

      unclassified =
        for [table, column] <- rows, {table, column} not in classified, do: "#{table}.#{column}"

      assert unclassified == [],
             "foreign keys to users that KilnCMS.Accounts.Registrations.Erasure does not classify: " <>
               Enum.join(unclassified, ", ") <>
               ". Add each to @blocking (it stops an erasure) or to @handled " <>
               "(Changes.AnonymizeUser scrubs or deletes it)."
    end

    test "name only columns that exist" do
      %{rows: rows} =
        Repo.query!("""
        SELECT table_name::text, column_name::text FROM information_schema.columns
        WHERE table_schema = 'public'
        """)

      existing = MapSet.new(rows, fn [table, column] -> {table, column} end)

      missing =
        for {table, column} <- Erasure.blocking() ++ Erasure.handled(),
            {table, column} not in existing,
            do: "#{table}.#{column}"

      assert missing == []
    end
  end
end
