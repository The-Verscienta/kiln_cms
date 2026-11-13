defmodule KilnCMSWeb.Plugs.IpBlock do
  @moduledoc """
  Refuses a request from an address on the site's block list with a bare `403`
  (#2242).

  Sits straight after `KilnCMSWeb.Plugs.SetTenant` in the endpoint: the list is
  per organization, so it needs the resolved tenant, and `ClientIp` has already
  rewritten `conn.remote_ip` to the real client. Anything `SetTenant` halted never
  gets here.

  The refusal is an empty body and no detail: it does not say a list exists, which
  rule matched, or why. Nothing logs the address. Every refusal counts on the
  `kiln_cms.ip_block.refused.count` counter (tag `surface: :http`), and is noted
  for the site's `blocked_ip` alert (`KilnCMS.Security.BlockedIpAlert`, which
  records one sampled audit event per client network per alert window,
  without the address).

  ## What it does not see

    * `GET /live` is answered earlier (`Plugs.Liveness`), and `/up` and `/ready`
      are exempted here by path: a block must never take a site's probes down,
      and the load balancer's address is not the abuser's. Loopback is also never
      blocked (`IpBlocklist.blocked?/2`).
    * Static assets and `/uploads` are served by `Plug.Static` above the tenant
      resolution and cannot be scoped to an organization. Put a CDN or proxy rule
      in front of those.
    * The sockets check for themselves — see `KilnCMSWeb.IpBlock`.
  """
  @behaviour Plug

  import Plug.Conn

  @exempt ["/up", "/ready"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: path} = conn, _opts) when path in @exempt, do: conn

  def call(%Plug.Conn{assigns: %{current_org: org}, remote_ip: ip} = conn, _opts) do
    case KilnCMS.Security.IpBlocklist.match(org, ip) do
      {:blocked, rule} ->
        KilnCMSWeb.IpBlock.count_refusal(:http)

        KilnCMS.Security.BlockedIpAlert.note(org.id, ip, rule, :http)

        conn |> send_resp(403, "") |> halt()

      false ->
        conn
    end
  end

  def call(conn, _opts), do: conn
end
