defmodule KilnCMS.NewsletterTest do
  @moduledoc """
  Newsletter dispatch (issue #337, Phase 1): sending a published post to
  confirmed subscribers via the built-in MTA, segment scoping, the
  gated-content guard, and unsubscribe exclusion.
  """
  # async: false — the send/mail Oban workers query the DB during drain and run
  # outside the test process, so they need the shared sandbox connection.
  use KilnCMS.DataCase, async: false

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.Newsletter

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "nl-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "nl-#{System.unique_integer([:positive])}"

  # A published post. Publishing fires the artifacts and mails the author a
  # workflow notice via Oban, so drain to materialize the `:web` artifact the
  # newsletter body reads from (the publish notice is filtered out below).
  defp published_post(actor, title, attrs \\ %{}) do
    post = CMS.create_post!(Map.merge(%{title: title, slug: slug()}, attrs), actor: actor)
    published = CMS.publish_post!(post, %{}, actor: actor)
    drain()
    published
  end

  defp subscriber(actor, opts \\ []) do
    email = Keyword.get(opts, :email, "sub-#{System.unique_integer([:positive])}@example.com")
    sub = Newsletter.subscribe!(%{email: email}, actor: actor)

    if Keyword.get(opts, :confirmed, true) do
      Newsletter.confirm_subscriber!(sub, actor: actor)
    else
      sub
    end
  end

  defp drain, do: KilnCMS.DataCase.drain_oban()

  # Collect *newsletter* emails for a subject out of the (process-global) test
  # mailbox. Filtered by the List-Unsubscribe header (only newsletters carry it,
  # so publish/workflow notices are excluded) and by subject (so parallel suites
  # don't leak in).
  defp sent_emails(subject_match) do
    Stream.repeatedly(fn ->
      receive do
        {:email, email} -> email
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.filter(
      &(Map.has_key?(&1.headers, "List-Unsubscribe") and
          String.contains?(&1.subject, subject_match))
    )
  end

  defp recipients(emails), do: emails |> Enum.flat_map(& &1.to) |> Enum.map(fn {_n, a} -> a end)

  test "sends to every confirmed subscriber and records the campaign" do
    actor = admin()
    a = subscriber(actor, email: "confirmed-a-#{System.unique_integer([:positive])}@example.com")
    b = subscriber(actor, email: "confirmed-b-#{System.unique_integer([:positive])}@example.com")
    _pending = subscriber(actor, confirmed: false)

    post = published_post(actor, "Weekly Digest #{slug()}")
    subject = post.title

    assert {:ok, send} = Newsletter.send_as_newsletter(post, actor: actor)
    drain()

    emails = sent_emails(subject)
    got = recipients(emails) |> Enum.sort()
    assert got == Enum.sort([to_string(a.email), to_string(b.email)])

    # One-click unsubscribe headers on every message.
    for email <- emails do
      assert email.headers["List-Unsubscribe"] =~ ~r{^<https?://.*/newsletter/unsubscribe/.+>$}
      assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
      assert email.headers["Message-ID"] =~ ~r/^<newsletter-.+@/
    end

    send = Newsletter.get_send!(send.id, authorize?: false)
    assert send.status == :sent
    assert send.total_recipients == 2
    assert send.sent_count == 2
    assert send.failed_count == 0
  end

  # A fan-out run twice — retried after a crash, or rescued by Oban.Lifeline
  # after a deploy killed it mid-loop (#1718) — must not mail anyone twice.
  test "re-running the fan-out enqueues each recipient once" do
    actor = admin()
    a = subscriber(actor, email: "rerun-a-#{System.unique_integer([:positive])}@example.com")
    b = subscriber(actor, email: "rerun-b-#{System.unique_integer([:positive])}@example.com")

    post = published_post(actor, "Rerun #{slug()}")
    assert {:ok, send} = Newsletter.send_as_newsletter(post, actor: actor)

    args = %{"newsletter_send_id" => send.id, "org_id" => send.org_id}

    # The first run delivers; the second finds every recipient already served.
    assert :ok = Oban.Testing.perform_job(Newsletter.SendWorker, args, repo: KilnCMS.Repo)
    drain()
    assert :ok = Oban.Testing.perform_job(Newsletter.SendWorker, args, repo: KilnCMS.Repo)
    drain()

    mail_jobs =
      Oban.Testing.all_enqueued(repo: KilnCMS.Repo, worker: Newsletter.MailWorker)
      |> Enum.concat(completed_mail_jobs(send.id))

    assert mail_jobs |> Enum.map(& &1.args["subscriber_id"]) |> Enum.sort() ==
             Enum.sort([a.id, b.id])

    got = recipients(sent_emails(post.title)) |> Enum.sort()
    assert got == Enum.sort([to_string(a.email), to_string(b.email)])
  end

  defp completed_mail_jobs(send_id) do
    Oban.Job
    |> Ecto.Query.where(worker: "KilnCMS.Newsletter.MailWorker", state: "completed")
    |> KilnCMS.Repo.all()
    |> Enum.filter(&(&1.args["newsletter_send_id"] == send_id))
  end

  test "a segment scopes delivery to its members" do
    actor = admin()
    segment = Newsletter.create_segment!(%{name: "VIPs", slug: slug()}, actor: actor)

    member = subscriber(actor, email: "member-#{System.unique_integer([:positive])}@example.com")
    Newsletter.add_to_segment!(%{segment_id: segment.id, subscriber_id: member.id}, actor: actor)
    _outsider = subscriber(actor)

    post = published_post(actor, "Members Only #{slug()}")

    assert {:ok, _send} =
             Newsletter.send_as_newsletter(post, segment_id: segment.id, actor: actor)

    drain()

    assert recipients(sent_emails(post.title)) == [to_string(member.email)]
  end

  test "refuses to send gated (non-public) content" do
    actor = admin()
    _sub = subscriber(actor)
    post = published_post(actor, "Secret #{slug()}", %{audience: :member})

    assert {:error, :gated} = Newsletter.send_as_newsletter(post, actor: actor)
    drain()
    assert sent_emails(post.title) == []
  end

  test "refuses to send an unpublished (draft) post" do
    actor = admin()
    draft = CMS.create_post!(%{title: "Draft #{slug()}", slug: slug()}, actor: actor)

    assert {:error, :not_published} = Newsletter.send_as_newsletter(draft, actor: actor)
  end

  test "unsubscribed subscribers are excluded from a later send" do
    actor = admin()

    staying =
      subscriber(actor, email: "staying-#{System.unique_integer([:positive])}@example.com")

    leaving =
      subscriber(actor, email: "leaving-#{System.unique_integer([:positive])}@example.com")

    Newsletter.unsubscribe_subscriber!(leaving, actor: actor)

    post = published_post(actor, "After Unsub #{slug()}")
    assert {:ok, _send} = Newsletter.send_as_newsletter(post, actor: actor)
    drain()

    assert recipients(sent_emails(post.title)) == [to_string(staying.email)]
  end

  describe "the campaign is created under the sender's authorization (#1655)" do
    defp campaigns do
      KilnCMS.Newsletter.NewsletterSend
      |> Ash.read!(authorize?: false, tenant: KilnCMS.Accounts.default_org_id())
    end

    defp fan_out_jobs,
      do: Oban.Testing.all_enqueued(repo: KilnCMS.Repo, worker: KilnCMS.Newsletter.SendWorker)

    # Called on the domain directly, with no console in front of it: the policy
    # is the gate, so nothing — no ledger row, no fan-out job — may come of it.
    for {label, role} <- [editor: :editor, viewer: :viewer] do
      test "an #{label} cannot create a send" do
        post = published_post(admin(), "Refused #{slug()}")

        actor =
          Ash.Seed.seed!(KilnCMS.Accounts.User, %{
            email: "nl-#{unquote(role)}-#{System.unique_integer([:positive])}@example.com",
            hashed_password: Bcrypt.hash_pwd_salt("password123456"),
            confirmed_at: DateTime.utc_now(),
            role: unquote(role)
          })

        assert {:error, %Ash.Error.Forbidden{}} =
                 Newsletter.send_as_newsletter(post, actor: actor)

        assert campaigns() == []
        assert fan_out_jobs() == []
      end
    end

    test "no actor at all cannot create a send" do
      post = published_post(admin(), "Actorless #{slug()}")

      assert {:error, %Ash.Error.Forbidden{}} = Newsletter.send_as_newsletter(post)
      assert campaigns() == []
    end

    # The grant widened in #1659 (the send pipeline reads the campaign and
    # keeps its counters as `Newsletter.system/0`); what a system actor may
    # still never do to the ledger is pinned in
    # `KilnCMS.Newsletter.SystemActorAuthorizationTest`.
    test "the system actor cannot erase or fail a campaign" do
      actor = admin()
      post = published_post(actor, "Readable #{slug()}")
      subscriber(actor)
      assert {:ok, send} = Newsletter.send_as_newsletter(post, actor: actor)
      system = KilnCMS.SystemActor.new(:automation)

      assert {:error, %Ash.Error.Forbidden{}} =
               Newsletter.mark_failed(send, actor: system, tenant: send.org_id)

      refute Ash.can?({send, :destroy}, system, tenant: send.org_id)
    end

    test "an admin's send records who sent it" do
      actor = admin()
      post = published_post(actor, "Admin #{slug()}")
      subscriber(actor)

      assert {:ok, send} = Newsletter.send_as_newsletter(post, actor: actor)
      assert send.sent_by_id == actor.id
      assert [%{id: id}] = campaigns()
      assert id == send.id
    end
  end

  describe "automation-driven sends (#376)" do
    alias KilnCMS.Automation.Rule
    alias KilnCMS.Automation.RuleWorker

    defp newsletter_rule(attrs \\ %{}) do
      Ash.Seed.seed!(
        Rule,
        Map.merge(
          %{
            name: "NL rule #{System.unique_integer([:positive])}",
            enabled: true,
            trigger_event: :published,
            action: :newsletter,
            config: %{}
          },
          attrs
        )
      )
    end

    defp run_rule(rule, post) do
      RuleWorker.perform(%Oban.Job{
        args: %{
          "rule_id" => rule.id,
          "event" => "post.published",
          "payload" => %{"id" => post.id, "title" => post.title, "slug" => post.slug},
          "org_id" => rule.org_id
        }
      })
    end

    defp sends_for(post) do
      Newsletter.list_sends!(
        authorize?: false,
        query: [filter: [content_id: post.id]]
      )
    end

    test "on publish, a newsletter rule sends the campaign exactly once (end to end)" do
      actor = admin()
      subscriber(actor)
      rule = newsletter_rule()

      # publish → (firing drains first) → dispatch → rule → send fan-out.
      post = published_post(actor, "Auto NL #{System.unique_integer([:positive])}")
      drain()

      assert [send] = sends_for(post)
      assert send.automation_rule_id == rule.id
      assert send.content_published_at == post.published_at
      assert length(sent_emails(post.title)) == 1
    end

    test "re-delivering the same job never double-sends; a new publish sends again" do
      actor = admin()
      subscriber(actor)
      rule = newsletter_rule(%{trigger_event: :updated})
      post = published_post(actor, "Dedupe NL #{System.unique_integer([:positive])}")

      assert :ok = run_rule(rule, post)
      assert :ok = run_rule(rule, post)
      drain()
      assert [_only_one] = sends_for(post)

      # A fresh publish revision (new published_at) is a new campaign.
      post = CMS.unpublish_post!(post, %{}, actor: actor)
      post = CMS.publish_post!(post, %{}, actor: actor)
      drain()
      assert :ok = run_rule(rule, post)
      assert length(sends_for(post)) == 2
    end

    test "gated (non-public) content is skipped, not sent and not retried" do
      actor = admin()
      subscriber(actor)
      rule = newsletter_rule()

      post =
        published_post(actor, "Gated NL #{System.unique_integer([:positive])}", %{
          audience: :member
        })

      assert :ok = run_rule(rule, post)
      assert sends_for(post) == []
    end

    test "an unfired document snoozes rather than failing" do
      actor = admin()
      subscriber(actor)
      rule = newsletter_rule()

      # Draft → publish but WITHOUT draining, so no :web artifact exists yet.
      post = CMS.create_post!(%{title: "Unfired NL", slug: slug()}, actor: actor)
      post = CMS.publish_post!(post, %{}, actor: actor)

      assert {:snooze, _} = run_rule(rule, post)
    end

    # #1775: an empty audience is settled, not retried, and spends nothing —
    # the same publish revision still sends once someone has confirmed.
    test "no confirmed subscriber is skipped without a campaign, and doesn't burn the revision" do
      actor = admin()
      rule = newsletter_rule(%{trigger_event: :updated})
      _pending = subscriber(actor, confirmed: false)
      post = published_post(actor, "Empty NL #{System.unique_integer([:positive])}")

      assert :ok = run_rule(rule, post)
      assert sends_for(post) == []

      subscriber(actor)
      assert :ok = run_rule(rule, post)
      assert [_campaign] = sends_for(post)
    end
  end

  describe "an audience with no confirmed subscriber (#1775)" do
    test "is refused before anything is recorded or queued" do
      actor = admin()
      post = published_post(actor, "Nobody #{slug()}")
      _pending = subscriber(actor, confirmed: false)

      assert {:error, :no_recipients} = Newsletter.send_as_newsletter(post, actor: actor)

      assert Newsletter.list_sends!(authorize?: false, query: [filter: [content_id: post.id]]) ==
               []

      assert Oban.Testing.all_enqueued(repo: KilnCMS.Repo, worker: KilnCMS.Newsletter.SendWorker) ==
               []
    end

    test "a segment whose only members are unconfirmed is refused" do
      actor = admin()
      post = published_post(actor, "Empty segment #{slug()}")
      _elsewhere = subscriber(actor)
      segment = Newsletter.create_segment!(%{name: "Pending only", slug: slug()}, actor: actor)
      pending = subscriber(actor, confirmed: false)

      Newsletter.add_to_segment!(%{segment_id: segment.id, subscriber_id: pending.id},
        actor: actor
      )

      assert {:error, :no_recipients} =
               Newsletter.send_as_newsletter(post, actor: actor, segment_id: segment.id)

      assert {:ok, _send} = Newsletter.send_as_newsletter(post, actor: actor)
    end

    test "has_recipients?/3 fails closed on a refused read" do
      actor = admin()
      subscriber(actor)
      org = KilnCMS.Accounts.default_org_id()

      assert {:ok, true} = Newsletter.has_recipients?(org, nil, actor)
      assert {:error, %Ash.Error.Forbidden{}} = Newsletter.has_recipients?(org, nil, nil)
    end
  end
end
