defmodule KilnCMS.CMS.Validations.UniqueFieldClean do
  @moduledoc """
  Refuses to turn `unique` on (#2276) for a field whose existing values
  already repeat.

  Uniqueness is enforced on write (`KilnCMS.CMS.UniqueValues`), so a repeated
  value already in the data would make every later edit of one of its records
  fail with a message about a record the editor cannot find. The probe counts
  the values live records share — scoped like the runtime check (organization,
  table or dynamic type, locale; trashed records ignored) — and reports how
  many, with a few examples, so the admin can make them distinct first.

  It runs only when `unique` is being switched on; a definition that is
  already unique keeps saving whatever the data holds. Fields on a type with
  no readable resource (an orphaned stored type) have nothing to probe.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldConstraints
  alias KilnCMS.CMS.UniqueValues

  @samples 3

  @impl true
  def validate(changeset, _opts, _context) do
    if turning_on?(changeset) do
      case scope(changeset) do
        nil -> :ok
        scope -> report(UniqueValues.duplicates(scope, name(changeset), @samples))
      end
    else
      :ok
    end
  end

  defp turning_on?(changeset) do
    now = FieldConstraints.unique?(Ash.Changeset.get_attribute(changeset, :validation))

    was =
      changeset.action_type == :update and FieldConstraints.unique?(changeset.data.validation)

    now and not was and is_binary(name(changeset))
  end

  defp name(changeset), do: Ash.Changeset.get_attribute(changeset, :name)

  defp scope(changeset) do
    org_id = Ash.Changeset.get_attribute(changeset, :org_id) || changeset.to_tenant
    type_id = Ash.Changeset.get_attribute(changeset, :type_definition_id)
    content_type = Ash.Changeset.get_attribute(changeset, :content_type)

    cond do
      is_nil(org_id) ->
        nil

      type_id ->
        %{resource: KilnCMS.CMS.Entry, org_id: org_id, type_definition_id: type_id}

      is_atom(content_type) and not is_nil(content_type) ->
        case ContentTypes.get(content_type) do
          %{resource: resource} when not is_nil(resource) ->
            %{resource: resource, org_id: org_id}

          _other ->
            nil
        end

      true ->
        nil
    end
  end

  defp report(%{groups: 0}), do: :ok

  defp report(%{groups: groups, samples: samples}) do
    {:error,
     InvalidAttribute.exception(
       field: :validation,
       message:
         dngettext(
           "errors",
           "can't require unique values yet: %{count} value is shared by several records (%{samples}). Make them distinct first",
           "can't require unique values yet: %{count} values are shared by several records (%{samples}). Make them distinct first",
           groups,
           count: groups,
           samples: Enum.map_join(samples, ", ", &sample/1)
         )
     )}
  end

  defp sample(%{value: value, count: count, locale: locale}) do
    shown = value |> display() |> String.slice(0, 40)
    "#{shown} ×#{count}#{if locale, do: " [#{locale}]"}"
  end

  defp display(value) when is_binary(value), do: inspect(value)
  defp display(value), do: Jason.encode!(value)
end
