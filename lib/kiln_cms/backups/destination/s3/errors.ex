defmodule KilnCMS.Backups.Destination.S3.Errors do
  @moduledoc """
  What an S3 store's answer means (#2221): a fixed table from the HTTP
  status, the allowlisted `<Code>` of its error body and two headers
  (`Date`, `x-amz-bucket-region`) to an `t:error/0`.

    * **permanent** (no retry fixes it; the backup fails this destination at
      once): `AccessDenied`, `InvalidAccessKeyId`, `SignatureDoesNotMatch`,
      `NoSuchBucket`, `PermanentRedirect` and any `301` (the bucket is in
      another region or behind another endpoint), `AuthorizationHeaderMalformed`,
      `RequestTimeTooSkewed` and any `403` whose `Date` is more than five
      minutes from this server's clock, `InvalidPart`, `EntityTooLarge`,
      `InvalidBucketName`, and any other redirect but a `307`;
    * **transient** (retried, bounded by `KilnCMS.Backups.Retry`): any `5xx`,
      `SlowDown`, `429`, `RequestTimeout`, `BadDigest`,
      `XAmzContentSHA256Mismatch`, a `307`, a connection failure or timeout,
      and every other `4xx`;
    * **upload_gone**: `NoSuchUpload`;
    * **not_found**: `NoSuchKey`, and a `404` with no code (a `HEAD`).

  The message is this module's own sentence. A code is named in it only when
  it is in the table, and the store's `<Message>` is never read: an
  admin-chosen host decides what that says.
  """

  alias KilnCMS.Backups.Destination.S3.Xml

  defmodule Error do
    @moduledoc "An S3 request's failure, classified. Carries no secret and nothing the store wrote."
    @enforce_keys [:class, :message]
    defstruct [:class, :message, :code, :status]

    @type t :: %__MODULE__{
            class: :permanent | :transient | :upload_gone | :not_found,
            message: String.t(),
            code: String.t() | nil,
            status: non_neg_integer() | nil
          }
  end

  @type error :: Error.t()

  @skew_seconds 300

  @permanent %{
    "AccessDenied" => "the store refused access (AccessDenied); check the key's permissions",
    "AllAccessDisabled" => "all access to the bucket is disabled (AllAccessDisabled)",
    "InvalidAccessKeyId" => "the store doesn't know the access key id (InvalidAccessKeyId)",
    "SignatureDoesNotMatch" => "the store refused the secret access key (SignatureDoesNotMatch)",
    "NoSuchBucket" => "the bucket does not exist (NoSuchBucket)",
    "PermanentRedirect" =>
      "the bucket is in another region or behind another endpoint (PermanentRedirect)",
    "AuthorizationHeaderMalformed" =>
      "the store refused the request's region (AuthorizationHeaderMalformed); check the region",
    "RequestTimeTooSkewed" =>
      "this server's clock is more than 5 minutes off the store's (RequestTimeTooSkewed); " <>
        "fix the clock (NTP)",
    "InvalidPart" => "the store refused a part of the upload (InvalidPart)",
    "EntityTooLarge" => "the file is larger than the store accepts (EntityTooLarge)",
    "InvalidBucketName" => "the store refused the bucket name (InvalidBucketName)"
  }

  @transient ~w(SlowDown InternalError ServiceUnavailable RequestTimeout BadDigest
                XAmzContentSHA256Mismatch OperationAborted TooManyRequests)

  @region ~r/\A[a-z0-9-]{1,40}\z/

  @doc """
  The error a response means, or `nil` for a success (`2xx`). `body` is the
  raw response body (`""` for a `HEAD`); `now` is this server's clock.
  """
  @spec classify(non_neg_integer(), [{String.t(), String.t()}], binary(), DateTime.t()) ::
          error() | nil
  def classify(status, headers, body, now \\ DateTime.utc_now())

  def classify(status, _headers, _body, _now) when status in 200..299, do: nil

  def classify(status, headers, body, now) do
    code = Xml.error_code(body)

    if status == 403 and skewed?(headers, now),
      do: permanent("RequestTimeTooSkewed", status),
      else: redirected(code, status, headers) || by_code(code, status) || by_status(status, code)
  end

  # The bucket is elsewhere: the answer says so, or names its region.
  defp redirected(code, status, headers) do
    if code == "PermanentRedirect" or status == 301 or
         (code == "AuthorizationHeaderMalformed" and region(headers) != nil),
       do: wrong_region(status, headers)
  end

  defp by_code(code, status) do
    cond do
      Map.has_key?(@permanent, code) ->
        permanent(code, status)

      code == "NoSuchUpload" ->
        %Error{
          class: :upload_gone,
          code: code,
          status: status,
          message: "the store no longer has the upload (NoSuchUpload)"
        }

      code == "NoSuchKey" or (status == 404 and code == nil) ->
        %Error{class: :not_found, code: code, status: status, message: "the file is not there"}

      true ->
        nil
    end
  end

  defp by_status(status, code) do
    named = if code in @transient, do: code

    cond do
      status == 307 ->
        transient(nil, status, "the store redirected the request for now (HTTP 307)")

      status in 300..399 ->
        %Error{
          class: :permanent,
          status: status,
          message: "the endpoint answered with a redirect (HTTP #{status}); check the endpoint"
        }

      status == 429 or code == "SlowDown" ->
        transient(named, status, "the store asked to slow down (#{named || "HTTP #{status}"})")

      status >= 500 ->
        transient(named, status, "the store failed the request (HTTP #{status}#{suffix(named)})")

      true ->
        transient(named, status, "the store refused the request (HTTP #{status}#{suffix(named)})")
    end
  end

  defp suffix(nil), do: ""
  defp suffix(code), do: ", " <> code

  @doc "A connection failure or timeout: transient, named by its reason when that is an atom."
  @spec transport(term()) :: error()
  def transport(%{reason: reason}), do: transport(reason)

  def transport(reason) when is_atom(reason),
    do: transient(nil, nil, "couldn't reach the store (#{reason})")

  def transport(_reason), do: transient(nil, nil, "couldn't reach the store")

  @doc """
  Whether the `Date` header of a response is more than five minutes from
  `now`. A missing or unreadable `Date` is not skew.
  """
  @spec skewed?([{String.t(), String.t()}], DateTime.t()) :: boolean()
  def skewed?(headers, now \\ DateTime.utc_now()) do
    case header(headers, "date") |> http_date() do
      {:ok, date} -> abs(DateTime.diff(date, now)) > @skew_seconds
      :error -> false
    end
  end

  @doc "The clock-skew error, as a check of the `Date` header makes it."
  @spec skew() :: error()
  def skew, do: permanent("RequestTimeTooSkewed", nil)

  @doc """
  What a reason means to `KilnCMS.Backups.Retry`: transient errors are
  retried, permanent ones not, and a missing upload or object is the
  caller's to handle.
  """
  @spec retry_class(term()) :: KilnCMS.Backups.Retry.class()
  def retry_class(%Error{class: :transient}), do: :transient
  def retry_class(%Error{class: :permanent}), do: :permanent
  def retry_class(_other), do: :final

  @doc """
  An error as `Kiln.BackupDestination` answers it: `{:permanent, message}`
  for a permanent one, the message for anything else.
  """
  @spec to_reason(term()) :: term()
  def to_reason(%Error{class: :permanent, message: message}), do: {:permanent, message}
  def to_reason(%Error{message: message}), do: message
  def to_reason(other), do: other

  defp permanent(code, status),
    do: %Error{
      class: :permanent,
      code: code,
      status: status,
      message: Map.fetch!(@permanent, code)
    }

  defp transient(code, status, message),
    do: %Error{class: :transient, code: code, status: status, message: message}

  defp wrong_region(status, headers) do
    message =
      case region(headers) do
        nil ->
          "the bucket is in another region or behind another endpoint; check the endpoint and region"

        region ->
          "the bucket is in the region #{region}; set the region (and endpoint) to match"
      end

    %Error{class: :permanent, code: "PermanentRedirect", status: status, message: message}
  end

  defp region(headers) do
    case header(headers, "x-amz-bucket-region") do
      value when is_binary(value) -> if Regex.match?(@region, value), do: value
      nil -> nil
    end
  end

  @doc "The first value of header `name` (lowercase), or `nil`."
  @spec header([{String.t(), String.t()}], String.t()) :: String.t() | nil
  def header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # RFC 7231's IMF-fixdate, "Sun, 06 Nov 1994 08:49:37 GMT", the form S3 and
  # every S3-compatible store send.
  defp http_date(value) when is_binary(value) do
    with [_, day, month, year, hh, mm, ss] <-
           Regex.run(
             ~r/\A\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT\z/,
             String.trim(value)
           ),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <-
           NaiveDateTime.new(
             String.to_integer(year),
             index + 1,
             String.to_integer(day),
             String.to_integer(hh),
             String.to_integer(mm),
             String.to_integer(ss)
           ) do
      {:ok, DateTime.from_naive!(date, "Etc/UTC")}
    else
      _ -> :error
    end
  end

  defp http_date(_value), do: :error
end
