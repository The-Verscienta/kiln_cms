defmodule KilnCMS.DocumentProcessorTest do
  @moduledoc """
  Byte-sniffed document validation (#481) — never trusts the filename/MIME a
  client claims, only the actual bytes, same posture as `ImageProcessor`.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.DocumentProcessor

  defp tmp_file(contents) do
    path = Path.join(System.tmp_dir!(), "docproc_#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    path
  end

  test "accepts a file starting with the PDF magic header" do
    path = tmp_file("%PDF-1.7\n%\xE2\xE3\xCF\xD3\nrest of a real pdf...")

    assert {:ok, %{ext: ".pdf", content_type: "application/pdf"}} =
             DocumentProcessor.validate_upload(path)
  end

  test "rejects a file with a .pdf-looking name but non-PDF bytes" do
    path = tmp_file("<html><body>not a pdf</body></html>")
    assert {:error, :unsupported_format} = DocumentProcessor.validate_upload(path)
  end

  test "rejects a plain text file" do
    path = tmp_file("just some text")
    assert {:error, :unsupported_format} = DocumentProcessor.validate_upload(path)
  end

  test "rejects an empty file" do
    path = tmp_file("")
    assert {:error, :unsupported_format} = DocumentProcessor.validate_upload(path)
  end

  test "rejects a JPEG (an image should go through ImageProcessor, not this)" do
    path = tmp_file(<<0xFF, 0xD8, 0xFF, 0xE0, "rest of jpeg header">>)
    assert {:error, :unsupported_format} = DocumentProcessor.validate_upload(path)
  end

  test "errors gracefully for a nonexistent path" do
    assert {:error, :unsupported_format} =
             DocumentProcessor.validate_upload("/nonexistent/#{System.unique_integer()}")
  end
end
