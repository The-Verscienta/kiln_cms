defmodule KilnCMS.Automation.JobArgsTest do
  @moduledoc """
  An automation job's `payload` — the event's serialized document, drafts
  included — leaves the job's row once the job is finished (#2992), and the
  readers accept it sealed (`KilnCMS.Jobs.PrivateArgs.seal/1`) as well as in
  the clear, so a later release can switch the writers to the sealed shape.

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
        refute inspect(row.args) =~ "Draft secret"
      end
    end

    test "a rule deleted or disabled since the event fired: done, and forgotten" do
      disabled = rule(%{trigger_event: :published, action: :broadcast, enabled: false})
      job = rule_job!(disabled, %{"payload" => payload()})

      drain()

      row = Repo.get!(Oban.Job, job.id)
      assert row.state == "completed"
      refute Map.has_key?(row.args, "payload")
      assert row.args["rule_id"] == disabled.id
    end

    test "a failure with attempts left keeps the payload, so the retry has it" do
      Automation.handle_event("post.published", payload(), org_id())

      # A lost grant fails the rules read, which fails the job (#1659).
      Automation.with_actor(nil, fn -> capture_log(fn -> drain() end) end)

      assert [row] = rows(DispatchWorker)
      assert row.state == "retryable"
      assert row.args["payload"]["title"] == "Draft secret"
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
      refute Map.has_key?(row.args, "payload")
    end
  end

  describe "a sealed payload (the shape the next release writes)" do
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
end
