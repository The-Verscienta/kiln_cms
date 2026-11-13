defmodule KilnCMS.Security.BlockedIpAlert do
  @moduledoc """
  A request refused by the site's block list, as an audit event and a
  `blocked_ip` security alert (#2245). Called by every request edge that
  refuses one: `KilnCMSWeb.Plugs.IpBlock` (`surface: :http`) and
  `KilnCMSWeb.IpBlock` (`:live`, `:gql`, `:collab`, `:bridge`). Never by
  `KilnCMS.Security.IpBlocklist.blocked?/2`, which the scanner guard also
  asks without refusing anything.

  ## No database write per blocked request

  A blocked address is a flood by nature, so everything before the database
  is in memory, on this node (`KilnCMSWeb.RateLimit`, ETS counters, one alert
  window long):

    1. **The site's cap.** At most 20 client networks per site per window
       are let through; once it is used up, nothing more is counted. Read
       first, without adding to it, so a flood past the cap costs one ETS
       read.
    2. **One per client network.** The first refusal of a network (an IPv4
       address, an IPv6 `/64`, `KilnCMS.Security.Cidr.client_range/1`) in
       the window passes; the rest are dropped.
    3. **The cap is charged** for a network that passed.

  What passes is recorded off the request path, the way the scanner guard
  dispatches its work: `KilnCMS.Security.Recorder.record_sampled/2`, sampled
  once per site and network per window across the cluster. The event raises
  the alert (`KilnCMS.Security.Changes.RaiseAlert`), whose own window gate
  sends one alert and then one summary. The summary counts the networks
  recorded, so at most 20 per node per window; the exact volume of
  refusals is the `kiln_cms.ip_block.refused.count` counter.

  The event is recorded whether or not the site turned `blocked_ip` off: the
  log is the audit trail, and a kind turned off is dropped at delivery.

  The request context is read before the dispatch, in the caller's process,
  and only the resulting map crosses into the task: never a conn or a socket.
  Nothing here raises, and nothing logs an address.
  """

  require Logger

  alias KilnCMS.Security.Alerts
  alias KilnCMS.Security.Cidr
  alias KilnCMS.Security.Recorder
  alias KilnCMSWeb.RateLimit

  @site_cap 20

  @typedoc "Where the refusal happened, recorded as the event's `surface`."
  @type surface :: :http | :live | :gql | :collab | :bridge

  @doc "How many client networks one site records per node per alert window."
  @spec site_cap() :: pos_integer()
  def site_cap, do: @site_cap

  @doc """
  Note one refused request from `ip` (an address tuple) on `org_id`'s site,
  blocked by `rule` (the rule's text). `request_fun` returns the request
  context (`KilnCMS.Security.Recorder.request_context/1`); it is called only
  for a refusal that passes the in-memory gates, in the caller's process.
  Always `:ok`.
  """
  @spec note(Ash.UUID.t(), :inet.ip_address(), String.t(), surface(), (-> Recorder.request())) ::
          :ok
  def note(org_id, ip, rule, surface, request_fun)
      when is_binary(org_id) and is_tuple(ip) and is_binary(rule) and is_atom(surface) and
             is_function(request_fun, 0) do
    with network when is_binary(network) <- Cidr.client_range(ip),
         true <- pass?(org_id, network) do
      dispatch(%{
        org_id: org_id,
        network: network,
        rule: rule,
        surface: surface,
        request: request_fun.()
      })
    end

    :ok
  rescue
    _error ->
      Logger.warning("BlockedIpAlert: could not note a refused request; skipped")
      :ok
  end

  def note(_org_id, _ip, _rule, _surface, _request_fun), do: :ok

  defp pass?(org_id, network) do
    window_ms = Alerts.window_ms()
    cap_key = "security_blocked_ip_org:#{org_id}"

    RateLimit.get(cap_key, window_ms) < @site_cap and
      match?({:allow, _}, RateLimit.hit("security_blocked_ip:#{org_id}:#{network}", window_ms, 1)) and
      match?({:allow, _}, RateLimit.hit(cap_key, window_ms, @site_cap))
  end

  # `:async_analytics` is off under test, where a detached task would run
  # outside the SQL sandbox connection. `start_child/2` is a call, so a
  # restarting supervisor exits the caller; this sits on the refusal path.
  defp dispatch(ctx) do
    if Application.get_env(:kiln_cms, :async_analytics, true) do
      Task.Supervisor.start_child(KilnCMS.TaskSupervisor, fn -> record(ctx) end)
    else
      record(ctx)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp record(ctx) do
    Recorder.record_sampled(:ip_block_refused,
      tenant: ctx.org_id,
      request: ctx.request,
      sample_key: ctx.network,
      limit: 1,
      scale: Alerts.window_ms(),
      metadata: %{"rule" => ctx.rule, "surface" => Atom.to_string(ctx.surface)}
    )
  end
end
