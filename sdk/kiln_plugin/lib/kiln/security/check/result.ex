defmodule Kiln.Security.Check.Result do
  @moduledoc """
  What a `Kiln.Security.Check` reports (kiln_cms#2252). Build one with the
  helpers `use Kiln.Security.Check` imports (`pass/2`, `warn/2`, `fail/2`,
  `unknown/2`, `n_a/2`) rather than by hand.

    * `status` — `:pass`, `:warn`, `:fail`, `:unknown` (the check could not
      tell, say because a setting could not be read) or `:n_a` (the check does
      not apply here, say a production-only setting on a development build).
      `:unknown` is never read as a pass.
    * `summary` — one sentence for the page, up to #{300} characters.
    * `details` — up to #{10} short strings (names, entries) shown under the
      summary when the row is opened. Only the console page shows them; they
      are never published elsewhere.
    * `fix_path` — a console path that fixes it (`"/editor/sessions"`). It must
      start with `/editor/`; anything else (a scheme, `//host`, a path outside
      the console) is dropped.
    * `docs_url` — an `https://` page explaining the check. Anything else is
      dropped.
    * `facts` — up to #{20} machine-readable values (`%{"admins_without" =>
      2}`): string or atom keys, and values that are `nil`, a boolean, a number
      or a short string. They are published to monitoring at
      `GET /api/security/posture`, so they must never carry a secret, a token
      or a person's address.

  The core passes every result through `sanitize/1` before it is shown, so a
  result over these limits is trimmed rather than refused, and text that is
  not valid UTF-8 has each bad byte sequence replaced with U+FFFD.
  """

  @statuses [:pass, :warn, :fail, :unknown, :n_a]
  @max_summary 300
  @max_details 10
  @max_detail 300
  @max_facts 20
  @max_fact_string 300
  @max_key 64

  @type status :: :pass | :warn | :fail | :unknown | :n_a

  @typedoc "A machine-readable value: `nil`, a boolean, a number or a short string."
  @type fact :: nil | boolean() | number() | String.t()

  @type t :: %__MODULE__{
          status: status(),
          summary: String.t(),
          details: [String.t()],
          fix_path: String.t() | nil,
          docs_url: String.t() | nil,
          facts: %{optional(String.t()) => fact()}
        }

  @enforce_keys [:status, :summary]
  defstruct status: nil, summary: "", details: [], fix_path: nil, docs_url: nil, facts: %{}

  @doc "The statuses a result may carry."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  A result with `status` and `summary`. Options: `:details`, `:fix_path`,
  `:docs_url` and `:facts`, as the moduledoc describes them. Not sanitized
  here; the core does that.
  """
  @spec new(status(), String.t(), keyword()) :: t()
  def new(status, summary, opts \\ []) when status in @statuses and is_binary(summary) do
    %__MODULE__{
      status: status,
      summary: summary,
      details: Keyword.get(opts, :details, []),
      fix_path: Keyword.get(opts, :fix_path),
      docs_url: Keyword.get(opts, :docs_url),
      facts: Keyword.get(opts, :facts, %{})
    }
  end

  @doc """
  `term` held to the limits in the moduledoc: `{:ok, result}` with the summary
  and details trimmed, an unusable `fix_path` or `docs_url` dropped, and only
  the facts that fit kept (keys as strings). Invalid UTF-8 in the summary, a
  detail, a fact key or a string fact value is replaced (U+FFFD) before it is
  trimmed, so the result always encodes as JSON. `:error` when `term` is not a
  result at all, or its status or summary is not one a result may carry.
  """
  @spec sanitize(term()) :: {:ok, t()} | :error
  def sanitize(%__MODULE__{status: status, summary: summary} = result)
      when status in @statuses and is_binary(summary) do
    {:ok,
     %__MODULE__{
       status: status,
       summary: summary |> String.replace_invalid() |> trim(@max_summary),
       details: details(result.details),
       fix_path: fix_path(result.fix_path),
       docs_url: docs_url(result.docs_url),
       facts: facts(result.facts)
     }}
  end

  def sanitize(_other), do: :error

  defp trim(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp details(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.take(@max_details)
    |> Enum.map(&(&1 |> String.replace_invalid() |> trim(@max_detail)))
  end

  defp details(_other), do: []

  @doc """
  `path` when it is a console path a fix link may point at: it starts with
  `/editor/`, holds no `//`, no backslash, no scheme and no whitespace.
  `nil` otherwise, and for a path that is not valid UTF-8 (a link is dropped,
  not repaired).
  """
  @spec fix_path(term()) :: String.t() | nil
  def fix_path(path) when is_binary(path) do
    if String.valid?(path) and String.starts_with?(path, "/editor/") and
         not String.contains?(path, ["//", "\\"]) and
         not String.match?(path, ~r/[\s\x00-\x1f\x7f]/u) and String.length(path) <= 300,
       do: path
  end

  def fix_path(_path), do: nil

  @doc """
  `url` when it is an `https://` URL with a host and no credentials, `nil`
  otherwise, and for a URL that is not valid UTF-8.
  """
  @spec docs_url(term()) :: String.t() | nil
  def docs_url(url) when is_binary(url) do
    case String.valid?(url) && URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        if String.match?(url, ~r/[\s"'<>\\]/) or String.length(url) > 500, do: nil, else: url

      _other ->
        nil
    end
  end

  def docs_url(_url), do: nil

  defp facts(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.flat_map(fn {key, value} ->
      with {:ok, key} <- fact_key(key),
           {:ok, value} <- fact_value(value) do
        [{key, value}]
      else
        :error -> []
      end
    end)
    |> Enum.sort()
    |> Enum.take(@max_facts)
    |> Map.new()
  end

  defp facts(_other), do: %{}

  defp fact_key(key) when is_atom(key) and not is_nil(key) and not is_boolean(key),
    do: fact_key(Atom.to_string(key))

  defp fact_key(key) when is_binary(key) do
    key = String.replace_invalid(key)

    if key != "" and String.length(key) <= @max_key, do: {:ok, key}, else: :error
  end

  defp fact_key(_key), do: :error

  defp fact_value(value) when is_nil(value) or is_boolean(value) or is_number(value),
    do: {:ok, value}

  defp fact_value(value) when is_binary(value),
    do: {:ok, value |> String.replace_invalid() |> trim(@max_fact_string)}

  defp fact_value(_value), do: :error
end
