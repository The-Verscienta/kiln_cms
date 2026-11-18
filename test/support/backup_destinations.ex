defmodule KilnCMS.Test.BackupDestinations do
  @moduledoc """
  Backup destination test helpers (#2220).

  `Fake` is an adapter registered in the test env only (`config/test.exs`,
  `:extra_adapters`), whose `"mode"` setting decides what every call does,
  so the facade's boundary (`KilnCMS.Backups.Destination.call/4`) and the
  step chain can be driven through each way a destination fails.
  """

  alias Kiln.BackupDestination.Config

  @doc """
  A `Fake` config. `settings` are merged over `"mode" => "ok"` and
  `"notify" => self()`; the secret `"token"` is `secret`.
  """
  @spec fake_config(map(), String.t()) :: Config.t()
  def fake_config(settings \\ %{}, secret \\ "fake-secret-token-123") do
    %Config{
      id: nil,
      key: "dest:fake",
      kind: "fake",
      settings: Map.merge(%{"mode" => "ok", "notify" => self()}, settings),
      secrets: %{"token" => secret}
    }
  end

  @doc """
  A stored `Fake` destination (`KilnCMS.Backups.DestinationConfig`), created
  through the code interface as `actor` (a fresh platform admin by default),
  so it runs the resource's own changes and validations. `attrs` are merged
  over a unique name, kind `"fake"`, settings `%{"mode" => "ok"}` and the
  secret `"token"` `secret`.
  """
  @spec destination!(map(), term(), String.t()) :: KilnCMS.Backups.DestinationConfig.t()
  def destination!(attrs \\ %{}, actor \\ nil, secret \\ "fake-secret-token-123") do
    attrs =
      Map.merge(
        %{
          name: "Fake #{System.unique_integer([:positive])}",
          kind: "fake",
          settings: %{"mode" => "ok"},
          secrets: %{"token" => secret}
        },
        attrs
      )

    KilnCMS.Backups.create_backup_destination!(attrs,
      actor: actor || KilnCMS.Test.BackupSchedules.platform_admin()
    )
  end

  @doc """
  Puts a stub `rclone` first on `PATH` (#2952), in `dir`, for the env
  destination's Test: `copyto`, `cat` and `deletefile` act on a store
  directory by basename. With `fail?: true` every call exits 1 and prints
  its `RCLONE_CONFIG_*` environment (a connection-string remote's
  credentials) to stderr, as a careless tool might.

  `PATH` is VM-global: only for an `async: false` module, which restores it
  (`on_exit`).
  """
  @spec fake_rclone!(Path.t(), keyword()) :: Path.t()
  def fake_rclone!(dir, opts \\ []) do
    bin = Path.join(dir, "bin")
    store = Path.join(dir, "store")
    File.mkdir_p!(bin)
    File.mkdir_p!(store)

    fail =
      if Keyword.get(opts, :fail?, false),
        do: ~s|env \| grep '^RCLONE_CONFIG_' >&2; echo "$1 refused" >&2; exit 1|,
        else: ""

    File.write!(Path.join(bin, "rclone"), """
    #!/bin/sh
    #{fail}
    case "$1" in
      copyto) cp "$2" "#{store}/$(basename "$3")" ;;
      cat) cat "#{store}/$(basename "$2")" ;;
      deletefile) rm -f "#{store}/$(basename "$2")" ;;
    esac
    exit 0
    """)

    File.chmod!(Path.join(bin, "rclone"), 0o755)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    store
  end

  defmodule Fake do
    @moduledoc """
    A destination that does what its `"mode"` setting says:

      * `"ok"` — every call succeeds (`put/3` keeps nothing; `list/1` is
        empty);
      * `"fail"` — `{:error, text}` naming the secret, literally and as
        `token=<secret>`, as a careless adapter might;
      * `"raise"` / `"exit"` / `"throw"` — just that, with the secret in it;
      * `"sleep"` — sleeps `"sleep_ms"` (default 60 s), then succeeds;
      * `"task_raise"` — starts a linked `Task` that raises, then waits for
        it;
      * `"bad_return"` — returns something that is not a result;
      * `"permanent"` — `{:error, {:permanent, text}}` naming the secret,
        and `"permanent_term"` the same with a term in place of the text
        (#2223);
      * `"present"` — `{:ok, :already_present}`, and `"ok_weird"` some other
        `{:ok, _}`;
      * `"deadline"` — `{:error, :deadline}`, as a resumable adapter that
        stopped at the step's deadline answers (#3082);
      * `"req"` — a `Req` request through the `Req.Test` stub named by
        `"req_stub"`, answering `{:ok, body}` (for a non-put call).

    `"test_mode"`, when set, is the mode `test/1` follows instead, so a
    stored destination can be saved (its `validate/1` passing) and still
    fail its Test. `"put_mode"` is the same for `put/3`, so a stored
    destination that fails every copy can be saved, and `"list_mode"` and
    `"delete_mode"` for `list/1` and `delete/2` (retention on a
    destination). `"entries"`, when set, is what a successful `list/1`
    returns (else nothing).

    For the step chain (#2220), whose stored destinations can't carry a
    pid, `put/3` also follows these settings:

      * `"fail_names"` — a file whose name contains it fails (the mode's
        error), every other file follows the mode;
      * `"log"` — a path: the name of every file `put/3` is called with is
        appended to it, one per line;
      * `"tamper_after"` — after a file whose name contains it is put, the
        same stamp's media part 2 next to it gets a byte appended, as
        something writing to the backup directory would;
      * `"pid_file"` — a path the calling process's pid is written to
        (`:erlang.pid_to_list/1`) before the mode runs.

    Every call sends `{:fake_destination, fun, args, self()}` to the
    `"notify"` pid first (`args` without the config), so a test sees what
    was called, in which process.
    """
    use Kiln.BackupDestination

    alias Kiln.BackupDestination.Config

    @impl Kiln.BackupDestination
    def kind, do: "fake"

    @impl Kiln.BackupDestination
    def label, do: "Fake (test)"

    @impl Kiln.BackupDestination
    def fields do
      [
        %{name: "mode", type: :string, required?: true, help: nil},
        %{name: "test_mode", type: :string, required?: false, help: nil},
        %{name: "put_mode", type: :string, required?: false, help: nil},
        %{name: "list_mode", type: :string, required?: false, help: nil},
        %{name: "delete_mode", type: :string, required?: false, help: nil},
        %{name: "sleep_ms", type: :integer, required?: false, help: nil},
        %{name: "fail_names", type: :string, required?: false, help: nil},
        %{name: "log", type: :string, required?: false, help: nil},
        %{name: "tamper_after", type: :string, required?: false, help: nil},
        %{name: "pid_file", type: :string, required?: false, help: nil},
        %{name: "token", type: :secret, required?: false, help: nil}
      ]
    end

    @impl Kiln.BackupDestination
    def supports, do: [:list, :delete]

    @impl Kiln.BackupDestination
    def validate(config), do: act(config, :validate, [])

    @impl Kiln.BackupDestination
    def test(config), do: act(config, :test, [])

    @impl Kiln.BackupDestination
    def put(%Config{settings: settings} = config, file, opts) do
      name = Map.get(file, :name, "")
      if log = settings["log"], do: File.write!(log, name <> "\n", [:append])
      if pid_file = settings["pid_file"], do: File.write!(pid_file, :erlang.pid_to_list(self()))

      config =
        case settings["fail_names"] do
          part when is_binary(part) ->
            mode = if String.contains?(name, part), do: "fail", else: "ok"
            %{config | settings: Map.put(settings, "put_mode", mode)}

          _ ->
            config
        end

      with :ok <- act(config, :put, [file, opts]) do
        tamper(settings["tamper_after"], file)
        :ok
      end
    end

    @impl Kiln.BackupDestination
    def list(config) do
      with :ok <- act(config, :list, []), do: {:ok, Map.get(config.settings, "entries", [])}
    end

    @impl Kiln.BackupDestination
    def get(config, ref, to), do: act(config, :get, [ref, to])

    @impl Kiln.BackupDestination
    def delete(config, ref), do: act(config, :delete, [ref])

    @impl Kiln.BackupDestination
    def describe(_config), do: "fake destination"

    defp act(%Config{settings: settings, secrets: secrets}, fun, args) do
      if pid = settings["notify"], do: send(pid, {:fake_destination, fun, args, self()})
      token = Map.get(secrets, "token", "")

      mode =
        case fun do
          :test -> settings["test_mode"]
          :put -> settings["put_mode"]
          :list -> settings["list_mode"]
          :delete -> settings["delete_mode"]
          _ -> nil
        end

      (mode || Map.get(settings, "mode", "ok")) |> behave(settings, token)
    end

    defp behave("ok", _settings, _token), do: :ok

    defp behave("fail", _settings, token),
      do: {:error, "the store refused #{token} for token=#{token} today"}

    defp behave("raise", _settings, token), do: raise("the store blew up holding #{token}")
    defp behave("exit", _settings, token), do: exit({:store_gone, token})
    defp behave("throw", _settings, token), do: throw({:store_gone, token})

    defp behave("sleep", settings, _token) do
      Process.sleep(Map.get(settings, "sleep_ms", 60_000))
      :ok
    end

    defp behave("task_raise", _settings, token) do
      # The closure holds the token, as a careless upload worker's might; a
      # crash report must still not show it.
      Task.async(fn ->
        _ = token
        raise "upload worker crashed"
      end)
      |> Task.await()
    end

    defp behave("bad_return", _settings, token), do: {:weird, token}

    defp behave("permanent", _settings, token),
      do: {:error, {:permanent, "the bucket is gone for token=#{token}"}}

    defp behave("permanent_term", _settings, token),
      do: {:error, {:permanent, {:no_such_bucket, token}}}

    defp behave("present", _settings, _token), do: {:ok, :already_present}
    defp behave("ok_weird", _settings, _token), do: {:ok, :weird}
    defp behave("deadline", _settings, _token), do: {:error, :deadline}

    defp behave("req", settings, _token) do
      case Req.get("http://store.test/ping", plug: {Req.Test, settings["req_stub"]}, retry: false) do
        {:ok, %Req.Response{body: body}} -> {:ok, body}
        {:error, error} -> {:error, Exception.message(error)}
      end
    end

    defp tamper(part, %{name: name, path: path}) when is_binary(part) do
      with true <- String.contains?(name, part),
           [stamp] <- Regex.run(~r/\d{8}-\d{6}/, name) do
        target =
          Path.join([
            path |> Path.dirname() |> Path.dirname(),
            "media",
            KilnCMS.Backups.Artifact.part_name(stamp, 2)
          ])

        File.write!(target, "tampered", [:append])
      end

      :ok
    end

    defp tamper(_part, _file), do: :ok
  end

  defmodule ResumableFake do
    @moduledoc """
    A resumable destination (#2223): `supports/0` declares `:resume` and it
    implements `abort_upload/3`, so `put/3` gets a
    `Kiln.BackupDestination.Resume`. It keeps files under its `"store_dir"`
    setting: an upload in progress as `<store_dir>/<name>.upload-<id>`, a
    finished file as `<store_dir>/<subdir>/<name>`.

    `put/3` sends `"chunk_bytes"` (default 64) at a time and saves
    `%{upload_id: id, offset: n, bytes_done: n}` (atom keys; they come back
    as strings) right after creating the upload and after each chunk. On a
    resume it checks that what the store holds is the start of the local
    file before it continues, and starts over otherwise. Settings:

      * `"only_names"` — when set, only a file whose name contains it is
        uploaded this way; any other is copied whole in one go, saving
        nothing (so a chain test needn't chunk a whole database dump);
      * `"stop_after_chunks"` — a put that starts afresh stops after that
        many chunks with a transient error (a resumed put never stops);
      * `"present"` — `"true"`: `{:ok, :already_present}`, sending nothing;
        `"after_upload"`: the same, but after creating and saving an upload;
      * `"permanent"` — `"true"`: creates and saves an upload, then answers
        `{:error, {:permanent, message}}`;
      * `"block_after_save"` — `"true"`: a put that starts afresh, after its
        first chunk's save, tells `"notify"`
        `{:resumable_fake, :blocked, name, self()}` and waits for `:continue`
        (or to be killed);
      * `"abort_mode"` — `"fail"`: `abort_upload/3` refuses;
      * `"put_return"` — `"weird_ok"`: `put/3` answers `{:ok, :weird}`;
        `"deadline"`: `{:error, :deadline}`, as one that stopped at the
        step's deadline does (#3082);
      * `"notify"` — a pid, or one as `:erlang.pid_to_list/1` text (a stored
        destination's settings can't hold a pid), told
        `{:resumable_fake, event, data, self()}` of `:put`, `:saved`,
        `:save_refused`, `:abort` and `:blocked`.
    """
    use Kiln.BackupDestination

    @impl Kiln.BackupDestination
    def kind, do: "fake_resumable"

    @impl Kiln.BackupDestination
    def label, do: "Resumable fake (test)"

    @impl Kiln.BackupDestination
    def fields do
      [
        %{name: "store_dir", type: :string, required?: true, help: nil},
        %{name: "chunk_bytes", type: :integer, required?: false, help: nil},
        %{name: "only_names", type: :string, required?: false, help: nil},
        %{name: "stop_after_chunks", type: :integer, required?: false, help: nil},
        %{name: "present", type: :string, required?: false, help: nil},
        %{name: "permanent", type: :string, required?: false, help: nil},
        %{name: "block_after_save", type: :string, required?: false, help: nil},
        %{name: "abort_mode", type: :string, required?: false, help: nil},
        %{name: "put_return", type: :string, required?: false, help: nil},
        %{name: "notify", type: :string, required?: false, help: nil}
      ]
    end

    @impl Kiln.BackupDestination
    def supports, do: [:list, :delete, :resume]

    @impl Kiln.BackupDestination
    def validate(_config), do: :ok

    @impl Kiln.BackupDestination
    def test(_config), do: :ok

    @impl Kiln.BackupDestination
    def put(%{settings: settings} = config, file, opts) do
      tell(settings, :put, %{name: file.name, opts: Keyword.keys(opts)})
      resume = Keyword.get(opts, :resume)

      only = settings["only_names"]

      case settings do
        %{"put_return" => "weird_ok"} ->
          {:ok, :weird}

        %{"put_return" => "deadline"} ->
          {:error, :deadline}

        %{"present" => "true"} ->
          {:ok, :already_present}

        _ when is_binary(only) ->
          if file.name =~ only, do: upload(config, file, resume), else: whole(settings, file)

        _ ->
          upload(config, file, resume)
      end
    end

    defp whole(settings, file) do
      target = stored_path(settings, file.subdir, file.name)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(file.path, target)
      :ok
    end

    @impl Kiln.BackupDestination
    def abort_upload(%{settings: settings}, %{name: name, checkpoint: checkpoint}, _opts) do
      id = checkpoint && checkpoint["upload_id"]
      tell(settings, :abort, %{name: name, upload_id: id})

      if settings["abort_mode"] == "fail" do
        {:error, "the store refused to abort the upload"}
      else
        if id, do: File.rm(upload_path(settings, name, id))
        :ok
      end
    end

    @impl Kiln.BackupDestination
    def list(_config), do: {:ok, []}

    @impl Kiln.BackupDestination
    def get(_config, _ref, _to), do: :ok

    @impl Kiln.BackupDestination
    def delete(_config, _ref), do: :ok

    @impl Kiln.BackupDestination
    def describe(_config), do: "resumable fake destination"

    @doc "Where an upload in progress is kept."
    def upload_path(settings, name, id),
      do: Path.join(settings["store_dir"], "#{name}.upload-#{id}")

    @doc "Where a finished file is kept."
    def stored_path(settings, subdir, name), do: Path.join([settings["store_dir"], subdir, name])

    defp upload(_config, _file, nil), do: {:error, "expected opts[:resume]"}

    defp upload(%{settings: settings}, file, resume) do
      File.mkdir_p!(settings["store_dir"])

      case continued(settings, file, resume.checkpoint) do
        {:ok, id, offset} ->
          send_chunks(settings, file, resume, id, offset, false)

        :fresh ->
          id = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
          File.write!(upload_path(settings, file.name, id), "")

          # Recorded before any data is sent, as the contract asks.
          with :ok <- save(settings, resume, file, id, 0, true),
               do: created(settings, file, resume, id)
      end
    end

    defp created(%{"permanent" => "true"}, _file, _resume, _id),
      do: {:error, {:permanent, "the bucket does not exist"}}

    defp created(%{"present" => "after_upload"}, _file, _resume, _id),
      do: {:ok, :already_present}

    defp created(settings, file, resume, id), do: send_chunks(settings, file, resume, id, 0, true)

    # The checkpoint's upload, when the store holds exactly the first
    # `offset` bytes of this file.
    defp continued(settings, file, %{"upload_id" => id, "offset" => offset})
         when is_binary(id) and is_integer(offset) do
      path = upload_path(settings, file.name, id)

      with {:ok, held} <- File.read(path),
           true <- byte_size(held) == offset,
           {:ok, local} <- File.read(file.path),
           true <- binary_part(local, 0, min(offset, byte_size(local))) == held do
        {:ok, id, offset}
      else
        _ -> :fresh
      end
    end

    defp continued(_settings, _file, _checkpoint), do: :fresh

    defp send_chunks(settings, file, resume, id, offset, fresh?) do
      run = %{
        settings: settings,
        file: file,
        resume: resume,
        id: id,
        fresh?: fresh?,
        local: File.read!(file.path),
        chunk: settings["chunk_bytes"] || 64,
        limit: if(fresh?, do: settings["stop_after_chunks"], else: nil)
      }

      chunks(run, offset, 0)
    end

    defp chunks(run, at, _sent) when at >= byte_size(run.local),
      do: finish(run.settings, run.file, run.id)

    defp chunks(%{limit: limit}, at, sent) when is_integer(limit) and sent >= limit,
      do: {:error, "connection reset after #{at} bytes"}

    defp chunks(run, at, sent) do
      piece = binary_part(run.local, at, min(run.chunk, byte_size(run.local) - at))
      File.write!(upload_path(run.settings, run.file.name, run.id), piece, [:append])
      at = at + byte_size(piece)

      with :ok <- save(run.settings, run.resume, run.file, run.id, at, run.fresh?) do
        if sent == 0, do: maybe_block(run)
        chunks(run, at, sent + 1)
      end
    end

    defp maybe_block(%{fresh?: true, settings: %{"block_after_save" => "true"}} = run) do
      tell(run.settings, :blocked, run.file.name)

      receive do
        :continue -> :ok
      end
    end

    defp maybe_block(_run), do: :ok

    defp save(settings, resume, file, id, at, fresh?) do
      case resume.save.(%{upload_id: id, offset: at, bytes_done: at}) do
        :ok ->
          tell(settings, :saved, %{name: file.name, upload_id: id, offset: at})
          :ok

        {:error, :superseded} = superseded ->
          tell(settings, :save_refused, %{name: file.name, upload_id: id})
          # A store upload this call created is this call's to abort.
          if fresh?, do: File.rm(upload_path(settings, file.name, id))
          superseded

        {:error, _reason} = error ->
          error
      end
    end

    defp finish(settings, file, id) do
      target = stored_path(settings, file.subdir, file.name)
      File.mkdir_p!(Path.dirname(target))
      File.rename!(upload_path(settings, file.name, id), target)
      :ok
    end

    defp tell(settings, event, data) do
      case settings["notify"] do
        pid when is_pid(pid) ->
          send(pid, {:resumable_fake, event, data, self()})

        "<" <> _ = text ->
          send(
            :erlang.list_to_pid(String.to_charlist(text)),
            {:resumable_fake, event, data, self()}
          )

        _ ->
          :ok
      end
    end
  end
end
