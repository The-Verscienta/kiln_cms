defmodule KilnCMS.Security.AdminAllowlist do
  @moduledoc """
  The site's admin allowlist (#2248), as the gates read it: the networks a
  site's console and sign-in may be reached from.

  The list is a `KilnCMS.CMS.SiteAdminAllowlist` row. An empty list, or no row,
  is "off": every network is admitted. The gates are
  `KilnCMSWeb.Plugs.AdminAllowlist` (the router pipelines in front of the
  console, `/setup` and every sign-in route) and `KilnCMSWeb.AdminAllowlist`
  (LiveView joins and `/ws/collab`).

  ## Two surfaces

  Every gate asks for one of two surfaces: `:console` (the console, `/setup`,
  their live sessions, `/ws/collab` and the security posture) or `:sign_in`
  (the sign-in family and the headless `POST /api/auth/sign_in*`). They answer
  the same unless the site turned "Also restrict sign-in" off (#2493): then
  `:sign_in` is `:off` while `:console` keeps the list. The cached value is
  the site's whole setting (`t:stored/0`); `for_surface/2` projects it, so a
  gate, a cache entry and a broadcast never disagree about which surface a
  value was meant for.

  ## What it costs

  `policy/1` is one cached lookup per request, for a minute, on the routes the
  gates sit on and nowhere else: public delivery never asks. The entries are
  parsed once, when the row is read, and a check is integer shift-compares over
  at most 100 of them. A site with no row caches `:off` and stops there. A save
  busts the cache on every node.

  ## It fails closed

  A row that cannot be read is not "no row". It answers `:unavailable`, which
  the gates turn into a `503` (HTTP) or a refused join, and it is not cached.
  The one exception is a site this node last read as off (no list): the read
  answers `:off` again from the last value it saw, so a database blip does not
  take the console of every site without a list down with it. Last known "on",
  or nothing known (a fresh node, a change since), stays closed: a list that
  vanishes under load is the failure this exists to avoid (#564). The console
  and sign-in cannot work without the database anyway.

  The last-known value is per node, kept a day, and versioned by the row's
  `updated_at`. A save sets it on every node to the list it saved, so a list
  turned on during a blip is never answered from the "off" it replaced, and a
  read that began before the save cannot write the older list back after it.

  ## No loopback exemption

  The block list never blocks loopback. This one does not admit it either:
  behind a same-host proxy that `TRUSTED_PROXIES` does not name, every request
  is `127.0.0.1`, and an exemption would admit the whole internet. The save's
  lock-out check refuses such a setup instead.

  ## The operator's switch

  `KILN_ADMIN_ALLOWLIST_DISABLED=1` (`config :kiln_cms, :admin_allowlist,
  disabled: true`) makes `policy/1` answer `:off` on this node for every site:
  the way back in for an operator who can set variables and restart but cannot
  run `bin/kiln_cms rpc` (`KilnCMS.Release.admin_allowlist/1`).
  """

  require Logger

  alias KilnCMS.Security.Cidr

  @type policy :: :off | {:on, [Cidr.t()]} | :unavailable
  @typedoc """
  The site's setting as cached and broadcast: a `t:policy/0`, or
  `{:console_only, cidrs}` for a list that leaves sign-in open (#2493).
  """
  @type stored :: policy() | {:console_only, [Cidr.t()]}
  @type surface :: :console | :sign_in
  @type verdict :: :allowed | :not_listed | :unavailable

  @ttl :timer.seconds(60)
  @last_known_ttl :timer.hours(24)
  @warn_every :timer.seconds(60)
  @warned_key "admin_allowlist:degrade_logged"

  @doc "How long a site's compiled list is cached, in milliseconds."
  @spec ttl() :: pos_integer()
  def ttl, do: @ttl

  @doc "The PubSub topic a site's open console and sign-in pages hear list changes on."
  @spec topic(Ash.UUID.t()) :: String.t()
  def topic(org_id) when is_binary(org_id), do: "admin_allowlist:#{org_id}"

  @doc "Is the operator's switch (`KILN_ADMIN_ALLOWLIST_DISABLED`) on, on this node?"
  @spec disabled?() :: boolean()
  def disabled? do
    :kiln_cms |> Application.get_env(:admin_allowlist, []) |> Keyword.get(:disabled, false) ==
      true
  end

  @doc """
  The site's list as the gate of `surface` (`:console`, the default, or
  `:sign_in`) uses it: `:off`, `{:on, cidrs}` (parsed), or `:unavailable` when
  the row could not be read (see "It fails closed").
  """
  @spec policy(Ash.UUID.t() | nil, surface()) :: policy()
  def policy(org_id, surface \\ :console)

  def policy(org_id, surface) when is_binary(org_id) do
    if disabled?(), do: :off, else: org_id |> resolve() |> for_surface(surface)
  end

  def policy(_no_org, _surface), do: :off

  @doc """
  A stored setting (`t:stored/0`, as cached or broadcast) as the gate of
  `surface` sees it. A list that leaves sign-in open is `:off` for `:sign_in`
  and the list for `:console`.
  """
  @spec for_surface(stored(), surface()) :: policy()
  def for_surface({:console_only, _cidrs}, :sign_in), do: :off
  def for_surface({:console_only, cidrs}, :console), do: {:on, cidrs}
  def for_surface(policy, surface) when surface in [:console, :sign_in], do: policy

  @doc false
  # The site's stored list as `policy/1` would answer it with the operator's
  # switch off: the same cached, fail-closed read. For the Security posture
  # page (#2252), which has to see a list the switch is currently ignoring.
  @spec configured(Ash.UUID.t(), surface()) :: policy()
  def configured(org_id, surface \\ :console) when is_binary(org_id),
    do: org_id |> resolve() |> for_surface(surface)

  defp resolve(org_id) do
    # Taken here, not in `read`: a cache miss runs `read` on a Cachex courier
    # process, where the `OrgSettings.with_actor/2` test seam does not reach.
    actor = KilnCMS.OrgSettings.system(:admin_allowlist)

    KilnCMS.OrgSettings.resolve(org_id,
      cache_key: KilnCMS.Cache.admin_allowlist_key(org_id),
      ttl: @ttl,
      read:
        &KilnCMS.CMS.list_site_admin_allowlist(
          tenant: &1,
          actor: actor,
          authorize_with: :error
        ),
      build: &remember_read(org_id, &1),
      fallback: fn -> degraded(org_id) end,
      label: "admin allowlist",
      warn: &warn_rate_limited/1
    )
  end

  # Kept as `{version, policy}`, the version being the row's `updated_at` (`nil`
  # for no row). A read that began before a save can finish after it; the save
  # has already put its own version here (`last_known/1`), so the late read's
  # older one is declined rather than writing the old list back.
  @doc false
  # Public so a test can stand in for a read that finished after a save.
  @spec remember_read(Ash.UUID.t(), struct() | nil) :: stored()
  def remember_read(org_id, row) do
    policy = from_row(row)
    version = version(row)

    # Inside a transaction the row may be uncommitted and roll back
    # (`KilnCMS.Cache` reads on the caller's connection there, #2823):
    # never pin it as the last-known list, whose newer-version guard would
    # then decline the real, older one for a day.
    unless KilnCMS.Repo.in_transaction?(), do: remember(org_id, version, policy)

    policy
  end

  defp remember(org_id, version, policy) do
    KilnCMS.Cache.put_unless_kept(
      KilnCMS.Cache.admin_allowlist_last_known_key(org_id),
      @last_known_ttl,
      fn
        {stored, _policy} -> if older?(version, stored), do: :keep, else: {version, policy}
        _nothing -> {version, policy}
      end
    )

    policy
  end

  @doc """
  The last-known value a save leaves behind on every node
  (`KilnCMS.Cache.bust_admin_allowlist/2`): the saved list, at its version.
  """
  @spec last_known(struct()) :: {DateTime.t() | nil, stored()}
  def last_known(row), do: {version(row), from_row(row)}

  defp version(nil), do: nil
  defp version(row), do: Map.get(row, :updated_at)

  defp older?(nil, nil), do: false
  defp older?(nil, _stored), do: true
  defp older?(_version, nil), do: false
  defp older?(version, stored), do: DateTime.compare(version, stored) == :lt

  # Only a list this node last saw OFF stays off through a failed read. A list
  # last seen with sign-in open is `:unavailable` for both surfaces: the console
  # must not open, and sign-in cannot work without the database anyway.
  defp degraded(org_id) do
    case KilnCMS.Cache.peek(KilnCMS.Cache.admin_allowlist_last_known_key(org_id)) do
      {_version, :off} -> :off
      _on_or_unknown -> :unavailable
    end
  end

  # Every gated request of every site asks, and anyone can make one: during an
  # outage one line a minute per node says what is happening, not one per
  # request.
  defp warn_rate_limited(message) do
    if is_nil(KilnCMS.Cache.peek(@warned_key)) do
      KilnCMS.Cache.put(@warned_key, true, @warn_every)
      Logger.warning(message <> " (logged at most once a minute)")
    end

    :ok
  end

  @doc """
  A `SiteAdminAllowlist` row (or `nil`, no row) as a stored setting: its list
  as a policy, or `{:console_only, cidrs}` when the list is on and
  `restrict_sign_in` is off. Anything but an explicit `false` restricts
  sign-in, as the column's default does.
  """
  @spec from_row(struct() | nil) :: stored()
  def from_row(nil), do: :off

  def from_row(%{cidrs: cidrs} = row) do
    case {from_cidrs(cidrs), Map.get(row, :restrict_sign_in)} do
      {{:on, parsed}, false} -> {:console_only, parsed}
      {policy, _restrict} -> policy
    end
  end

  @doc """
  A list of entries (strings) as a policy. An entry that does not parse admits
  nothing (the save refuses one, so only a hand-edited row has it); a list of
  nothing but such entries is still on, and admits nobody.
  """
  @spec from_cidrs([String.t()] | nil) :: :off | {:on, [Cidr.t()]}
  def from_cidrs(cidrs) do
    case List.wrap(cidrs) do
      [] -> :off
      texts -> {:on, Enum.flat_map(texts, &parsed/1)}
    end
  end

  defp parsed(text) do
    case Cidr.parse(text) do
      {:ok, cidr} -> [cidr]
      _invalid -> []
    end
  end

  @doc """
  The gates' answer for `ip` on the site `org_id`, for `surface` (`:console`
  by default): `:allowed`, `:not_listed` or `:unavailable`. An unknown (`nil`) address is never listed.
  """
  @spec check(Ash.UUID.t() | nil, :inet.ip_address() | nil, surface()) :: verdict()
  def check(org_id, ip, surface \\ :console),
    do: org_id |> policy(surface) |> verdict([ip])

  @doc """
  `policy` judged against every address in `ips`: allowed only when the list
  is off or **each** of them is on it. A `nil` among them is an address that
  could not be determined, and is never listed.
  """
  @spec verdict(stored(), [:inet.ip_address() | nil]) :: verdict()
  def verdict(:off, _ips), do: :allowed
  def verdict(:unavailable, _ips), do: :unavailable
  # A stored setting that reached a gate unprojected is judged as the console
  # would judge it: the stricter reading, never an open door.
  def verdict({:console_only, cidrs}, ips), do: verdict({:on, cidrs}, ips)

  def verdict({:on, cidrs}, ips) when is_list(ips) do
    if ips != [] and Enum.all?(ips, &Cidr.any_contains?(cidrs, &1)),
      do: :allowed,
      else: :not_listed
  end

  @doc """
  Would a list of `cidr_texts` admit `ip`? `true` for an empty list (off).
  The save's lock-out check (`KilnCMS.CMS.Changes.RefuseAdminLockout`).
  """
  @spec would_admit?([String.t()], :inet.ip_address() | nil) :: boolean()
  def would_admit?(cidr_texts, ip), do: verdict(from_cidrs(cidr_texts), [ip]) == :allowed
end
