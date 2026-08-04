defmodule KilnCMSWeb.Params do
  @moduledoc """
  Reads a request parameter the client chose the *shape* of (#751).

  Plug's query decoder gives the caller control over the type, not just the
  value: `?q=x` is a binary, `?q[]=x` is a **list**, and `?q[a]=x` is a **map**.
  A `%{"slug" => slug}` function head constrains the key, never the value. So
  every parameter arriving from a query string or a form body is
  `term()` until something checks, and the two ways of forgetting that fail
  differently:

    * a bare parser — `Integer.parse/1`, `DateTime.from_iso8601/1`,
      `Plug.Crypto.verify/4` — has no clause for either shape and raises on
      both;
    * `to_string/1` quietly *absorbs* the list (`to_string(["x"]) == "x"`) and
      raises `Protocol.UndefinedError` on the map — so a site can look tested
      and still be one bracket away from a 500.

  Neither is caught by `Plug.Exception`, so on a public route both are a 500
  plus one error-tracker event **per request**: an unauthenticated report
  generator, which is the shape #700 was worth fixing on its own.

  ## Absent, not coerced

  A value the client sent in a shape this parameter does not have reads as
  **absent**. Coercing the list back to its first element would preserve the
  accident `to_string/1` produced, and `?q[]=x` is not a spelling of `?q=x` —
  treating it as one means the same request means two things depending on which
  helper the handler happened to use.

  Absent also composes with what callers already do: every one of these
  parameters is optional and has a documented fallback, so the malformed
  request answers exactly as the omitted one does.

  ## When absent is the wrong answer

  Where the handler's contract is to *reject* a bad value rather than ignore it
  — `?as_of=` answers `400 invalid_as_of` — the guard belongs on the parser
  instead, so a non-binary takes the same branch a garbage string does. Reading
  it as absent there would silently serve the live document to a compliance
  reader asking for a historical one, which is worse than the crash.
  """

  @doc """
  `params[key]` when the client sent a plain string, `default` otherwise.

      iex> KilnCMSWeb.Params.string(%{"q" => "hello"}, "q")
      "hello"

      iex> KilnCMSWeb.Params.string(%{"q" => ["hello"]}, "q")
      nil

      iex> KilnCMSWeb.Params.string(%{"q" => %{"a" => "hello"}}, "q", "")
      ""
  """
  @spec string(map(), String.t(), default) :: String.t() | default when default: term()
  def string(params, key, default \\ nil)

  # A struct is a map, so `%{} = params` matches `%Plug.Conn.Unfetched{}` — and
  # then reading a key out of it raises, in the one module whose contract is
  # that it does not. `Map.get/2` rather than `params[key]` for the same
  # reason: `Access` is not implemented by every map-shaped thing.
  def string(%_struct{}, _key, default), do: default

  def string(params, key, default) when is_map(params) and is_binary(key),
    do: coerce(Map.get(params, key), default)

  def string(_params, _key, default), do: default

  @doc """
  The integer at `key`, clamped to `range`, or `default`.

  The other half of the same problem: every bounded numeric parameter here was
  a hand-rolled `Integer.parse(to_string(params[key]))` plus a range match, and
  `to_string/1` is exactly the trap this module exists to remove.

      iex> KilnCMSWeb.Params.integer(%{"limit" => "5"}, "limit", 10, 1..20)
      5

      iex> KilnCMSWeb.Params.integer(%{"limit" => "999"}, "limit", 10, 1..20)
      10

      iex> KilnCMSWeb.Params.integer(%{"limit" => ["5"]}, "limit", 10, 1..20)
      10
  """
  @spec integer(map(), String.t(), integer(), Range.t()) :: integer()
  def integer(params, key, default, %Range{} = range) do
    case Integer.parse(string(params, key, "")) do
      {n, ""} -> if n in range, do: n, else: default
      _other -> default
    end
  end

  defp coerce(value, _default) when is_binary(value), do: value
  defp coerce(_value, default), do: default
end
