defmodule KilnCMS.Provenance.Canonical do
  @moduledoc """
  Deterministic JSON canonicalization for signed provenance (#340).

  A signature is only verifiable if the signer and every verifier hash the
  *same bytes*. Plain `Jason.encode/1` iterates a map in an unspecified order,
  so two encodings of the same content can differ. `encode/1` fixes an order:
  object keys are sorted lexicographically (by their UTF-8 bytes), recursively,
  with no insignificant whitespace. This is JCS-*style* (RFC 8785 in spirit);
  our payloads are strings, integers, booleans, `nil`, maps, and lists — we do
  not need RFC 8785's floating-point number canonicalization, and reject floats
  rather than emit a non-reproducible form.

  The canonicalization identifier embedded in manifests is `"kiln-jcs-v1"`;
  bump it here (and in the manifest) if this encoding ever changes, so old
  manifests stay verifiable under their declared algorithm.
  """

  @id "kiln-jcs-v1"

  @doc "The canonicalization algorithm identifier recorded in manifests."
  @spec id() :: String.t()
  def id, do: @id

  @doc "Canonical-encode a JSON-able term to an iodata-free binary."
  @spec encode(term()) :: binary()
  def encode(term), do: IO.iodata_to_binary(to_iodata(term))

  @doc "SHA-256 digest of the canonical encoding, Base64 (standard alphabet)."
  @spec digest(term()) :: String.t()
  def digest(term), do: Base.encode64(:crypto.hash(:sha256, encode(term)))

  defp to_iodata(nil), do: "null"
  defp to_iodata(true), do: "true"
  defp to_iodata(false), do: "false"
  defp to_iodata(int) when is_integer(int), do: Integer.to_string(int)
  defp to_iodata(atom) when is_atom(atom), do: encode_string(Atom.to_string(atom))
  defp to_iodata(str) when is_binary(str), do: encode_string(str)

  defp to_iodata(list) when is_list(list) do
    ["[", list |> Enum.map(&to_iodata/1) |> Enum.intersperse(","), "]"]
  end

  defp to_iodata(map) when is_map(map) do
    body =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [encode_string(k), ":", to_iodata(v)] end)
      |> Enum.intersperse(",")

    ["{", body, "}"]
  end

  # A JSON string, escaped exactly as Jason would, so the bytes match what
  # consumers reproduce with a standard JSON encoder.
  defp encode_string(str), do: Jason.encode!(str)
end
