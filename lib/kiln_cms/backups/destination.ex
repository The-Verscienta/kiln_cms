defmodule KilnCMS.Backups.Destination do
  @moduledoc """
  Where an in-app backup copies its finished files (#2220): the registry of
  destination adapters, the destinations a backup sends to, and the one way
  an adapter is called.

  The behaviour every adapter implements is `Kiln.BackupDestination`, in the
  plugin SDK, so Kiln's own adapters (`KilnCMS.Backups.Destination.Rclone`,
  `KilnCMS.Backups.Destination.Local`, `KilnCMS.Backups.Destination.S3`) and
  a plugin's are the same kind of thing. This module is the core's side of it:

    * `registry/0` — every installed adapter, by `kind/0`;
    * `active/0` — the destinations a backup starting now sends to, as plain
      maps with no secret in them, fit for `state.json`, or
      `{:error, :unreadable}` when the stored ones can't be read;
    * `resolve/1` — one of those back into the `Kiln.BackupDestination.Config`
      an adapter is called with, secrets decrypted only now;
    * `call/4` — the call itself: bounded in time, isolated so a crash in the
      adapter is that destination's error rather than the backup's, and with
      every error scrubbed of the destination's secrets.

  ## The env destination

  `BACKUP_RCLONE_REMOTE` is a destination like the others, but read-only and
  not stored: it comes from the environment on every read, and it records its
  results under the key it always had, `"rclone:" <> Redact.text(remote)`
  (the key `KilnCMS.Backups.Artifact.from_manifest/2` gives a cron run's
  files). A connection-string remote's parameters travel as its secrets, as
  the `RCLONE_CONFIG_*` variables `KilnCMS.Backups.RcloneRemote` splits them
  into, so they reach `rclone` the way they always have and are scrubbed from
  its errors the way they always were.
  """

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, DestinationConfig, RcloneRemote, Redact, RunDestination}
  alias KilnCMS.Backups.Destination.{Local, Rclone, S3}

  require Logger

  # Kiln's own adapters. First in the registry, so a plugin can never take
  # over the kind a stored destination of Kiln's carries.
  @core [Rclone, Local, S3]

  # The bound on one adapter call made outside a backup step (a Test, a
  # task), unless the caller passes `:timeout` or `:deadline`. A step passes
  # its own `:deadline` instead, so this never cuts an upload short: before
  # #2220 nothing bounded `rclone copy` but the step's own timeout.
  @default_call_timeout :timer.minutes(60)

  # The least time a call made against a `:deadline` gets, however little of
  # the step is left: enough to fail with a clear timeout rather than not
  # start at all.
  @min_call_timeout :timer.seconds(1)

  # A runner the caller died before starting gives up after this long.
  @start_timeout :timer.seconds(5)

  @kind ~r/\A[a-z0-9_]{1,32}\z/

  @typedoc """
  A destination a backup sends to, as `active/0` lists it and `state.json`
  keeps it: no secret, no remote string, nothing that needs redacting.

    * `"key"` — what results are recorded under: `"rclone:<redacted>"` for
      the env destination, `"dest:<id>"` for a stored one;
    * `"id"` — the stored destination's id, `nil` for the env destination;
    * `"kind"` — the adapter's `kind/0`;
    * `"source"` — `"env"` or `"db"`;
    * `"label"` — what people are shown, already redacted.
  """
  @type entry :: %{String.t() => String.t() | nil}

  ## Registry

  @doc """
  Every installed destination adapter, one per kind: Kiln's own, then each
  plugin's (`Kiln.Plugins.backup_destinations/0`, in plugin order), then the
  test-only `:extra_adapters` of this module's config.

  A module that does not load, does not implement `Kiln.BackupDestination`,
  or answers no usable `kind/0` is left out, and so is one whose kind an
  earlier module already has: the first one listed keeps it, so a plugin
  cannot displace Kiln's own `local`, `rclone` or `s3` (`core_kinds/0`). `mix kiln.plugins.doctor`
  reports both.
  """
  @spec registry() :: [module()]
  def registry do
    (@core ++ Kiln.Plugins.backup_destinations() ++ extra_adapters())
    |> Enum.uniq()
    |> Enum.flat_map(fn module ->
      case kind_of(module) do
        {:ok, kind} -> [{kind, module}]
        :error -> []
      end
    end)
    |> Enum.uniq_by(fn {kind, _module} -> kind end)
    |> Enum.map(fn {_kind, module} -> module end)
  end

  @doc """
  The kinds of Kiln's own adapters: `"rclone"`, `"local"` and `"s3"`. No
  plugin can take one over.
  """
  @spec core_kinds() :: [String.t()]
  def core_kinds, do: Enum.map(@core, & &1.kind())

  @doc "The installed adapter for `kind`, or `{:error, :not_installed}`."
  @spec adapter(String.t()) :: {:ok, module()} | {:error, :not_installed}
  def adapter(kind) when is_binary(kind) do
    case Enum.find(registry(), &(kind_of(&1) == {:ok, kind})) do
      nil -> {:error, :not_installed}
      module -> {:ok, module}
    end
  end

  def adapter(_kind), do: {:error, :not_installed}

  @doc """
  Whether the adapter of `config` (or of the kind `kind`) declares every
  capability in `needed` in its optional `supports/0`. An adapter that is not
  installed, has no `supports/0`, or whose `supports/0` raises or answers
  something other than a list supports nothing: retention on a destination
  runs only on an adapter that opted in to `[:list, :delete]`.
  """
  @spec supports?(Config.t() | String.t(), [Kiln.BackupDestination.capability()]) :: boolean()
  def supports?(%Config{kind: kind}, needed), do: supports?(kind, needed)

  def supports?(kind, needed) when is_list(needed) do
    with {:ok, module} <- adapter(kind),
         true <- function_exported?(module, :supports, 0),
         declared when is_list(declared) <- safely(module, :supports) do
      Enum.all?(needed, &(&1 in declared))
    else
      _ -> false
    end
  end

  @doc """
  Whether `module` implements `Kiln.BackupDestination`: it loads and declares
  the behaviour.
  """
  @spec adapter?(term()) :: boolean()
  def adapter?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and Kiln.BackupDestination in behaviours(module)
  end

  def adapter?(_other), do: false

  @doc """
  `module`'s `kind/0`, when it is an adapter and the kind is usable: lowercase
  letters, digits and `_`, at most 32 characters.
  """
  @spec kind_of(module()) :: {:ok, String.t()} | :error
  def kind_of(module) do
    with true <- adapter?(module),
         kind when is_binary(kind) <- safely(module, :kind),
         true <- kind =~ @kind do
      {:ok, kind}
    else
      _ -> :error
    end
  end

  defp extra_adapters do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:extra_adapters, [])
  end

  defp behaviours(module) do
    :attributes |> module.module_info() |> Keyword.get_values(:behaviour) |> List.flatten()
  end

  # `kind/0` is plugin code: one that raises is not an adapter, not a crash.
  defp safely(module, fun) do
    apply(module, fun, [])
  rescue
    _error -> nil
  end

  ## The destinations a backup sends to

  @doc """
  The destinations a backup starting now sends to: the env destination
  (`BACKUP_RCLONE_REMOTE`) first, when it is set, then the enabled stored
  destinations (`KilnCMS.Backups.DestinationConfig`) by position.

    * `{:ok, entries}` — every destination, possibly none;
    * `{:error, :unreadable}` — the stored destinations couldn't be read
      (the table, the connection, or the `:backups` system actor's grant).
      Logged as an error here, with the cause.

  **Fails closed** (#2220, critic change 4): an unreadable table is never
  `{:ok, [env]}`. A backup must not quietly send to fewer places than the
  admin asked and then report a complete off-site copy. The step that calls
  this treats `{:error, :unreadable}` as a failure of that attempt: it
  retries, and on its last attempt records a "couldn't read destinations"
  entry, which makes the run partly off-site, never complete, and raises the
  backup alarm.

  A stored destination whose adapter is no longer installed is still listed:
  it was asked for, so the backup records it as failed (`resolve/1` answers
  `:not_installed`) rather than leaving it out.
  """
  @spec active() :: {:ok, [entry()]} | {:error, :unreadable}
  def active do
    case configured() do
      {:ok, entries} ->
        {:ok, entries}

      {:error, error} ->
        # The error's module only: its message inspects the query and the
        # actor, which belong in no log line.
        Logger.error(
          "Backups: couldn't read the backup destinations; " <>
            "a backup now can't reach them (#{inspect(short_error(error))})"
        )

        {:error, :unreadable}
    end
  end

  @doc """
  The destinations configured now, as `active/0` lists them, but quiet: a
  read that fails is `{:error, error}` with the read's own error and nothing
  is logged, so a caller that asks often (`KilnCMS.Backups.status/0`, #2951)
  decides how loudly to say it. The stored rows are read as the `:backups`
  system actor with `authorize_with: :error`, so a lost grant is an error,
  not "no rows".
  """
  @spec configured() :: {:ok, [entry()]} | {:error, term()}
  def configured do
    case Backups.list_enabled_backup_destinations(
           actor: Backups.system(),
           authorize_with: :error
         ) do
      {:ok, rows} -> {:ok, List.wrap(env_destination()) ++ Enum.map(rows, &stored_entry/1)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  The keys a run's destination entries are matched against to tell whether
  that destination is still configured (#2951): every key in `entries`
  (`configured/0`'s), plus `KilnCMS.Backups.RunDestination.unreadable_key/0`
  while any of them is a stored destination, since the "unreadable" entry
  stands for the stored destinations.
  """
  @spec configured_keys([entry()]) :: MapSet.t(String.t())
  def configured_keys(entries) when is_list(entries) do
    keys = MapSet.new(entries, & &1["key"])

    if Enum.any?(entries, &(&1["source"] == "db")),
      do: MapSet.put(keys, RunDestination.unreadable_key()),
      else: keys
  end

  defp short_error(%{__struct__: module}), do: module

  # The name is the admin's text: redacted all the same, in case it holds a
  # URL with credentials.
  defp stored_entry(%DestinationConfig{} = row) do
    %{
      "key" => DestinationConfig.key(row),
      "id" => row.id,
      "kind" => row.kind,
      "source" => "db",
      "label" => Redact.text(row.name)
    }
  end

  @doc """
  The env destination's entry (see `t:entry/0`), or `nil` when
  `BACKUP_RCLONE_REMOTE` is unset.
  """
  @spec env_destination() :: entry() | nil
  def env_destination do
    case Backups.rclone_remote() do
      remote when is_binary(remote) and remote != "" ->
        key = env_key(remote)

        %{
          "key" => key,
          "id" => nil,
          "kind" => Rclone.kind(),
          "source" => "env",
          "label" => Redact.text(remote)
        }

      _unset ->
        nil
    end
  end

  @doc """
  The key the env destination records its results under for `remote`:
  `"rclone:" <> Redact.text(remote)`, the key a cron run's files have always
  had (`KilnCMS.Backups.Artifact.from_manifest/2`).
  """
  @spec env_key(String.t()) :: String.t()
  def env_key(remote) when is_binary(remote), do: "rclone:" <> Redact.text(remote)

  @doc """
  Where the env destination writes (`location/1` of its config), or `nil`
  when `BACKUP_RCLONE_REMOTE` is unset. Retention on a stored destination
  checks it again before deleting anything (#2220).
  """
  @spec env_location() :: Rclone.location() | nil
  def env_location do
    case Backups.rclone_remote() do
      remote when is_binary(remote) and remote != "" -> Rclone.location(remote)
      _unset -> nil
    end
  end

  @doc """
  The config an adapter is called with for `entry`, secrets decrypted now.

    * `{:error, :not_installed}` — no installed adapter has its kind (a
      plugin was removed);
    * `{:error, :removed}` — it no longer exists: the env remote changed or
      was unset, or the stored destination was deleted or disabled since the
      backup started;
    * `{:error, :undecryptable}` — the stored destination's secrets open
      under no key (`SECRET_KEY_BASE` changed); the admin re-enters them;
    * `{:error, :unreadable}` — the stored destination couldn't be read.
  """
  @spec resolve(entry()) ::
          {:ok, Config.t()}
          | {:error, :not_installed | :removed | :undecryptable | :unreadable}
  def resolve(%{"kind" => kind} = entry) do
    with {:ok, _module} <- adapter(kind), do: resolve_source(entry)
  end

  defp resolve_source(%{"source" => "env", "key" => key}) do
    case Backups.rclone_remote() do
      remote when is_binary(remote) and remote != "" ->
        if env_key(remote) == key, do: {:ok, env_config(remote)}, else: {:error, :removed}

      _unset ->
        {:error, :removed}
    end
  end

  # The row as it is now, its secrets decrypted only here, just before the
  # call. Deleted or disabled since the backup started: `:removed`.
  defp resolve_source(%{"source" => "db", "id" => id}) when is_binary(id) do
    case Backups.get_backup_destination(id, actor: Backups.system(), authorize_with: :error) do
      {:ok, %DestinationConfig{enabled: true} = row} -> DestinationConfig.to_config(row)
      {:ok, _deleted_or_disabled} -> {:error, :removed}
      {:error, _error} -> {:error, :unreadable}
    end
  end

  defp resolve_source(_entry), do: {:error, :removed}

  # The remote as `RcloneRemote.split_credentials/1` leaves it, with the
  # connection-string parameters as secrets: the `RCLONE_CONFIG_*`
  # environment `rclone` is run with, and what its errors are scrubbed of.
  defp env_config(remote) do
    {bare, env} = RcloneRemote.split_credentials(remote)

    %Config{
      id: nil,
      key: env_key(remote),
      kind: Rclone.kind(),
      settings: %{"remote" => bare, "display" => Redact.text(remote)},
      secrets: Map.new(env)
    }
  end

  @doc """
  Whether `config`'s adapter takes resumable uploads (#2223): it declares
  `:resume` in `supports/0` and implements `abort_upload/3`. One that
  declares `:resume` without `abort_upload/3` is treated as non-resumable,
  since Kiln could never free an upload it started.
  """
  @spec resumable?(Config.t()) :: boolean()
  def resumable?(%Config{kind: kind} = config) do
    with true <- supports?(config, [:resume]),
         {:ok, module} <- adapter(kind) do
      Code.ensure_loaded?(module) and function_exported?(module, :abort_upload, 3)
    else
      _ -> false
    end
  end

  ## Files and locations

  @typedoc "Where a destination writes, as `location/1` normalizes it."
  @type location ::
          Rclone.location()
          | {:s3, String.t(), non_neg_integer(), String.t(), [String.t()]}
          | :unknown

  @doc """
  Whether `name` is a whole backup file: an artifact or a checksum sidecar,
  named as `scripts/backup.sh` names them, and not a `.partial` upload.
  Anything else a destination holds is not Kiln's to list or delete.
  """
  @spec backup_file?(String.t()) :: boolean()
  def backup_file?(name) when is_binary(name) do
    match?({:ok, %{partial?: false}}, Artifact.parse_file(name)) or
      match?({:ok, %{partial?: false}}, Artifact.parse_sidecar_name(name))
  end

  def backup_file?(_name), do: false

  @doc """
  Where `config` writes, normalized for `overlap?/2`: `{:rclone, name,
  segments}`, `{:local, segments}` or `{:s3, host, port, bucket, segments}`
  for Kiln's own adapters, `:unknown` for a plugin's, whose settings mean
  nothing here.
  """
  @spec location(Config.t()) :: location()
  def location(%Config{kind: "rclone"} = config), do: Rclone.location(config)
  def location(%Config{kind: "local"} = config), do: Local.location(config)
  def location(%Config{kind: "s3"} = config), do: S3.location(config)
  def location(%Config{}), do: :unknown

  @doc """
  The settings that make up where a destination of `kind` writes: the ones
  `location/1` reads, fixed once the destination is stored (critic change 2),
  so the Destinations form shows them read-only on edit. `[]` for a plugin's
  kind, whose location can't be told.
  """
  @spec location_fields(String.t()) :: [String.t()]
  def location_fields("rclone"), do: ["remote_name", "path"]
  def location_fields("local"), do: ["path"]
  def location_fields("s3"), do: ["endpoint", "bucket", "prefix"]
  def location_fields(_kind), do: []

  @doc """
  Whether two locations are the same place or one is inside the other,
  compared by whole path segments. Two destinations that overlap would see
  each other's files, and retention on one could delete what the other was
  sent (critic change 2), so a new destination must overlap none. An
  `:unknown` location overlaps nothing that can be told.
  """
  @spec overlap?(location(), location()) :: boolean()
  def overlap?({:rclone, name, a}, {:rclone, name, b}), do: nested?(a, b)
  def overlap?({:local, a}, {:local, b}), do: nested?(a, b)

  # The same store (host and port) and bucket, one prefix inside the other.
  # An S3 location is never compared with an rclone remote, which may name
  # the same bucket under any name: retention treats that pair as unknown.
  def overlap?({:s3, host, port, bucket, a}, {:s3, host, port, bucket, b}), do: nested?(a, b)
  def overlap?(_a, _b), do: false

  defp nested?(a, b), do: List.starts_with?(a, b) or List.starts_with?(b, a)

  @doc """
  The key a send to `entry` is recorded against (the `"sent"` map of a
  backup's `state.json`, and `KilnCMS.Backups.Upload`'s `destination_key`):
  `"<key>|<location fingerprint>"` for a stored destination, so a record of
  a send never licenses a skip, or resumes an upload, somewhere else; `nil`
  for the env destination, which never skips and never resumes.
  """
  @spec target_key(entry(), Config.t()) :: String.t() | nil
  def target_key(%{"source" => "env"}, _config), do: nil

  def target_key(%{"key" => key}, %Config{} = config) do
    where =
      case location(config) do
        :unknown -> {:settings, config.kind, config.settings}
        location -> location
      end

    fingerprint =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(where))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    key <> "|" <> fingerprint
  end

  ## Calling an adapter

  @doc """
  Calls `fun` on `config`'s adapter with `config` and `args`:
  `call(config, :put, [file, []])` is `adapter.put(config, file, [])`.

  The adapter runs in a process of its own, so:

    * a raise, a throw or an exit (from it, or from a process linked to it)
      is `{:error, reason}`, never a crash of the caller;
    * it is bounded in time (`call_timeout/1`): by `opts[:timeout]`
      (milliseconds), else by what is left until `opts[:deadline]` (a
      `System.monotonic_time(:millisecond)` instant, what a backup step
      passes), else by a default. Past it the
      process is killed, with any process linked to it, and the answer is
      `{:error, {:timeout, call, ms}}` (`timed_out?/1`), which
      `format_reason/1` says as `"<call> timed out after …"`;
    * when the caller dies (a canceled backup, a fenced node) the adapter's
      process is killed with it, as an `rclone` started through
      `KilnCMS.ExternalCommand` is.

  Every error is scrubbed of `config.secrets` (literally and in `key=value`
  form) and cut to 500 characters. A string or `Command` error stays one; an
  atom and a timeout stay themselves; `{:permanent, message}` keeps its tag,
  its message scrubbed (`permanent?/1`); anything else becomes its scrubbed
  `inspect`. An uninstalled kind is `{:error, :not_installed}`.

  A `put` may answer `:ok` or `{:ok, :already_present}`; any other `{:ok, _}`
  from it is `{:error, "<adapter>.put/3 returned an unexpected value"}`.

  The adapter's process carries the caller in `$callers`, so a database
  write it makes (a resumable upload's `save`) runs on the caller's sandbox
  connection in tests, and a `Req.Test` stub the caller owns answers it.
  """
  @spec call(Config.t(), atom(), list(), keyword()) :: term()
  def call(%Config{} = config, fun, args, opts \\ []) when is_atom(fun) and is_list(args) do
    with {:ok, module} <- adapter(config.kind) do
      timeout = call_timeout(opts)

      module
      |> bounded(fun, [config | args], timeout)
      |> scrub(secret_env(config))
    end
  end

  @doc """
  A reason `call/4` returned, as one line for people: a string as it is, a
  failed command as `"rclone exited 1: …"`, and the atoms the core adapters
  return as a sentence.
  """
  @spec format_reason(term()) :: String.t()
  def format_reason(reason) when is_binary(reason), do: reason

  def format_reason({:exit_status, executable, status, output}),
    do: "#{executable} exited #{status}: #{output}"

  def format_reason({:timeout, call, ms}) when is_binary(call) and is_integer(ms),
    do: "#{call} timed out after #{duration(ms)}"

  def format_reason({executable, :enoent}) when is_binary(executable),
    do: "#{executable} is not installed"

  def format_reason(:missing_rclone), do: "rclone is not installed in this image"

  def format_reason(:not_installed),
    do: "the adapter for this destination is not installed (was its plugin removed?)"

  def format_reason(:removed), do: "the destination was removed or disabled"

  def format_reason(:undecryptable),
    do: "credentials can't be decrypted (was SECRET_KEY_BASE changed?); re-enter them"

  def format_reason(:unreadable), do: "couldn't read the backup destinations"

  def format_reason({:permanent, message}) when is_binary(message), do: message

  def format_reason(:deadline), do: format_reason(:deadline, next_attempt?: true)
  def format_reason(:superseded), do: "a later attempt of this backup took over the upload"
  def format_reason(reason), do: inspect(reason)

  @doc """
  `format_reason/1`, said for what follows. Only `:deadline` reads
  differently, by two options:

    * `:next_attempt?` (default `true`) - whether an attempt of the step
      follows that tries the file again; without one (the step's last
      attempt, or a destination it failed now), the backup's Resume or its
      next run does;
    * `:resumable?` (default `true`) - whether the upload is recorded, so it
      resumes mid-file; otherwise (the env destination, an adapter that
      can't resume) the file is sent again whole.
  """
  @spec format_reason(term(), keyword()) :: String.t()
  def format_reason(:deadline, opts) do
    after_this =
      case {Keyword.get(opts, :resumable?, true), Keyword.get(opts, :next_attempt?, true)} do
        {true, true} -> "the upload resumes on the next attempt"
        {true, false} -> "it resumes when the backup is resumed or runs again"
        {false, true} -> "it is sent again on the next attempt"
        {false, false} -> "it is sent again when the backup is resumed or runs again"
      end

    "stopped before the step's time ran out; " <> after_this
  end

  def format_reason(reason, _opts), do: format_reason(reason)

  @doc """
  Whether `reason` is the error `call/4` gives when the call ran past its
  bound. The backup's off-site step ends a destination's attempt there: the
  next file would only wait as long again.
  """
  @spec timed_out?(term()) :: boolean()
  def timed_out?({:timeout, call, ms}) when is_binary(call) and is_integer(ms), do: true
  def timed_out?(:deadline), do: true
  def timed_out?(_reason), do: false

  @doc """
  Whether `reason` is a failure the adapter says no retry fixes
  (`{:permanent, message}`): the off-site step fails the destination at once
  rather than spending the backup's remaining attempts on it.
  """
  @spec permanent?(term()) :: boolean()
  def permanent?({:permanent, message}) when is_binary(message), do: true
  def permanent?(_reason), do: false

  @doc """
  The bound on one `call/4` made with `opts`, in milliseconds:

    * `opts[:timeout]`, when given;
    * with `opts[:deadline]`, the time left until it (at least one second),
      capped by this module's `:call_timeout` config when that is set. A
      backup step passes the end of its own run time here, so an upload
      takes as long as the step allows, as `rclone copy` always could;
    * otherwise the `:call_timeout` config, else `:default_call_timeout`,
      else 60 minutes.
  """
  @spec call_timeout(keyword()) :: pos_integer()
  def call_timeout(opts \\ []) do
    config = Application.get_env(:kiln_cms, __MODULE__, [])
    cap = Keyword.get(config, :call_timeout)

    cond do
      Keyword.has_key?(opts, :timeout) ->
        Keyword.fetch!(opts, :timeout)

      Keyword.has_key?(opts, :deadline) ->
        left = max(opts[:deadline] - System.monotonic_time(:millisecond), @min_call_timeout)
        if is_integer(cap), do: min(left, cap), else: left

      is_integer(cap) ->
        cap

      true ->
        Keyword.get(config, :default_call_timeout, @default_call_timeout)
    end
  end

  defp secret_env(%Config{secrets: secrets}) when is_map(secrets) do
    for {name, value} <- secrets, is_binary(value), do: {to_string(name), value}
  end

  defp secret_env(_config), do: []

  # The adapter runs in `runner`, monitored but not linked: a crash there, or
  # in a process linked to it, is a DOWN message here rather than an exit
  # signal that takes the backup step down with it. Not being linked, it
  # would outlive a caller that is killed, so a watcher (the pattern
  # `KilnCMS.ExternalCommand` uses for its OS process) kills it when the
  # caller dies. The runner waits for `:go` until the watcher is in place, so
  # no instant exists where the caller could die and leave it running.
  defp bounded(module, fun, args, timeout) do
    caller = self()
    callers = [caller | Process.get(:"$callers", [])]
    tag = make_ref()

    {runner, ref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)

        receive do
          {^tag, :go} -> send(caller, {tag, guarded(module, fun, args)})
        after
          @start_timeout -> :ok
        end
      end)

    watcher = watch(caller, runner)
    send(runner, {tag, :go})

    try do
      receive do
        {^tag, result} ->
          Process.demonitor(ref, [:flush])
          result

        {:DOWN, ^ref, :process, ^runner, reason} ->
          {:error, "#{name(module, fun, args)} crashed: #{exit_reason(reason)}"}
      after
        timeout ->
          Process.exit(runner, :kill)
          Process.demonitor(ref, [:flush])
          # The answer may have been sent just before the kill.
          receive do
            {^tag, _late} -> :ok
          after
            0 -> :ok
          end

          {:error, {:timeout, name(module, fun, args), timeout}}
      end
    after
      send(watcher, :done)
    end
  end

  defp watch(caller, runner) do
    spawn(fn ->
      caller_ref = Process.monitor(caller)
      runner_ref = Process.monitor(runner)

      receive do
        :done -> :ok
        {:DOWN, ^runner_ref, :process, _pid, _reason} -> :ok
        {:DOWN, ^caller_ref, :process, _pid, _reason} -> Process.exit(runner, :kill)
      end
    end)
  end

  # A raising, throwing or exiting adapter is a failed call. Nothing of the
  # config is in what this returns: an exception's message is the adapter's
  # own text, and it is scrubbed below like any other error.
  defp guarded(module, fun, args) do
    case {fun, apply(module, fun, args)} do
      {_fun, :ok} -> :ok
      {:put, {:ok, :already_present} = present} -> present
      {:put, {:ok, _other}} -> {:error, "#{name(module, fun, args)} returned an unexpected value"}
      {_fun, {:ok, _value} = ok} -> ok
      {_fun, {:error, _reason} = error} -> error
      {_fun, _other} -> {:error, "#{name(module, fun, args)} returned an unexpected value"}
    end
  rescue
    error -> {:error, "#{name(module, fun, args)} raised: #{Exception.message(error)}"}
  catch
    :exit, reason -> {:error, "#{name(module, fun, args)} exited: #{exit_reason(reason)}"}
    :throw, value -> {:error, "#{name(module, fun, args)} threw: #{inspect(value)}"}
  end

  defp name(module, fun, args), do: "#{inspect(module)}.#{fun}/#{length(args)}"

  # The exception's message, never its stacktrace: a frame can carry a
  # function's arguments, and an adapter's arguments are its config.
  defp exit_reason({error, stacktrace}) when is_exception(error) and is_list(stacktrace),
    do: Exception.message(error)

  defp exit_reason({{error, stacktrace}, _call}) when is_exception(error) and is_list(stacktrace),
    do: Exception.message(error)

  defp exit_reason({reason, stacktrace}) when is_list(stacktrace), do: inspect(reason)
  defp exit_reason(reason), do: inspect(reason)

  defp duration(ms) when rem(ms, 60_000) == 0 and ms > 0, do: "#{div(ms, 60_000)} min"
  defp duration(ms) when rem(ms, 1000) == 0 and ms > 0, do: "#{div(ms, 1000)} s"
  defp duration(ms), do: "#{ms} ms"

  defp scrub({:error, reason}, env), do: {:error, scrub_reason(reason, env)}
  defp scrub(result, _env), do: result

  defp scrub_reason(reason, env) when is_binary(reason), do: Redact.text(reason, env, 500)

  defp scrub_reason({:exit_status, executable, status, output}, env),
    do: {:exit_status, executable, status, Redact.text(output, env, 500)}

  defp scrub_reason({:permanent, message}, env) when is_binary(message),
    do: {:permanent, Redact.text(message, env, 500)}

  defp scrub_reason({:permanent, other}, env),
    do: {:permanent, Redact.text(inspect(other), env, 500)}

  defp scrub_reason(reason, _env) when is_atom(reason), do: reason
  defp scrub_reason({:timeout, call, _ms} = reason, _env) when is_binary(call), do: reason
  defp scrub_reason(reason, env), do: Redact.text(inspect(reason), env, 500)
end
