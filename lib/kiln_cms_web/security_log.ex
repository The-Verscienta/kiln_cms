defmodule KilnCMSWeb.SecurityLog do
  @moduledoc """
  What the security log page (`KilnCMSWeb.SecurityLogLive`) and its CSV
  download (`KilnCMSWeb.SecurityLogExportController`) share (#2241): reading
  the filter params, resolving them to `Security.list_events` arguments, and
  the display labels.

  ## Filters

  `type`, `actor` (an email address), `from` and `to` (`YYYY-MM-DD`, UTC, both
  days included). Anything malformed is dropped rather than raised on: the
  params are a URL a person can edit.

  ## The actor filter is not a user search

  The address is matched, case-insensitively, against the **actor labels in
  this site's own log**, read as the signed-in admin in this site's tenant. So
  it only ever resolves an address the admin could already read in a row. An
  address with no such row is reported as "no such member" and the log is shown
  empty; it never falls back to an unfiltered list and never looks at the
  accounts table or another site, so the field cannot be used to learn who
  exists. A person with no recorded event cannot be filtered on (there would be
  nothing to show), and one whose account was erased has no label left.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  require Ash.Query

  alias KilnCMS.Security.Event
  alias KilnCMS.Types.UnknownAtom

  @type filters :: %{
          required(String.t()) => String.t()
        }

  @keys ~w(type actor from to)

  @doc "The filter params this page understands, as a string-keyed map of non-blank strings."
  @spec parse(map()) :: filters()
  def parse(params) when is_map(params) do
    params
    |> Map.take(@keys)
    |> Enum.flat_map(fn
      {key, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> []
          trimmed -> [{key, String.slice(trimmed, 0, 254)}]
        end

      _other ->
        []
    end)
    |> Map.new()
    |> drop_invalid()
  end

  def parse(_params), do: %{}

  defp drop_invalid(filters) do
    filters
    |> then(fn f ->
      if f["type"] && is_nil(type(f["type"])), do: Map.delete(f, "type"), else: f
    end)
    |> then(fn f ->
      if f["from"] && is_nil(date(f["from"])), do: Map.delete(f, "from"), else: f
    end)
    |> then(fn f -> if f["to"] && is_nil(date(f["to"])), do: Map.delete(f, "to"), else: f end)
  end

  @doc """
  The `Security.list_events` arguments for `filters`, as `org`'s admin `actor`.

  `{:ok, args}`, or `:no_such_actor` when the actor filter names nobody on
  this site (see the moduledoc).
  """
  @spec arguments(filters(), map(), map()) :: {:ok, map()} | :no_such_actor
  def arguments(filters, actor, org) do
    base =
      %{}
      |> put(:type, type(filters["type"]))
      |> put(:since, filters["from"] |> date() |> start_of_day())
      |> put(:until, filters["to"] |> date() |> end_of_day())

    case filters["actor"] do
      nil ->
        {:ok, base}

      email ->
        case actor_id(email, actor, org) do
          nil -> :no_such_actor
          id -> {:ok, Map.put(base, :actor_id, id)}
        end
    end
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  # Matched against the known list: never `String.to_atom/1` on a URL.
  defp type(value) when is_binary(value),
    do: Enum.find(Event.types(), &(Atom.to_string(&1) == value))

  defp type(_value), do: nil

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _invalid -> nil
    end
  end

  defp date(_value), do: nil

  defp start_of_day(nil), do: nil
  defp start_of_day(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")
  defp end_of_day(nil), do: nil
  defp end_of_day(%Date{} = date), do: DateTime.new!(date, ~T[23:59:59.999999], "Etc/UTC")

  # Looked up in the log itself, as the admin and in this site's tenant: the
  # only addresses that resolve are ones already in rows this admin may read.
  # (An org admin cannot list a site's memberships - that read is the platform
  # operator's - and `Accounts` has no per-site user search to reuse.)
  defp actor_id(email, actor, org) do
    wanted = String.downcase(email)

    Event
    |> Ash.Query.filter(not is_nil(actor_id) and string_downcase(actor_label) == ^wanted)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:actor_id])
    |> Ash.read!(actor: actor, tenant: org, authorize_with: :error)
    |> case do
      [%{actor_id: id}] -> id
      [] -> nil
    end
  end

  @doc """
  The label for an event type. A type this release does not know (one a newer
  release recorded, #2509) is labeled with its stored name.
  """
  @spec type_label(atom() | UnknownAtom.t()) :: String.t()
  def type_label(:sign_in), do: gettext("Sign-in")
  def type_label(:sign_in_failed), do: gettext("Failed sign-in")
  def type_label(:sign_in_locked), do: gettext("Sign-in locked out")
  def type_label(:second_factor_enrolled), do: gettext("Second factor added")
  def type_label(:second_factor_removed), do: gettext("Second factor removed")
  def type_label(:recovery_code_used), do: gettext("Recovery code used")
  def type_label(:passkey_added), do: gettext("Passkey added")
  def type_label(:passkey_removed), do: gettext("Passkey removed")
  def type_label(:role_granted), do: gettext("Role granted")
  def type_label(:role_revoked), do: gettext("Role revoked")
  def type_label(:member_invited), do: gettext("Member invited")
  def type_label(:invitation_revoked), do: gettext("Invitation revoked")
  def type_label(:elevation_granted), do: gettext("Temporary elevation granted")
  def type_label(:api_key_created), do: gettext("API key created")
  def type_label(:api_key_revoked), do: gettext("API key revoked")
  def type_label(:sso_config_changed), do: gettext("Single sign-on changed")
  def type_label(:org_setting_changed), do: gettext("Site setting changed")
  def type_label(:ip_auto_blocked), do: gettext("Address blocked automatically")
  def type_label(:session_idle_expired), do: gettext("Signed out after inactivity")
  def type_label(:all_sessions_revoked), do: gettext("Everyone signed out")
  def type_label(:admin_access_refused), do: gettext("Refused outside the admin allowlist")
  def type_label(:admin_allowlist_changed), do: gettext("Admin allowlist changed")

  def type_label(:admin_allowlist_overridden),
    do: gettext("Admin allowlist changed from the server")

  def type_label(:sign_in_unlock_requested), do: gettext("Sign-in unlock link sent")
  def type_label(:sign_in_unlocked), do: gettext("Sign-in pause lifted by email")
  def type_label(:sign_in_unlock_refused), do: gettext("Sign-in unlock link refused")
  def type_label(:registration_queued), do: gettext("Registration awaiting approval")
  def type_label(:registration_approved), do: gettext("Registration approved")
  def type_label(:registration_rejected), do: gettext("Registration rejected")
  def type_label(:backup_canceled), do: gettext("Backup canceled")

  def type_label(%UnknownAtom{value: value}),
    do: gettext("Unrecognized event (%{type})", type: value)

  def type_label(other), do: to_string(other)

  @doc "`{label, value}` options for the type filter, in `Event.types/0` order."
  @spec type_options() :: [{String.t(), String.t()}]
  def type_options, do: Enum.map(Event.types(), &{type_label(&1), Atom.to_string(&1)})
end
