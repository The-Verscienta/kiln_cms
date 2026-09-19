defmodule KilnClient.Error do
  @moduledoc """
  The error the write functions and `KilnClient.graphql/3` return, as
  `{:error, %KilnClient.Error{}}` — never raised by the client itself, but an
  exception so a caller can `raise` it as-is.

  Branch on `:reason`:

  | `:reason` | When |
  |---|---|
  | `:no_api_key` | Refused client-side: a write with no API key configured or passed. Nothing was sent. |
  | `:unauthorized` | 401 — no credential, or an invalid/expired/revoked `kiln_…` key. |
  | `:forbidden` | 403 — the key's owner lacks the right (a `:read` key writing, an editor publishing). |
  | `:not_found` | 404 — no such record, or one the credential cannot see. |
  | `:validation` | 400 / 422 — refused as invalid. AshJsonApi answers most attribute errors with **400**, not 422, so both land here; `pointers/1` names the fields. |
  | `:conflict` | 409 — a workflow transition from the wrong state (`code: "invalid_state_transition"`, see `current_state/1`), or a write that lost a race. Reload and decide. |
  | `:rate_limited` | 429 — wait `:retry_after` seconds. |
  | `:server` | 5xx — a server fault or a cold cache (503, which may carry `:retry_after`). |
  | `:http` | Any other non-2xx status. |
  | `:transport` | No response at all (DNS, refused, TLS, timeout); the underlying exception is in `:exception`. |
  | `:graphql` | `/gql` answered with a top-level `errors` array; any partial `data` is in `:data`. |

  `:errors` is the JSON:API `errors` array Kiln answers every headless refusal
  with (`[%{"status" => "409", "code" => …, "detail" => …, "source" =>
  %{"pointer" => …}, "meta" => …}]`), or the GraphQL errors for `:graphql`;
  `:code` is its first entry's code.

  The read functions keep their original `{:error, {:http_status, status,
  body}}` shape for compatibility — `normalize/1` converts one of those (or a
  transport exception, or `:not_found` from `KilnClient.one/3`) into this struct
  so one error handler can serve both.
  """

  @type reason ::
          :no_api_key
          | :unauthorized
          | :forbidden
          | :not_found
          | :validation
          | :conflict
          | :rate_limited
          | :server
          | :http
          | :transport
          | :graphql

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          code: String.t() | nil,
          errors: [map()],
          retry_after: non_neg_integer() | nil,
          body: term(),
          data: term(),
          exception: Exception.t() | nil,
          method: atom() | nil,
          path: String.t() | nil
        }

  defexception [
    :reason,
    :status,
    :code,
    :retry_after,
    :body,
    :data,
    :exception,
    :method,
    :path,
    errors: []
  ]

  @impl true
  def message(%__MODULE__{reason: :no_api_key, method: method, path: path}) do
    "#{format_method(method)} #{path} writes to Kiln and needs an API key: set " <>
      "`config :kiln_client, api_key: …` or pass `api_key:` — a :read_write key on an " <>
      "editor (create/update/submit) or admin (publish/unpublish/return/delete) account"
  end

  def message(%__MODULE__{reason: :transport, exception: exception} = error) do
    "Kiln #{format_method(error.method)} #{error.path} failed: " <>
      if(exception, do: Exception.message(exception), else: "transport error")
  end

  def message(%__MODULE__{reason: :graphql, errors: errors}) do
    first = List.first(errors) || %{}
    "Kiln GraphQL request failed: #{first["message"] || "unknown error"}"
  end

  def message(%__MODULE__{} = error) do
    detail = error.errors |> List.first(%{}) |> Map.get("detail")
    status = if error.status, do: " #{error.status}", else: ""
    where = if error.path, do: " (#{format_method(error.method)} #{error.path})", else: ""

    "Kiln request failed:#{status} #{error.reason}#{where}" <>
      if(detail, do: " — #{detail}", else: "")
  end

  @doc """
  Every `source.pointer` the server named, in order
  (`["/data/attributes/slug"]`).
  """
  @spec pointers(t()) :: [String.t()]
  def pointers(%__MODULE__{errors: errors}) do
    for %{"source" => %{"pointer" => pointer}} when is_binary(pointer) <- errors, do: pointer
  end

  @doc """
  Details grouped by attribute name (`/data/attributes/slug` → `"slug"`):
  `%{"slug" => ["has already been taken"]}`.
  """
  @spec field_errors(t()) :: %{optional(String.t()) => [String.t()]}
  def field_errors(%__MODULE__{errors: errors}) do
    for %{"source" => %{"pointer" => pointer}} = error when is_binary(pointer) <- errors,
        reduce: %{} do
      acc ->
        field = String.replace_prefix(pointer, "/data/attributes/", "")
        detail = error["detail"] || error["title"] || error["code"] || "invalid"
        Map.update(acc, field, [detail], &(&1 ++ [detail]))
    end
  end

  @doc "`meta.current_state` of the first error — what a 409 transition found."
  @spec current_state(t()) :: String.t() | nil
  def current_state(%__MODULE__{errors: [%{"meta" => %{"current_state" => state}} | _]})
      when is_binary(state),
      do: state

  def current_state(%__MODULE__{}), do: nil

  @doc """
  Build the error for a non-2xx response. `headers` is the response's header
  map (Req's `%{name => [values]}`), read for `retry-after`.
  """
  @spec from_response(pos_integer(), term(), map(), keyword()) :: t()
  def from_response(status, body, headers \\ %{}, opts \\ []) do
    errors = error_objects(body)

    %__MODULE__{
      reason: reason_for(status),
      status: status,
      code: errors |> List.first(%{}) |> Map.get("code"),
      errors: errors,
      retry_after: headers |> header("retry-after") |> parse_retry_after(),
      body: body,
      method: opts[:method],
      path: opts[:path]
    }
  end

  @doc """
  Convert any error a `KilnClient` function returns into this struct: the
  read functions' `{:http_status, status, body}`, a transport exception,
  `KilnClient.one/3`'s `:not_found`, or an existing `%KilnClient.Error{}`
  (returned unchanged).
  """
  @spec normalize(term()) :: t()
  def normalize(%__MODULE__{} = error), do: error
  def normalize({:http_status, status, body}), do: from_response(status, body)
  def normalize(:not_found), do: %__MODULE__{reason: :not_found, status: 404}

  def normalize(%{__exception__: true} = exception),
    do: %__MODULE__{reason: :transport, exception: exception}

  def normalize(other), do: %__MODULE__{reason: :http, body: other}

  @doc false
  @spec reason_for(pos_integer()) :: reason()
  def reason_for(401), do: :unauthorized
  def reason_for(403), do: :forbidden
  def reason_for(404), do: :not_found
  def reason_for(status) when status in [400, 422], do: :validation
  def reason_for(409), do: :conflict
  def reason_for(429), do: :rate_limited
  def reason_for(status) when status >= 500, do: :server
  def reason_for(_status), do: :http

  @doc false
  # Delta-seconds, or an HTTP date (seconds from now, floored at 0).
  @spec parse_retry_after(String.t() | nil) :: non_neg_integer() | nil
  def parse_retry_after(nil), do: nil

  def parse_retry_after(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        seconds

      _ ->
        case parse_http_date(value) do
          {:ok, at} -> max(0, DateTime.diff(at, DateTime.utc_now()))
          :error -> nil
        end
    end
  end

  defp error_objects(%{"errors" => errors}) when is_list(errors),
    do: Enum.filter(errors, &is_map/1)

  defp error_objects(_body), do: []

  defp header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp header(_headers, _name), do: nil

  # IMF-fixdate only (`Sun, 06 Nov 1994 08:49:37 GMT`) — the one form RFC 9110
  # requires senders to use.
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  defp parse_http_date(value) do
    with [_day, dd, mon, yyyy, time, "GMT"] <- String.split(value, [" ", ","], trim: true),
         month when is_integer(month) <- Enum.find_index(@months, &(&1 == mon)),
         {day, ""} <- Integer.parse(dd),
         {year, ""} <- Integer.parse(yyyy),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, date} <- Date.new(year, month + 1, day) do
      DateTime.new(date, time, "Etc/UTC")
    else
      _ -> :error
    end
  end

  defp format_method(nil), do: "request"
  defp format_method(method), do: method |> to_string() |> String.upcase()
end
