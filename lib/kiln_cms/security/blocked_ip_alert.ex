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
       (20 of each rule source, see below) are let through; once it is used
       up, nothing more is counted. Read first, without adding to it, so a
       flood past the cap costs one ETS read.
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

  ## Rules the scanner guard added

  A refusal by a temporary rule the scanner guard added
  (`KilnCMS.CMS.IpBlockRule` `source: :scanner_guard`, #2253) is recorded
  but raises no alert (#2810, owner decision 2026-11-27): the guard already
  recorded `ip_auto_blocked` when it added the rule, and the refusals that
  follow are the rule working, not news for the site's admins. Its event carries
  `"source" => "scanner_guard"`, which `KilnCMS.Security.Alerts.classify/2`
  reads to raise nothing; an admin rule's event has no `source` key, so its
  metadata (and webhook payload) is what it was before.

  The two sources are gated and sampled apart: 20 of each per site per
  window, and a network's scanner refusal does not use up the one sample its
  admin refusal gets. A flood the scanner guard is already answering cannot
  hide a refusal by an admin's rule. Where both kinds of rule contain the
  address, the admin rule is the one matched
  (`KilnCMS.Security.IpBlocklist.match/2`).

  A rule added before the `source` column existed reads `:admin` and keeps
  alerting until it expires (`KILN_SCANNER_BLOCKING_BLOCK_MINUTES`, default
  60, at most 7 days).

  ## No address is recorded

  The event carries the rule that matched and the surface, and no request
  context: its `ip` and `user_agent` are `nil` (#2245), so ADR 0026's
  "nothing logs the address" holds for the audit log, the alert and its
  webhooks alike. The client network is only the sampling key: stored in
  `throttle_counters` as its SHA-256 (`KilnCMS.Accounts.ThrottleStore`
  hashes every key) and held in this node's ETS for one window, never
  written to the database as text. A rule is the
  site's own text, masked the way the site's settings mask an address
  (`KilnCMS.Security.Alerts.display_metadata/3`). Nothing here raises, and
  nothing logs an address.
  """

  require Logger

  alias KilnCMS.Security.Alerts
  alias KilnCMS.Security.Cidr
  alias KilnCMS.Security.Recorder
  alias KilnCMSWeb.RateLimit

  @site_cap 20

  @typedoc "Where the refusal happened, recorded as the event's `surface`."
  @type surface :: :http | :live | :gql | :collab | :bridge

  @typedoc "Who added the rule that matched (`KilnCMS.CMS.IpBlockRule`'s `source`)."
  @type source :: :admin | :scanner_guard

  @doc "How many client networks one site records per node per alert window, per rule source."
  @spec site_cap() :: pos_integer()
  def site_cap, do: @site_cap

  @doc """
  Note one refused request from `ip` (an address tuple) on `org_id`'s site,
  blocked by `rule` (the rule's text), which `source` added. `ip` picks the
  client network the gates count per; it is not recorded. Always `:ok`.
  """
  @spec note(Ash.UUID.t(), :inet.ip_address(), String.t(), source(), surface()) :: :ok
  def note(org_id, ip, rule, source, surface)
      when is_binary(org_id) and is_tuple(ip) and is_binary(rule) and
             source in [:admin, :scanner_guard] and is_atom(surface) do
    with network when is_binary(network) <- Cidr.client_range(ip),
         true <- pass?(org_id, network, source) do
      dispatch(%{
        org_id: org_id,
        network: network,
        rule: rule,
        source: source,
        surface: surface
      })
    end

    :ok
  rescue
    _error ->
      Logger.warning("BlockedIpAlert: could not note a refused request; skipped")
      :ok
  end

  def note(_org_id, _ip, _rule, _source, _surface), do: :ok

  defp pass?(org_id, network, source) do
    window_ms = Alerts.window_ms()
    {cap_key, network_key} = gate_keys(org_id, network, source)

    RateLimit.get(cap_key, window_ms) < @site_cap and
      match?({:allow, _}, RateLimit.hit(network_key, window_ms, 1)) and
      match?({:allow, _}, RateLimit.hit(cap_key, window_ms, @site_cap))
  end

  # An admin rule's keys are the ones used before #2810; the scanner guard's
  # are their own, so neither source can use up the other's.
  defp gate_keys(org_id, network, :admin),
    do: {"security_blocked_ip_org:#{org_id}", "security_blocked_ip:#{org_id}:#{network}"}

  defp gate_keys(org_id, network, :scanner_guard),
    do:
      {"security_blocked_ip_auto_org:#{org_id}", "security_blocked_ip_auto:#{org_id}:#{network}"}

  defp sample_key(network, :admin), do: network
  defp sample_key(network, :scanner_guard), do: "scanner_guard:" <> network

  # `source` only on a scanner guard refusal: an admin rule's event, and the
  # webhook payload built from it, keep the shape they had.
  defp metadata(ctx) do
    metadata = %{"rule" => ctx.rule, "surface" => Atom.to_string(ctx.surface)}

    case ctx.source do
      :scanner_guard -> Map.put(metadata, "source", "scanner_guard")
      :admin -> metadata
    end
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
      # No request context: the event records no address (see the moduledoc).
      request: nil,
      sample_key: sample_key(ctx.network, ctx.source),
      limit: 1,
      scale: Alerts.window_ms(),
      metadata: metadata(ctx)
    )
  end
end
