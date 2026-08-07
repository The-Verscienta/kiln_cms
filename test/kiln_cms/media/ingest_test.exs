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
  end

  describe "max_upload_size/0" do
    test "is the ceiling the upload UI advertises" do
      assert Ingest.max_upload_size() == 500_000_000
    end
  end
end
