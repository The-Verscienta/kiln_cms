defmodule KilnCMS.CMS.Validations.SectionCarried do
  @moduledoc """
  Refuses a `KilnCMS.CMS.FieldSection` for a section no top-level field of
  its owner is filed under (#3061).

  A section exists only while some field carries its name, and a layout
  nothing carries is not harmless: the next field filed under that name
  inherits it. Every field write already prunes the layouts it leaves empty
  (`KilnCMS.CMS.Changes.KeepSectionLayouts`); this closes the other door, a
  direct create through the code interface, iex or AshAdmin. The update
  accepts neither the owner nor the name, so only the create checks.

  ## Checked under a lock, inside the write

  The resource runs this with `before_action?: true`: after authorization,
  so a caller the create's policy refuses gets `Ash.Error.Forbidden` and
  reads nothing, and inside the create's own transaction. The carrying field
  is read there `FOR SHARE` (`KilnCMS.CMS.SectionLayouts.carrier?/3`) and
  stays locked until the create commits. A write that moves that field out
  of the section takes it `FOR UPDATE` first (`KeepSectionLayouts`), so it
  waits, and its prune then sees the new layout and drops it. Without the
  lock the move's prune could run before the create committed, and the new
  row would be left with nothing to lay out.

  A field of a type this release does not register (#2605) still carries
  its section, as everywhere else in `SectionLayouts`.

  The read runs as the caller and fails closed: a read the caller may not
  make refuses the create as `Ash.Error.Forbidden`, and any other failed read
  refuses it as uncheckable. Neither lets a row through unchecked.

  A missing, doubled or unknown owner is left to the resource's other
  validations, which report it; this one then reads nothing.

  ## Messages are gettext'd (#3074)

  As in `KilnCMS.CMS.Validations.ReleaseOpenForEdit`: translated in the
  caller's locale, the default `en` text for a caller with none.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.SectionLayouts

  @impl true
  def validate(changeset, _opts, context) do
    with owner when not is_nil(owner) <- owner(changeset),
         name when is_binary(name) <- Ash.Changeset.get_attribute(changeset, :name) do
      check(owner, name, changeset, context)
    else
      _ -> :ok
    end
  end

  defp check(owner, name, changeset, context) do
    case SectionLayouts.carrier?(owner, name, read_opts(changeset, context)) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        error(name, gettext("is not a section any top-level field of this type is in"))

      # Refused to this caller: refused, as the action's own policy would.
      {:error, %Ash.Error.Forbidden{} = forbidden} ->
        {:error, forbidden}

      {:error, _error} ->
        error(name, gettext("could not be checked against the type's fields"))
    end
  end

  defp error(name, message),
    do: {:error, InvalidAttribute.exception(field: :name, message: message, value: name)}

  # Exactly one owner, and a compiled one this release registers; anything
  # else is the other validations' to report.
  defp owner(changeset) do
    type = Ash.Changeset.get_attribute(changeset, :content_type)
    definition = Ash.Changeset.get_attribute(changeset, :type_definition_id)

    cond do
      not is_nil(type) and not is_nil(definition) -> nil
      not is_nil(definition) -> {:dynamic, definition}
      is_atom(type) and not is_nil(type) and ContentTypes.type?(type) -> {:compiled, type}
      true -> nil
    end
  end

  # As the caller, in the row's org. Without a tenant (a non-strict build's
  # global write) the row's own org is where its fields are.
  defp read_opts(changeset, context) do
    context
    |> Ash.Context.to_opts()
    |> Keyword.take([:actor, :authorize?, :tracer])
    |> Keyword.put(:tenant, changeset.tenant || Ash.Changeset.get_attribute(changeset, :org_id))
  end
end
