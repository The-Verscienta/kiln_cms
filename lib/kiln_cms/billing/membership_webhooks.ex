defmodule KilnCMS.Billing.MembershipWebhooks do
  @moduledoc """
  Outbound `membership.activated` / `membership.canceled` webhook events.

  They follow **access**, not the provider's status machine. A membership is
  *activated* when it starts granting its tier's audience and *canceled* when
  it stops — the two edges an outside system acts on: provisioning a hosted
  site, adding a contact to a CRM, revoking either. Everything in between is
  silent:

  | Transition | Event |
  |------------|-------|
  | `:incomplete` / `:canceled` → `:active` / `:comped` | `membership.activated` |
  | `:active` / `:past_due` / `:comped` → `:canceled` | `membership.canceled` |
  | `:active` → `:active` (renewal), `:active` ↔ `:past_due` | none — access unchanged |
  | `:incomplete` → `:canceled` (abandoned checkout) | none — never granted |

  `:past_due` still grants (see `KilnCMS.Billing.Membership`), so dunning is
  not a cancellation; the provider giving up is.

  ## Delivered through an outbox

  `enqueue/3` runs inside the transition's transaction
  (`KilnCMS.Billing.Changes.RecordTransition`) and inserts one Oban job, so the
  event commits or rolls back with the access change. The job
  (`KilnCMS.Billing.MembershipWebhookWorker`) dispatches after commit, with
  retries. Content webhooks make the opposite trade — dispatched after commit,
  best-effort (`KilnCMS.CMS.Changes.NotifyWebhooks`) — because a missed
  `page.published` costs a cache refresh, while a missed
  `membership.activated` means a paying customer is never provisioned.
  """

  alias KilnCMS.Billing.Membership
  alias KilnCMS.Billing.MembershipWebhookWorker

  @activated "membership.activated"
  @canceled "membership.canceled"

  @doc "The event names, for `KilnCMS.CMS.WebhookEndpoint.events/1`."
  @spec events() :: [String.t()]
  def events, do: [@activated, @canceled]

  @doc """
  The event a transition from `from` to `to` emits, or `nil`.

      iex> KilnCMS.Billing.MembershipWebhooks.event_for(:incomplete, :active)
      "membership.activated"
      iex> KilnCMS.Billing.MembershipWebhooks.event_for(:past_due, :canceled)
      "membership.canceled"
      iex> KilnCMS.Billing.MembershipWebhooks.event_for(:active, :past_due)
      nil
  """
  @spec event_for(atom() | nil, atom()) :: String.t() | nil
  def event_for(from, to) do
    case {Membership.entitling?(from), Membership.entitling?(to)} do
      {false, true} -> @activated
      {true, false} -> @canceled
      _unchanged -> nil
    end
  end

  @doc """
  Enqueue the event for a transition, if it is one — inside the caller's
  transaction. `event_id` is the `KilnCMS.Billing.MembershipEvent` recorded for
  the same transition; receivers get it as `event_id` and can dedupe on it.
  """
  @spec enqueue(atom() | nil, struct(), Ecto.UUID.t()) ::
          {:ok, Oban.Job.t() | nil} | {:error, term()}
  def enqueue(from_status, membership, event_id) do
    case event_for(from_status, membership.status) do
      nil ->
        {:ok, nil}

      event ->
        # Ids and statuses only: the email is read when the job runs, so it is
        # never copied into `oban_jobs.args`, and an erasure that lands first
        # is respected.
        %{
          "event" => event,
          "event_id" => event_id,
          "membership_id" => membership.id,
          "org_id" => membership.org_id,
          "from_status" => from_status && to_string(from_status),
          "to_status" => to_string(membership.status),
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
        |> MembershipWebhookWorker.new()
        |> Oban.insert()
    end
  end
end
