defmodule KilnCMS.Notifications.QueuedMailRetryTest do
  @moduledoc """
  A workflow or task mail job queued before #3019 keeps its address while it
  can still be retried, and drops it once it fails for the last time
  (`KilnCMS.Jobs.PrivateArgs.finishing/3`).

  `async: false`: these tests swap the operator's mailer adapter, which is
  application-global.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias KilnCMS.Notifications.TaskMailWorker
  alias KilnCMS.Notifications.WorkflowMailWorker

  # A greylist: transient, so the job raises and Oban retries it.
  defmodule GreylistAdapter do
    use Swoosh.Adapter

    def deliver(_email, _config),
      do:
        {:error,
         {:retries_exceeded, {:temporary_failure, ~c"mx.example.com", "451 4.7.1 greylisted"}}}
  end

  setup do
    mailer = Application.get_env(:kiln_cms, KilnCMS.Mailer)
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Mailer, mailer) end)
    Application.put_env(:kiln_cms, KilnCMS.Mailer, adapter: GreylistAdapter)
    :ok
  end

  defp user do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "queued-retry-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp legacy!(worker, args) do
    job = args |> worker.new() |> Oban.insert!()

    # From the app's clock: in the sandbox transaction the column default is
    # the transaction's start, older than the account seeded above.
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [inserted_at: DateTime.utc_now()]
    )

    job
  end

  defp row(id), do: Repo.one!(from(j in Oban.Job, where: j.id == ^id))

  defp fail_once(job) do
    capture_log(fn -> Oban.drain_queue(queue: :mail) end)
    row(job.id)
  end

  defp last_attempt!(job, row) do
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "available", attempt: row.max_attempts - 1, scheduled_at: DateTime.utc_now()]
    )
  end

  test "a legacy workflow mail keeps its address to retry, and drops it on the last failure" do
    address = to_string(user().email)

    job =
      legacy!(WorkflowMailWorker, %{
        "to" => address,
        "event" => "submitted_for_review",
        "kind" => "page",
        "title" => "Retried",
        "id" => Ecto.UUID.generate(),
        "actor_name" => "Ada",
        "org_id" => KilnCMS.Accounts.default_org_id()
      })

    row = fail_once(job)
    assert row.state == "retryable"
    assert row.args["to"] == address
    assert row.args["title"] == "Retried"

    last_attempt!(job, row)
    row = fail_once(job)
    assert row.state == "discarded"
    for key <- ~w(to title actor_name), do: refute(Map.has_key?(row.args, key))
  end

  test "a legacy task mail keeps its address to retry, and drops it on the last failure" do
    assignee = user()
    address = to_string(assignee.email)

    # A real task: a legacy assignment is sent only while its task is still
    # open and the assignee's (#3037).
    {:ok, task} =
      KilnCMS.CMS.assign_task(
        %{content_type: "page", content_id: Ecto.UUID.generate(), assignee_id: assignee.id},
        actor: user()
      )

    job =
      legacy!(TaskMailWorker, %{
        "kind" => "assigned",
        "to" => address,
        "task_id" => task.id,
        "content_type" => task.content_type,
        "content_id" => task.content_id,
        "org_id" => KilnCMS.Accounts.default_org_id(),
        "note" => "retried note"
      })

    row = fail_once(job)
    assert row.state == "retryable"
    assert row.args["to"] == address

    last_attempt!(job, row)
    row = fail_once(job)
    assert row.state == "discarded"
    refute Map.has_key?(row.args, "to")
    refute Map.has_key?(row.args, "note")
  end
end
