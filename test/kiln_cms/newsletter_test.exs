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
      KilnCMS.Newsletter.NewsletterSend
      |> Ash.Query.filter(content_id == ^post.id)
      |> Ash.read!(authorize?: false)
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
      rule = newsletter_rule()

      # Draft → publish but WITHOUT draining, so no :web artifact exists yet.
      post = CMS.create_post!(%{title: "Unfired NL", slug: slug()}, actor: actor)
      post = CMS.publish_post!(post, %{}, actor: actor)

      assert {:snooze, _} = run_rule(rule, post)
    end
  end
end
