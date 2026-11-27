defmodule KilnCMS.Automation.JobArgsTest do
  @moduledoc """
  An automation job's payload — the event's serialized document, drafts
  included — is written sealed (`KilnCMS.Jobs.PrivateArgs.seal/1`), so the
  pending row holds no document text, and it leaves the job's row once the
  job is finished (#2992). The readers still accept it in the clear, the
  shape a job queued by a release before 1.12 carries.

  Jobs are inserted and drained rather than `perform_job/3`'d: the worker's
  write to its own row is the behavior under test, and a job with no id has
  no row to write.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias KilnCMS.Automation
  alias KilnCMS.Automation.{DispatchWorker, Rule, RuleWorker}
  alias KilnCMS.Jobs.PrivateArgs

  defp rule(attrs) do
    Ash.Seed.seed!(
      Rule,
      Map.merge(
        %{name: "Rule #{System.unique_integer([:positive])}", enabled: true, config: %{}},
        attrs
      )
    )
  end

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{"id" => Ash.UUID.generate(), "title" => "Draft secret", "slug" => "draft-secret"},
      overrides
    )
  end

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp rows(worker) do
    Repo.all(from(j in Oban.Job, where: j.worker == ^inspect(worker), order_by: j.id))
  end

  defp rule_job!(rule, args) do
    %{"rule_id" => rule.id, "event" => "post.published", "org_id" => org_id()}
    |> Map.merge(args)
    |> RuleWorker.new()
    |> Oban.insert!()
  end

  defp drain, do: Oban.drain_queue(queue: :default, with_recursion: true)

  describe "a finished job keeps no payload" do
    test "the dispatch job and the rule job it fans out to, once drained" do
      topic = "job-args-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, "automation:#{topic}")
      rule(%{trigger_event: :published, action: :broadcast, config: %{"topic" => topic}})

      Automation.handle_event("post.published", payload(), org_id())
      drain()

      assert_receive {:automation_event, "post.published", %{"title" => "Draft secret"}}, 2_000

      for worker <- [DispatchWorker, RuleWorker] do
        assert [row] = rows(worker)
        assert row.state == "completed"
        refute Map.has_key?(row.args, "payload")
        refute Map.has_key?(row.args, "sealed")
        refute inspect(row.args) =~ "Draft secret"
      end
    end

    test "a rule deleted or disabled since the event fired: done, and forgotten" do
      disabled = rule(%{trigger_event: :published, action: :broadcast, enabled: false})
      job = rule_job!(disabled, %{"sealed" => PrivateArgs.seal(payload())})

      drain()

      row = Repo.get!(Oban.Job, job.id)
      assert row.state == "completed"
      refute Map.has_key?(row.args, "sealed")
      assert row.args["rule_id"] == disabled.id
    end

    test "a failure with attempts left keeps the payload, so the retry has it" do
      Automation.handle_event("post.published", payload(), org_id())

      # A lost grant fails the rules read, which fails the job (#1659).
      Automation.with_actor(nil, fn -> capture_log(fn -> drain() end) end)

      assert [row] = rows(DispatchWorker)
      assert row.state == "retryable"
      assert {:ok, %{"title" => "Draft secret"}} = Automation.job_payload(row.args)
    end

    test "failing the last attempt forgets it" do
      Automation.handle_event("post.published", payload(), org_id())
      [row] = rows(DispatchWorker)

      Repo.update_all(from(j in Oban.Job, where: j.id == ^row.id),
        set: [attempt: row.max_attempts - 1]
      )

      Automation.with_actor(nil, fn -> capture_log(fn -> drain() end) end)

      row = Repo.get!(Oban.Job, row.id)
      assert row.state == "discarded"
      refute Map.has_key?(row.args, "sealed")
    end
  end

  describe "a pending job holds no payload text" do
    test "the dispatch job seals the payload and keeps the event and site in the clear" do
      Automation.handle_event("post.published", payload(), org_id())

      assert [row] = rows(DispatchWorker)
      assert row.state == "available"
      refute Map.has_key?(row.args, "payload")
      refute inspect(row.args) =~ "Draft secret"
      refute inspect(row.args) =~ "draft-secret"
      assert %{"event" => "post.published", "sealed" => sealed} = row.args
      assert row.args["org_id"] == org_id()
      assert {:ok, %{"title" => "Draft secret"}} = PrivateArgs.open(sealed)
    end

    test "the rule job seals it too and keeps what its uniqueness compares" do
      r = rule(%{trigger_event: :published, action: :broadcast})
      snapshot = payload()

      assert :ok = Automation.dispatch("post.published", snapshot, org_id())

      assert [row] = rows(RuleWorker)
      refute Map.has_key?(row.args, "payload")
      refute inspect(row.args) =~ "Draft secret"
      assert row.args["rule_id"] == r.id
      assert row.args["event"] == "post.published"
      assert row.args["document_id"] == snapshot["id"]
      assert {:ok, ^snapshot} = Automation.job_payload(row.args)
    end

    test "a duplicate event still collapses onto the pending rule job" do
      rule(%{trigger_event: :published, action: :broadcast})
      snapshot = payload()

      # Each seal has its own nonce, so the two jobs' args differ; uniqueness
      # compares the clear keys only.
      assert :ok = Automation.dispatch("post.published", snapshot, org_id())
      assert :ok = Automation.dispatch("post.published", snapshot, org_id())
      assert [_one] = rows(RuleWorker)

      assert :ok = Automation.dispatch("post.published", payload(), org_id())
      assert [_one, _two] = rows(RuleWorker)
    end
  end

  describe "a clear payload (a job queued by a release before 1.12)" do
    test "a dispatch job still matches, fans out, and forgets it" do
      topic = "job-args-legacy-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, "automation:#{topic}")
      rule(%{trigger_event: :published, action: :broadcast, config: %{"topic" => topic}})

      %{"event" => "post.published", "org_id" => org_id(), "payload" => payload()}
      |> DispatchWorker.new()
      |> Oban.insert!()

      drain()

      assert_receive {:automation_event, "post.published", %{"title" => "Draft secret"}}, 2_000

      for worker <- [DispatchWorker, RuleWorker] do
        assert [row] = rows(worker)
        assert row.state == "completed"
        refute Map.has_key?(row.args, "payload")
      end
    end

    test "a rule job's email renders the snapshot" do
      r =
        rule(%{
          trigger_event: :published,
          action: :send_email,
          config: %{"to" => "team@example.com", "subject" => "Live: {{title}}"}
        })

      job = rule_job!(r, %{"payload" => payload(%{"title" => "Clear news"})})
      drain()

      assert_email_sent(fn email -> assert email.subject == "Live: Clear news" end)

      row = Repo.get!(Oban.Job, job.id)
      assert row.state == "completed"
      refute Map.has_key?(row.args, "payload")
    end
  end

  describe "a sealed payload" do
    test "a rule's email renders the snapshot as it does from a plain payload" do
      r =
        rule(%{
          trigger_event: :published,
          action: :send_email,
          config: %{"to" => "team@example.com", "subject" => "Live: {{title}}"}
        })

      job = rule_job!(r, %{"sealed" => PrivateArgs.seal(payload(%{"title" => "Sealed news"}))})
      drain()

      assert_email_sent(fn email -> assert email.subject == "Live: Sealed news" end)

      row = Repo.get!(Oban.Job, job.id)
      assert row.state == "completed"
      refute Map.has_key?(row.args, "sealed")
    end

    test "a broadcast gets the whole snapshot back" do
      topic = "job-args-sealed-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, "automation:#{topic}")
      r = rule(%{trigger_event: :published, action: :broadcast, config: %{"topic" => topic}})
      snapshot = payload(%{"audience" => "member", "locked" => false})

      rule_job!(r, %{"sealed" => PrivateArgs.seal(snapshot)})
      drain()

      assert_receive {:automation_event, "post.published", ^snapshot}, 2_000
    end

    test "a dispatch job matches and fans out from a sealed payload" do
      topic = "job-args-dispatch-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, "automation:#{topic}")
      rule(%{trigger_event: :published, action: :broadcast, config: %{"topic" => topic}})

      %{
        "event" => "post.published",
        "org_id" => org_id(),
        "sealed" => PrivateArgs.seal(payload())
      }
      |> DispatchWorker.new()
      |> Oban.insert!()

      drain()

      assert_receive {:automation_event, "post.published", %{"title" => "Draft secret"}}, 2_000
      assert [row] = rows(DispatchWorker)
      refute Map.has_key?(row.args, "sealed")
    end

    test "a seal that no longer opens cancels the job, names the fix and keeps nothing" do
      r = rule(%{trigger_event: :published, action: :broadcast})
      unreadable = Base.encode64("not a ciphertext under any key")
      job = rule_job!(r, %{"sealed" => unreadable})

      drain()

      row = Repo.get!(Oban.Job, job.id)
      assert row.state == "cancelled"
      refute Map.has_key?(row.args, "sealed")
      assert [%{"error" => error}] = row.errors
      assert error =~ "PREVIOUS_SECRET_KEY_BASE"
    end

    test "a job carrying neither shape cancels instead of crashing on every retry" do
      r = rule(%{trigger_event: :published, action: :broadcast})
      job = rule_job!(r, %{})

      drain()

      row = Repo.get!(Oban.Job, job.id)
      assert row.state == "cancelled"
      assert [%{"error" => error}] = row.errors
      assert error =~ "no longer available"
    end
  end

  describe "a send_email rule and the suppression lists (#3051)" do
    defp email_rule(config \\ %{"to" => "team@example.com", "subject" => "Live: {{title}}"}) do
      rule(%{trigger_event: :published, action: :send_email, config: config})
    end

    defp sealed_job!(rule), do: rule_job!(rule, %{"sealed" => PrivateArgs.seal(payload())})

    test "a `to` on the instance-wide list sends nothing, completes, and forgets the payload" do
      r = email_rule()
      job = sealed_job!(r)
      # Case-insensitive, as every lookup of the list is.
      KilnCMS.Mail.suppress_recipient!(%{email: "TEAM@EXAMPLE.COM"}, authorize?: false)

      log = capture_log(fn -> drain() end)

      assert_no_email_sent()
      row = Repo.get!(Oban.Job, job.id)
      assert row.state == "completed"
      refute Map.has_key?(row.args, "sealed")
      assert log =~ "[warning]"
      assert log =~ "Automation rule #{r.id} sent nothing"
      refute String.downcase(log) =~ "team@example.com"
    end

    test "the rule's own site's list stops it; another site's does not" do
      r = email_rule()

      KilnCMS.Mail.suppress_site_recipient!(%{email: "team@example.com"},
        tenant: org_id(),
        authorize?: false
      )

      sealed_job!(r)
      capture_log(fn -> drain() end)
      assert_no_email_sent()

      other = KilnCMS.OrgFixtures.org("rule-supp")
      elsewhere = email_rule(%{"to" => "elsewhere@example.com", "subject" => "Live"})

      KilnCMS.Mail.suppress_site_recipient!(%{email: "elsewhere@example.com"},
        tenant: other.id,
        authorize?: false
      )

      sealed_job!(elsewhere)
      drain()
      assert_email_sent(fn email -> assert email.to == [{"", "elsewhere@example.com"}] end)
    end

    test "a list that cannot be read retries the job, keeping the payload, and sends nothing" do
      job = sealed_job!(email_rule())

      KilnCMS.Mail.with_actor(nil, fn -> capture_log(fn -> drain() end) end)

      assert_no_email_sent()
      row = Repo.get!(Oban.Job, job.id)
      assert row.state == "retryable"
      assert Map.has_key?(row.args, "sealed")
      refute String.downcase(inspect(row.errors)) =~ "team@example.com"
    end

    test "a rule with no `to` still logs the missing address and completes" do
      job = sealed_job!(email_rule(%{"subject" => "Live"}))

      log = capture_log(fn -> drain() end)

      assert_no_email_sent()
      assert Repo.get!(Oban.Job, job.id).state == "completed"
      assert log =~ "missing a `to` address"
    end
  end
end
