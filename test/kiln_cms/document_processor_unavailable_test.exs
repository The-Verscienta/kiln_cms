defmodule KilnCMS.DocumentProcessorUnavailableTest do
  @moduledoc """
  `KilnCMS.DocumentProcessor` with no capable qpdf (#807): it says so, and it
  refuses rather than storing a PDF as it came.

  Split out of `KilnCMS.DocumentProcessorTest` and `async: false` because it
  forces the `available?/0` cache, a `:persistent_term` the whole VM shares and
  the upload path reads: while it ran async, a concurrent PDF upload would be
  refused (#2380).
  """
  use ExUnit.Case, async: false

  alias KilnCMS.DocumentProcessor

  test "reports unavailable — and refuses — when there is no capable qpdf" do
    path = Path.join(System.tmp_dir!(), "docproc_#{System.unique_integer([:positive])}")
    File.write!(path, KilnCMS.PdfFixtures.pdf(metadata: true))
    on_exit(fn -> File.rm(path) end)

    # The posture that distinguishes this from AVProcessor: no stripper means
    # the upload fails, never "stored as it came".
    :persistent_term.put({DocumentProcessor, :available?}, false)
    # Erasing makes the next `available?/0` probe the host again, which puts
    # back whatever it really is.
    on_exit(&DocumentProcessor.reset_available_cache/0)

    refute DocumentProcessor.available?()
    assert {:error, :unavailable} = DocumentProcessor.strip_metadata(path)
  end
end
