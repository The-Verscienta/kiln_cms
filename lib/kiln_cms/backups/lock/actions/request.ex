defmodule KilnCMS.Backups.Lock.Actions.Request do
  @moduledoc """
  `KilnCMS.Backups.Lock`'s `:request` action (#2218): start a backup, queue it
  behind the running chain, fold it into the queued one of the same kind, or
  refuse it (`{:queue_busy, queued}`) when the queued one is of another kind
  (`KilnCMS.Backups.Chain.request/1`).

  The policy has decided who may ask by the time this runs; the lock itself is
  written as `KilnCMS.Backups.system/0`, never as the caller. A person's id is
  kept on a queued request (`waiting_requested_by`).
  """
  use Ash.Resource.Actions.Implementation

  alias KilnCMS.Backups.{Chain, Refused, WorkState}

  @impl true
  def run(input, _opts, context) do
    resume = Ash.ActionInput.get_argument(input, :resume)

    if resume != nil and not WorkState.valid_stamp?(resume) do
      {:error, Refused.exception(reason: :invalid_stamp)}
    else
      attrs = %{
        trigger: Ash.ActionInput.get_argument(input, :trigger),
        resume: resume,
        requested_by: requested_by(context.actor)
      }

      case Chain.request(attrs) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, Refused.exception(reason: reason)}
      end
    end
  end

  defp requested_by(%KilnCMS.Accounts.User{id: id}), do: id
  defp requested_by(_actor), do: nil
end
