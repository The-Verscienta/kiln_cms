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

  describe "strip_metadata/1 (#807)" do
    defp pdf_with_metadata, do: tmp_file(KilnCMS.PdfFixtures.pdf(metadata: true))

    # qpdf compresses what it writes, so the stripped file has to be expanded
    # before a grep means anything. Asserting on the compressed bytes would
    # "pass" for content that is merely deflated — including the metadata this
    # is supposed to have removed.
    defp expanded(path) do
      out = Path.join(System.tmp_dir!(), "expanded_#{System.unique_integer([:positive])}.pdf")
      {_, 0} = System.cmd("qpdf", ["--qdf", "--object-streams=disable", path, out])
      on_exit(fn -> File.rm(out) end)
      File.read!(out)
    end

    @tag :qpdf
    test "removes the /Info dictionary and the XMP packet" do
      source = pdf_with_metadata()
      assert File.read!(source) =~ "Jane Author"

      assert {:ok, stripped} = DocumentProcessor.strip_metadata(source)
      on_exit(fn -> File.rm(stripped) end)

      content = expanded(stripped)

      for marker <- KilnCMS.PdfFixtures.metadata_markers() do
        refute content =~ marker, "#{marker} survived the strip"
      end
    end

    @tag :qpdf
    test "keeps the document intact — page content and bookmarks survive" do
      # The reason this uses `--remove-info --remove-metadata` rather than the
      # `--empty --pages` idiom, which also strips metadata but rebuilds the
      # file from its pages and drops the outline. Measured, not assumed.
      assert {:ok, stripped} = DocumentProcessor.strip_metadata(pdf_with_metadata())
      on_exit(fn -> File.rm(stripped) end)

      content = expanded(stripped)

      for marker <- KilnCMS.PdfFixtures.content_markers() do
        assert content =~ marker, "#{marker} was destroyed by the strip"
      end
    end

    @tag :qpdf
    test "writes a new file and leaves the original alone" do
      source = pdf_with_metadata()
      before = File.read!(source)

      assert {:ok, stripped} = DocumentProcessor.strip_metadata(source)
      on_exit(fn -> File.rm(stripped) end)

      assert stripped != source
      assert File.read!(source) == before
    end

    @tag :qpdf
    test "refuses a file qpdf cannot parse rather than passing it through" do
      # `validate_upload/1` only checks the first five bytes, so a truncated or
      # corrupt PDF reaches this. Storing it unstripped because the stripper
      # choked is the exact failure this feature exists to prevent.
      path = tmp_file("%PDF-1.7\nthis is not actually a pdf body")

      assert {:error, :strip_failed} = DocumentProcessor.strip_metadata(path)
    end

    test "reports unavailable — and refuses — when there is no capable qpdf" do
      # The posture that distinguishes this from AVProcessor: no stripper means
      # the upload fails, never "stored as it came".
      :persistent_term.put({DocumentProcessor, :available?}, false)
      on_exit(&DocumentProcessor.reset_available_cache/0)

      refute DocumentProcessor.available?()
      assert {:error, :unavailable} = DocumentProcessor.strip_metadata(pdf_with_metadata())
    end
  end
end
