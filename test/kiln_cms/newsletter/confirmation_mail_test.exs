defmodule KilnCMS.Newsletter.ConfirmationMailTest do
  @moduledoc """
  Double opt-in actually opting in (issue #586).

  Before this, `:subscribe` minted a `confirm_token` that nothing ever sent, so
  no subscriber could reach `:confirmed` except by admin fiat — and a paying
  member linked as `:pending` by `TierSync` was stuck there forever.
  """
  use KilnCMS.DataCase, async: false

  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.Mail.DeliveryWorker
  alias KilnCMS.Newsletter

  defp email_for(name), do: "confirm-#{name}-#{System.unique_integer([:positive])}@example.com"

  defp subscribe(attrs), do: Newsletter.subscribe(attrs, authorize?: false)

  # Every queued mail job addressed to this recipient (the shared oban_jobs table
  # is why the unique address, not the count, is the scope).
  defp queued_mails(address) do
    Enum.filter(all_enqueued(worker: DeliveryWorker), &match?([_name, ^address], &1.args["to"]))
  end

  defp queued_mail(address), do: List.first(queued_mails(address))

  describe "the confirmation email" do
    test "a new subscriber is mailed a link carrying their confirm token" do
      address = email_for("new")

      assert {:ok, subscriber} = subscribe(%{email: address})
      assert subscriber.status == :pending

      job = queued_mail(address)
      assert job, "subscribing must queue a confirmation email"
      assert job.args["subject"] =~ "Confirm"
      assert job.args["html_body"] =~ "/newsletter/confirm/#{subscriber.confirm_token}"
    end

    test "the mailed token is the PERSISTED one, so the link actually resolves" do
      # The regression this guards: `:subscribe` upserts with
      # `upsert_fields [:name]`, so the freshly generated token in the changeset
      # is discarded on conflict. Mailing that token instead of the stored one
      # would produce a confirmation link that always says "not recognized".
      address = email_for("upsert")
      {:ok, first} = subscribe(%{email: address, name: "First"})

      {:ok, second} = subscribe(%{email: address, name: "Second"})

      assert second.id == first.id
      assert second.confirm_token == first.confirm_token
      assert second.name == "Second"

      # A re-sign-up while still pending resends — people lose the first email.
      assert [_one, _two] = queued_mails(address)

      # And the token in every one of those mails resolves to a real row.
      assert %{id: id} =
               Newsletter.subscriber_by_confirm_token!(second.confirm_token, authorize?: false)

      assert id == first.id
    end

    test "an already-confirmed subscriber is not re-mailed" do
      # Otherwise the anonymous endpoint becomes a way to mail any address that
      # subscribes to this site, on demand.
      address = email_for("confirmed")
      {:ok, subscriber} = subscribe(%{email: address})
      {:ok, _} = Newsletter.confirm_subscriber(subscriber, authorize?: false)
      assert [_the_original] = queued_mails(address)

      assert {:ok, %{status: :confirmed}} = subscribe(%{email: address})

      assert [_the_original] = queued_mails(address)
    end

    test "an unsubscribed subscriber is neither resurrected nor mailed" do
      # An opt-out is honoured indefinitely; handing back a re-opt-in link on
      # someone else's form submission would undo that.
      address = email_for("unsubscribed")
      {:ok, subscriber} = subscribe(%{email: address})
      {:ok, _} = Newsletter.unsubscribe_subscriber(subscriber, authorize?: false)
      assert [_the_original] = queued_mails(address)

      assert {:ok, %{status: :unsubscribed}} = subscribe(%{email: address})

      assert [_the_original] = queued_mails(address)
    end

    test "linking a paying member does not mail an opt-in prompt" do
      # A purchase is not a request for marketing email. `/account` is where a
      # member turns the newsletter on.
      address = email_for("member")
      user_id = Ash.UUID.generate()

      assert {:ok, %{status: :pending}} =
               Newsletter.link_member_subscriber(user_id, %{email: address}, authorize?: false)

      assert queued_mails(address) == []
    end

    test "the mailed link ends at a route that confirms the subscriber" do
      # End to end through the token, so the URL shape can't drift from the route.
      address = email_for("roundtrip")
      {:ok, subscriber} = subscribe(%{email: address})

      "/newsletter/confirm/" <> token =
        Regex.run(~r{/newsletter/confirm/[^"]+}, queued_mail(address).args["html_body"]) |> hd()

      {:ok, found} = Newsletter.subscriber_by_confirm_token(token, authorize?: false)
      {:ok, confirmed} = Newsletter.confirm_subscriber(found, authorize?: false)

      assert confirmed.id == subscriber.id
      assert confirmed.status == :confirmed
    end
  end

  describe "self-service consent policy" do
    # `/account` calls `:for_user`, `:resubscribe` and `:unsubscribe` with the
    # member as actor. As plain policies those self-grants were AND-narrowed to
    # nothing by the blanket admin policy, so the card looked empty and every
    # button came back Forbidden. They are a bypass now — these tests pin both
    # halves of that: the member gets in, and nobody gets in on anyone else.
    defp user(role \\ :viewer) do
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "consent-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: role
      })
    end

    defp linked(user) do
      Newsletter.link_member_subscriber!(user.id, %{email: to_string(user.email)},
        authorize?: false
      )
    end

    test "a member reads and updates their own row" do
      user = user()
      subscriber = linked(user)

      assert {:ok, [found]} = Newsletter.subscribers_for_user(user.id, actor: user)
      assert found.id == subscriber.id

      assert {:ok, %{status: :confirmed}} =
               Newsletter.resubscribe_subscriber(subscriber,
                 actor: user,
                 tenant: subscriber.org_id
               )

      assert {:ok, %{status: :unsubscribed}} =
               Newsletter.unsubscribe_subscriber(subscriber,
                 actor: user,
                 tenant: subscriber.org_id
               )
    end

    test "a member cannot touch another member's row" do
      stranger = linked(user())
      intruder = user()

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.resubscribe_subscriber(stranger,
                 actor: intruder,
                 tenant: stranger.org_id
               )

      assert {:ok, []} = Newsletter.subscribers_for_user(stranger.user_id, actor: intruder)
    end

    test "an UNLINKED row is not reachable by an actor-less caller" do
      # The bypass expression reduces to `user_id == nil` without its nil guard,
      # which would match every hand-added subscriber on the site.
      {:ok, orphan} = subscribe(%{email: email_for("orphan")})
      assert orphan.user_id == nil

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.unsubscribe_subscriber(orphan, actor: nil, tenant: orphan.org_id)
    end

    test "an admin still reaches these actions through the blanket policy" do
      # A failing bypass falls through to the remaining policies, so admin
      # management of anyone's subscription is unaffected.
      admin = user(:admin)
      subscriber = linked(user())

      assert {:ok, %{status: :unsubscribed}} =
               Newsletter.unsubscribe_subscriber(subscriber,
                 actor: admin,
                 tenant: subscriber.org_id
               )

      assert {:ok, [_row]} = Newsletter.subscribers_for_user(subscriber.user_id, actor: admin)
    end
  end

  describe "address validation" do
    test "a malformed address is a changeset error, not a raised ArgumentError" do
      # `Mail.enqueue!/1` raises on a bad recipient; without the validation that
      # raise escapes the anonymous POST as a 500.
      for bad <- ["no-at-sign", "@example.com", "someone@", "a b@example.com", ""] do
        assert {:error, %Ash.Error.Invalid{} = error} = subscribe(%{email: bad})

        assert Enum.any?(error.errors, &(Map.get(&1, :field) == :email)),
               "expected an :email error for #{inspect(bad)}, got #{inspect(error.errors)}"
      end
    end

    test "an ordinary address still passes" do
      assert {:ok, _} = subscribe(%{email: email_for("ok")})
    end
  end
end
