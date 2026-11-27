defmodule KilnCMS.Mail.ErasureSuppressionTest do
  @moduledoc """
  Erasure deletes the erased account's address from the instance-wide
  suppression list and from every site's (#3036).

  Before this, `AnonymizeUser` tombstoned the account and left the address on
  both lists indefinitely. Pinned here: the rows go on the instance list and
  on every site's, whatever the case they were recorded in; other addresses'
  rows stay; `nil` is a no-op; `:forget_erased` is refused to any request
  carrying an actor (the platform admin, a site's admin, the mail system
  actor); the access the lists had before is unchanged; and a failure in the
  sweep raises inside the transaction, so it rolls back, and is logged
  without the address.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures, only: [org: 1]

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Mail
  alias KilnCMS.Mail.SiteSuppressedRecipient

  defp user(role \\ :viewer, email \\ nil) do
    Ash.Seed.seed!(User, %{
      email: email || "supp-erase-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp member(site, tier) do
    member = user()

    Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
      user_id: member.id,
      organization_id: site.id,
      role: tier
    })

    member
  end

  defp suppress!(email), do: Mail.suppress_recipient!(%{email: email}, actor: Mail.system())

  defp suppress!(email, site),
    do: Mail.suppress_site_recipient!(%{email: email}, actor: Mail.system(), tenant: site)

  defp instance_list do
    Mail.list_suppressed_recipients!(authorize?: false) |> Enum.map(&to_string(&1.email))
  end

  defp site_list(site) do
    Mail.list_site_suppressed_recipients!(authorize?: false, tenant: site)
    |> Enum.map(&to_string(&1.email))
  end

  defp unique, do: System.unique_integer([:positive])

  describe "erasing an account" do
    test "drops its address from the instance list and every site's, in any case" do
      site_a = org("supp-erase-a")
      site_b = org("supp-erase-b")
      n = unique()
      subject = user(:viewer, "Erase.Me-#{n}@Example.com")
      other = "someone-else-#{n}@example.com"

      suppress!("erase.me-#{n}@example.com")
      suppress!(other)
      suppress!("ERASE.ME-#{n}@EXAMPLE.COM", site_a)
      suppress!(other, site_a)
      suppress!("Erase.Me-#{n}@Example.com", site_b)
      suppress!(other, site_b)

      Accounts.anonymize_user!(subject, actor: user(:admin))

      assert instance_list() == [other]
      assert site_list(site_a) == [other]
      assert site_list(site_b) == [other]
    end

    test "a registration rejected with erasure drops the address too" do
      site = org("supp-erase-reject")
      site_admin = member(site, :admin)

      KilnCMS.CMS.save_site_registration!(
        %{approval_required: true, rejected_accounts: :erase_unconfirmed},
        actor: user(:admin),
        tenant: site.id
      )

      n = unique()

      applicant =
        Ash.Seed.seed!(User, %{
          email: "Rejected-#{n}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          role: :viewer
        })

      row =
        Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
          user_id: applicant.id,
          organization_id: site.id,
          role: :viewer,
          status: :pending,
          created_account: true
        })

      suppress!("rejected-#{n}@example.com")
      suppress!("rejected-#{n}@example.com", site)

      assert {:ok, _rejected} =
               Accounts.reject_registration(row, %{erase: true}, actor: site_admin)

      assert Accounts.get_user!(applicant.id, authorize?: false).anonymized_at
      assert instance_list() == []
      assert site_list(site) == []
    end

    test "nil (an account with no address left) is a no-op" do
      site = org("supp-erase-nil")
      suppress!("kept@example.com")
      suppress!("kept@example.com", site)

      assert :ok = Mail.forget_suppressions(nil)

      assert instance_list() == ["kept@example.com"]
      assert site_list(site) == ["kept@example.com"]
    end
  end

  describe "a failure in the sweep" do
    test "raises inside the transaction, rolling back what it had deleted" do
      address = "rollback-#{unique()}@example.com"
      suppress!(address)

      log =
        capture_log(fn ->
          assert {:error, _reason} =
                   KilnCMS.Repo.transaction(fn ->
                     try do
                       Mail.forget_suppressions(address, ["not-an-org-id"])
                     catch
                       # Ash reports the failed write inside a transaction as
                       # a rollback; anything else is turned into one here.
                       :error, error -> KilnCMS.Repo.rollback(error)
                     end
                   end)
        end)

      # The instance row was deleted before the site sweep failed, and came
      # back with the rollback.
      assert instance_list() == [address]

      assert log =~ "mail forget_suppressions failed for org not-an-org-id"
      refute log =~ address
    end
  end

  describe ":forget_erased is the system's alone" do
    setup do
      site = org("supp-erase-authz")
      entry = suppress!("refused-#{unique()}@example.com")
      site_entry = suppress!("refused-#{unique()}@example.com", site)
      %{site: site, entry: entry, site_entry: site_entry}
    end

    test "refused to the platform admin and the mail system actor on the instance list",
         %{entry: entry} do
      for actor <- [user(:admin), Mail.system()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Mail.forget_erased_suppressions(entry, entry.email, actor: actor)
      end

      assert instance_list() == [to_string(entry.email)]
    end

    test "refused to the site's admin, the platform admin and the mail system actor on a site's list",
         %{site: site, site_entry: entry} do
      for actor <- [member(site, :admin), user(:admin), Mail.system()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Mail.forget_erased_site_suppressions(entry, entry.email,
                   actor: actor,
                   tenant: site
                 )
      end

      assert site_list(site) == [to_string(entry.email)]
    end

    test "refused to an actor as a bulk delete, even with the read unauthorized",
         %{site: site, entry: entry, site_entry: site_entry} do
      bulk = [authorize_query?: false, return_errors?: true, return_records?: false]

      assert %Ash.BulkResult{status: :error} =
               KilnCMS.Mail.SuppressedRecipient
               |> Ash.Query.filter(email == ^entry.email)
               |> Mail.forget_erased_suppressions(entry.email,
                 actor: user(:admin),
                 bulk_options: bulk
               )

      assert %Ash.BulkResult{status: :error} =
               SiteSuppressedRecipient
               |> Ash.Query.filter(email == ^site_entry.email)
               |> Mail.forget_erased_site_suppressions(site_entry.email,
                 actor: member(site, :admin),
                 tenant: site,
                 bulk_options: bulk
               )

      assert instance_list() == [to_string(entry.email)]
      assert site_list(site) == [to_string(site_entry.email)]
    end
  end

  # The address bounds the delete in the action, not only in the caller's
  # query: a sweep whose filter went missing must not empty a list.
  describe ":forget_erased is bounded by the address it is given" do
    @bulk [
      authorize_query?: false,
      strategy: [:atomic, :atomic_batches, :stream],
      return_records?: false,
      return_errors?: true
    ]

    test "an unfiltered query deletes only that address's rows, on either list" do
      site = org("supp-erase-bound")
      n = unique()
      gone = "bound-#{n}@example.com"
      kept = "bound-kept-#{n}@example.com"

      for email <- [gone, kept] do
        suppress!(email)
        suppress!(email, site)
      end

      assert %Ash.BulkResult{status: :success} =
               Mail.forget_erased_suppressions(
                 Ash.Query.new(KilnCMS.Mail.SuppressedRecipient),
                 "BOUND-#{n}@Example.com",
                 bulk_options: @bulk
               )

      assert %Ash.BulkResult{status: :success} =
               Mail.forget_erased_site_suppressions(
                 Ash.Query.new(SiteSuppressedRecipient),
                 "BOUND-#{n}@Example.com",
                 tenant: site,
                 bulk_options: @bulk
               )

      assert instance_list() == [kept]
      assert site_list(site) == [kept]
    end

    test "with no address the delete is invalid and deletes nothing" do
      site = org("supp-erase-no-address")
      suppress!("kept@example.com")
      suppress!("kept@example.com", site)

      assert %Ash.BulkResult{status: :error, errors: [%Ash.Error.Invalid{} | _]} =
               Mail.forget_erased_suppressions(
                 Ash.Query.new(KilnCMS.Mail.SuppressedRecipient),
                 nil,
                 bulk_options: @bulk
               )

      assert %Ash.BulkResult{status: :error, errors: [%Ash.Error.Invalid{} | _]} =
               Mail.forget_erased_site_suppressions(Ash.Query.new(SiteSuppressedRecipient), nil,
                 tenant: site,
                 bulk_options: @bulk
               )

      assert instance_list() == ["kept@example.com"]
      assert site_list(site) == ["kept@example.com"]
    end
  end

  # The policies were narrowed from `always()` and `action_type([:read,
  # :destroy])` to named actions, so that `:forget_erased` is held to its own
  # policy alone. Everything they decided before is decided the same way.
  describe "the access the lists had before is unchanged" do
    test "instance list: the platform admin reads, records and clears; an editor does none" do
      admin = user(:admin)
      editor = user(:editor)

      assert {:ok, entry} =
               Mail.suppress_recipient(%{email: "admin-#{unique()}@example.com"}, actor: admin)

      assert [_] = Mail.list_suppressed_recipients!(actor: admin, authorize_with: :error)

      assert {:error, %Ash.Error.Forbidden{}} =
               Mail.list_suppressed_recipients(actor: editor, authorize_with: :error)

      assert {:error, %Ash.Error.Forbidden{}} =
               Mail.suppress_recipient(%{email: "editor@example.com"}, actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} = Mail.unsuppress_recipient(entry, actor: editor)
      assert :ok = Mail.unsuppress_recipient(entry, actor: admin)
    end

    test "instance list: the mail system actor reads and records, and may not clear" do
      system = Mail.system()
      entry = suppress!("system-#{unique()}@example.com")

      assert [_] = Mail.list_suppressed_recipients!(actor: system, authorize_with: :error)
      assert {:error, %Ash.Error.Forbidden{}} = Mail.unsuppress_recipient(entry, actor: system)
    end

    test "site list: its admin reads and clears; its editor does neither; nobody but the pipeline records" do
      site = org("supp-erase-site-access")
      admin = member(site, :admin)
      editor = member(site, :editor)
      entry = suppress!("site-#{unique()}@example.com", site)

      assert [_] =
               Mail.list_site_suppressed_recipients!(
                 actor: admin,
                 tenant: site,
                 authorize_with: :error
               )

      assert {:ok, []} = Mail.list_site_suppressed_recipients(actor: editor, tenant: site)

      assert {:error, %Ash.Error.Forbidden{}} =
               Mail.unsuppress_site_recipient(entry, actor: editor, tenant: site)

      for actor <- [admin, user(:admin)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Mail.suppress_site_recipient(%{email: "person@example.com"},
                   actor: actor,
                   tenant: site
                 )
      end

      assert :ok = Mail.unsuppress_site_recipient(entry, actor: admin, tenant: site)
    end

    test "site list: the mail system actor reads and records, and may not clear" do
      site = org("supp-erase-site-system")
      system = Mail.system()
      entry = suppress!("site-system-#{unique()}@example.com", site)

      assert [_] =
               Mail.list_site_suppressed_recipients!(
                 actor: system,
                 tenant: site,
                 authorize_with: :error
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Mail.unsuppress_site_recipient(entry, actor: system, tenant: site)
    end
  end
end
