defmodule KilnCMS.Accounts.BreachedPassword do
  @moduledoc """
  Asks the Have I Been Pwned "range" API whether a password has appeared in a
  known breach (#2240), without telling it the password.

  ## What leaves the server

  The k-anonymity protocol: the password is hashed with SHA-1 here, and only
  the first five hex characters of that hash go out, as the path of
  `GET https://api.pwnedpasswords.com/range/<prefix>`. The service answers with
  every known suffix under that prefix and the number of times each was seen;
  the match is made locally. The full hash, the suffix, the password and the
  account never leave the node.

  The request carries `Add-Padding: true`, so the response is padded with
  fake suffixes (count `0`) to a uniform size and its length reveals nothing
  about how many real hits the prefix has. A count of `0` is therefore
  **padding, not a hit**: a line only counts when its suffix matches *and* its
  count is at least `1`.

  The password is hashed exactly as typed. It is never trimmed or normalised:
  the same bytes are what `HashPasswordChange` stores.

  ## Outbound HTTP

  Through `KilnCMS.SafeFetch` like every other outbound call (`AGENTS.md`),
  although the host is pinned in config rather than chosen by content: the
  one fetch path means the redirect, byte-cap and address-pinning rules apply
  without a second implementation. No redirects, no retries, a 128 KB cap, and
  short timeouts — a password change must not wait on a third party. An overall
  deadline (default 3 s) bounds the whole call, including the DNS lookup
  `SafeUrl` makes before connecting, which has its own timeout.

  ## Result

    * `{:ok, :clean}`
    * `{:ok, {:breached, count}}` with `count >= 1`
    * `{:error, class}` where `class` is `:timeout`, `:http_status`,
      `:transport`, `:blocked` or `:malformed`.

  Every error is meant to **fail open**: the caller treats it as "could not
  tell" and lets the password through, because an outage at a third party must
  never lock anyone out of setting a password. The class is the only detail
  that is ever logged or counted; nothing here puts the password, the hash,
  the prefix, the suffix or the URL in a log line or a telemetry event.

  ## Configuration

      config :kiln_cms, KilnCMS.Accounts.BreachedPassword,
        enabled: true,
        default_policy: :warn,
        host: "https://api.pwnedpasswords.com",
        connect_timeout: 1_500,
        receive_timeout: 2_000,
        deadline: 3_000,
        req_options: []

  `BREACHED_PASSWORD_CHECK=false` turns the check off for an air-gapped
  deployment (no outbound call is ever made); `BREACHED_PASSWORD_POLICY` sets
  the operator default (`off`, `warn` or `block`) that a site's own setting
  overrides (`KilnCMS.Accounts.PasswordPolicy`).
  """

  alias KilnCMS.SafeFetch

  @default_host "https://api.pwnedpasswords.com"
  @default_connect_timeout 1_500
  @default_receive_timeout 2_000
  @default_deadline 3_000
  @max_bytes 128 * 1024
  @policies [:off, :warn, :block]

  @type error_class :: :timeout | :http_status | :transport | :blocked | :malformed
  @type result :: {:ok, :clean} | {:ok, {:breached, pos_integer()}} | {:error, error_class()}

  @doc "Whether the check runs at all (`BREACHED_PASSWORD_CHECK`, default on)."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, true) == true

  @doc "The operator's default policy: `:off`, `:warn` (the default) or `:block`."
  @spec default_policy() :: :off | :warn | :block
  def default_policy do
    case Keyword.get(config(), :default_policy, :warn) do
      policy when policy in @policies -> policy
      _other -> :warn
    end
  end

  @doc """
  The overall time one lookup may take, in milliseconds. One number, used
  everywhere the check runs.
  """
  @spec deadline() :: pos_integer()
  def deadline, do: Keyword.get(config(), :deadline, @default_deadline)

  @doc """
  Look `password` up. See the moduledoc for the result shapes.

  Runs the request in a supervised, unlinked task so the overall deadline is
  enforced even when `SafeUrl`'s DNS resolution is the slow part.
  """
  @spec check(String.t()) :: result()
  def check(password) when is_binary(password) do
    {prefix, suffix} = split_hash(password)
    url = Keyword.get(config(), :host, @default_host) <> "/range/" <> prefix

    case start_lookup(url) do
      {:ok, task} ->
        case Task.yield(task, deadline()) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, %{status: 200, body: body}}} -> match(body, suffix)
          {:ok, {:ok, %{status: _other}}} -> {:error, :http_status}
          {:ok, {:error, reason}} -> {:error, classify(reason)}
          {:exit, _reason} -> {:error, :transport}
          nil -> {:error, :timeout}
        end

      :error ->
        {:error, :transport}
    end
  end

  # `async_nolink` raises when the shared supervisor is at `max_children` (or
  # gone). That must fail open like every other lookup problem: a busy node must
  # not turn "could not check" into a 500 on a password change.
  defp start_lookup(url) do
    {:ok, Task.Supervisor.async_nolink(KilnCMS.TaskSupervisor, fn -> fetch(url) end)}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  @doc """
  SHA-1 of `password` in uppercase hex, split into the 5-character prefix that
  is sent and the 35-character suffix that is compared locally. Public for the
  test that pins what goes on the wire; the suffix is never to be logged.
  """
  @spec split_hash(String.t()) :: {String.t(), String.t()}
  def split_hash(password) do
    hash = :sha |> :crypto.hash(password) |> Base.encode16(case: :upper)
    {binary_part(hash, 0, 5), binary_part(hash, 5, 35)}
  end

  defp fetch(url) do
    SafeFetch.get(url,
      headers: [{"add-padding", "true"}, {"user-agent", "KilnCMS"}],
      max_redirects: 0,
      max_bytes: @max_bytes,
      connect_timeout: Keyword.get(config(), :connect_timeout, @default_connect_timeout),
      receive_timeout: Keyword.get(config(), :receive_timeout, @default_receive_timeout),
      req_options: Keyword.get(config(), :req_options, [])
    )
  end

  # `SUFFIX:COUNT` per line. A count of 0 is padding. A body with no parseable
  # line at all, or a line that is not that shape, is malformed — an HTML error
  # page served with a 200 must not read as "clean".
  defp match(body, suffix) do
    lines = String.split(body, ["\r\n", "\n"], trim: true)

    with [_ | _] <- lines,
         {:ok, entries} <- parse(lines) do
      verdict(entries, suffix)
    else
      _malformed -> {:error, :malformed}
    end
  end

  defp verdict(entries, suffix) do
    case List.keyfind(entries, suffix, 0) do
      {_suffix, count} when count >= 1 -> {:ok, {:breached, count}}
      _padding_or_absent -> {:ok, :clean}
    end
  end

  defp parse(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      with [line_suffix, count] <- line |> String.trim() |> String.split(":"),
           true <- String.match?(line_suffix, ~r/\A[0-9A-Fa-f]{35}\z/),
           {count, ""} <- Integer.parse(count),
           true <- count >= 0 do
        {:cont, {:ok, [{String.upcase(line_suffix), count} | acc]}}
      else
        _bad -> {:halt, :error}
      end
    end)
  end

  # `SafeFetch` reports failures as strings (and a caller may see an
  # exception); only the class is kept.
  defp classify(%{__exception__: true} = error), do: classify(Exception.message(error))

  defp classify("blocked" <> _rest), do: :blocked
  defp classify("response exceeded" <> _rest), do: :malformed
  defp classify("unexpected response body" <> _rest), do: :malformed

  defp classify(reason) when is_binary(reason) do
    if String.contains?(String.downcase(reason), "timeout"), do: :timeout, else: :transport
  end

  defp classify(_other), do: :transport

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
