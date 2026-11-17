defmodule KilnCMS.Backups.Destination.S3.Client do
  @moduledoc """
  One S3 destination's requests (#2221): built, signed, sent, classified and
  retried here, and nowhere else.

    * **Built** from the destination's own settings and secrets only
      (`ExAws.Config.Defaults.defaults(:s3)` overlaid with them), never from
      the app's `:ex_aws` config or the environment: those are the
      credentials of the media store, and the host here is one an admin
      typed. No region-to-host lookup either, so any region a store names
      (`auto`, `us-west-004`) works.
    * **Signed** with `ExAws.Auth.headers/6` (SigV4, the payload's sha256
      signed too). ExAws's request layer is not used: it merges app config,
      retries with sleeps of its own past any deadline, and follows no rule
      of ours about redirects.
    * **Sent** through `KilnCMS.Storage.S3.ReqClient` to the address the
      endpoint was pinned to (`KilnCMS.Backups.Destination.S3.Endpoint.pin/2`),
      with redirects off.
    * **Classified** by `KilnCMS.Backups.Destination.S3.Errors`. A `403` to
      a `HEAD`, which has no body to read a code from, is checked for clock
      skew and otherwise asked once more as a `ListObjectsV2` with
      `max-keys=0`, whose code says what was refused.
    * **Retried** by `KilnCMS.Backups.Retry` when transient, never past the
      call's deadline.

  Each request emits `[:kiln_cms, :backups, :s3, :request]` with the
  `duration` (native units) and the `operation`, `method`, `status` and
  `class` of its outcome: never a header, a body, a key or a URL.

  The struct holds the secrets for the length of one adapter call, in the
  calling process; its `Inspect` shows only the endpoint.
  """

  alias KilnCMS.Backups.Destination.S3.{Endpoint, Errors}
  alias KilnCMS.Backups.Destination.S3.Errors.Error
  alias KilnCMS.Backups.Retry
  alias KilnCMS.Storage.S3.ReqClient

  @derive {Inspect, only: [:endpoint]}
  @enforce_keys [:endpoint, :aws]
  defstruct [:endpoint, :aws, :pinned, :deadline, receive_timeout: 300_000]

  @type t :: %__MODULE__{
          endpoint: Endpoint.t(),
          aws: map(),
          pinned: :inet.ip_address() | nil,
          deadline: integer() | nil,
          receive_timeout: pos_integer()
        }

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @event [:kiln_cms, :backups, :s3, :request]

  # Response bodies: 8 MiB for an XML answer (a 1,000-key listing is well
  # under 1 MiB), and a ranged read's own length, never under 64 KiB so an
  # error document still fits.
  @max_body 8 * 1024 * 1024
  @min_body_limit 64 * 1024

  @doc "The telemetry event each request emits."
  @spec event() :: [atom()]
  def event, do: @event

  @doc """
  A client for `endpoint` with the access key pair, pinned now. `opts`:
  `:deadline` (a monotonic instant every retry stays clear of).
  """
  @spec new(Endpoint.t(), String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, String.t() | {:permanent, String.t()}}
  def new(%Endpoint{} = endpoint, access_key_id, secret_access_key, opts \\ []) do
    with {:ok, pinned} <- Endpoint.pin(endpoint) do
      {:ok,
       %__MODULE__{
         endpoint: endpoint,
         aws: aws_config(endpoint, access_key_id, secret_access_key),
         pinned: pinned,
         deadline: Keyword.get(opts, :deadline),
         receive_timeout: Keyword.get(config(), :receive_timeout_ms, 300_000)
       }}
    end
  end

  @doc """
  The ExAws config the request is signed with: S3's static defaults, the
  endpoint's own host, scheme, port and region, and the key pair. Nothing
  from `Application.get_env(:ex_aws, …)`, and no `security_token` key (ExAws
  would send a `nil` one).
  """
  @spec aws_config(Endpoint.t(), String.t(), String.t()) :: map()
  def aws_config(%Endpoint{} = endpoint, access_key_id, secret_access_key) do
    :s3
    |> ExAws.Config.Defaults.defaults()
    |> Map.merge(%{
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      region: endpoint.region,
      scheme: endpoint.scheme <> "://",
      host: Endpoint.connect_host(endpoint),
      port: endpoint.port,
      retries: [max_attempts: 1, base_backoff_in_ms: 0, max_backoff_in_ms: 0],
      http_client: ReqClient
    })
  end

  @doc """
  `request/7`, retried while transient (`KilnCMS.Backups.Retry`), within the
  client's deadline. `{:error, :deadline}` when the next retry would not fit.
  """
  @spec call(
          t(),
          atom(),
          atom(),
          String.t(),
          [{String.t(), String.t()}],
          [{String.t(), String.t()}],
          binary()
        ) ::
          {:ok, response()} | {:error, Error.t() | :deadline}
  def call(client, operation, method, key, query \\ [], headers \\ [], body \\ "") do
    retry(client, fn -> request(client, operation, method, key, query, headers, body) end)
  end

  @doc """
  `fun` (answering like `request/7`) retried while transient, within the
  client's deadline: for a request whose `2xx` answer still needs reading
  (a `CompleteMultipartUpload` can fail with a `200`).
  """
  @spec retry(t(), (-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def retry(%__MODULE__{deadline: deadline}, fun),
    do: Retry.run(fun, &Errors.retry_class/1, deadline: deadline)

  @doc """
  One signed request: `{:ok, response}` for a `2xx`, else the classified
  error (`KilnCMS.Backups.Destination.S3.Errors`). `key` is the object key
  under the bucket (`""` for the bucket); `query` is unencoded pairs.
  """
  @spec request(
          t(),
          atom(),
          atom(),
          String.t(),
          [{String.t(), String.t()}],
          [{String.t(), String.t()}],
          binary()
        ) ::
          {:ok, response()} | {:error, Error.t()}
  def request(%__MODULE__{} = client, operation, method, key, query, headers, body) do
    started = System.monotonic_time()
    result = send_signed(client, method, key, query, headers, body)

    result =
      case result do
        {:error, %Error{status: 403, class: :transient}} when method == :head ->
          explain_head_403(client, result)

        other ->
          other
      end

    emit(started, operation, method, result)
    result
  end

  defp send_signed(client, method, key, query, headers, body) do
    url = Endpoint.url(client.endpoint, key, encode_query(query))
    signed = [{"x-amz-content-sha256", sha256_hex(body)} | headers]

    with {:ok, signed} <- sign(method, url, client.aws, signed, body) do
      method
      |> ReqClient.request(url, body, signed, http_opts(client, body_limit(headers)))
      |> response()
    end
  end

  # ExAws' own error mentions the config key, never its value for a string.
  defp sign(method, url, aws, headers, body) do
    case ExAws.Auth.headers(method, url, :s3, aws, headers, body) do
      {:ok, headers} ->
        {:ok, headers}

      {:error, _message} ->
        {:error, %Error{class: :permanent, message: "the access key pair is incomplete"}}
    end
  end

  defp http_opts(client, limit) do
    timeout =
      case client.deadline do
        nil -> client.receive_timeout
        deadline -> max(min(client.receive_timeout, deadline - now()), 1_000)
      end

    [
      pinned: true,
      pinned_address: client.pinned,
      receive_timeout: timeout,
      req_options: Keyword.put(Keyword.get(config(), :req_options, []), :into, capped(limit))
    ]
  end

  @doc """
  The most bytes a response body to a request with `headers` may have: the
  asked range (with room for an error document), else 8 MiB. A store that
  sends more is cut off there, not buffered (see `capped/1`).
  """
  @spec body_limit([{String.t(), String.t()}]) :: pos_integer()
  def body_limit(headers) do
    with "bytes=" <> range <- Errors.header(headers, "range"),
         [from, to] <- String.split(range, "-"),
         {from, ""} <- Integer.parse(from),
         {to, ""} <- Integer.parse(to),
         true <- to >= from do
      max(to - from + 1, @min_body_limit)
    else
      _ -> @max_body
    end
  end

  # Streams the body in, stopping (and marking it) past `limit` bytes, so
  # an admin-chosen host can't make a backup buffer what it likes.
  defp capped(limit) do
    fn {:data, data}, {request, response} ->
      body = response.body <> data

      if byte_size(body) > limit,
        do: {:halt, {request, %{response | body: {:too_large, limit}}}},
        else: {:cont, {request, %{response | body: body}}}
    end
  end

  defp response({:ok, %{status_code: status, body: {:too_large, limit}}}) do
    {:error,
     %Error{
       class: :transient,
       status: status,
       message: "the store's answer was larger than the #{limit} bytes expected; it was cut off"
     }}
  end

  defp response({:ok, %{status_code: status, headers: headers, body: body}}) do
    body = if is_binary(body), do: body, else: ""

    case Errors.classify(status, headers, body) do
      nil -> {:ok, %{status: status, headers: headers, body: body}}
      %Error{} = error -> {:error, error}
    end
  end

  defp response({:error, reason}), do: {:error, Errors.transport(reason)}

  # A HEAD 403 has no body to read a code from: skew was ruled out by
  # `Errors.classify/4`, so ask the bucket once what is refused. A listing
  # that works means only this object's read is refused.
  defp explain_head_403(client, original) do
    case send_signed(client, :get, "", [{"list-type", "2"}, {"max-keys", "0"}], [], "") do
      {:ok, _listed} ->
        {:error,
         %Error{
           class: :permanent,
           code: "AccessDenied",
           status: 403,
           message:
             "the store refused to read the file (AccessDenied); check the key's permissions"
         }}

      {:error, %Error{class: :permanent}} = refused ->
        refused

      {:error, _other} ->
        original
    end
  end

  defp emit(started, operation, method, result) do
    {status, class} =
      case result do
        {:ok, %{status: status}} -> {status, :ok}
        {:error, %Error{status: status, class: class}} -> {status, class}
      end

    :telemetry.execute(@event, %{duration: System.monotonic_time() - started}, %{
      operation: operation,
      method: method,
      status: status,
      class: class
    })
  end

  @doc "The query string for `pairs`, encoded as SigV4 canonicalizes it."
  @spec encode_query([{String.t(), String.t()}]) :: String.t()
  def encode_query(pairs) do
    Enum.map_join(pairs, "&", fn {key, value} ->
      URI.encode_www_form(key) <> "=" <> ExAws.Auth.aws_encode_www_form(value)
    end)
  end

  @doc "A header's first value (case-insensitive name), or `nil`."
  @spec header(response(), String.t()) :: String.t() | nil
  def header(%{headers: headers}, name), do: Errors.header(headers, name)

  defp sha256_hex(body), do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

  defp now, do: System.monotonic_time(:millisecond)

  defp config, do: Application.get_env(:kiln_cms, KilnCMS.Backups.Destination.S3, [])
end
