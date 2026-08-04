defmodule KilnCMS.DocumentProcessor do
  @moduledoc """
  Byte-validates a non-image document upload (#481) — the `KilnCMS.ImageProcessor`
  analogue for the document library, deny-by-default and magic-byte-sniffed
  (never the client-supplied filename/MIME).

  PDF only for v1: `@allowed_formats` is a single-entry map so the shape
  matches `ImageProcessor.validate_upload/1`'s and stays trivial to extend
  when office-doc/zip support lands (tracked separately, out of scope here).

  Unlike `ImageProcessor`, there is no `strip_metadata/2` — PDF metadata
  (XMP, the `/Info` dict, embedded author/producer strings) is a genuinely
  separate problem needing PDF-specific tooling this codebase doesn't have
  yet. Deliberately deferred, not an oversight — see the follow-up issue.
  """

  # Canonical {extension, content_type} per magic-byte signature this module
  # recognizes. Deny-by-default: anything else is rejected, same posture as
  # ImageProcessor's `@allowed_formats`.
  @allowed_formats %{
    "%PDF-" => {".pdf", "application/pdf"}
  }

  @doc """
  Returns `{:ok, %{ext: ".pdf", content_type: "application/pdf"}}` when `path`
  starts with a recognized document magic byte signature. Rejects anything
  else — including a file that merely has a `.pdf` extension — with
  `{:error, :unsupported_format}`.
  """
  # `path` is a LiveView upload's own server-generated temp file, never user
  # input — the traversal warning is a false positive (same reasoning as
  # ImageProcessor's temp-file reads/writes).
  # sobelow_skip ["Traversal.FileModule"]
  @spec validate_upload(Path.t()) ::
          {:ok, %{ext: String.t(), content_type: String.t()}} | {:error, term()}
  def validate_upload(path) when is_binary(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 1024)) do
      {:ok, header} when is_binary(header) -> match_signature(header)
      _ -> {:error, :unsupported_format}
    end
  end

  defp match_signature(header) do
    @allowed_formats
    |> Enum.find(fn {sig, _fmt} -> String.starts_with?(header, sig) end)
    |> case do
      {_sig, {ext, content_type}} -> {:ok, %{ext: ext, content_type: content_type}}
      nil -> {:error, :unsupported_format}
    end
  end
end
