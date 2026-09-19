defmodule KilnCMS.Billing.MembershipWebhookWorker do
  @moduledoc """
  Dispatches one `membership.activated` / `membership.canceled` event after the
  transition that caused it has committed. Enqueued by
  `KilnCMS.Billing.MembershipWebhooks.enqueue/3`; see that module for which
  transitions are events and why this is an outbox.

  The payload is built here, not at enqueue time, so the member's email never
  sits in `oban_jobs.args`. The facts of the event — which edge, from which
  status to which — come from the job args and so describe the transition
  itself, even if the membership has moved on since.

  `KilnCMS.Webhooks.dispatch/3` records one delivery (and one job) per
  subscribed endpoint. It runs inside a transaction here, so a retry after a
  failure part-way through does not deliver twice to the endpoints it had
  already reached.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 8

  alias KilnCMS.Accounts
  alias KilnCMS.Billing

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"membership_id" => id, "org_id" => org_id} = args}) do
    case Billing.get_membership(id,
           actor: KilnCMS.SystemActor.new(:billing),
           tenant: org_id,
           load: [:tier],
           not_found_error?: false
         ) do
      {:ok, nil} ->
        {:cancel, :membership_gone}

      {:ok, membership} ->
        payload = payload(args, membership, email(membership.user_id))

        KilnCMS.Repo.transaction(fn ->
          KilnCMS.Webhooks.dispatch(args["event"], payload, org_id)
        end)
        |> case do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: KilnCMS.Mail.backoff_seconds(attempt)

  @doc false
  # The delivered body. Public for the moduledoc'd shape to be testable.
  def payload(args, membership, email) do
    tier = membership.tier

    %{
      "event_id" => args["event_id"],
      "membership_id" => membership.id,
      "org_id" => membership.org_id,
      "user_id" => membership.user_id,
      "email" => email,
      "tier" => %{
        "id" => tier.id,
        "slug" => tier.slug,
        "name" => tier.name,
        "audience" => to_string(tier.audience)
      },
      "status" => args["to_status"],
      "previous_status" => args["from_status"],
      "occurred_at" => args["occurred_at"],
      "activated_at" => iso8601(membership.activated_at),
      "canceled_at" => iso8601(membership.canceled_at),
      "current_period_end" => iso8601(membership.current_period_end)
    }
  end

  # Same read `KilnCMS.Billing.Entitlements` makes. `nil` for a user erased
  # since — the event still goes out, carrying ids an erased account no longer
  # maps to a person.
  #
  # `authorize?: false` because this is a job with no actor, and
  # `KilnCMS.Accounts.User` admits no system actor. Safe: it reads the one
  # account the membership row already names, by id, and the email goes only to
  # endpoints an admin subscribed to membership events.
  defp email(user_id) do
    case Accounts.get_user(user_id, authorize?: false, not_found_error?: false) do
      {:ok, %{email: email}} when not is_nil(email) -> to_string(email)
      _missing -> nil
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
