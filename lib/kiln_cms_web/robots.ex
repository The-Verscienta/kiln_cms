defmodule KilnCMSWeb.Robots do
  @moduledoc """
  The robots directive a document asks for (#2256), from its `noindex` and
  `nofollow` flags.

  One function builds the string for both places it is sent — the
  `<meta name="robots">` tag and the `x-robots-tag` response header — so the two
  can never disagree. `nil` means "no directive": a document with neither flag
  set sends nothing, and the default behaviour of a crawler is unchanged.
  """

  @doc """
  The directive for a record or teaser: `"noindex"`, `"nofollow"`,
  `"noindex, nofollow"`, or `nil` when neither flag is set.

  A struct from a cache older than the flags (no key at all) reads as unset. A
  flag that is present but `%Ash.NotLoaded{}` raises `ArgumentError`: the query
  did not select it, and reading that as "no directive" would serve a hidden
  page as indexable.
  """
  @spec directive(map()) :: String.t() | nil
  def directive(record) do
    case {flag(record, :noindex), flag(record, :nofollow)} do
      {true, true} -> "noindex, nofollow"
      {true, false} -> "noindex"
      {false, true} -> "nofollow"
      {false, false} -> nil
    end
  end

  defp flag(record, key) do
    case Map.get(record, key) do
      %Ash.NotLoaded{} ->
        raise ArgumentError,
              "cannot build a robots directive: #{key} was not loaded " <>
                "(select it, or load the record in full)"

      value ->
        value == true
    end
  end

  @doc "Assigns `:robots` and sets `x-robots-tag` on `conn` when the record has a directive."
  @spec put(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put(conn, record) do
    case directive(record) do
      nil ->
        conn

      value ->
        conn
        |> Plug.Conn.put_resp_header("x-robots-tag", value)
        |> Plug.Conn.assign(:robots, value)
    end
  end
end
