defmodule KilnCMS.CMS.Changes.RefuseAdminLockout do
  @moduledoc """
  Refuses an admin allowlist that would lock out the person saving it (#2248).
  There is no "confirm anyway": a list that excludes you takes effect at once,
  for the console and for signing back in.

  The caller hands in what it knows about itself as the action's context:

    * `client_ip` — the address the HTTP request that opened the page resolved
      to (`KilnCMSWeb.Plugs.ClientIp`), which is what the HTTP gate checks;
    * `socket_ip` — the address the page's socket resolved to, when the socket
      can see the client at all (`ClientIp.socket_client/2`), which the
      socket gate also checks. `nil` when it cannot;
    * `untrusted_forwarding?` — the request carried a forwarding header that
      nothing is configured to trust, so `client_ip` is a proxy's.

  A non-empty list is refused when it does not admit `client_ip`, or does not
  admit `socket_ip` when there is one (a dual-stack client can arrive over
  IPv4 on one and IPv6 on the other), when `client_ip` is unknown (IEx, a seed,
  a disconnected mount), or when forwarding is untrusted. An empty list is
  always accepted: turning the list off cannot lock anyone out.

  A `before_action`, so the policy has spoken first: someone who may not save
  the list is told so, not that they would lock themselves out. The errors are
  on `:cidrs` with fixed English messages that `KilnCMSWeb.AdminAllowlistLive`
  translates.
  """
  use Ash.Resource.Change

  alias KilnCMS.Security.AdminAllowlist

  @doc "The messages this change refuses with, for a caller telling them apart."
  def messages do
    [untrusted_message(), unknown_message(), excluded_message(), excluded_both_message()]
  end

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      cidrs = Ash.Changeset.get_attribute(changeset, :cidrs) || []

      case refusal(cidrs, changeset.context) do
        nil ->
          changeset

        # Built as the struct: `add_error/2` given a keyword list files its
        # `vars:` one level down, under `vars`.
        error ->
          Ash.Changeset.add_error(
            changeset,
            Ash.Error.Changes.InvalidAttribute.exception([field: :cidrs] ++ error)
          )
      end
    end)
  end

  defp refusal([], _context), do: nil

  defp refusal(cidrs, context) do
    client_ip = Map.get(context, :client_ip)
    socket_ip = Map.get(context, :socket_ip)

    cond do
      Map.get(context, :untrusted_forwarding?) == true ->
        [message: untrusted_message()]

      is_nil(client_ip) ->
        [message: unknown_message()]

      excluded?(cidrs, client_ip, socket_ip) ->
        excluded(client_ip, socket_ip)

      true ->
        nil
    end
  end

  defp excluded?(cidrs, client_ip, socket_ip) do
    not AdminAllowlist.would_admit?(cidrs, client_ip) or
      (not is_nil(socket_ip) and not AdminAllowlist.would_admit?(cidrs, socket_ip))
  end

  defp excluded(client_ip, socket_ip) when is_nil(socket_ip) or socket_ip == client_ip,
    do: [message: excluded_message(), vars: [ip: text(client_ip)]]

  defp excluded(client_ip, socket_ip),
    do: [
      message: excluded_both_message(),
      vars: [ip: text(client_ip), socket_ip: text(socket_ip)]
    ]

  defp text(ip), do: ip |> :inet.ntoa() |> to_string()

  defp untrusted_message,
    do:
      "Kiln is seeing a proxy's address, not yours: a forwarding header arrived that nothing " <>
        "is configured to trust. Either Kiln runs behind a proxy that TRUSTED_PROXIES (or " <>
        "CLIENT_IP_HEADER) does not name, or a proxy on your side added the header. Fix that " <>
        "before turning on the admin allowlist."

  defp unknown_message,
    do: "Your address could not be determined, so this list can't be checked against it."

  defp excluded_message,
    do:
      "This list doesn't include your current address, %{ip}. Add it, or a range that " <>
        "contains it, so you aren't locked out."

  defp excluded_both_message,
    do:
      "This list must include both of your current addresses, %{ip} and %{socket_ip}. Add " <>
        "them, or ranges that contain them, so you aren't locked out."
end
