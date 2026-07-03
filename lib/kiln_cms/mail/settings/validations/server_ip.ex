defmodule KilnCMS.Mail.Settings.Validations.ServerIp do
  @moduledoc """
  `server_ip` must parse as an IP address (v4 or v6) when present; nil clears
  it. It drives the SPF record suggestion and the PTR check, so free-text here
  would produce silently wrong DNS guidance.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :server_ip) do
      nil ->
        :ok

      ip ->
        case ip |> String.to_charlist() |> :inet.parse_address() do
          {:ok, _address} -> :ok
          {:error, _} -> {:error, field: :server_ip, message: "is not a valid IP address"}
        end
    end
  end
end
