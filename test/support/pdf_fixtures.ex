defmodule KilnCMS.PdfFixtures do
  @moduledoc """
  Minimal but **structurally valid** PDFs for tests.

  Built here rather than committed as binary fixtures for two reasons. The
  assertions are about specific strings being present before a strip and absent
  after, which a blob nobody can read makes impossible to review. And the file
  has to be real: since #807 an uploaded PDF is rewritten by qpdf before it is
  stored, so `"%PDF-1.7\\nsome bytes"` — which satisfied the magic-byte check —
  is no longer storable. That is the feature working (a file no parser can read
  is refused rather than kept), but it means any test that goes through the
  *upload* path needs a document qpdf can actually parse.

  Tests that only write a blob straight to storage, or that exercise the
  magic-byte check alone, do not need this and should keep using a short
  literal — it is cheaper and says what it is testing.
  """

  @doc """
  A one-page PDF.

  With `metadata: true` it also carries an `/Info` dictionary, a **document**
  XMP packet, a **page-level** XMP packet, a `/PieceInfo` private dictionary
  and an outline — so a test can tell "stripped the metadata" apart from
  "rebuilt the file and lost the bookmarks", and apart from "cleared the two
  document-level fields and left everything Illustrator writes".

  The page-level pair matters more than it looks: this fixture used to attach
  `/Metadata` to the Catalog only, so `metadata_markers/0` passed while
  `qpdf --remove-info --remove-metadata` was leaving per-page XMP and
  `/PieceInfo` in the stored file (#918). A fixture that only carries what the
  implementation already handles cannot fail.

  The strings it embeds are returned by `metadata_markers/0` and
  `content_markers/0` so assertions never restate them.
  """
  @spec pdf(keyword()) :: binary()
  def pdf(opts \\ []) do
    if Keyword.get(opts, :metadata, false), do: build(with_metadata()), else: build(plain())
  end

  @doc "Strings a stripped PDF must NOT contain."
  @spec metadata_markers() :: [String.t()]
  def metadata_markers,
    do: [
      "Jane Author",
      "Quarterly Secrets",
      "SecretApp",
      "InternalTool",
      # Page-level XMP and /PieceInfo (#918) — the two the document-level flags
      # do not reach.
      "Page Level Author",
      "PieceInfoSecretPath",
      # A STREAM object's dictionary (#918). qpdf's JSON gives streams a
      # different shape from plain objects, and image/Form XObjects — which are
      # streams — are where a placed asset's original XMP and Photoshop's
      # `/PieceInfo` actually live. Matching only the plain shape missed the
      # most common real-world carrier.
      "XObject Level Author",
      "XObjectPieceInfoPath",
      # A DIRECT (inline) sub-dictionary, one level down from the object.
      "NestedAnnotSecret"
    ]

  @doc "Strings a stripped PDF MUST still contain — the document itself."
  @spec content_markers() :: [String.t()]
  def content_markers, do: ["Kiln page body", "Chapter One"]

  defp plain do
    [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      page_object(),
      stream("BT /F1 12 Tf 20 100 Td (Kiln page body) Tj ET", ""),
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    ]
  end

  defp with_metadata do
    [
      "<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R /Metadata 8 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      page_object(page_metadata()),
      stream("BT /F1 12 Tf 20 100 Td (Kiln page body) Tj ET", ""),
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      "<< /Type /Outlines /First 7 0 R /Last 7 0 R /Count 1 >>",
      "<< /Title (Chapter One) /Parent 6 0 R /Dest [3 0 R /Fit] >>",
      stream(xmp("Jane Author"), "/Type /Metadata /Subtype /XML "),
      "<< /Title (Quarterly Secrets) /Author (Jane Author) " <>
        "/Creator (SecretApp 4.2) /Producer (InternalTool) >>",
      stream(xmp("Page Level Author"), "/Type /Metadata /Subtype /XML "),
      # A Form XObject: a STREAM whose dictionary carries both markers.
      stream(
        "0 0 10 10 re f",
        "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Metadata 12 0 R " <>
          "/PieceInfo << /Photoshop << /Private (XObjectPieceInfoPath) >> >> "
      ),
      stream(xmp("XObject Level Author"), "/Type /Metadata /Subtype /XML ")
    ]
  end

  defp page_object(extra \\ "") do
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R " <>
      "/Resources << /Font << /F1 5 0 R >> >>#{extra} >>"
  end

  # What a real authoring tool leaves on the page itself: an XMP packet and a
  # private blob carrying the authoring machine's filesystem path.
  defp page_metadata do
    # A direct annotation dictionary — `/Metadata` nested one level down,
    # where a top-level key drop never reaches it.
    " /Metadata 10 0 R /PieceInfo << /Illustrator << /LastModified " <>
      "(D:20250101000000Z) /Private (C:\\\\Users\\\\jane\\\\PieceInfoSecretPath) >> >>" <>
      " /XObject << /X1 11 0 R >>" <>
      " /Annots [<< /Type /Annot /Subtype /Square /Rect [0 0 10 10] " <>
      "/PieceInfo << /App << /Private (NestedAnnotSecret) >> >> >>]"
  end

  defp stream(data, extra),
    do: "<< #{extra}/Length #{byte_size(data)} >>\nstream\n#{data}\nendstream"

  defp xmp(creator) do
    ~s(<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>) <>
      ~s(<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF ) <>
      ~s(xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">) <>
      ~s(<rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>) <>
      ~s(<rdf:Seq><rdf:li>#{creator}</rdf:li></rdf:Seq></dc:creator>) <>
      ~s(</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="w"?>)
  end

  # The xref table has to carry each object's real byte offset — qpdf reads it,
  # and a wrong offset makes the file "damaged", which is exactly the state
  # these fixtures exist to avoid.
  defp build(objects) do
    {body, offsets} =
      Enum.reduce(Enum.with_index(objects, 1), {"%PDF-1.7\n", []}, fn {obj, i}, {acc, offs} ->
        {acc <> "#{i} 0 obj\n#{obj}\nendobj\n", [byte_size(acc) | offs]}
      end)

    count = length(objects) + 1

    table =
      offsets
      |> Enum.reverse()
      |> Enum.map_join(&to_string(:io_lib.format("~10..0B 00000 n \n", [&1])))

    info = if length(objects) >= 9, do: " /Info 9 0 R", else: ""

    body <>
      "xref\n0 #{count}\n0000000000 65535 f \n" <>
      table <>
      "trailer\n<< /Size #{count} /Root 1 0 R#{info} >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end
