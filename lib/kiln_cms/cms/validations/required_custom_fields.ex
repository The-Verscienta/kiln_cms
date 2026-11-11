defmodule KilnCMS.CMS.Validations.RequiredCustomFields do
  @moduledoc """
  Refuses a publish while a required custom field is blank.

  `KilnCMS.CMS.Changes.ApplyCustomFields` enforces `required` on every write
  that names `custom_fields`, which is not every way a document reaches a
  publish: the content editor's scaffold create defers `required` so a type
  with a required, default-less field can be started at all, a write that
  only changes the title never runs the editable pass, and a draft can be
  given a publish date the moment it is created (the calendar's "new on this
  day"). So `:publish` and `:publish_scheduled` ask once more, against the
  values the publish would make live.

  Runs as a `before_action`, after `ApplyCustomFields` has refreshed the
  computed fields and stashed the definitions it read.
  """
  use Ash.Resource.Validation

  alias KilnCMS.CMS.Changes.ApplyCustomFields

  @impl true
  def validate(changeset, _opts, _context) do
    case ApplyCustomFields.missing_required(changeset) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end
end
