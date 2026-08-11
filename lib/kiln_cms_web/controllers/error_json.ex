defmodule KilnCMSWeb.ErrorJSON do
  @moduledoc """
  Invoked by the endpoint (`render_errors:` in `config/config.exs`) for a
  *raised* error on a JSON-negotiated request — an unrouted `/api/...` path,
  or an unhandled exception anywhere the format negotiates to JSON, not only
  under `/api`.

  Answers the same envelope every headless surface does
  (`KilnCMSWeb.ApiError`, #744/#750): this used to render the `errors` key as
  a bare object holding one `detail` string, rather than the documented
  array-of-entries shape — so `errors[0]` was `undefined` for a client written
  to `docs/api.md`'s contract, and precisely on the two paths a client has the
  least context for reporting.
  """

  @doc false
  def render(template, _assigns), do: KilnCMSWeb.ApiError.body_from_template(template)
end
