defmodule KilnCMS.Newsletter.SystemActorAuthorizationTest do
  @moduledoc """
  #1659 batch 12 (the last): the newsletter send pipeline runs as
  `KilnCMS.Newsletter.system/0` rather than `authorize?: false`, and the
  send guard reads the target segment as the sender.

  Every grant is paired with a refusal. The reads that decide who is mailed
  are tested with the grant taken away (`Newsletter.with_actor(nil, ...)`,
  withdrawn part-way through a job where a read has to be isolated):

    * a refused campaign read must retry, not cancel as "send not found";
    * a refused subscriber list must retry, not stamp zero recipients and
      mark the campaign `:sent` having mailed nobody;
    * a refused subscriber read must retry, not cancel the recipient's job
      (which is `unique` over every state, so it could never be re-enqueued);
    * a refused counter write after delivery is logged, not raised, so Oban
      does not mail the same person twice to fix a tally.
  """
  # async: false — publishing a post fires its artifacts through Oban, drained
  # in the test process with the shared sandbox connection.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog

  alias KilnCMS.CMS
  alias KilnCMS.Newsletter
  alias KilnCMS.Newsletter.MailWorker
  alias KilnCMS.Newsletter.NewsletterSend
  alias KilnCMS.Newsletter.SendWorker
  alias KilnCMS.Newsletter.Subscriber

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sab12-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "sab12-#{System.unique_integer([:positive])}"

  defp published_post(actor) do
    post = CMS.create_post!(%{title: "SAB12 #{slug()}", slug: slug()}, actor: actor)
    published = CMS.publish_post!(post, %{}, actor: actor)
    KilnCMS.DataCase.drain_oban()
    published
  end

  defp subscriber(actor) do
    %{email: "sab12-sub-#{System.unique_integer([:positive])}@example.com"}
    |> Newsletter.subscribe!(actor: actor)
    |> Newsletter.confirm_subscriber!(actor: actor)
  end

  # A queued campaign with one confirmed recipient, and the fan-out's args.
  defp campaign do
    admin = user(:admin)
    sub = subscriber(admin)
    post = published_post(admin)
    {:ok, send} = Newsletter.send_as_newsletter(post, actor: admin)
    %{admin: admin, sub: sub, post: post, send: send}
  end

  defp send_args(send), do: %{"newsletter_send_id" => send.id, "org_id" => send.org_id}

  defp mail_args(send, sub),
    do: %{"newsletter_send_id" => send.id, "subscriber_id" => sub.id, "org_id" => send.org_id}

  defp reload(send), do: Newsletter.get_send!(send.id, authorize?: false, tenant: send.org_id)

  defp newsletters_to(address) do
    Stream.repeatedly(fn ->
      receive do
        {:email, email} -> email
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.filter(fn email ->
      Map.has_key?(email.headers, "List-Unsubscribe") and
        Enum.any?(email.to, fn {_name, to} -> to == address end)
    end)
  end

  # Withdraw the newsletter grant the moment a read of `resource` finishes, in
  # this process, so the NEXT read in the same job is the one refused. The
  # telemetry handler runs in the process that ran the read.
  defp withdraw_after_read_of(resource, fun) do
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:ash, :newsletter, :read, :stop],
      fn _event, _measurements, metadata, _config ->
        if metadata[:resource] == resource,
          do: KilnCMS.SystemActor.put_override(:newsletter, nil)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
      KilnCMS.SystemActor.delete_override(:newsletter)
    end
  end

  # Refuse the newsletter grant for the Subscriber read ONLY: withdrawn when
  # the campaign read (which comes first in both workers) returns, restored
  # when the Subscriber read returns, so every later call in the job still
  # succeeds. A read that swallowed the refusal as "nothing" would then carry
  # on and show it: a zero-recipient fan-out marked `:sent`, say. (The actor
  # is resolved before a read's `:start` event fires, so the window has to
  # open on the previous read's `:stop`.)
  defp refuse_subscriber_reads(fun) do
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:ash, :newsletter, :read, :stop],
      fn _event, _measurements, metadata, _config ->
        case metadata[:resource] do
          NewsletterSend -> KilnCMS.SystemActor.put_override(:newsletter, nil)
          Subscriber -> KilnCMS.SystemActor.delete_override(:newsletter)
          _other -> :ok
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
      KilnCMS.SystemActor.delete_override(:newsletter)
    end
  end

  describe "NewsletterSend" do
    test "the system actor reads a campaign and keeps its bookkeeping" do
      %{send: send} = campaign()
      system = Newsletter.system()
      opts = [actor: system, tenant: send.org_id]

      assert {:ok, %{id: id}} = Newsletter.get_send(send.id, [authorize_with: :error] ++ opts)
      assert id == send.id

      assert {:ok, send} = Newsletter.mark_sending(send, %{total_recipients: 3}, opts)
      assert {:ok, _} = Newsletter.record_sent(send, opts)
      assert {:ok, _} = Newsletter.record_failed(send, opts)
      assert {:ok, _} = Newsletter.mark_sent(send, opts)

      send = reload(send)
      assert send.status == :sent
      assert {send.total_recipients, send.sent_count, send.failed_count} == {3, 1, 1}
    end

    test "...and may not fail or erase one" do
      %{send: send} = campaign()
      system = Newsletter.system()

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.mark_failed(send, actor: system, tenant: send.org_id)

      refute Ash.can?({send, :destroy}, system, tenant: send.org_id)
      assert reload(send).status == :pending
    end

    test "a person below admin gets none of it" do
      %{send: send} = campaign()
      editor = user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.mark_sending(send, %{total_recipients: 1},
                 actor: editor,
                 tenant: send.org_id
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.get_send(send.id,
                 actor: editor,
                 authorize_with: :error,
                 tenant: send.org_id
               )
    end
  end

  describe "Subscriber" do
    test "the system actor reads the confirmed list and one subscriber" do
      %{sub: sub, send: send} = campaign()
      opts = [actor: Newsletter.system(), authorize_with: :error, tenant: send.org_id]

      assert {:ok, confirmed} = Newsletter.confirmed_subscribers(nil, opts)
      assert sub.id in Enum.map(confirmed, & &1.id)

      assert {:ok, %{id: id}} = Newsletter.get_subscriber(sub.id, opts)
      assert id == sub.id
    end

    test "...and may not change anyone's consent or add to the list" do
      %{sub: sub, send: send} = campaign()
      system = Newsletter.system()

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.unsubscribe_subscriber(sub, actor: system, tenant: send.org_id)

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.resubscribe_subscriber(sub, actor: system, tenant: send.org_id)

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.subscribe(%{email: "sab12-new@example.com"},
                 actor: system,
                 tenant: send.org_id
               )
    end
  end

  describe "SendWorker fails closed" do
    test "a refused campaign read retries instead of cancelling as \"not found\"" do
      %{send: send} = campaign()

      log =
        capture_log(fn ->
          assert {:error, %Ash.Error.Forbidden{}} =
                   Newsletter.with_actor(nil, fn -> perform_job(SendWorker, send_args(send)) end)
        end)

      assert log =~ "could not read newsletter send"
      assert reload(send).status == :pending
      refute_enqueued(worker: MailWorker)
    end

    test "a refused subscriber list retries: no zero-recipient fan-out, not marked sent" do
      %{send: send} = campaign()

      log =
        capture_log(fn ->
          assert {:error, %Ash.Error.Forbidden{}} =
                   refuse_subscriber_reads(fn ->
                     perform_job(SendWorker, send_args(send))
                   end)
        end)

      assert log =~ "could not fan out newsletter send"

      send = reload(send)
      assert send.status == :pending
      assert send.total_recipients in [nil, 0]
      refute_enqueued(worker: MailWorker)
    end

    test "with the grant in place, the fan-out runs as the system actor" do
      %{send: send, sub: sub} = campaign()

      assert :ok = perform_job(SendWorker, send_args(send))
      assert_enqueued(worker: MailWorker, args: mail_args(send, sub))

      send = reload(send)
      assert send.status == :sent
      assert send.total_recipients == 1
    end
  end

  describe "MailWorker fails closed" do
    test "a refused subscriber read retries instead of cancelling the recipient" do
      %{send: send, sub: sub} = campaign()

      log =
        capture_log(fn ->
          assert {:error, %Ash.Error.Forbidden{}} =
                   refuse_subscriber_reads(fn ->
                     perform_job(MailWorker, mail_args(send, sub))
                   end)
        end)

      assert log =~ "could not read subscriber #{sub.id}"
      assert newsletters_to(to_string(sub.email)) == []
      assert reload(send).failed_count == 0
    end

    test "a refused campaign read retries too" do
      %{send: send, sub: sub} = campaign()

      log =
        capture_log(fn ->
          assert {:error, %Ash.Error.Forbidden{}} =
                   Newsletter.with_actor(nil, fn ->
                     perform_job(MailWorker, mail_args(send, sub))
                   end)
        end)

      assert log =~ "could not read send #{send.id}"
      assert newsletters_to(to_string(sub.email)) == []
    end

    test "a counter that will not move after delivery is logged, not retried" do
      %{send: send, sub: sub} = campaign()

      log =
        capture_log(fn ->
          assert :ok =
                   withdraw_after_read_of(Subscriber, fn ->
                     perform_job(MailWorker, mail_args(send, sub))
                   end)
        end)

      assert log =~ "could not record_sent on send #{send.id}"
      assert [_one] = newsletters_to(to_string(sub.email))
      assert reload(send).sent_count == 0
    end

    test "with the grant in place, delivery is counted" do
      %{send: send, sub: sub} = campaign()

      assert :ok = perform_job(MailWorker, mail_args(send, sub))
      assert [_one] = newsletters_to(to_string(sub.email))
      assert reload(send).sent_count == 1
    end
  end

  describe "send_as_newsletter/2 reads the segment as the sender" do
    test "an actor who cannot read the segment is refused, not told it is missing" do
      admin = user(:admin)
      segment = Newsletter.create_segment!(%{name: "SAB12", slug: slug()}, actor: admin)
      post = published_post(admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.send_as_newsletter(post, segment_id: segment.id, actor: user(:editor))
    end

    test "the automation's system actor reads it and sends" do
      admin = user(:admin)
      segment = Newsletter.create_segment!(%{name: "SAB12", slug: slug()}, actor: admin)
      post = published_post(admin)
      sub = subscriber(admin)
      Newsletter.add_to_segment!(%{segment_id: segment.id, subscriber_id: sub.id}, actor: admin)

      assert {:ok, send} =
               Newsletter.send_as_newsletter(post,
                 segment_id: segment.id,
                 actor: KilnCMS.SystemActor.new(:automation)
               )

      assert send.segment_id == segment.id
    end

    # #1775: the recipient preflight fails CLOSED. A refused subscriber read
    # would otherwise answer "nobody to send to", and the automation would
    # settle it as skipped; as a Forbidden, the rule's job retries.
    test "a refused recipient read is a Forbidden, not :no_recipients" do
      admin = user(:admin)
      subscriber(admin)
      post = published_post(admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.with_actor(nil, fn ->
                 Newsletter.send_as_newsletter(post, actor: KilnCMS.SystemActor.new(:automation))
               end)

      assert Newsletter.list_sends!(authorize?: false, query: [filter: [content_id: post.id]]) ==
               []
    end

    test "a segment that does not exist is still :no_such_segment" do
      admin = user(:admin)
      post = published_post(admin)

      assert {:error, :no_such_segment} =
               Newsletter.send_as_newsletter(post, segment_id: Ash.UUID.generate(), actor: admin)
    end
  end

  # #1747: each grant names the subsystem whose code makes the call, so the
  # automation (which opens a campaign) and the send pipeline (which works it)
  # are two actors, not one. Every other label is refused everything.
  describe "each subsystem gets only its own newsletter actions (#1747)" do
    @send_pipeline [:read, :mark_sending, :mark_sent, :record_sent, :record_failed]
    @outsiders [:automation, :mail, :billing, :notifications, :operator]

    defp can?(subject, label, org_id),
      do: Ash.can?(subject, KilnCMS.SystemActor.new(label), tenant: org_id)

    test "the send pipeline's actions are :newsletter's alone" do
      %{send: send} = campaign()

      for action <- @send_pipeline do
        assert can?({send, action}, :newsletter, send.org_id),
               "NewsletterSend #{inspect(action)} refused :newsletter"

        for label <- @outsiders do
          refute can?({send, action}, label, send.org_id),
                 "NewsletterSend #{inspect(action)} admitted #{inspect(label)}"
        end
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.mark_sending(send, %{total_recipients: 1},
                 actor: KilnCMS.SystemActor.new(:automation),
                 tenant: send.org_id
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.get_send(send.id,
                 actor: KilnCMS.SystemActor.new(:automation),
                 authorize_with: :error,
                 tenant: send.org_id
               )

      assert reload(send).status == :pending
    end

    test "opening a campaign is :automation's alone" do
      admin = user(:admin)
      subscriber(admin)
      post = published_post(admin)

      assert {:ok, _send} =
               Newsletter.send_as_newsletter(post, actor: KilnCMS.SystemActor.new(:automation))

      for label <- [:newsletter | @outsiders -- [:automation]] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Newsletter.send_as_newsletter(post, actor: KilnCMS.SystemActor.new(label)),
               "#{inspect(label)} opened a campaign"
      end
    end

    test "the subscriber reads are :newsletter's alone" do
      %{sub: sub, send: send} = campaign()

      for label <- @outsiders do
        opts = [
          actor: KilnCMS.SystemActor.new(label),
          authorize_with: :error,
          tenant: send.org_id
        ]

        assert {:error, %Ash.Error.Forbidden{}} = Newsletter.confirmed_subscribers(nil, opts),
               "#{inspect(label)} read the confirmed list"

        assert {:error, %Ash.Error.Forbidden{}} = Newsletter.get_subscriber(sub.id, opts),
               "#{inspect(label)} read a subscriber"
      end
    end

    test "the automation reads a segment, and nothing of its tier lifecycle" do
      admin = user(:admin)
      segment = Newsletter.create_segment!(%{name: "SAB12", slug: slug()}, actor: admin)
      org_id = segment.org_id

      assert can?({segment, :read}, :automation, org_id)
      refute can?({segment, :sync_managed}, :automation, org_id)
      refute can?({KilnCMS.Newsletter.Segment, :for_tier}, :automation, org_id)

      for label <- @outsiders -- [:automation] do
        refute can?({segment, :read}, label, org_id), "#{inspect(label)} read a segment"
      end
    end
  end
end
