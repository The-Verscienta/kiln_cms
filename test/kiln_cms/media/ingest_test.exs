defmodule KilnCMS.Media.IngestTest do
  @moduledoc """
  The shared media ingest pipeline (#487).

  The upload path is covered end-to-end by `KilnCMSWeb.MediaLiveTest`, which
  now runs through this module. What is pinned here is the part that has no
  other caller and the most to lose: `store_url/2` is pointed at URLs taken
  from a file someone uploaded, which makes it a server-side request forgery
  primitive if it fetches whatever it is handed.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Media.Ingest

  defp actor do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ingest-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  describe "store_url/2 refuses unsafe targets" do
    test "loopback" do
      assert {:error, {:unsafe_url, _}} = Ingest.store_url("http://localhost/pic.jpg")
      assert {:error, {:unsafe_url, _}} = Ingest.store_url("http://127.0.0.1/pic.jpg")
    end

    test "private ranges" do
      assert {:error, {:unsafe_url, _}} = Ingest.store_url("http://10.0.0.5/pic.jpg")
      assert {:error, {:unsafe_url, _}} = Ingest.store_url("http://192.168.1.1/pic.jpg")
    end

    # The single most valuable target on a cloud host.
    test "the cloud metadata endpoint" do
      assert {:error, {:unsafe_url, _}} =
               Ingest.store_url("http://169.254.169.254/latest/meta-data/")
    end

    test "a non-http scheme" do
      assert {:error, {:unsafe_url, _}} = Ingest.store_url("file:///etc/passwd")
      assert {:error, {:unsafe_url, _}} = Ingest.store_url("gopher://example.com/")
    end

    test "garbage that is not a URL at all" do
      assert {:error, {:unsafe_url, _}} = Ingest.store_url("not a url")
      assert {:error, {:unsafe_url, _}} = Ingest.store_url("")
    end
  end

  describe "store_file/3" do
    test "refuses a file no processor recognises, and writes nothing" do
      path = Path.join(System.tmp_dir!(), "ingest-#{System.unique_integer([:positive])}.bin")
      File.write!(path, "this is not an image, a video, or a document")

      on_exit(fn -> File.rm(path) end)

      assert {:error, _reason} = Ingest.store_file(path, "junk.bin", actor: actor())
    end

    test "leaves the caller's file in place" do
      path = Path.join(System.tmp_dir!(), "ingest-#{System.unique_integer([:positive])}.bin")
      File.write!(path, "junk")
      on_exit(fn -> File.rm(path) end)

      Ingest.store_file(path, "junk.bin", actor: actor())

      assert File.exists?(path)
    end

    # #807 stripped PDF metadata in `MediaLive`'s own upload chain. Moving that
    # chain into this module (#487) could silently drop it — nothing else asserts
    # that an INGESTED pdf is stripped, only that `DocumentProcessor` can strip
    # one. So the guarantee is pinned against the blob that actually gets stored.
    @tag :qpdf
    test "a pdf is stored stripped of its metadata" do
      path = Path.join(System.tmp_dir!(), "ingest-#{System.unique_integer([:positive])}.pdf")
      File.write!(path, KilnCMS.PdfFixtures.pdf(metadata: true))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, item} = Ingest.store_file(path, "report.pdf", actor: actor())

      {:ok, stored} = KilnCMS.Storage.fetch(item.storage_key)

      # The STORED blob, not the strip's return value: the bug this guards
      # against is storing the original after stripping a copy.
      for marker <- KilnCMS.PdfFixtures.metadata_markers() do
        refute String.contains?(stored, marker), "#{marker} survived into the stored blob"
      end

      # That the content survives a strip is `DocumentProcessorTest`'s job (it
      # expands the compressed streams to check). Here it is enough that what
      # landed is still a PDF and not a truncated or empty file.
      assert String.starts_with?(stored, "%PDF-")
      assert byte_size(stored) > 100
    end
  end

  describe "max_upload_size/0" do
    test "is the ceiling the upload UI advertises" do
      assert Ingest.max_upload_size() == 500_000_000
    end
  end

  # #820: an MP4 off a phone carries GPS, device model, OS version and often a
  # local wall-clock creation date. ffmpeg is an OPTIONAL dependency, so the
  # guarantee is conditional — and these two tests pin exactly what the
  # condition is, which is the part an operator has to be able to rely on.
  #
  # The no-ffmpeg branch is where the privacy promise is weakest, so it is
  # pinned here; the strip-succeeds branch is pinned in `AVProcessorTest`
  # behind the `:ffmpeg` tag, where ffprobe can read the output back and show
  # the GPS is actually gone.
  #
  # Both of the no-ffmpeg tests below are `:no_ffmpeg`-tagged rather than
  # wrapped in `if available?() do :ok else ... end`. The wrapped form was the
  # first cut and it was wrong: on any machine with ffmpeg it reported green
  # having asserted nothing, which is precisely what `test/test_helper.exs`
  # warns about two comments running.
  describe "A/V metadata stripping (#820)" do
    # Minimal ISO-BMFF: a 4-byte size, `ftyp`, then an allowlisted brand.
    defp mp4_path do
      path = Path.join(System.tmp_dir!(), "ingest-#{System.unique_integer([:positive])}.mp4")
      File.write!(path, <<0, 0, 0, 24>> <> "ftyp" <> "isom" <> String.duplicate("\0", 64))
      on_exit(fn -> File.rm(path) end)
      path
    end

    @tag :no_ffmpeg
    test "without ffmpeg the upload still lands, and says so" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, item} = Ingest.store_file(mp4_path(), "clip.mp4", actor: actor())
          assert item.content_type == "video/mp4"
        end)

      # The gap must be visible rather than assumed away.
      assert log =~ "container metadata intact"
      assert log =~ "Install ffmpeg"
    end

    @tag :no_ffmpeg
    test "require_av_metadata_strip refuses, and blames the server not the file" do
      previous = Application.fetch_env(:kiln_cms, :require_av_metadata_strip)
      Application.put_env(:kiln_cms, :require_av_metadata_strip, true)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:kiln_cms, :require_av_metadata_strip, value)
          :error -> Application.delete_env(:kiln_cms, :require_av_metadata_strip)
        end
      end)

      # `:av_strip_unavailable`, not `:strip_failed` — the two get different
      # words in front of an editor, because retrying fixes exactly one of
      # them and the PDF-flavoured `:unavailable` copy names the wrong
      # subsystem entirely.
      assert {:error, :av_strip_unavailable} =
               Ingest.store_file(mp4_path(), "clip.mp4", actor: actor())
    end

    # #1100. Every other strip failure is a standing property of the host or the
    # file — ffmpeg is absent, or this container will never remux — and the
    # default stores the upload rather than making it permanently unuploadable.
    # Running out of temp disk is none of those: it is transient, retrying
    # works, and it is the one condition under which the privacy guarantee
    # lapses while nobody is watching. So it is refused whatever the flag says,
    # and this test asserts that with the flag explicitly OFF.
    @tag :ffmpeg
    test "no temp space refuses the upload even with the strip not required" do
      previous = Application.fetch_env(:kiln_cms, :require_av_metadata_strip)
      Application.put_env(:kiln_cms, :require_av_metadata_strip, false)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:kiln_cms, :require_av_metadata_strip, value)
          :error -> Application.delete_env(:kiln_cms, :require_av_metadata_strip)
        end
      end)

      # A file whose `stat` size no disk can hold a copy of, written as a hole
      # rather than 8 TB of bytes. `max_bytes` is raised past it so the size cap
      # — which is checked first, and would otherwise refuse this as
      # `:too_large` — is not what the assertion ends up measuring.
      size = 8_000_000_000_000
      path = Path.join(System.tmp_dir!(), "ingest-#{System.unique_integer([:positive])}.mp4")

      {:ok, fd} = :file.open(path, [:write, :binary])
      :ok = :file.write(fd, <<0, 0, 0, 24>> <> "ftyp" <> "isom" <> String.duplicate("\0", 64))
      :ok = :file.pwrite(fd, size, <<0>>)
      :ok = :file.close(fd)
      on_exit(fn -> File.rm(path) end)

      assert File.stat!(path).size == size + 1

      assert {:error, :av_strip_no_space} =
               Ingest.store_file(path, "huge.mp4", actor: actor(), max_bytes: size + 2)
    end

    # A caption track is text this codebase already parsed — there is no
    # container metadata, and it must not be routed through ffmpeg.
    test "a WebVTT track is stored without a strip attempt" do
      path = Path.join(System.tmp_dir!(), "ingest-#{System.unique_integer([:positive])}.vtt")
      File.write!(path, "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello\n")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, item} = Ingest.store_file(path, "captions.vtt", actor: actor())
      assert item.content_type == "text/vtt"
    end
  end
end
