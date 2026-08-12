defmodule KilnCMSWeb.AshSortErrors do
  @moduledoc """
  `Ash.Error.Query.UnsortableField` is not implemented for
  `AshJsonApi.ToJsonApiError` upstream, so without the impl below JSON:API
  takes the fallback branch in `AshJsonApi.Error.to_json_api_errors/4` and
  returns an opaque `something_went_wrong` 400 with a random error id and a
  logged stacktrace — indistinguishable to a client from a genuine server
  fault.

  `KilnCMS.CMS.Preparations.RejectUnsortableCalculations` raises this error
  when a request sorts by a public calculation declared `sortable? false`
  (`word_count`, `path`, `effective_seo_title`, `related_links`, `block_ids`,
  ...) — the same class of request `filter[word_count]=...` already gets
  rejected for via `filterable?`. This impl reports a `400 invalid_sort`,
  the same code `ash_json_api`'s own sort parser already uses when a sort
  field doesn't exist at all, so a client can't tell "unknown field" from
  "field exists but can't be sorted on" without reading `detail`.
  """

  defimpl AshJsonApi.ToJsonApiError, for: Ash.Error.Query.UnsortableField do
    def to_json_api_error(error) do
      %AshJsonApi.Error{
        id: Ash.UUID.generate(),
        status_code: 400,
        code: "invalid_sort",
        title: "InvalidSort",
        detail: Ash.Error.Query.UnsortableField.message(error),
        source_parameter: "sort",
        meta: %{field: to_string(error.field)}
      }
    end
  end
end
