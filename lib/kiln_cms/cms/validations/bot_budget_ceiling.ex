defmodule KilnCMS.CMS.Validations.BotBudgetCeiling do
  @moduledoc """
  Refuses a `SiteBotBudgets` value above the operator's (#2243): the operator
  owns delivery capacity, and a site may only tighten it.

  The `KilnCMS.CMS.Validations.EmbedCeiling` shape: only a column the changeset
  is **changing** is checked, so a row written before the operator lowered
  their value can still be saved for its other columns. `KilnCMS.BotBudgets`
  clamps the stored value at read time either way, so the stale value is not
  a live widening in the meantime.

  Unlike the embed ceiling, the message names the operator's value: it is one
  number per class for the whole deployment, not a list that would tell one
  site about another's partners.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.BotBudgets

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    errors =
      BotBudgets.fields()
      |> Enum.filter(fn {_class, field} ->
        Ash.Changeset.changing_attribute?(changeset, field)
      end)
      |> Enum.flat_map(&over_ceiling(changeset, &1))

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  # `nil` is "inherit", which is never above anything.
  defp over_ceiling(changeset, {class, field}) do
    value = Ash.Changeset.get_attribute(changeset, field)
    ceiling = BotBudgets.operator_percent(class)

    if is_integer(value) and value > ceiling do
      [
        Ash.Error.Changes.InvalidAttribute.exception(
          field: field,
          message:
            dgettext(
              "errors",
              "may not be more than %{ceiling}%: this server's operator caps it there. Ask them to raise it, or choose a lower value.",
              ceiling: ceiling
            )
        )
      ]
    else
      []
    end
  end

  @impl true
  def describe(_opts),
    do: [message: "must not exceed the operator's ceiling for this class", vars: []]
end
