defmodule KilnCMS.CMS.Changes.NormalizeIpBlockCidr do
  @moduledoc """
  Stores an `IpBlockRule`'s `cidr` in its one canonical spelling and refuses a
  rule that must never be stored (#2242): not an address, wider than the prefix
  floor, or overlapping loopback. The rules live in `KilnCMS.Security.Cidr`; this
  only maps a refusal onto the field.
  """
  use Ash.Resource.Change

  alias KilnCMS.Security.Cidr

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :cidr) do
      nil ->
        changeset

      input ->
        case Cidr.blockable(input) do
          {:ok, cidr} ->
            Ash.Changeset.force_change_attribute(changeset, :cidr, cidr)

          {:error, reason} ->
            Ash.Changeset.add_error(changeset, field: :cidr, message: message(reason))
        end
    end
  end

  defp message(:invalid), do: "must be an IP address or a range like 203.0.113.0/24"
  defp message(:too_broad), do: "is too broad: use at least /8 for IPv4 or /16 for IPv6"
  defp message(:loopback), do: "must not include loopback (127.0.0.0/8 or ::1)"
end
