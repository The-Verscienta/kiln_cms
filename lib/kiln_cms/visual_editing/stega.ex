defmodule KilnCMS.VisualEditing.Stega do
  @moduledoc """
  Steganographic field-mapping encoding for the visual-editing bridge (#355).

  A tiny payload describing *where a string came from* (`%{"type" => …, "id" =>
  …, "field" => …}`) is encoded into a run of **invisible** Unicode Tag
  characters (block U+E0000–U+E007F) and appended to the visible string. The
  visible text renders identically; the invisible tail rides along into the
  external front end's DOM text node, so the bridge overlay can read it back at
  the point of a click and map the value to its Kiln field — the same trick
  Sanity's stega uses, with no cooperation required from the front end beyond
  printing the string.

  This is applied **only** to annotated preview responses (draft content, behind
  a preview token / API key). The public fired artifacts are never stega-encoded
  — see `KilnCMS.VisualEditing`.

  ## Wire format

  `<START> <tag chars…> <END>` where the tag chars are the UTF-8 bytes of a
  base64url (unpadded) JSON payload, each byte `b` mapped to codepoint
  `0xE0000 + b`. `START`/`END` are fixed sentinels outside the payload range so a
  decoder can locate the run inside surrounding text.
  """

  # Base of the Unicode Tags block. A payload byte `b` (0x00–0xFF) maps to
  # `@tag_base + b`; base64url only emits 0x2D–0x7A, well inside the block.
  @tag_base 0xE0000
  # Sentinels: chosen outside the base64url byte range (0x2D–0x7A) so they can't
  # be mistaken for payload.
  @start 0xE0000 + 0x02
  @stop 0xE0000 + 0x7F

  @doc """
  Append an invisible encoded `payload` to `string`. Returns `string` unchanged
  when it is empty or the payload can't be encoded (never raises on the hot
  serialization path).
  """
  @spec encode(String.t(), map()) :: String.t()
  def encode(string, _payload) when string in [nil, ""], do: string || ""

  def encode(string, payload) when is_binary(string) and is_map(payload) do
    string <> tag(payload)
  rescue
    _ -> string
  end

  @doc "Just the invisible tag for `payload` (no visible text)."
  @spec tag(map()) :: String.t()
  def tag(payload) when is_map(payload) do
    data = payload |> Jason.encode!() |> Base.url_encode64(padding: false)

    encoded =
      data
      |> :binary.bin_to_list()
      |> Enum.map(&(&1 + @tag_base))

    List.to_string([@start] ++ encoded ++ [@stop])
  end

  @doc """
  Decode the first encoded payload found in `string`, or `nil` if there is none.
  Mirrors the JS decoder in `priv/static/bridge.js`.
  """
  @spec decode(String.t()) :: map() | nil
  def decode(string) when is_binary(string) do
    with [_ | _] = codepoints <- extract(String.to_charlist(string)),
         bytes = Enum.map(codepoints, &(&1 - @tag_base)),
         {:ok, json} <- Base.url_decode64(:binary.list_to_bin(bytes), padding: false),
         {:ok, payload} <- Jason.decode(json) do
      payload
    else
      _ -> nil
    end
  end

  def decode(_), do: nil

  @doc "Strip every invisible tag character (and sentinels) from `string`."
  @spec clean(String.t()) :: String.t()
  def clean(string) when is_binary(string) do
    string
    |> String.to_charlist()
    |> Enum.reject(&tag_char?/1)
    |> List.to_string()
  end

  def clean(other), do: other

  # Collect the codepoints between the first START and the next STOP.
  defp extract(chars), do: extract(chars, :seeking, [])

  defp extract([], _state, _acc), do: nil
  defp extract([@start | rest], :seeking, _acc), do: extract(rest, :collecting, [])
  defp extract([_ | rest], :seeking, acc), do: extract(rest, :seeking, acc)
  defp extract([@stop | _rest], :collecting, acc), do: Enum.reverse(acc)
  defp extract([c | rest], :collecting, acc), do: extract(rest, :collecting, [c | acc])

  defp tag_char?(c), do: c >= @tag_base and c <= @tag_base + 0x7F
end
