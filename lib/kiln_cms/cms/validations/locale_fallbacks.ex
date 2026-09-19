defmodule KilnCMS.CMS.Validations.LocaleFallbacks do
  @moduledoc """
  Validates a `SiteLocaleSettings.fallbacks` map: every key and every chain
  entry is a locale the deployment runs (`KilnCMS.I18n.locales/0`), no chain
  names its own locale or repeats one, and each chain is a list.

  Held at write time so the editor is told about a typo (`fr_CA`) when they
  make it, rather than the chain silently skipping the entry on every request.
  `KilnCMS.I18n.Fallback` still drops unsupported entries at read time, for a
  locale an operator removes after the row was written.
  """
  use Ash.Resource.Validation

  alias KilnCMS.I18n

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :fallbacks) do
      # "Inherit the operator default" — a state, not an empty map.
      nil -> :ok
      fallbacks when is_map(fallbacks) -> fallbacks |> Enum.sort() |> check()
      _other -> error("must be a map of locale to a list of locales")
    end
  end

  @impl true
  def describe(_opts), do: [message: "must map supported locales to supported locales", vars: []]

  defp check([]), do: :ok

  defp check([{locale, chain} | rest]) do
    cond do
      not (is_binary(locale) and I18n.supported?(locale)) ->
        error("#{inspect(locale)} is not a locale this site runs")

      not (is_list(chain) and Enum.all?(chain, &is_binary/1)) ->
        error("the chain for #{locale} must be a list of locales")

      unsupported = Enum.find(chain, &(not I18n.supported?(&1))) ->
        error(
          "#{inspect(unsupported)} (in the chain for #{locale}) is not a locale this site runs"
        )

      locale in chain ->
        error("the chain for #{locale} names #{locale} itself")

      Enum.uniq(chain) != chain ->
        error("the chain for #{locale} names a locale twice")

      true ->
        check(rest)
    end
  end

  defp error(message),
    do:
      {:error, Ash.Error.Changes.InvalidAttribute.exception(field: :fallbacks, message: message)}
end
