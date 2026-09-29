defmodule KilnCMS.CMS.Validations.ReleaseContentExists do
  @moduledoc """
  Refuses to add an item to a release unless `content_type` + `content_id`
  resolve to a real record right now (#500 follow-up).

  Go-live walks every pending item inside ONE transaction and rolls back the
  entire release the moment a single item's record can't be found
  (`Releases.fetch_record/2` returns `"content no longer exists"`, which
  `Releases.apply_all/4` turns into `Repo.rollback/1`). Without this check, a
  stale or bogus `content_id` — belonging to a record since hard-deleted, or one
  that never existed — sits `:pending` unnoticed until the whole release fires,
  aborting every other admin-approved item along with it. Refusing the add is
  cheap; refusing go-live for the entire bundle is not.

  Runs after `KilnCMS.CMS.Validations.KnownContentType`: an unknown
  `content_type` fails there, so this only resolves the id once the type itself
  is real, and stays silent (not this validation's job) otherwise.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Validations.Lookup

  @impl true
  def validate(changeset, _opts, context) do
    content_type = Ash.Changeset.get_attribute(changeset, :content_type)
    content_id = Ash.Changeset.get_attribute(changeset, :content_id)

    if content_type in [nil, ""] or content_id in [nil, ""] or
         not ContentTypes.type?(content_type) do
      :ok
    else
      check(content_type, content_id, changeset.tenant, context)
    end
  end

  # As the caller (#1659): adding to a release needs `OrgEditor`, which reads
  # every document in the org, draft or published — unless a type scope (#332)
  # withholds the type, which `EditableReleaseContent` reports on its own. A record
  # the caller may not read is refused like one that does not exist, never
  # taken as existing; answering it as an ordinary invalid write (not a
  # Forbidden) keeps a scoped editor's error what it was, and says nothing
  # about whether the record is there.
  defp check(content_type, content_id, tenant, context) do
    case ContentTypes.get_record(content_type, content_id, Lookup.as_caller(context, tenant)) do
      {:ok, %{} = _record} -> :ok
      _missing_or_refused -> refuse(content_id)
    end
  rescue
    # The type resolved in the guard above, but the registry can still race a
    # retirement between that check and this call.
    _error -> refuse(content_id)
  end

  defp refuse(content_id) do
    {:error,
     InvalidAttribute.exception(
       field: :content_id,
       message: "does not resolve to an existing record",
       value: content_id
     )}
  end
end
