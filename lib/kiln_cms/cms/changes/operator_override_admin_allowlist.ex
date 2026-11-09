defmodule KilnCMS.CMS.Changes.OperatorOverrideAdminAllowlist do
  @moduledoc """
  The operator's way back in when an admin allowlist has locked a site's
  admins out (#2248): `SiteAdminAllowlist`'s `operator_override`, run by
  `KilnCMS.Release.admin_allowlist/1`.

  Exactly one of the two arguments:

    * `clear: true` empties the list (turns it off);
    * `add: "<address or range>"` appends one entry, normalised as a save
      normalises (`Cidr.allowable/1`), to a list that is **on**. Adding to a
      list that is off is refused: it would turn the list on from a shell and
      lock out every admin who is not on the one network named.

  So the override can only widen or empty a list, never narrow it, and cannot
  lock anyone out.

  It records `admin_allowlist_overridden` in its own transaction — `change` is
  `cleared` or `added`, `count` the entries after — with no actor (the server
  did it) and the site as the target. If the event cannot be written, the list
  does not change.
  """
  use Ash.Resource.Change

  alias KilnCMS.Security.Cidr
  alias KilnCMS.Security.Recorder

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      current = changeset.data.cidrs || []
      add = Ash.Changeset.get_argument(changeset, :add)
      clear? = Ash.Changeset.get_argument(changeset, :clear) == true

      case override(current, add, clear?) do
        {:ok, change, cidrs} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:cidrs, cidrs)
          |> Ash.Changeset.after_action(&record(&1, &2, change))

        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :add, message: message)
      end
    end)
  end

  defp override(_current, add, true) when is_binary(add),
    do: {:error, "give add: or clear: true, not both"}

  defp override(_current, _add, true), do: {:ok, "cleared", []}

  defp override(_current, nil, false),
    do: {:error, "give add: \"<address or range>\" or clear: true"}

  defp override([], _add, false),
    do:
      {:error,
       "the admin allowlist is off on this site; adding would turn it on. Use the console."}

  defp override(current, add, false) do
    case Cidr.allowable(add) do
      {:ok, cidr} -> add_entry(current, cidr)
      {:error, :invalid} -> {:error, "#{inspect(add)} is not an IP address or range"}
      {:error, :too_broad} -> {:error, "#{inspect(add)} is too broad"}
      {:error, :loopback} -> {:error, "#{inspect(add)} includes loopback"}
    end
  end

  # An entry already listed changes nothing, so it is refused rather than
  # recorded as an addition; the cap is the one a save enforces.
  defp add_entry(current, cidr) do
    cond do
      cidr in current ->
        {:error, "#{cidr} is already on the admin allowlist"}

      length(current) >= KilnCMS.CMS.SiteAdminAllowlist.max_entries() ->
        {:error,
         "the admin allowlist already holds #{KilnCMS.CMS.SiteAdminAllowlist.max_entries()} entries"}

      true ->
        {:ok, "added", current ++ [cidr]}
    end
  end

  defp record(_changeset, record, change) do
    case Recorder.record(:admin_allowlist_overridden,
           tenant: record.org_id,
           target_type: "organization",
           target_id: record.org_id,
           metadata: %{"change" => change, "count" => length(record.cidrs)}
         ) do
      {:error, error} -> {:error, error}
      _ok -> {:ok, record}
    end
  end
end
