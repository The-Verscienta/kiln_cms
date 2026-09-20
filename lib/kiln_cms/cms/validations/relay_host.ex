defmodule KilnCMS.CMS.Validations.RelayHost do
  @moduledoc """
  A site's SMTP relay host (`KilnCMS.CMS.SiteMailRelay.host`) has to be a host
  name or IP address that the SSRF rules allow.

  A site admin is not the operator. A relay host they choose is a connection
  this server opens, and the error that comes back is shown to them. So a
  private address is refused here, where the admin can see why. It is checked
  again at every connection (`KilnCMS.Mail.SiteRelay`), because DNS can change
  between the save and the send.

  `host:port` is refused as a shape error rather than split, because the port
  has its own field and a colon in a host name is otherwise an IPv6 literal.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  # A DNS name (labels of letters, digits and hyphens) or an IP literal.
  @hostname ~r/\A(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\z/i

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :host) do
      host when is_binary(host) and host != "" -> check(host)
      _blank -> :ok
    end
  end

  defp check(host) do
    cond do
      not (Regex.match?(@hostname, host) or ip_literal?(host)) ->
        error("must be a host name like smtp.example.com, without a port")

      KilnCMS.Mail.SiteRelay.allow_private_hosts?() ->
        :ok

      true ->
        case KilnCMS.Webhooks.SafeUrl.resolve_host_pinned(host) do
          {:ok, _address} -> :ok
          {:error, message} -> error(message)
        end
    end
  end

  defp ip_literal?(host), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))

  defp error(message), do: {:error, InvalidAttribute.exception(field: :host, message: message)}
end
