defmodule KilnCMS.Automation.DispatchWorker do
  @moduledoc """
  Matches an editorial event against the automation rules and fans out one
  `KilnCMS.Automation.RuleWorker` per matching rule (#342).

  Enqueued by `KilnCMS.Automation.handle_event/2` on the publish path (an
  `Oban.insert` that commits with the publish). Running the rule *match* here —
  rather than inline in `Webhooks.dispatch/2` — keeps the `automation_rules`
  read off the publish transaction, so a rules read that errors can't roll the
  publish back.
  """
  # No uniqueness: every editorial event must fan out its own rules (two publishes
  # of the same content are distinct events, and dropping one would drop its
  # automation).
  use Oban.Worker, queue: :default, max_attempts: 3

  alias KilnCMS.Automation
  alias KilnCMS.Jobs.PrivateArgs

  # The payload is the event's serialized document, drafts included (#2992):
  # it is read in either shape `Automation.job_payload/1` accepts and dropped
  # from the job's row once the job is finished.
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event" => event} = args} = job) do
    PrivateArgs.finishing(job, PrivateArgs.keys(__MODULE__), fn ->
      case Automation.job_payload(args) do
        {:ok, payload} ->
          # `org_id` scopes the rule match to the event's own site (epic #336);
          # pre-#336 jobs carry none and fall back to the sole org.
          org_id = Map.get(args, "org_id", KilnCMS.Accounts.default_org_id())
          Automation.dispatch(event, payload, org_id)

        {:error, reason} ->
          {:cancel, Automation.describe_payload_error(reason)}
      end
    end)
  end
end
