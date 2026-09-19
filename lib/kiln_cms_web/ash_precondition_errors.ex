defmodule KilnCMSWeb.AshPreconditionErrors do
  @moduledoc """
  Client-facing translations of `KilnCMS.CMS.Errors.PreconditionFailed` — a
  write refused because the record moved on since the client read it
  (`If-Match` / `expected_lock_version`).

  JSON:API answers **412 Precondition Failed**, the status RFC 9110 gives a
  false `If-Match`, with code `precondition_failed` and the current `etag` and
  `lock_version` in `meta` so the client can re-read (or, having re-read, retry)
  without guessing. GraphQL has no status, so the same code and values ride in
  the error's `vars`.

  A transport concern, like `KilnCMSWeb.AshStateMachineErrors` beside it.
  """

  alias KilnCMS.CMS.Errors.PreconditionFailed

  @doc false
  def vars(%PreconditionFailed{lock_version: version, state: state} = error) do
    %{
      lock_version: version,
      state: state && to_string(state),
      etag: KilnCMSWeb.ContentETag.etag(Map.from_struct(error))
    }
  end

  defimpl AshJsonApi.ToJsonApiError, for: KilnCMS.CMS.Errors.PreconditionFailed do
    def to_json_api_error(error) do
      %AshJsonApi.Error{
        id: Ash.UUID.generate(),
        status_code: 412,
        code: "precondition_failed",
        title: "PreconditionFailed",
        detail: Exception.message(error),
        meta: KilnCMSWeb.AshPreconditionErrors.vars(error)
      }
    end
  end

  defimpl AshGraphql.Error, for: KilnCMS.CMS.Errors.PreconditionFailed do
    def to_error(error) do
      %{
        message: Exception.message(error),
        short_message: "precondition failed",
        code: "precondition_failed",
        vars: KilnCMSWeb.AshPreconditionErrors.vars(error),
        fields: [:expected_lock_version]
      }
    end
  end
end
