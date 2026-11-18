defmodule KilnCMS.Backups.Lock.Actions.RequestResend do
  @moduledoc """
  `KilnCMS.Backups.Lock`'s `:request_resend` action (#2949): re-send a partly
  off-site run to the destinations it missed (`KilnCMS.Backups.Chain.request_resend/1`).

  The policy has decided who may ask by the time this runs (a platform admin,
  or the `:backups` system actor); the lock itself is written as
  `KilnCMS.Backups.system/0`, never as the caller. Not audited (owner
  decision O10): a re-send changes no file and no run outcome a person
  could want traced, and its Cancel is audited.

  A refusal is a `KilnCMS.Backups.Refused` carrying the reason, which
  `KilnCMS.Backups.resend_offsite/2` unwraps.
  """
  use Ash.Resource.Actions.Implementation

  alias KilnCMS.Backups.{Chain, Refused}

  @impl true
  def run(input, _opts, _context) do
    case Chain.request_resend(Ash.ActionInput.get_argument(input, :stamp)) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, Refused.exception(reason: reason)}
    end
  end
end
