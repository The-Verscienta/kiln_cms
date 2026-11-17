defmodule KilnCMS.Jobs.PrivateArgsScrubTest do
  @moduledoc """
  `KilnCMS.Jobs.PrivateArgsScrub` (#2992): finished rows of a registered
  worker lose their private keys; a row still waiting to run, and every row of
  any other worker, is untouched.
  """
  use KilnCMS.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Jobs.PrivateArgsScrub

  # A row as an earlier release left it: queued with the private args, then
  # moved to `state` without the worker ever touching it.
  defp row!(worker, args, state) do
    job = args |> worker.new() |> Oban.insert!()
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
    job
  end

  defp args(job), do: Repo.one!(from(j in Oban.Job, where: j.id == ^job.id, select: j.args))

  defp form_args, do: %{"form_id" => Ecto.UUID.generate(), "data" => %{"message" => "secret"}}

  test "finished rows of every registered worker lose their private keys" do
    notification = row!(KilnCMS.Forms.NotificationWorker, form_args(), "completed")

    autoresponder =
      row!(
        KilnCMS.Forms.AutoresponderWorker,
        Map.put(form_args(), "to", "visitor@example.com"),
        "completed"
      )

    dispatch =
      row!(
        KilnCMS.Automation.DispatchWorker,
        %{"event" => "post.published", "payload" => %{"title" => "secret"}},
        "completed"
      )

    rule =
      row!(
        KilnCMS.Automation.RuleWorker,
        %{"rule_id" => Ecto.UUID.generate(), "event" => "post.published", "sealed" => "c2Vj"},
        "completed"
      )

    assert %{
             "KilnCMS.Forms.NotificationWorker" => 1,
             "KilnCMS.Forms.AutoresponderWorker" => 1,
             "KilnCMS.Automation.DispatchWorker" => 1,
             "KilnCMS.Automation.RuleWorker" => 1
           } = PrivateArgsScrub.run()

    assert Map.keys(args(notification)) == ["form_id"]
    assert Map.keys(args(autoresponder)) == ["form_id"]
    assert args(dispatch) == %{"event" => "post.published"}
    assert Map.keys(args(rule)) |> Enum.sort() == ["event", "rule_id"]
  end

  test "cancelled and discarded rows are finished too (a job Lifeline discarded)" do
    cancelled = row!(KilnCMS.Forms.NotificationWorker, form_args(), "cancelled")
    discarded = row!(KilnCMS.Forms.NotificationWorker, form_args(), "discarded")

    PrivateArgsScrub.run()

    refute Map.has_key?(args(cancelled), "data")
    refute Map.has_key?(args(discarded), "data")
  end

  test "a job still waiting to run keeps what it needs" do
    for state <- ~w(available scheduled retryable executing) do
      job = row!(KilnCMS.Forms.NotificationWorker, form_args(), state)
      PrivateArgsScrub.run()
      assert args(job)["data"] == %{"message" => "secret"}, "scrubbed a #{state} job"
    end
  end

  test "another worker's args are never touched, whatever their keys are called" do
    other =
      row!(KilnCMS.Accounts.ErasureBackfill, %{"data" => "x", "payload" => "y"}, "completed")

    PrivateArgsScrub.run()

    assert args(other) == %{"data" => "x", "payload" => "y"}
  end

  test "a second run finds nothing" do
    row!(KilnCMS.Forms.NotificationWorker, form_args(), "completed")

    assert PrivateArgsScrub.run()["KilnCMS.Forms.NotificationWorker"] == 1
    assert PrivateArgsScrub.run() |> Map.values() |> Enum.sum() == 0
  end

  test "the worker runs the pass" do
    job = row!(KilnCMS.Forms.NotificationWorker, form_args(), "completed")
    assert :ok = PrivateArgsScrub.perform(%Oban.Job{})
    refute Map.has_key?(args(job), "data")
  end

  test "runs daily from the assembled crontab, besides the boot run" do
    plugins = Keyword.fetch!(KilnCMS.Application.oban_config(), :plugins)
    assert {Oban.Plugins.Cron, cron} = List.keyfind(plugins, Oban.Plugins.Cron, 0)

    assert {"50 4 * * *", PrivateArgsScrub} =
             List.keyfind(cron[:crontab], PrivateArgsScrub, 1)
  end

  test "the boot enqueue queues one run ten minutes out, deduplicated" do
    assert :ok = PrivateArgsScrub.enqueue()
    assert :ok = PrivateArgsScrub.enqueue()

    assert [job] =
             Repo.all(from(j in Oban.Job, where: j.worker == "KilnCMS.Jobs.PrivateArgsScrub"))

    assert job.state == "scheduled"
    assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) in 590..600
  end
end
