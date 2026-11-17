defmodule KilnCMS.Mail.AccountMailErasureTest do
  @moduledoc """
  Account mail is checked when it is sent, and withheld at erasure (#3035).

  A `KilnCMS.Mail.DeliveryWorker` job can wait hours for a retry. Account
  mail now names its account (`"user_id"`), and the worker sends it only
  while that account still holds the address the job was queued to. Erasure
  withholds the account's jobs not yet finished (`Mail.withhold_pending/2`),
  in every state but the finished ones, and those queued by the release
  before (no `"user_id"` key) by address.

  Jobs are queued the real way (the senders, `Mail.enqueue!/2`) and run by a
  drain; the legacy, executing and finished rows are written as an earlier
  release, or a running attempt, leaves them. The "previous release" block
  runs the rows through v1.10.1's `DeliveryWorker.perform/1`, which is
  `Mail.open_args/1` (unchanged since) and its cancel: `old_release_perform/1`
  below is that function.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import Ecto.Query, only: [from: 2]
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.SecondFactorNotice
  alias KilnCMS.Accounts.SignInAlert
  alias KilnCMS.Accounts.User
  alias KilnCMS.Accounts.User.Senders
  alias KilnCMS.CMS
  alias KilnCMS.Mail
  alias KilnCMS.Mail.DeliveryWorker
  alias KilnCMS.Security.AlertMail

  @moduletag :capture_log

  @worker "KilnCMS.Mail.DeliveryWorker"

  defp unique, do: System.unique_integer([:positive])

  defp user(role \\ :viewer, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "account-mail-#{unique()}@example.com",
          name: "Person #{unique()}",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp erase!(user), do: Accounts.anonymize_user!(user, actor: user(:admin))

  defp address(user), do: to_string(user.email)

  defp drain, do: KilnCMS.DataCase.drain_oban()

  defp emails do
    Stream.repeatedly(fn ->
      receive do
        {:email, email} -> email
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
  end

  defp sent_to(emails, address),
    do: Enum.filter(emails, fn email -> Enum.any?(email.to, &(elem(&1, 1) == address)) end)

  defp mail(address, subject \\ "Account mail") do
    Swoosh.Email.new()
    |> Swoosh.Email.from({"Kiln", "noreply@example.com"})
    |> Swoosh.Email.to(address)
    |> Swoosh.Email.subject(subject)
    |> Swoosh.Email.html_body("<p>#{subject}</p>")
  end

  defp mail_jobs, do: Repo.all(from(j in Oban.Job, where: j.worker == @worker, order_by: j.id))

  defp jobs_to(address), do: Enum.filter(mail_jobs(), &(&1.args["to"] == ["", address]))

  defp row(id), do: Repo.one!(from(j in Oban.Job, where: j.id == ^id))

  defp set_state(job, state),
    do: Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])

  # Queue account mail for `user`, as the senders do. Returns the job row.
  defp queue_for!(user, to_address \\ nil) do
    to_address = to_address || address(user)
    :ok = Mail.enqueue!(mail(to_address), user_id: user.id)
    List.last(jobs_to(to_address))
  end

  # A row as the release before #3035 queued it: no `"user_id"` key.
  defp legacy!(to_address, state \\ "available") do
    :ok = Mail.enqueue!(mail(to_address))
    job = List.last(jobs_to(to_address))
    args = Map.delete(job.args, "user_id")

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [args: args, state: state]
    )

    row(job.id)
  end

  defp withheld?(job) do
    args = row(job.id).args
    args["withheld"] == "erased" and not Map.has_key?(args, "to") and message_gone?(args)
  end

  defp message_gone?(args),
    do: Enum.all?(~w(sealed subject html_body text_body), &(not Map.has_key?(args, &1)))

  # v1.10.1's `KilnCMS.Mail.DeliveryWorker.perform/1`, with Oban's part (the
  # cancel) as its return value: `git show v1.10.1:lib/kiln_cms/mail/delivery_worker.ex`.
  # `Mail.open_args/1` and `Mail.deliver_for_worker/2` are unchanged since.
  defp old_release_perform(args) do
    case Mail.open_args(args) do
      {:ok, email} -> Mail.deliver_for_worker(email, org_id: args["org_id"])
      {:error, reason} -> {:cancel, Mail.describe_open_error(reason)}
    end
  end

  describe "the args name the account" do
    test "account mail carries `user_id`, the recipient and the sealed message" do
      person = user()
      job = queue_for!(person)

      assert job.args["user_id"] == person.id
      assert job.args["to"] == ["", address(person)]
      assert is_binary(job.args["sealed"])
      refute Map.has_key?(job.args, "subject")
    end

    test "mail with no account writes the key with a null id" do
      address = "nobody-#{unique()}@example.com"
      :ok = Mail.enqueue!(mail(address))

      assert [job] = jobs_to(address)
      assert Map.has_key?(job.args, "user_id")
      assert job.args["user_id"] == nil
    end

    test "`user_id:` with more than one recipient raises" do
      email = mail("a-#{unique()}@example.com") |> Swoosh.Email.to("b-#{unique()}@example.com")

      assert_raise ArgumentError, ~r/names one account/, fn ->
        Mail.enqueue!(email, user_id: Ecto.UUID.generate())
      end
    end
  end

  describe "every account mail sender names the account" do
    setup do
      %{site: Accounts.default_org(), other_site: org("account-mail")}
    end

    defp assert_named(person, send) do
      send.()
      assert [job] = jobs_to(address(person))
      assert job.args["user_id"] == person.id
    end

    test "the sign-in unlock", %{site: site} do
      person = user()
      assert_named(person, fn -> Senders.SendSignInUnlock.deliver(person, "tok", site) end)
    end

    test "a password reset, the self-service one and the admin's" do
      person = user()
      assert_named(person, fn -> Senders.SendPasswordResetEmail.send(person, "tok", []) end)

      other = user()
      assert {:ok, :sent} = Accounts.send_user_password_reset(other.id, actor: user(:admin))
      assert [job] = jobs_to(address(other))
      assert job.args["user_id"] == other.id
    end

    test "a magic link to an account; one to a bare address names none" do
      person = user()
      assert_named(person, fn -> Senders.SendMagicLink.send(person, "tok", []) end)

      bare = "bare-#{unique()}@example.com"
      Senders.SendMagicLink.send(bare, "tok", [])
      assert [job] = jobs_to(bare)
      assert job.args["user_id"] == nil
    end

    test "the confirmation mail" do
      person = user(:viewer, %{confirmed_at: nil})

      assert_named(person, fn ->
        Senders.SendNewUserConfirmationEmail.send(person, "tok", [])
      end)
    end

    test "the registration notice goes to the account holding the address" do
      person = user()
      assert_named(person, fn -> Senders.SendRegistrationNotice.deliver(address(person)) end)
    end

    test "the registration notice sends nothing once no account holds the address" do
      person = user()
      old_address = address(person)
      erase!(person)

      assert :ok = Senders.SendRegistrationNotice.deliver(old_address)
      assert jobs_to(old_address) == []

      nobody = "nobody-#{unique()}@example.com"
      assert :ok = Senders.SendRegistrationNotice.deliver(nobody)
      assert jobs_to(nobody) == []
    end

    test "a membership notice, a registration decision, a registration pending", ctx do
      member = user()

      assert_named(member, fn ->
        Senders.SendMembershipNotice.deliver(member, ctx.other_site, :editor)
      end)

      applicant = user()

      assert_named(applicant, fn ->
        Senders.SendRegistrationDecision.deliver(:approve, applicant, ctx.other_site, :viewer)
      end)

      admin = user(:admin)

      assert_named(admin, fn ->
        Senders.SendRegistrationPending.deliver(admin, ctx.other_site)
      end)
    end

    test "the second-factor notices" do
      person = user()
      assert_named(person, fn -> SecondFactorNotice.factor_added(person.id, :passkey, %{}) end)

      other = user()

      assert_named(other, fn ->
        SecondFactorNotice.factor_removed(other.id, :totp, other, %{})
      end)
    end

    test "the second-factor sign-in alert" do
      person = user()
      assert_named(person, fn -> SignInAlert.second_factor_locked(person) end)
    end

    test "a security alert" do
      admin = user(:admin)

      data = %{
        kind: "lockout",
        channel: "site",
        site_name: "Site",
        occurred_at: "2026-11-17T00:00:00Z",
        console_url: "https://example.com/editor/security"
      }

      assert_named(admin, fn -> AlertMail.deliver!(admin, data, true) end)
    end

    test "an invitation and a newsletter confirmation are mail to an address", ctx do
      invited = "invited-#{unique()}@example.com"

      Senders.SendInvitation.deliver(
        %{email: invited, organization_id: ctx.other_site.id, role: :viewer},
        "tok",
        nil,
        "Site"
      )

      subscriber = "news-#{unique()}@example.com"
      {:ok, _row} = KilnCMS.Newsletter.subscribe(%{email: subscriber}, authorize?: false)

      for address <- [invited, subscriber] do
        assert [job] = jobs_to(address)
        assert job.args["user_id"] == nil
      end
    end
  end

  describe "the worker checks the account when it sends" do
    test "a live account's mail is delivered" do
      person = user()
      job = queue_for!(person)
      drain()

      assert [_mail] = sent_to(emails(), address(person))
      assert row(job.id).state == "completed"
    end

    test "mail queued with the old address after erasure is sent nothing, and completes" do
      # The race erasure's sweep cannot close: a sender read the address
      # before the erasure committed and inserted the job after it.
      person = user()
      old_address = address(person)
      erase!(person)

      job = queue_for!(person, old_address)
      drain()

      assert sent_to(emails(), old_address) == []
      row = row(job.id)
      assert row.state == "completed"
      refute Map.has_key?(row.args, "to")
      assert message_gone?(row.args)
      assert Mail.recent_delivery_failures() == []
    end

    test "an account that no longer holds the address is sent nothing" do
      person = user()
      job = queue_for!(person, "elsewhere-#{unique()}@example.com")
      drain()

      assert emails() == []
      refute Map.has_key?(row(job.id).args, "to")
    end

    test "the address is compared case insensitively" do
      person = user()
      job = queue_for!(person, String.upcase(address(person)))
      drain()

      assert [_mail] = emails()
      assert row(job.id).state == "completed"
    end

    test "an account gone is sent nothing" do
      job = queue_for!(%{id: Ecto.UUID.generate(), email: "gone-#{unique()}@example.com"})
      drain()

      assert emails() == []
      assert row(job.id).state == "completed"
      refute Map.has_key?(row(job.id).args, "to")
    end

    test "an account that cannot be read retries, and its last attempt drops the message" do
      address = "unreadable-#{unique()}@example.com"
      :ok = Mail.enqueue!(mail(address), user_id: "not-a-uuid")
      [job] = jobs_to(address)

      assert {:error, message} = DeliveryWorker.perform(%{job | attempt: 1})
      assert message =~ "could not read the recipient's account"
      refute message =~ address
      assert Map.has_key?(row(job.id).args, "to")

      assert {:error, _message} = DeliveryWorker.perform(%{job | attempt: job.max_attempts})
      refute Map.has_key?(row(job.id).args, "to")
      assert message_gone?(row(job.id).args)
      assert emails() == []
    end
  end

  describe "erasure withholds account mail not yet finished" do
    test "the account's waiting jobs, in every unfinished state, complete unsent" do
      person = user()
      old_address = address(person)

      jobs =
        for state <- ~w(available scheduled retryable executing suspended) do
          job = queue_for!(person)
          set_state(job, state)
          job
        end

      erase!(person)

      for job <- jobs, do: assert(withheld?(job), "#{row(job.id).state} not withheld")

      # Run each as its next attempt would.
      for job <- jobs, do: assert(:ok = perform_job(DeliveryWorker, row(job.id).args))
      for job <- jobs, do: set_state(job, "available")
      drain()

      assert sent_to(emails(), old_address) == []
      for job <- jobs, do: assert(row(job.id).state == "completed")
      assert Mail.recent_delivery_failures() == []
    end

    test "the sweep withholds before the worker's own check would" do
      person = user()
      job = queue_for!(person)
      erase!(person)

      # Before any attempt ran: the row itself holds nothing.
      assert withheld?(job)
      refute Jason.encode!(row(job.id).args) =~ to_string(person.email)
    end

    test "a job queued by the release before, to the address, is withheld in any state" do
      person = user()
      old_address = address(person)

      jobs =
        for state <- ~w(available retryable executing) do
          legacy!(old_address, state)
        end

      upper = legacy!(String.upcase(old_address))
      erase!(person)

      for job <- [upper | jobs], do: assert(withheld?(job))

      for job <- [upper | jobs], do: set_state(job, "available")
      drain()
      assert sent_to(emails(), old_address) == []
    end

    test "an executing legacy job retried after the sweep sends nothing, on either release" do
      person = user()
      old_address = address(person)
      job = legacy!(old_address, "executing")

      erase!(person)
      args = row(job.id).args

      # This release: the withheld clause.
      assert :ok = perform_job(DeliveryWorker, args)
      # The release before: no message to open, so it cancels.
      assert {:cancel, reason} = old_release_perform(args)
      assert reason =~ "message no longer available"
      assert emails() == []
    end

    test "other people's jobs and mail to an address with no account are untouched" do
      person = user()
      bystander = user()
      erased_address = address(person)

      bystanders_legacy = legacy!(address(bystander))
      bystanders = queue_for!(bystander)
      # A null `user_id`: an invitation to the address, say.
      :ok = Mail.enqueue!(mail(erased_address, "Invitation"))
      [address_mail] = jobs_to(erased_address)

      erase!(person)

      for job <- [bystanders_legacy, bystanders, address_mail] do
        refute Map.has_key?(row(job.id).args, "withheld")
        assert is_binary(row(job.id).args["sealed"])
      end

      drain()
      sent = emails()
      assert [_invitation] = sent_to(sent, erased_address)
      assert [_legacy, _current] = sent_to(sent, address(bystander))
    end

    test "finished jobs for the account lose the address, matched by account" do
      person = user()
      elsewhere = "elsewhere-#{unique()}@example.com"
      job = queue_for!(person, elsewhere)
      set_state(job, "completed")

      erase!(person)

      refute Map.has_key?(row(job.id).args, "to")
      refute Map.has_key?(row(job.id).args, "withheld")
    end

    test "an applicant erased on rejection has their waiting confirmation withheld" do
      site = org("account-mail-reject")
      site_admin = user()

      Ash.Seed.seed!(OrgMembership, %{
        user_id: site_admin.id,
        organization_id: site.id,
        role: :admin
      })

      CMS.save_site_registration!(
        %{approval_required: true, rejected_accounts: :erase_unconfirmed},
        actor: user(:admin),
        tenant: site.id
      )

      applicant = user(:viewer, %{confirmed_at: nil})

      row =
        Ash.Seed.seed!(OrgMembership, %{
          user_id: applicant.id,
          organization_id: site.id,
          role: :viewer,
          status: :pending,
          created_account: true
        })

      Senders.SendNewUserConfirmationEmail.send(applicant, "tok", [])
      [confirmation] = jobs_to(address(applicant))

      assert {:ok, rejected} =
               Accounts.reject_registration(row, %{erase: true}, actor: site_admin)

      assert rejected.__metadata__[:registration_outcome] == :erased
      assert withheld?(confirmation)
    end
  end

  describe "the release before, running this release's rows" do
    test "a new-shape row opens and is addressed as before" do
      person = user()
      job = queue_for!(person)

      assert {:ok, email} = Mail.open_args(job.args)
      assert email.to == [{"", address(person)}]
      assert :ok = old_release_perform(job.args)
      assert [_mail] = sent_to(emails(), address(person))
    end

    test "a withheld row is `:body_unavailable`, and cancels" do
      person = user()
      job = queue_for!(person)
      erase!(person)

      assert {:error, :body_unavailable} = Mail.open_args(row(job.id).args)
      assert {:cancel, _reason} = old_release_perform(row(job.id).args)
    end
  end
end
