defmodule KilnCMS.CMS.Changes.RefuseIpSelfBlock do
  @moduledoc """
  Refuses an `IpBlockRule` that would block the person adding it, unless they say
  they mean it (#2242).

  The caller hands its client address in as `context: %{client_ip: tuple | nil}`.
  The rule is refused with `confirm_self_block: false` when it contains that
  address, and also when the address is `nil` — the caller could not say who it
  is, so the rule cannot be shown to be safe. Confirming is
  `confirm_self_block: true`. Loopback is never blockable, so a console reached
  over loopback cannot trip this.
  """
  use Ash.Resource.Change

  alias KilnCMS.Security.IpBlocklist

  @impl true
  def change(changeset, _opts, _context) do
    # A `before_action`, so the policy has already spoken: someone who may not add
    # rules is told so, not asked to confirm.
    Ash.Changeset.before_action(changeset, fn changeset ->
      cidr = Ash.Changeset.get_attribute(changeset, :cidr)
      confirmed? = Ash.Changeset.get_argument(changeset, :confirm_self_block) == true
      client_ip = Map.get(changeset.context, :client_ip)

      if not confirmed? and IpBlocklist.would_block?(cidr, client_ip) do
        Ash.Changeset.add_error(changeset,
          field: :confirm_self_block,
          message: message(client_ip)
        )
      else
        changeset
      end
    end)
  end

  defp message(nil),
    do:
      "your own address could not be determined, so this rule cannot be checked against it; confirm to add it anyway"

  defp message(_ip),
    do: "this rule includes your own address and would lock you out; confirm to add it anyway"
end
