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
      * `"bad_return"` — returns something that is not a result.

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
end
