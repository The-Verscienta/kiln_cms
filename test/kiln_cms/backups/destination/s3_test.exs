defmodule KilnCMS.Backups.Destination.S3Test do
  @moduledoc """
  The S3 backup destination (#2221) against `KilnCMS.Test.FakeS3`: copying
  small and multipart files, resuming an upload from a checkpoint the store
  must confirm, the deadline and `save`'s answers, how the store's errors
  are classified (and never echoed), listing, ranged reads, deleting,
  aborting and the Test button.

  The test env sends files of 1 KiB or more in parts of 1 KiB, reads 1,500
  bytes at a time and retries without waiting (`config/test.exs`).
  """
  use ExUnit.Case, async: true

  alias Kiln.BackupDestination.{Config, Resume}
  alias KilnCMS.Backups.Destination.S3
  alias KilnCMS.Backups.Destination.S3.{Client, Endpoint, Errors, Multipart}
  alias KilnCMS.Test.FakeS3

  @moduletag :tmp_dir

  @secret "very-secret-access-key-xyz"
  @key_id "AKIDTESTKEY123"

  defp config(settings \\ %{}) do
    %Config{
      id: nil,
      key: "dest:s3",
      kind: "s3",
      settings:
        Map.merge(
          %{
            "endpoint" => "https://s3.test",
            "region" => "us-east-1",
            "bucket" => "kiln-backups",
            "prefix" => "site/a",
            "path_style" => true
          },
          settings
        ),
      secrets: %{"access_key_id" => @key_id, "secret_access_key" => @secret}
    }
  end

  defp file!(dir, bytes, name \\ "kiln-db-20261117-000000.dump") do
    path = Path.join(dir, name)
    body = :crypto.strong_rand_bytes(bytes)
    File.write!(path, body)

    %{
      path: path,
      subdir: "db",
      name: name,
      bytes: bytes,
      sha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    }
  end

  defp key(file), do: "site/a/#{file.subdir}/#{file.name}"

  # A Resume whose saves are sent to the test, answered by `answer`.
  defp resume(checkpoint \\ nil, answer \\ fn _n -> :ok end) do
    test = self()
    counter = :counters.new(1, [])

    %Resume{
      checkpoint: checkpoint,
      save: fn checkpoint ->
        :counters.add(counter, 1, 1)
        send(test, {:saved, checkpoint})
        answer.(:counters.get(counter, 1))
      end
    }
  end

  # The last checkpoint saved, as it comes back from the database.
  defp last_saved do
    checkpoints = saved()
    checkpoints |> List.last() |> Jason.encode!() |> Jason.decode!()
  end

  defp saved do
    receive do
      {:saved, checkpoint} -> [checkpoint | saved()]
    after
      0 -> []
    end
  end

  defp parts_sent(fake) do
    for {:upload_part, _key, %{"partNumber" => n}} <- FakeS3.requests(fake),
        do: String.to_integer(n)
  end

  defp put(file, opts \\ []), do: S3.put(config(), file, opts)

  defp sha256(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)

  describe "validate/1" do
    test "accepts a well-formed destination, offline" do
      assert S3.validate(config()) == :ok
      assert S3.validate(config(%{"region" => "auto", "prefix" => nil})) == :ok
    end

    test "refuses http://, private and metadata hosts unless listed, and never metadata" do
      assert {:error, "the endpoint must use https://" <> _} =
               S3.validate(config(%{"endpoint" => "http://s3.test"}))

      assert {:error, "the endpoint resolves to a private" <> _} =
               S3.validate(config(%{"endpoint" => "https://10.0.0.5"}))

      assert {:error, "the endpoint must not be a .local" <> _} =
               S3.validate(config(%{"endpoint" => "https://minio.local"}))

      assert {:error, "the endpoint must not be a loopback host"} =
               S3.validate(config(%{"endpoint" => "https://localhost:9000"}))

      assert {:error, "the endpoint must not be a metadata host"} =
               S3.validate(config(%{"endpoint" => "https://metadata.google.internal"}))

      assert {:error, _} = S3.validate(config(%{"endpoint" => "https://169.254.169.254"}))
    end

    test "a host BACKUP_S3_PRIVATE_HOSTS lists may be private and http://, but never link-local" do
      settings = %{"endpoint" => "http://minio.lan:9000", "bucket" => "kiln-backups"}

      assert {:ok, %Endpoint{scheme: "http", host: "minio.lan", port: 9000}} =
               Endpoint.parse(config(settings).settings, ["minio.lan"])

      assert {:ok, _} =
               Endpoint.parse(config(%{"endpoint" => "http://10.0.0.5"}).settings, ["10.0.0.5"])

      assert {:ok, _} =
               Endpoint.parse(config(%{"endpoint" => "https://garage.internal"}).settings, [
                 "garage.internal"
               ])

      assert {:error, "the endpoint resolves to a link-local" <> _} =
               Endpoint.parse(config(%{"endpoint" => "http://169.254.169.254"}).settings, [
                 "169.254.169.254"
               ])

      assert {:error, "the endpoint must not be a metadata host"} =
               Endpoint.parse(
                 config(%{"endpoint" => "http://metadata.google.internal"}).settings,
                 [
                   "metadata.google.internal"
                 ]
               )

      # Exact names only: a listed name opens neither its subdomains nor its parent.
      assert {:error, _} =
               Endpoint.parse(config(%{"endpoint" => "http://x.minio.lan"}).settings, [
                 "minio.lan"
               ])
    end

    test "a listing names the host connected to: a virtual-hosted bucket needs its own name" do
      settings = fn endpoint, path_style ->
        config(%{"endpoint" => endpoint, "bucket" => "vault", "path_style" => path_style}).settings
      end

      assert {:error, _} =
               Endpoint.parse(settings.("http://corp.internal", false), ["corp.internal"])

      assert {:error, _} =
               Endpoint.parse(settings.("https://corp.internal", false), ["corp.internal"])

      assert {:ok, _} = Endpoint.parse(settings.("http://corp.internal", true), ["corp.internal"])

      assert {:ok, %Endpoint{path_style?: false}} =
               Endpoint.parse(settings.("http://corp.internal", false), ["vault.corp.internal"])
    end

    test "no listing opens link-local reached through NAT64 or 6to4" do
      refute Endpoint.allowed_address?({0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE}, true)
      refute Endpoint.allowed_address?({0x2002, 0xA9FE, 0xA9FE, 0, 0, 0, 0, 1}, true)
      assert Endpoint.allowed_address?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0005}, true)
      refute Endpoint.allowed_address?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0005}, false)
    end

    test "checks the bucket, region and prefix" do
      assert {:error, "the bucket name must be" <> _} = S3.validate(config(%{"bucket" => "Kiln"}))

      assert {:error, "the bucket name must not have" <> _} =
               S3.validate(config(%{"bucket" => "a..b"}))

      assert {:error, "the bucket name must not look like" <> _} =
               S3.validate(config(%{"bucket" => "10.0.0.1"}))

      assert {:error, "the region must be" <> _} = S3.validate(config(%{"region" => "US East"}))
      assert {:error, "the prefix must be" <> _} = S3.validate(config(%{"prefix" => "a/../b"}))
      assert {:error, "the prefix must be" <> _} = S3.validate(config(%{"prefix" => "a b"}))

      assert {:error, "the endpoint must not have a path"} =
               S3.validate(config(%{"endpoint" => "https://s3.test/x"}))

      assert {:error, "the endpoint must not contain credentials"} =
               S3.validate(config(%{"endpoint" => "https://u:p@s3.test"}))
    end

    test "requires both keys" do
      assert {:error, "the secret access key is missing"} =
               S3.validate(%{config() | secrets: %{"access_key_id" => @key_id}})

      assert {:error, "the access key id is missing"} =
               S3.validate(%{config() | secrets: %{"secret_access_key" => @secret}})
    end

    test "a dotted bucket, or an IP endpoint, is addressed path-style" do
      {:ok, dotted} =
        Endpoint.parse(config(%{"bucket" => "kiln.backups", "path_style" => false}).settings)

      assert dotted.path_style?
      assert Endpoint.url(dotted, "db/x") == "https://s3.test/kiln.backups/db/x"

      {:ok, virtual} = Endpoint.parse(config(%{"path_style" => false}).settings)
      refute virtual.path_style?
      assert Endpoint.url(virtual, "db/x", "a=b") == "https://kiln-backups.s3.test/db/x?a=b"
    end
  end

  describe "put/3, small files" do
    test "sends one PutObject with Content-MD5 and the sha256 as metadata", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 500)

      assert put(file, resume: resume()) == :ok

      object = FakeS3.object(fake, key(file))
      assert sha256(object.body) == file.sha256
      assert object.meta["kiln-sha256"] == file.sha256
      assert FakeS3.count(fake, :put_object) == 1
      assert FakeS3.count(fake, :create_multipart) == 0
      assert saved() == []
    end

    test "a file already there, same size and sha256, is not sent again", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 500)
      :ok = put(file)

      assert put(file) == {:ok, :already_present}
      assert FakeS3.count(fake, :put_object) == 1
    end

    test "a file that changed since it was verified is not sent", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 500)
      File.write!(file.path, "something else")

      assert {:error, message} = put(%{file | bytes: 14})
      assert message =~ "changed since it was verified"
      assert FakeS3.count(fake, :put_object) == 0
    end

    test "a file over 5 TiB is refused before anything is sent", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 10)

      assert {:error, {:permanent, message}} =
               put(%{file | bytes: Multipart.max_object_bytes() + 1})

      assert message =~ "5 TiB"
      assert FakeS3.requests(fake) == []
    end
  end

  describe "put/3, multipart" do
    test "sends sequential parts, saving after the create and after each part", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)

      assert put(file, resume: resume()) == :ok

      assert sha256(FakeS3.object(fake, key(file)).body) == file.sha256
      assert FakeS3.object(fake, key(file)).meta["kiln-sha256"] == file.sha256
      assert FakeS3.uploads(fake) == %{}
      assert parts_sent(fake) == [1, 2, 3, 4, 5]

      checkpoints = saved()
      assert length(checkpoints) == 6
      assert [%{parts_done: 0, bytes_done: 0} | _] = checkpoints
      last = List.last(checkpoints)
      assert %{parts_done: 5, bytes_done: 5_000, part_size: 1024, md5_etags: true} = last
      assert last.key == key(file)
      assert byte_size(Jason.encode!(last)) < 1024
    end

    test "the part size grows past 9,000 parts, in whole MiB" do
      mib = 1024 * 1024
      assert Multipart.part_size(100 * mib) == 16 * mib
      assert Multipart.part_size(9_000 * 16 * mib) == 16 * mib
      assert Multipart.part_size(9_000 * 16 * mib + 1) == 17 * mib
      assert Multipart.part_size(5 * 1024 * 1024 * mib) == 583 * mib
      assert div(5 * 1024 * 1024 * mib + 583 * mib - 1, 583 * mib) <= 10_000
    end

    test "a cut-off upload resumes after the parts the store confirms", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      # Part 3 never gets through on the first attempt: six tries, all dropped.
      FakeS3.inject(fake, :upload_part, :drop, skip: 2, times: 6)

      assert {:error, message} = put(file, resume: resume())
      assert message =~ "couldn't reach the store"
      assert FakeS3.object(fake, key(file)) == nil

      checkpoint = last_saved()
      assert checkpoint["parts_done"] == 2

      assert put(file, resume: resume(checkpoint)) == :ok

      assert FakeS3.count(fake, :list_parts) == 1
      assert FakeS3.count(fake, :create_multipart) == 1
      # 1 and 2 were sent once; 3 six times dropped, then once more.
      assert Enum.frequencies(parts_sent(fake)) == %{1 => 1, 2 => 1, 3 => 7, 4 => 1, 5 => 1}
      assert sha256(FakeS3.object(fake, key(file)).body) == file.sha256
    end

    test "resumes on a store whose ETags are no MD5 (SSE-KMS, MinIO SSE)", %{tmp_dir: dir} do
      fake = FakeS3.start(etags: :opaque)
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :upload_part, :drop, skip: 3, times: 6)

      assert {:error, _reason} = put(file, resume: resume())
      checkpoint = last_saved()
      assert checkpoint["md5_etags"] == false

      assert put(file, resume: resume(checkpoint)) == :ok
      assert FakeS3.count(fake, :create_multipart) == 1
      assert FakeS3.count(fake, :abort_multipart) == 0
      assert sha256(FakeS3.object(fake, key(file)).body) == file.sha256
    end

    test "with MD5 ETags, a held part that no longer matches the local one starts over", %{
      tmp_dir: dir
    } do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :upload_part, :drop, skip: 2, times: 6)
      {:error, _reason} = put(file, resume: resume())
      checkpoint = last_saved()
      assert checkpoint["md5_etags"] == true

      # The local bytes changed under the verified sha256: the held parts are
      # not this file's, and the new upload is refused before completing.
      File.write!(file.path, :crypto.strong_rand_bytes(5_000))

      assert {:error, message} = put(file, resume: resume(checkpoint))
      assert message =~ "changed since it was verified"
      assert FakeS3.count(fake, :create_multipart) == 2
      assert FakeS3.uploads(fake) == %{}
      assert FakeS3.object(fake, key(file)) == nil
    end

    test "every part sent but Complete failed: the next attempt only completes", %{
      tmp_dir: dir
    } do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      # Six failures: Retry gives up on the first attempt's Complete.
      FakeS3.inject(fake, :complete, {:error, 500, "InternalError"}, times: 6)

      assert {:error, _transient} = put(file, resume: resume())
      checkpoint = last_saved()
      assert checkpoint["parts_done"] == 5
      [upload_id] = Map.keys(FakeS3.uploads(fake))
      assert checkpoint["upload_id"] == upload_id

      assert put(file, resume: resume(checkpoint)) == :ok
      assert parts_sent(fake) == [1, 2, 3, 4, 5]
      assert FakeS3.count(fake, :create_multipart) == 1
      assert FakeS3.count(fake, :complete) == 7
      assert saved() == []
      assert sha256(FakeS3.object(fake, key(file)).body) == file.sha256
    end

    test "an unusable checkpoint's upload is aborted before a new one starts", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :upload_part, :drop, skip: 2, times: 6)
      {:error, _reason} = put(file, resume: resume())
      [old] = Map.keys(FakeS3.uploads(fake))

      assert put(file, resume: resume(%{last_saved() | "part_size" => 0})) == :ok

      assert [{:abort_multipart, _key, %{"uploadId" => ^old}}] =
               Enum.filter(FakeS3.requests(fake), &(elem(&1, 0) == :abort_multipart))

      assert FakeS3.count(fake, :create_multipart) == 2
      assert FakeS3.uploads(fake) == %{}
    end

    test "a replaced upload that can't be aborted keeps its checkpoint: no new upload", %{
      tmp_dir: dir
    } do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :upload_part, :drop, skip: 2, times: 6)
      {:error, _reason} = put(file, resume: resume())
      checkpoint = %{last_saved() | "parts_digest" => String.duplicate("0", 64)}
      FakeS3.inject(fake, :abort_multipart, {:error, 500, "InternalError"}, times: :infinity)

      assert {:error, message} = put(file, resume: resume(checkpoint))
      assert message =~ "couldn't abort the earlier upload"
      assert message =~ "the next attempt tries again"
      assert FakeS3.count(fake, :create_multipart) == 1
      assert saved() == []
      assert map_size(FakeS3.uploads(fake)) == 1
    end

    test "without a Resume, a failed Complete aborts the upload this call started", %{
      tmp_dir: dir
    } do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :complete, {:error, 400, "InvalidPart"})

      assert {:error, {:permanent, _message}} = put(file)
      assert FakeS3.uploads(fake) == %{}
      assert FakeS3.count(fake, :abort_multipart) == 1
    end

    test "lists parts page by page", %{tmp_dir: dir} do
      fake = FakeS3.start(parts_page: 1)
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :upload_part, :drop, skip: 3, times: 6)
      {:error, _reason} = put(file, resume: resume())

      assert put(file, resume: resume(last_saved())) == :ok
      assert FakeS3.count(fake, :list_parts) == 3
    end

    test "a checkpoint the store doesn't confirm aborts that upload and starts over", %{
      tmp_dir: dir
    } do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :upload_part, :drop, skip: 2, times: 6)
      {:error, _reason} = put(file, resume: resume())

      checkpoint = %{last_saved() | "parts_digest" => String.duplicate("0", 64)}

      assert put(file, resume: resume(checkpoint)) == :ok
      assert FakeS3.count(fake, :create_multipart) == 2
      assert FakeS3.count(fake, :abort_multipart) == 1
      assert FakeS3.uploads(fake) == %{}
      assert sha256(FakeS3.object(fake, key(file)).body) == file.sha256
    end

    test "a checkpoint claiming more parts than the store holds starts over", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :upload_part, :drop, skip: 2, times: 6)
      {:error, _reason} = put(file, resume: resume())

      checkpoint = %{last_saved() | "parts_done" => 4}

      assert put(file, resume: resume(checkpoint)) == :ok
      assert FakeS3.count(fake, :create_multipart) == 2
    end

    test "an upload the store no longer has starts over", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :upload_part, :drop, skip: 2, times: 6)
      {:error, _reason} = put(file, resume: resume())
      checkpoint = last_saved()

      [id] = Map.keys(FakeS3.uploads(fake))

      :ok =
        S3.abort_upload(config(), %{subdir: "db", name: file.name, checkpoint: checkpoint}, [])

      refute Map.has_key?(FakeS3.uploads(fake), id)

      assert put(file, resume: resume(checkpoint)) == :ok
      assert FakeS3.count(fake, :create_multipart) == 2
    end

    test "stops before the deadline with its progress saved", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      # Less than the retry margin (1 s in the test env) is left.
      deadline = System.monotonic_time(:millisecond) + 500

      assert put(file, resume: resume(), deadline: deadline) == {:error, :deadline}
      assert [%{parts_done: 0}] = saved()
      assert parts_sent(fake) == []
      assert map_size(FakeS3.uploads(fake)) == 1
    end

    test "superseded on the first save: aborts the upload it created", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)

      assert put(file, resume: resume(nil, fn _n -> {:error, :superseded} end)) ==
               {:error, :superseded}

      assert FakeS3.uploads(fake) == %{}
      assert FakeS3.count(fake, :abort_multipart) == 1
      assert parts_sent(fake) == []
    end

    test "superseded after a part: aborts the upload it created, sends nothing more", %{
      tmp_dir: dir
    } do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      answer = fn n -> if n >= 3, do: {:error, :superseded}, else: :ok end

      assert put(file, resume: resume(nil, answer)) == {:error, :superseded}
      assert parts_sent(fake) == [1, 2]
      assert FakeS3.uploads(fake) == %{}
    end

    # #3041: the off-site step's lease check, made just before the Complete.
    test "a lease lost before the Complete: nothing is completed", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)

      assert put(file, resume: resume(), holds: fn -> {:error, :superseded} end) ==
               {:error, :superseded}

      assert parts_sent(fake) == [1, 2, 3, 4, 5]
      assert FakeS3.count(fake, :complete) == 0
      assert FakeS3.object(fake, key(file)) == nil
    end

    test "a lease that holds completes as before", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)

      assert put(file, resume: resume(), holds: fn -> :ok end) == :ok
      assert FakeS3.count(fake, :complete) == 1
      assert sha256(FakeS3.object(fake, key(file)).body) == file.sha256
    end

    test "superseded while resuming another call's upload leaves it alone", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :upload_part, :drop, skip: 2, times: 6)
      {:error, _reason} = put(file, resume: resume())

      assert put(file, resume: resume(last_saved(), fn _n -> {:error, :superseded} end)) ==
               {:error, :superseded}

      assert map_size(FakeS3.uploads(fake)) == 1
      assert FakeS3.count(fake, :abort_multipart) == 0
    end

    test "any failure of the first save aborts the upload, which nothing would know of", %{
      tmp_dir: dir
    } do
      fake = FakeS3.start()
      file = file!(dir, 5_000)

      assert put(file, resume: resume(nil, fn _n -> {:error, :database_down} end)) ==
               {:error, :database_down}

      assert FakeS3.uploads(fake) == %{}
    end

    test "without a Resume, a failure aborts the upload this call started", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :upload_part, {:error, 403, "AccessDenied"}, skip: 1)

      assert {:error, {:permanent, _message}} = put(file)
      assert FakeS3.uploads(fake) == %{}
    end

    test "a Complete answered with a 200 <Error> is retried", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :complete, {:ok_error, "InternalError"})

      assert put(file, resume: resume()) == :ok
      assert FakeS3.count(fake, :complete) == 2
      assert sha256(FakeS3.object(fake, key(file)).body) == file.sha256
    end

    test "a Complete that took effect but answered an error is confirmed by a HEAD", %{
      tmp_dir: dir
    } do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :complete, {:after, {:ok_error, "InternalError"}})

      # The retry finds the upload gone (NoSuchUpload); the object decides.
      assert put(file, resume: resume()) == :ok
      assert FakeS3.count(fake, :complete) == 2
      assert sha256(FakeS3.object(fake, key(file)).body) == file.sha256
    end

    test "an upload gone at Complete, with no object, is an error to retry", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :complete, {:error, 404, "NoSuchUpload"})

      assert {:error, "the store no longer has the upload (NoSuchUpload)"} =
               put(file, resume: resume())

      assert FakeS3.object(fake, key(file)) == nil
    end

    test "a part the store refuses for good is a permanent failure", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :complete, {:error, 400, "InvalidPart"})

      assert {:error, {:permanent, "the store refused a part of the upload (InvalidPart)"}} =
               put(file, resume: resume())
    end
  end

  describe "errors" do
    test "are classified from the code, never echoing the store's message", %{tmp_dir: dir} do
      file = file!(dir, 500)

      for {code, status, expected} <- [
            {"AccessDenied", 403, "(AccessDenied)"},
            {"InvalidAccessKeyId", 403, "(InvalidAccessKeyId)"},
            {"SignatureDoesNotMatch", 403, "(SignatureDoesNotMatch)"},
            {"AuthorizationHeaderMalformed", 400, "(AuthorizationHeaderMalformed)"},
            {"EntityTooLarge", 400, "(EntityTooLarge)"},
            {"InvalidBucketName", 400, "(InvalidBucketName)"},
            {"RequestTimeTooSkewed", 403, "fix the clock"}
          ] do
        fake = FakeS3.start()
        FakeS3.inject(fake, :put_object, {:error, status, code})

        assert {:error, {:permanent, message}} = put(file)
        assert message =~ expected
        refute message =~ "STORE-MESSAGE"
        assert FakeS3.count(fake, :put_object) == 1
      end
    end

    test "a bucket that doesn't exist is permanent", %{tmp_dir: dir} do
      FakeS3.start(buckets: [])
      file = file!(dir, 500)

      # The HEAD finds nothing; the PUT names the bucket.
      assert {:error, {:permanent, "the bucket does not exist (NoSuchBucket)"}} = put(file)
    end

    test "a bucket in another region is permanent and names the region", %{tmp_dir: dir} do
      fake = FakeS3.start()
      FakeS3.inject(fake, :head_object, {:status, 301, [{"x-amz-bucket-region", "eu-west-1"}]})

      assert {:error, {:permanent, message}} = put(file!(dir, 500))
      assert message =~ "the region eu-west-1"
    end

    test "a store whose clock is off by more than 5 minutes is permanent", %{tmp_dir: dir} do
      fake = FakeS3.start(skew: 3_600)
      FakeS3.inject(fake, :head_object, {:status, 403, []})

      assert {:error, {:permanent, message}} = put(file!(dir, 500))
      assert message =~ "clock"
      # Skew decided it: no listing was needed to read a code.
      assert FakeS3.count(fake, :list_objects) == 0
    end

    test "a HEAD 403 is explained by one listing's code", %{tmp_dir: dir} do
      fake = FakeS3.start()
      FakeS3.inject(fake, :head_object, {:status, 403, []})
      FakeS3.inject(fake, :list_objects, {:error, 403, "InvalidAccessKeyId"})

      assert {:error, {:permanent, message}} = put(file!(dir, 500))
      assert message =~ "InvalidAccessKeyId"
    end

    test "a HEAD 403 on a bucket that lists is access denied to the file", %{tmp_dir: dir} do
      fake = FakeS3.start()
      FakeS3.inject(fake, :head_object, {:status, 403, []})

      assert {:error, {:permanent, message}} = put(file!(dir, 500))
      assert message =~ "AccessDenied"
    end

    test "transient errors are retried a bounded number of times", %{tmp_dir: dir} do
      fake = FakeS3.start()
      FakeS3.inject(fake, :put_object, {:error, 503, "SlowDown"}, times: :infinity)

      assert {:error, "the store asked to slow down (SlowDown)"} = put(file!(dir, 500))
      assert FakeS3.count(fake, :put_object) == 6
    end

    test "transient errors that clear are ridden out", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 500)

      for {response, n} <- [
            {{:error, 500, "InternalError"}, 1},
            {{:error, 429, "TooManyRequests"}, 1},
            {{:error, 400, "RequestTimeout"}, 1},
            {{:error, 400, "BadDigest"}, 1},
            {:drop, 1}
          ] do
        FakeS3.inject(fake, :put_object, response, times: n)
      end

      # Five failures and the sixth, last, try.
      assert put(file) == :ok
      assert FakeS3.count(fake, :put_object) == 6
    end

    test "classify/4 reads only the code" do
      body = FakeS3.error_body("NoSuchUpload")
      assert %{class: :upload_gone} = Errors.classify(404, [], body)
      assert %{class: :not_found} = Errors.classify(404, [], "")
      assert %{class: :transient} = Errors.classify(307, [], "")
      assert %{class: :permanent} = Errors.classify(302, [], "")
      assert %{class: :transient} = Errors.classify(400, [], "<not xml")
      assert nil == Errors.classify(204, [], "")

      message = Errors.classify(500, [], body).message
      refute message =~ "STORE-MESSAGE"
    end
  end

  describe "secrets" do
    test "appear in no error, inspect or telemetry", %{tmp_dir: dir} do
      fake = FakeS3.start()
      test = self()
      handler = "s3-telemetry-#{inspect(self())}"

      :telemetry.attach(
        handler,
        Client.event(),
        fn _event, measurements, metadata, _config ->
          if self() == test, do: send(test, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      FakeS3.inject(fake, :put_object, {:error, 403, "SignatureDoesNotMatch"})
      result = put(file!(dir, 500))

      refute inspect(result) =~ @secret
      refute inspect(result) =~ @key_id

      assert_received {:telemetry, %{duration: _}, metadata}
      assert Map.keys(metadata) |> Enum.sort() == [:class, :method, :operation, :status]

      {:ok, endpoint} = Endpoint.parse(config().settings)
      {:ok, client} = Client.new(endpoint, @key_id, @secret)
      refute inspect(client) =~ @secret
      refute inspect(client) =~ @key_id
    end

    test "the signing config is the destination's alone" do
      {:ok, endpoint} = Endpoint.parse(config(%{"region" => "us-west-004"}).settings)
      aws = Client.aws_config(endpoint, @key_id, @secret)

      # config/test.exs gives :ex_aws its own "test" credentials: never these.
      assert aws.access_key_id == @key_id
      assert aws.secret_access_key == @secret
      refute Map.has_key?(aws, :security_token)
      assert aws.region == "us-west-004"
      assert aws.host == "s3.test"
    end
  end

  describe "signing" do
    test "pins ExAws's SigV4 against AWS's published S3 example" do
      # docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html,
      # "Example: GET Object".
      aws = %{
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-east-1"
      }

      empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      datetime = {{2013, 5, 24}, {0, 0, 0}}

      canonical =
        ExAws.Auth.build_canonical_request(
          :get,
          "/test.txt",
          "",
          [
            {"host", "examplebucket.s3.amazonaws.com"},
            {"range", "bytes=0-9"},
            {"x-amz-content-sha256", empty},
            {"x-amz-date", "20130524T000000Z"}
          ],
          ""
        )

      string_to_sign =
        Enum.join(
          [
            "AWS4-HMAC-SHA256",
            "20130524T000000Z",
            "20130524/us-east-1/s3/aws4_request",
            sha256(canonical)
          ],
          "\n"
        )

      assert ExAws.Auth.Signatures.generate_signature_v4("s3", aws, datetime, string_to_sign) ==
               "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    end

    for region <- ["auto", "us-west-004", "us-central-1"] do
      test "signs for the region #{region}, which no host table knows", %{tmp_dir: dir} do
        fake = FakeS3.start()
        region = unquote(region)
        {:ok, endpoint} = Endpoint.parse(config(%{"region" => region}).settings)
        aws = Client.aws_config(endpoint, @key_id, @secret)

        {:ok, headers} =
          ExAws.Auth.headers(:get, Endpoint.url(endpoint, "db/x"), :s3, aws, [], "")

        {_, authorization} = List.keyfind(headers, "Authorization", 0)
        assert authorization =~ ~r"Credential=#{@key_id}/\d{8}/#{region}/s3/aws4_request"

        assert S3.put(config(%{"region" => region}), file!(dir, 100), []) == :ok
        assert FakeS3.count(fake, :put_object) == 1
      end
    end
  end

  describe "list/1, get/3, delete/2" do
    test "a file put comes back whole through ranged reads", %{tmp_dir: dir} do
      fake = FakeS3.start()
      db = file!(dir, 5_000)
      media = %{file!(dir, 700, "kiln-media-20261117-000000.part01.tar.gz") | subdir: "media"}
      :ok = put(db, resume: resume())
      :ok = put(media)
      # Not Kiln's: ignored.
      FakeS3.put_object(fake, "site/a/db/notes.txt", "x")
      FakeS3.put_object(fake, "site/a/db/deeper/kiln-db-20261117-000000.dump", "x")
      FakeS3.put_object(fake, "site/b/db/kiln-db-20261117-000000.dump", "x")

      assert {:ok, entries} = S3.list(config())

      assert [
               %{subdir: "db", name: name, bytes: 5_000, mtime: %DateTime{}},
               %{subdir: "media", bytes: 700}
             ] = entries

      assert name == db.name

      to = Path.join(dir, "restored.dump")
      assert S3.get(config(), %{subdir: "db", name: db.name}, to) == :ok
      assert sha256(File.read!(to)) == db.sha256
      # 5,000 bytes in 1,500-byte ranges.
      assert FakeS3.count(fake, :get_object) == 4

      assert S3.delete(config(), %{subdir: "db", name: db.name}) == :ok
      assert S3.delete(config(), %{subdir: "db", name: db.name}) == :ok
      assert {:ok, [%{subdir: "media"}]} = S3.list(config())
    end

    test "lists page by page" do
      fake = FakeS3.start(list_page: 2)

      for n <- 1..5 do
        FakeS3.put_object(fake, "site/a/db/kiln-db-2026111#{n}-000000.dump", "x")
      end

      assert {:ok, entries} = S3.list(config())
      assert length(entries) == 5
      assert FakeS3.count(fake, :list_objects) == 4
    end

    test "a read that doesn't match the object's sha256 keeps nothing", %{tmp_dir: dir} do
      fake = FakeS3.start()
      name = "kiln-db-20261117-000000.dump"

      FakeS3.put_object(fake, "site/a/db/#{name}", "data", %{
        "kiln-sha256" => String.duplicate("a", 64)
      })

      to = Path.join(dir, "restored.dump")

      assert {:error, message} = S3.get(config(), %{subdir: "db", name: name}, to)
      assert message =~ "doesn't match"
      refute File.exists?(to)
    end

    test "an empty file reads back empty", %{tmp_dir: dir} do
      fake = FakeS3.start()
      name = "kiln-db-20261117-000000.dump"
      FakeS3.put_object(fake, "site/a/db/#{name}", "")
      to = Path.join(dir, "restored.dump")

      assert S3.get(config(), %{subdir: "db", name: name}, to) == :ok
      assert File.read!(to) == ""
    end

    test "an oversize answer is cut off and classified, not buffered", %{tmp_dir: dir} do
      fake = FakeS3.start()
      oversize = :binary.copy("x", 8 * 1024 * 1024 + 1)
      FakeS3.inject(fake, :list_objects, {:raw, 200, oversize}, times: :infinity)

      assert {:error, message} = S3.list(config())
      assert message =~ "larger than the 8388608 bytes expected"

      name = "kiln-db-20261117-000000.dump"
      FakeS3.put_object(fake, "site/a/db/#{name}", :crypto.strong_rand_bytes(3_000))
      FakeS3.inject(fake, :get_object, {:raw, 206, :binary.copy("y", 70_000)}, times: :infinity)
      to = Path.join(dir, "restored.dump")

      assert {:error, message} = S3.get(config(), %{subdir: "db", name: name}, to)
      assert message =~ "larger than the 65536 bytes expected"
      refute File.exists?(to)
    end

    test "a ranged read may be as large as its range, an error document always fits" do
      assert Client.body_limit([{"range", "bytes=0-16777215"}]) == 16_777_216
      assert Client.body_limit([{"range", "bytes=0-1499"}]) == 65_536
      assert Client.body_limit([]) == 8 * 1024 * 1024
    end

    test "refuses names that are not a backup's" do
      FakeS3.start()

      assert {:error, _} = S3.delete(config(), %{subdir: "db", name: "../x"})

      assert {:error, _} =
               S3.delete(config(), %{subdir: "etc", name: "kiln-db-20261117-000000.dump"})
    end
  end

  describe "abort_upload/3" do
    test "aborts the recorded upload, on the key the settings name", %{tmp_dir: dir} do
      fake = FakeS3.start()
      file = file!(dir, 5_000)
      FakeS3.inject(fake, :upload_part, :drop, skip: 1, times: 6)
      {:error, _reason} = put(file, resume: resume())

      # A checkpoint whose key was tampered with still aborts this file's upload.
      checkpoint = %{last_saved() | "key" => "elsewhere/x"}
      upload = %{subdir: "db", name: file.name, checkpoint: checkpoint}

      assert S3.abort_upload(config(), upload, []) == :ok
      assert FakeS3.uploads(fake) == %{}

      assert [{:abort_multipart, key, _query}] =
               Enum.filter(FakeS3.requests(fake), &(elem(&1, 0) == :abort_multipart))

      assert key == key(file)

      # Gone already, or never recorded: success.
      assert S3.abort_upload(config(), upload, []) == :ok
      assert S3.abort_upload(config(), %{upload | checkpoint: nil}, []) == :ok
    end
  end

  describe "test/1" do
    test "checks the bucket, lists, writes, reads back and removes a probe" do
      fake = FakeS3.start()

      assert S3.test(config()) == :ok
      assert FakeS3.keys(fake) == []
      assert FakeS3.count(fake, :put_object) == 1
      assert FakeS3.count(fake, :delete_object) == 1
    end

    test "says when the store's clock is off" do
      FakeS3.start(skew: -900)
      assert {:error, {:permanent, message}} = S3.test(config())
      assert message =~ "clock"
    end

    test "says when the bucket doesn't exist" do
      FakeS3.start(buckets: [])

      assert {:error, {:permanent, "checking the bucket: the bucket does not exist"}} =
               S3.test(config())
    end

    test "a probe that can't be read back says so, not that the bucket is missing" do
      fake = FakeS3.start()
      FakeS3.inject(fake, :get_object, {:error, 404, "NoSuchKey"})

      assert {:error, message} = S3.test(config())
      assert message =~ "reading the test file back"
      refute message =~ "bucket does not exist"
      assert FakeS3.keys(fake) == []
    end

    test "removes the probe when reading it back fails" do
      fake = FakeS3.start()
      FakeS3.inject(fake, :get_object, {:error, 403, "AccessDenied"})

      assert {:error, {:permanent, message}} = S3.test(config())
      assert message =~ "reading the test file back"
      assert FakeS3.keys(fake) == []
    end
  end

  test "describe/1 and location/1 name no secret" do
    assert S3.describe(config()) == "s3://kiln-backups/site/a (s3.test)"
    assert S3.location(config()) == {:s3, "s3.test", 443, "kiln-backups", ["site", "a"]}
  end
end
