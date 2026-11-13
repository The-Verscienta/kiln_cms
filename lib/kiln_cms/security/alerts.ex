defmodule KilnCMS.Security.Alerts do
  @moduledoc """
  What a security event is worth telling someone about, and whom (#2245).

  Security alerts are built on the audit log (`KilnCMS.Security.Event`): no
  emit site of their own. `classify/2` maps an event, as it is recorded, to the
  alert kinds it raises. It is pure — no reads, no settings — so the same event
  always classifies the same way, at record time and when a summary
  re-classifies a closed window's events to count them.

  ## Kinds and channels

  A **site** alert is about one site and goes to that site's member admins
  (`site_recipients/1`); the site's `KilnCMS.CMS.SiteSecurityAlerts` row can
  turn each kind off and mute the bell and email. A **platform** alert is about
  the deployment and goes to every platform admin; it cannot be muted, and
  only `api_key_rate_limited` can be turned off, by a platform admin
  (`platform_optional_kinds/0`, stored in
  `KilnCMS.Security.PlatformAlertSettings`, on by default).

  | kind | channel | raised by |
  |------|---------|-----------|
  | `new_admin` | site | a membership granted or raised to admin, a temporary site admin grant, a registration approved as admin |
  | `new_admin` | platform | an account's own role granted or raised to admin, a temporary platform admin grant |
  | `platform_role_changed` | platform | an account's own admin role taken away |
  | `role_elevation` | site | a role raised to editor (or viewer → anything below admin), a temporary non-admin grant |
  | `failed_sign_ins` | site | the site's failed sign-ins reaching the threshold in one window (off by default) |
  | `lockout` | site | an account locked out of signing in |
  | `two_factor_disabled` | site | a second factor removed |
  | `sso_config_changed` | site | the site's identity provider changed |
  | `new_api_key` | platform | an API key minted (not rotated) |
  | `api_key_abuse` | platform | a rotated API key presented again |
  | `api_key_rate_limited` | platform | a verified API key over a rate limit |
  | `blocked_ip` | site | a request from an address on the site's block list refused |

  `api_key_rate_limited` is its own kind, not part of `api_key_abuse`: an
  alert window is claimed per kind, so a key over a rate limit must not use up
  the window a stolen key's reuse alerts in.

  Not alerts: a legacy account's tier carried onto its first membership
  (`via: "legacy_carry"`, it holds nothing new), a key rotation
  (`via: "rotate"`), and a second factor dropped because an invitee took the
  account over (`via: "invitation"`, the account's previous holder's factor).
  Erasing a site admin records no role event, so it raises nothing either.

  ## Notices: silencing is never silent

  Some changes make the alerts quieter. Each raises an `alerts_silenced`
  **notice** to the site's member admins that no setting turns off and no
  mute silences: `classify/2` derives two of them from events (another person
  removing or demoting a site admin, and a change to the site's mail relay);
  settings and webhook changes raise their own. See `notice_changes/0`.
  """

  require Ash.Query
  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Security.AlertTrips
  alias KilnCMS.Security.Cidr

  @site_kinds [
    :new_admin,
    :role_elevation,
    :failed_sign_ins,
    :lockout,
    :two_factor_disabled,
    :sso_config_changed,
    :blocked_ip
  ]

  @platform_kinds [
    :new_admin,
    :platform_role_changed,
    :new_api_key,
    :api_key_abuse,
    :api_key_rate_limited
  ]

  # The platform kinds a platform admin can turn off (owner decision D-A on
  # #2245): a key over a rate limit can be routine for an installation whose
  # clients batch. Every other platform kind is always on.
  @platform_optional_kinds [:api_key_rate_limited]

  @notice_changes ~w(kind_disabled admin_notifications_off webhook_changed webhook_removed
                     webhook_secret_rotated webhook_auto_disabled admin_removed admin_demoted
                     admin_grant_revoked mail_relay_changed)

  @default_disabled ["failed_sign_ins"]

  # The failed-sign-in tally: how many in one window raise the alert.
  @failed_sign_in_threshold 10
  @failed_sign_in_bucket "security_alert_failed_sign_in"
  # How many rows one site's tally is spread over (#2639).
  @failed_sign_in_shards 8

  @default_window_ms :timer.minutes(15)

  @typedoc "An alert kind."
  @type kind ::
          :new_admin
          | :role_elevation
          | :failed_sign_ins
          | :lockout
          | :two_factor_disabled
          | :sso_config_changed
          | :blocked_ip
          | :platform_role_changed
          | :new_api_key
          | :api_key_abuse
          | :api_key_rate_limited

  @typedoc """
  One thing an event raises: an alert of `kind` on a channel, or an
  `alerts_silenced` notice naming the `change` (one of `notice_changes/0`).
  """
  @type classification :: {kind(), :site | :platform} | {:alerts_silenced, :notice, String.t()}

  @typedoc "A site's resolved alert settings (`settings_for/1`)."
  @type settings :: %{
          disabled_kinds: [String.t()],
          notify_admins: boolean(),
          include_full_ip: boolean()
        }

  @doc """
  Whether recording an event claims alert windows. Always, outside the test
  suite. Notices (`alerts_silenced`) take no window and are raised either way.

  `config :kiln_cms, KilnCMS.Security.Alerts, enabled: false` is the test
  suite's default, and only a test seam: a claim takes a row lock on its
  window (`KilnCMS.Security.AlertGate`), and two sandboxed tests that both
  mint an API key would otherwise wait on each other's uncommitted claim of
  the same platform window. A test about alerts turns it on, in an
  `async: false` module.
  """
  @spec enabled?() :: boolean()
  def enabled?,
    do: Keyword.get(Application.get_env(:kiln_cms, __MODULE__, []), :enabled, true) != false

  @doc "The kinds a site raises and its admins can turn off, in display order."
  @spec site_kinds() :: [kind()]
  def site_kinds, do: @site_kinds

  @doc """
  The kinds the platform raises, to every platform admin. Only
  `platform_optional_kinds/0` can be turned off.
  """
  @spec platform_kinds() :: [kind()]
  def platform_kinds, do: @platform_kinds

  @doc """
  The platform kinds a platform admin can turn off
  (`KilnCMS.Security.PlatformAlertSettings`), in display order.
  """
  @spec platform_optional_kinds() :: [kind()]
  def platform_optional_kinds, do: @platform_optional_kinds

  @doc "The changes an `alerts_silenced` notice can name."
  @spec notice_changes() :: [String.t()]
  def notice_changes, do: @notice_changes

  @doc """
  The webhook events a site's endpoint can subscribe to: `security.<kind>` for
  each site kind, and `security.alerts_silenced`. Platform kinds go by bell and
  email only.
  """
  @spec webhook_events() :: [String.t()]
  def webhook_events,
    do: Enum.map(@site_kinds, &"security.#{&1}") ++ ["security.alerts_silenced"]

  # The event types each kind can come from, for a summary's re-count of a
  # closed window. `failed_sign_ins` is counted on its tally instead.
  @kind_event_types %{
    new_admin: [:role_granted, :elevation_granted, :registration_approved],
    role_elevation: [:role_granted, :elevation_granted],
    lockout: [:sign_in_locked],
    two_factor_disabled: [:second_factor_removed],
    sso_config_changed: [:sso_config_changed],
    platform_role_changed: [:role_revoked],
    new_api_key: [:api_key_created],
    api_key_abuse: [:api_key_reuse_detected],
    api_key_rate_limited: [:api_key_rate_limited],
    blocked_ip: [:ip_block_refused]
  }

  @doc """
  The event types `kind` can be raised by, for a summary to re-classify a
  closed window's events (`classify/2` decides which of them count). `[]`
  for `failed_sign_ins`, which is counted on its tally.
  """
  @spec event_types(kind()) :: [atom()]
  def event_types(kind), do: Map.get(@kind_event_types, kind, [])

  @doc """
  The alert kind a dispatch row names, as an atom: one of `site_kinds/0` or
  `platform_kinds/0`, else `nil` (a kind a newer release wrote).
  """
  @spec kind(String.t() | atom()) :: kind() | nil
  def kind(name) do
    name = to_string(name)
    Enum.find(Enum.uniq(@site_kinds ++ @platform_kinds), &(Atom.to_string(&1) == name))
  end

  @doc "The kinds a site with no settings row has turned off: `failed_sign_ins`."
  @spec default_disabled_kinds() :: [String.t()]
  def default_disabled_kinds, do: @default_disabled

  @doc "How many failed sign-ins on one site in one window raise `failed_sign_ins`."
  @spec failed_sign_in_threshold() :: pos_integer()
  def failed_sign_in_threshold, do: @failed_sign_in_threshold

  @doc "The `KilnCMS.Accounts.ThrottleStore` bucket the failed-sign-in tally counts in."
  @spec failed_sign_in_bucket() :: String.t()
  def failed_sign_in_bucket, do: @failed_sign_in_bucket

  @doc """
  How many rows a site's failed-sign-in tally is spread over (#2639). Its
  keys are `KilnCMS.Accounts.ThrottleStore.sharded_keys(org_id, failed_sign_in_shards())`.
  """
  @spec failed_sign_in_shards() :: pos_integer()
  def failed_sign_in_shards, do: @failed_sign_in_shards

  @doc """
  The total of `org_id`'s failed-sign-in tally in window `window_index`,
  current or closed, over every shard and the unsharded key a node of the
  previous release counts on. `nil` when there is none or it cannot be read:
  never read that as zero.
  """
  @spec failed_sign_in_total(Ash.UUID.t(), integer()) :: non_neg_integer() | nil
  def failed_sign_in_total(org_id, window_index) when is_binary(org_id),
    do:
      ThrottleStore.window_sum(
        @failed_sign_in_bucket,
        ThrottleStore.sharded_keys(org_id, @failed_sign_in_shards),
        window_index
      )

  @doc """
  The length of an alert window, in milliseconds: 15 minutes. One alert per
  kind per window; the rest of the window is one summary. Windows are aligned
  to the database clock (`floor(epoch_ms / window_ms)`), shared by the
  failed-sign-in tally and `KilnCMS.Security.AlertGate`.

  Set by `config :kiln_cms, :security_alert_window_ms` for tests only.
  """
  @spec window_ms() :: pos_integer()
  def window_ms, do: Application.get_env(:kiln_cms, :security_alert_window_ms, @default_window_ms)

  @doc """
  The alerts and notices `event` raises. Pure.

  `context` is the recording changeset's context: a failed sign-in raises
  `failed_sign_ins` only when it carries the threshold flag
  `security_alert: {:threshold, window_index, count}` (set by the recorder on
  the one event that crossed the threshold), never on its own.
  """
  @spec classify(map(), map()) :: [classification()]
  def classify(%{type: type} = event, context \\ %{}) do
    metadata = Map.get(event, :metadata) || %{}
    do_classify(type, metadata, event, context || %{})
  end

  defp do_classify(type, metadata, _event, _context)
       when type in [:role_granted, :elevation_granted] do
    role = meta(metadata, "role")

    cond do
      meta(metadata, "via") == "legacy_carry" -> []
      role == "admin" -> [{:new_admin, level_channel(metadata)}]
      # A platform role raised short of admin is no site's business: the
      # event's tenant is whichever site the platform admin was browsing, and
      # the platform kinds have no role elevation of their own.
      level_channel(metadata) == :platform -> []
      type == :elevation_granted and role != nil -> [{:role_elevation, :site}]
      meta(metadata, "previous_role") != nil -> [{:role_elevation, :site}]
      true -> []
    end
  end

  defp do_classify(:registration_approved, metadata, _event, _context) do
    if meta(metadata, "role") == "admin", do: [{:new_admin, :site}], else: []
  end

  defp do_classify(:role_revoked, metadata, event, _context) do
    cond do
      meta(metadata, "role") != "admin" -> []
      level_channel(metadata) == :platform -> [{:platform_role_changed, :platform}]
      notice = admin_loss_notice(metadata, event) -> [{:alerts_silenced, :notice, notice}]
      true -> []
    end
  end

  defp do_classify(:sign_in_failed, _metadata, _event, context) do
    case Map.get(context, :security_alert) do
      {:threshold, _window_index, _count} -> [{:failed_sign_ins, :site}]
      _none -> []
    end
  end

  defp do_classify(:sign_in_locked, _metadata, _event, _context), do: [{:lockout, :site}]

  defp do_classify(:second_factor_removed, metadata, _event, _context) do
    # An invitee taking an account over drops the previous holder's factor
    # (#2453): not the account's owner turning their protection off.
    if meta(metadata, "via") == "invitation", do: [], else: [{:two_factor_disabled, :site}]
  end

  defp do_classify(:sso_config_changed, _metadata, _event, _context),
    do: [{:sso_config_changed, :site}]

  defp do_classify(:api_key_created, metadata, _event, _context) do
    if meta(metadata, "via") == "rotate", do: [], else: [{:new_api_key, :platform}]
  end

  defp do_classify(:api_key_reuse_detected, _metadata, _event, _context),
    do: [{:api_key_abuse, :platform}]

  defp do_classify(:api_key_rate_limited, _metadata, _event, _context),
    do: [{:api_key_rate_limited, :platform}]

  defp do_classify(:ip_block_refused, _metadata, _event, _context),
    do: [{:blocked_ip, :site}]

  defp do_classify(:org_setting_changed, metadata, _event, _context) do
    if meta(metadata, "setting") == "site_mail_relay",
      do: [{:alerts_silenced, :notice, "mail_relay_changed"}],
      else: []
  end

  defp do_classify(_type, _metadata, _event, _context), do: []

  # Another person taking a site admin's power away: the admins who are left
  # hear of it, since a removed admin no longer gets the site's alerts. Not a
  # self-demotion, and not a change with nobody behind it.
  defp admin_loss_notice(metadata, event) do
    actor_id = Map.get(event, :actor_id)

    if actor_id != nil and actor_id != Map.get(event, :target_id) do
      case meta(metadata, "change") do
        "removed" -> "admin_removed"
        "demoted" -> "admin_demoted"
        "grant_revoked" -> "admin_grant_revoked"
        _other -> nil
      end
    end
  end

  defp level_channel(metadata) do
    if meta(metadata, "level") == "platform", do: :platform, else: :site
  end

  # Metadata is string-keyed with scalar values once sanitized; an atom value
  # (an unsanitized changeset attribute) reads the same.
  defp meta(metadata, key) do
    case Map.get(metadata, key) do
      nil -> nil
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end
  end

  @doc """
  A site's alert settings: its `KilnCMS.CMS.SiteSecurityAlerts` row, or the
  defaults (every kind but `failed_sign_ins` on, bell and email on, addresses
  masked).

  Read uncached as `KilnCMS.OrgSettings.system(:security_alerts)` with
  `authorize_with: :error`. A row that cannot be read is logged and answered
  with `unreadable_settings/0` — every kind on, `failed_sign_ins` included,
  addresses masked: the direction that still alerts and still masks. The
  failed-sign-in tally counts on the same fallback, so an alert it claimed is
  still delivered.
  """
  @spec settings_for(Ash.UUID.t() | struct() | nil) :: settings()
  def settings_for(org) do
    case read_settings(org) do
      {:ok, settings} -> settings
      :error -> unreadable_settings()
    end
  end

  @doc """
  A site's alert settings as `settings_for/1` reads them, but able to say it
  could not: `{:ok, settings}`, or `:error` when the row cannot be read
  (logged). For a reader that must not mistake `unreadable_settings/0` for
  the site's choice — the security posture report (#2640).
  """
  @spec read_settings(Ash.UUID.t() | struct() | nil) :: {:ok, settings()} | :error
  def read_settings(org) do
    case KilnCMS.OrgSettings.resolve_uncached(Accounts.org_id(org), settings_opts()) do
      nil -> :error
      settings -> {:ok, settings}
    end
  end

  @doc "The settings a site without a row has."
  @spec defaults() :: settings()
  def defaults,
    do: %{disabled_kinds: @default_disabled, notify_admins: true, include_full_ip: false}

  @doc """
  The settings a site whose row cannot be read is treated as having: every
  kind on, bell and email on, addresses masked.
  """
  @spec unreadable_settings() :: settings()
  def unreadable_settings, do: %{defaults() | disabled_kinds: []}

  @doc "Whether `kind` is on under `settings`."
  @spec enabled?(settings(), kind() | String.t()) :: boolean()
  def enabled?(%{disabled_kinds: disabled}, kind), do: to_string(kind) not in disabled

  defp settings_opts do
    actor = KilnCMS.OrgSettings.system(:security_alerts)

    [
      read:
        &KilnCMS.CMS.list_site_security_alerts(tenant: &1, actor: actor, authorize_with: :error),
      build: &build_settings/1,
      label: "security alert settings"
    ]
  end

  defp build_settings(nil), do: defaults()

  defp build_settings(row) do
    %{
      disabled_kinds: row.disabled_kinds || [],
      notify_admins: row.notify_admins,
      include_full_ip: row.include_full_ip
    }
  end

  @doc """
  The platform kinds turned off, as strings: the
  `KilnCMS.Security.PlatformAlertSettings` row's `disabled_kinds`, or `[]`
  when there is no row.

  Read uncached as `KilnCMS.Security.alerts_system/0` with
  `authorize_with: :error`, so a lost grant is an error rather than "no row".
  `{:error, error}` when it cannot be read; `platform_disabled_kinds/0` is
  the caller that falls back.
  """
  @spec fetch_platform_disabled_kinds() :: {:ok, [String.t()]} | {:error, term()}
  def fetch_platform_disabled_kinds do
    case KilnCMS.Security.list_platform_alert_settings(
           actor: KilnCMS.Security.alerts_system(),
           authorize_with: :error
         ) do
      {:ok, [row | _]} -> {:ok, row.disabled_kinds || []}
      {:ok, []} -> {:ok, []}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  `fetch_platform_disabled_kinds/0`, with a row that cannot be read logged and
  answered `[]`: every platform kind on, the direction that still alerts.
  """
  @spec platform_disabled_kinds() :: [String.t()]
  def platform_disabled_kinds do
    case fetch_platform_disabled_kinds() do
      {:ok, kinds} ->
        kinds

      {:error, error} ->
        Logger.warning(
          "Security alerts: the platform alert settings could not be read " <>
            "(#{error_kind(error)}); every platform kind is treated as on."
        )

        []
    end
  end

  defp error_kind(%{__struct__: struct}), do: inspect(struct)

  @doc """
  Whether the platform kind `kind` is on: always for a kind not in
  `platform_optional_kinds/0`, without a read; otherwise unless the platform's
  settings turned it off (`platform_disabled_kinds/0`).
  """
  @spec platform_enabled?(kind() | String.t()) :: boolean()
  def platform_enabled?(kind) do
    name = to_string(kind)

    if Enum.any?(@platform_optional_kinds, &(Atom.to_string(&1) == name)),
      do: name not in platform_disabled_kinds(),
      else: true
  end

  @doc """
  An address as an alert shows it: in full only when the site opted in
  (`include_full_ip`), its network otherwise (`KilnCMS.Security.Cidr.truncate/1`,
  a `/24` or `/48`). `nil` settings — a platform alert — always masks. The
  audit log itself keeps the full address.
  """
  @spec display_ip(String.t() | nil, settings() | nil) :: String.t() | nil
  def display_ip(nil, _settings), do: nil
  def display_ip(ip, %{include_full_ip: true}), do: ip
  def display_ip(ip, _settings), do: Cidr.truncate(ip)

  @doc """
  A block rule as an alert shows it, by the same rule as `display_ip/2`: in
  full only when the site opted in (`include_full_ip`), otherwise a rule
  narrower than a `/24` or `/48` is widened to it
  (`KilnCMS.Security.Cidr.truncate_range/1`), so a host rule does not name
  the host. `nil` settings always mask.
  """
  @spec display_rule(String.t() | nil, settings() | nil) :: String.t() | nil
  def display_rule(nil, _settings), do: nil
  def display_rule(rule, %{include_full_ip: true}), do: rule
  def display_rule(rule, _settings), do: Cidr.truncate_range(rule)

  @doc """
  An event's metadata as an alert carries it (webhooks, bell, mail): every
  value that names an address is masked by `display_rule/2`, the rest is
  carried as recorded. Today that is the `rule` of `:ip_block_refused`.
  """
  @spec display_metadata(atom() | String.t() | nil, map() | nil, settings() | nil) :: map()
  def display_metadata(_type, nil, _settings), do: %{}

  def display_metadata(_type, metadata, settings) when is_map(metadata) do
    case Map.fetch(metadata, "rule") do
      {:ok, rule} when is_binary(rule) ->
        Map.put(metadata, "rule", display_rule(rule, settings))

      {:ok, _not_text} ->
        Map.delete(metadata, "rule")

      :error ->
        metadata
    end
  end

  @doc """
  Count one failed sign-in on `org_id`'s tally (#2245), keyed on the site
  alone — never on the address or account tried, which an attacker chooses.

    * `{:threshold, window_index, count}` — the window's count has reached the
      threshold, and this is the first attempt on this node to see it: record
      it as the alert's event. `count` is the total this attempt saw, which
      can be past the threshold when attempts arrive together.
    * `:counted` — counted, below the threshold or already past it.
    * `:off` — the site has `failed_sign_ins` turned off, so nothing is counted.

  The tally is spread over `failed_sign_in_shards/0` rows
  (`KilnCMS.Accounts.ThrottleStore.count_sharded/5`, #2639), so a burst of
  failed sign-ins on one site does not queue on one row lock. Each attempt
  reads the total after its own increment committed, so at least one attempt
  sees `count >= threshold`; `KilnCMS.Security.AlertTrips` admits the first
  such attempt per node and window (once for the shared tally and once for
  this node's fallback, which a database outage counts on), and `KilnCMS.Security.AlertGate`'s claim
  keeps the alert to one across nodes.

  Whether the kind is on comes from a cached read of the site's settings; one
  that cannot be read counts (the direction that can still alert). Outside any
  transaction, as `KilnCMS.Accounts.ThrottleStore.count_sharded/5` requires.

  Options: `:window_ms` (default `window_ms/0`), and `:shard` (tests).
  """
  @spec charge_failed_sign_in(Ash.UUID.t(), keyword()) ::
          {:threshold, integer(), pos_integer()} | :counted | :off
  def charge_failed_sign_in(org_id, opts \\ []) when is_binary(org_id) do
    if failed_sign_ins_enabled?(org_id) do
      window_ms = Keyword.get(opts, :window_ms, window_ms())

      {count, window_index, source} =
        ThrottleStore.count_sharded(
          @failed_sign_in_bucket,
          org_id,
          window_ms,
          @failed_sign_in_shards,
          Keyword.take(opts, [:shard])
        )

      # The source is in the trip: a crossing counted only on this node's
      # fallback (the database down) must not use up the window's shared one,
      # or the database's crossing after it recovers would never be claimed.
      if count >= @failed_sign_in_threshold and
           AlertTrips.first?(
             {:failed_sign_ins, source, org_id, window_ms, window_index},
             window_ms
           ) do
        {:threshold, window_index, count}
      else
        :counted
      end
    else
      :off
    end
  end

  # Cached: this runs on every failed sign-in. Busted by every settings write
  # (`KilnCMS.CMS.Changes.SecurityAlertsChanged`); a read that fails is not
  # cached and counts.
  defp failed_sign_ins_enabled?(org_id) do
    settings =
      KilnCMS.OrgSettings.resolve(
        org_id,
        Keyword.merge(settings_opts(),
          cache_key: KilnCMS.Cache.security_alerts_key(org_id),
          ttl: :timer.minutes(5),
          fallback: &unreadable_settings/0
        )
      )

    enabled?(settings, :failed_sign_ins)
  end

  @doc """
  Who a site alert or notice goes to: the site's member admins
  (`KilnCMS.Accounts.Scoping.site_member_admins/1`), or, when the site has
  none, the platform admins — the only admins it has (OC-1/OC-2 on #2245,
  2026-11-10). A site with member admins never adds the platform admins.
  """
  @spec site_recipients(Ash.UUID.t() | struct() | nil) :: [struct()]
  def site_recipients(org) do
    case Scoping.site_member_admins(org) do
      [] -> Scoping.platform_admins()
      admins -> admins
    end
  end

  @doc "Whether the site has any member admins of its own (`site_recipients/1` falls back when not)."
  @spec member_admins?(Ash.UUID.t() | struct() | nil) :: boolean()
  def member_admins?(org), do: Scoping.site_member_admins(org) != []

  @doc "Who a platform alert goes to: every platform admin."
  @spec platform_recipients() :: [struct()]
  def platform_recipients, do: Scoping.platform_admins()

  @doc """
  Whether `user` is a member admin of any site — someone site alerts reach,
  and so someone the mute (`User.notify_on_security_alert`) means anything
  to. `false` for a platform admin, whose alerts are the platform's.
  """
  @spec member_admin_anywhere?(map() | nil) :: boolean()
  def member_admin_anywhere?(%{id: user_id} = user) when is_binary(user_id) do
    if RoleGrant.effective_role(user) == :admin do
      false
    else
      admin = RoleGrant.expression([:admin])

      query =
        Ash.Query.filter(
          Accounts.User,
          id == ^user_id and exists(org_memberships, status == :active and ^admin)
        )

      # authorize?: false — reads the caller's own memberships for a yes/no,
      # returning no row to anyone; OrgMembership's read policy needs a tenant.
      Accounts.list_users!(authorize?: false, query: query) != []
    end
  end

  def member_admin_anywhere?(_user), do: false
end
