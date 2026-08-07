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

    @tag :qpdf
    test "removes PAGE-level XMP and /PieceInfo, which the two flags do not (#918)" do
      # Named separately from the marker sweep above because this is the pair
      # `--remove-info --remove-metadata` leaves behind, and every PDF
      # Illustrator, InDesign or Acrobat writes carries them. `/PieceInfo` in
      # particular holds the authoring machine's filesystem path.
      source = pdf_with_metadata()
      before = File.read!(source)

      # The fixture has to actually carry them, or this passes vacuously — the
      # exact way CI missed the gap in the first place.
      assert before =~ "Page Level Author"
      assert before =~ "PieceInfoSecretPath"

      assert {:ok, stripped} = DocumentProcessor.strip_metadata(source)
      on_exit(fn -> File.rm(stripped) end)

      content = expanded(stripped)

      refute content =~ "Page Level Author"
      refute content =~ "PieceInfoSecretPath"
      # …and the page itself is still there.
      assert content =~ "Kiln page body"
    end

    @tag :qpdf
    test "prunes STREAM objects and nested dictionaries, not just page dicts (#918)" do
      # qpdf's JSON gives a stream object a different shape (`"stream"`, not
      # `"value"`), and image/Form XObjects are streams — which is where a
      # placed asset's original XMP and Photoshop's `/PieceInfo` actually live.
      # Matching only the plain shape missed the most common real-world carrier
      # while the moduledoc claimed otherwise.
      source = pdf_with_metadata()
      before = File.read!(source)

      for marker <- ["XObject Level Author", "XObjectPieceInfoPath", "NestedAnnotSecret"] do
        assert before =~ marker, "the fixture must carry #{marker} for this to mean anything"
      end

      assert {:ok, stripped} = DocumentProcessor.strip_metadata(source)
      on_exit(fn -> File.rm(stripped) end)

      content = expanded(stripped)

      refute content =~ "XObject Level Author"
      refute content =~ "XObjectPieceInfoPath"
      # A direct (inline) annotation dictionary, one level below the object.
      refute content =~ "NestedAnnotSecret"
    end

    @tag :qpdf
    test "prunes a DAMAGED-xref PDF too, where qpdf emits warnings (#918)" do
      # The object dump goes to a file rather than stdout precisely because of
      # this: qpdf merges stderr into stdout, and any file whose xref it
      # reconstructs prints `WARNING:` lines first. Read from stdout, they land
      # in front of the JSON, `Jason.decode/1` fails, and the prune is silently
      # skipped — on exactly the files a sloppy authoring tool produced.
      source = KilnCMS.PdfFixtures.pdf(metadata: true)
      damaged = tmp_file(String.replace(source, ~r/startxref\n\d+/, "startxref\n999999"))

      assert {:ok, stripped} = DocumentProcessor.strip_metadata(damaged)
      on_exit(fn -> File.rm(stripped) end)

      content = expanded(stripped)

      for marker <- KilnCMS.PdfFixtures.metadata_markers() do
        refute content =~ marker, "#{marker} survived the strip of a damaged file"
      end
    end

    @tag :qpdf
    test "an owner-password-only PDF is stripped, not refused (#918)" do
      # `qpdf --is-encrypted` exits 0 for these too, so probing encryption up
      # front refused every "restrict printing/editing" export — files that open
      # with no password anywhere and that qpdf strips perfectly well. The
      # uploader was told to remove a password that does not exist.
      source = pdf_with_metadata()
      restricted = Path.join(System.tmp_dir!(), "own_#{System.unique_integer([:positive])}.pdf")
      on_exit(fn -> File.rm(restricted) end)

      {_out, 0} =
        System.cmd("qpdf", [
          "--encrypt",
          "--owner-password=owner",
          "--user-password=",
          "--bits=256",
          "--",
          source,
          restricted
        ])

      assert {:ok, stripped} = DocumentProcessor.strip_metadata(restricted)
      on_exit(fn -> File.rm(stripped) end)
    end

    @tag :qpdf
    test "refuses a password-protected PDF with a reason the uploader can act on" do
      # qpdf cannot open a user-password-encrypted file, so it cannot strip one.
      # Distinct from `:strip_failed`: that means "this file is broken", this
      # means "unlock it first", and only one of them is actionable.
      source = pdf_with_metadata()
      encrypted = Path.join(System.tmp_dir!(), "enc_#{System.unique_integer([:positive])}.pdf")
      on_exit(fn -> File.rm(encrypted) end)

      {_out, 0} =
        System.cmd("qpdf", [
          "--encrypt",
          "--user-password=secret",
          "--owner-password=owner",
          "--bits=256",
          "--",
          source,
          encrypted
        ])

      assert {:error, :encrypted} = DocumentProcessor.strip_metadata(encrypted)
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
