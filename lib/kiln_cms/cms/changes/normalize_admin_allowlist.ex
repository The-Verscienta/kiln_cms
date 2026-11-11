defmodule KilnCMS.CMS.Changes.NormalizeAdminAllowlist do
  @moduledoc """
  One stored spelling per entry of a `KilnCMS.CMS.SiteAdminAllowlist` (#2248):
  each through `KilnCMS.Security.Cidr.allowable/1` (masked, compressed, mapped
  IPv4 folded), blanks dropped, duplicates dropped in order, at most
  `SiteAdminAllowlist.max_entries/0`.

  An entry that is not allowed is an error on `:cidrs` naming the text it was
  given — never anything else's. The messages are fixed English strings,
  matched by `KilnCMSWeb.AdminAllowlistLive` to translated ones.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.SiteAdminAllowlist
  alias KilnCMS.Security.Cidr

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :cidrs) do
      normalise(changeset, Ash.Changeset.get_attribute(changeset, :cidrs) || [])
    else
      changeset
    end
  end

  defp normalise(changeset, entries) do
    {normalised, errors} =
      entries
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce({[], []}, fn entry, {ok, errors} ->
        case Cidr.allowable(entry) do
          {:ok, cidr} -> {[cidr | ok], errors}
          {:error, reason} -> {ok, [{entry, reason} | errors]}
        end
      end)

    normalised = normalised |> Enum.reverse() |> Enum.uniq()

    cond do
      errors != [] ->
        errors
        |> Enum.reverse()
        |> Enum.reduce(changeset, fn {entry, reason}, changeset ->
          Ash.Changeset.add_error(
            changeset,
            invalid(message: message(reason), vars: [entry: entry])
          )
        end)

      length(normalised) > SiteAdminAllowlist.max_entries() ->
        Ash.Changeset.add_error(
          changeset,
          invalid(
            message: "at most %{max} entries",
            vars: [max: SiteAdminAllowlist.max_entries()]
          )
        )

      true ->
        Ash.Changeset.force_change_attribute(changeset, :cidrs, normalised)
    end
  end

  # Built as the struct: `add_error/2` given a keyword list files its `vars:`
  # one level down, under `vars`.
  defp invalid(opts), do: Ash.Error.Changes.InvalidAttribute.exception([field: :cidrs] ++ opts)

  defp message(:invalid), do: "%{entry} is not an IP address or range"
  defp message(:too_broad), do: "%{entry} is too broad"
  defp message(:loopback), do: "%{entry} includes loopback"
end
