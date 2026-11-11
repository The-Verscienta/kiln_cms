defmodule KilnCMS.CMS.Preparations.RegisteredFieldTypes do
  @moduledoc """
  Leaves out of every `FieldDefinition` read the rows whose `field_type` this
  release does not register (#2605): `FieldDefinition.unknown_type?/1`.

  Such a row is written by a newer release and read by an older one (a
  rollback), or names a plugin type whose plugin was removed. Its type loads
  as a `KilnCMS.Types.UnknownAtom` (the column is a `KilnCMS.Types.KnownAtom`),
  and nothing downstream — coercion, the editor, filters, fired delivery,
  the schema export — has a clause for it. So the field is skipped as if it
  were not there, in SQL, on every read action and every relationship load.

  The values stay where they are, and stay readable where a record's stored
  map is served as stored (the content API's raw stored values, a
  point-in-time replay), unless the field is private. The few readers that
  must see the row pass `context: FieldDefinition.all_types_context()` and
  handle it themselves:

    * `Changes.ApplyCustomFields` keeps its stored values on every write
      ("held" values), so saving a record does not erase them;
    * `KilnCMS.CMS.PrivateFields` still masks a private one;
    * the Fields screen lists such rows apart, with a delete.

  Only the read's own (top-level) context counts, not `shared`: the
  `link_fields` and `group_fields` it loads stay filtered.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    case query.context do
      %{field_types: :all} ->
        query

      _registered_only ->
        names = KilnCMS.CMS.FieldTypes.names()
        Ash.Query.filter(query, field_type in ^names)
    end
  end
end
