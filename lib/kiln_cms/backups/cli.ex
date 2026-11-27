defmodule KilnCMS.Backups.CLI do
  @moduledoc """
  The backup command line (#2234): `bin/backup` in a release
  (`KilnCMS.Release.backup/1`) and `mix kiln.backup.*` in a checkout.

      bin/backup list [--limit N] [--json]
      bin/backup run [--components db,media] [--wait [--timeout SECONDS]] [--json]
      bin/backup verify <stamp|id> [--json]
      bin/backup prune [--dry-run] [--json]
      bin/backup rescan [--json]
      bin/backup help

  Every command goes through the `KilnCMS.Backups` code interfaces as
  `KilnCMS.Backups.system/0`, with the grants it already has (the Run and
  destination reads, the lock's `:request`): no new action, no
  `authorize?: false`.

    * `prune` only reports. It is `KilnCMS.Backups.Retention.run/2` with
      `dry_run: true`, which plans and deletes nothing; a real prune is the
      prune step of every backup's chain, fenced by its lease (ADR 0067), so
      `bin/backup run` is how to prune now.
    * `rescan` imports cron-made backups in this node's backup directory
      (`KilnCMS.Backups.Importer.retry_failed/0`), clearing its import
      backoff first. Local only (`"scope": "local"`).
    * `verify` re-checks files and never records anything
      (`KilnCMS.Backups.Verify`).

  ## Where each command runs

  `list` and `verify` run beside the serving node (`bin/kiln_cms eval`, with
  only the repo started): `verify` hashes gigabytes, which must not happen
  on the serving node, so it is refused under `:rpc`. `run`, `rescan` and
  `prune` need the serving node (its job queue, its importer backoff), so
  they are refused under `:eval`. `:mix` allows everything.

  ## Output and exit codes

  `main/2` never prints, never halts and never writes to `:stderr` (under
  `rpc` that is the server's): it returns `{exit_code, output}` and the
  caller prints. Exit `0` on success, `1` when the command failed, `2` on a
  usage error. With `--json` the output is one JSON object and a newline:
  `schema` (1), `command`, `ok`, `exit_code`, `error` (`null` or `%{code,
  message}`) and the command's own keys. Keys are only ever added.
  """

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Destination, DestinationConfig, DiskView, Importer}
  alias KilnCMS.Backups.{Lock, Presence, Retention, Run, Verify, WorkState}

  require Ash.Query

  @schema 1

  @commands %{
    "list" => :list,
    "run" => :run,
    "verify" => :verify,
    "prune" => :prune,
    "rescan" => :rescan,
    "help" => :help
  }

  @switches %{
    list: [json: :boolean, limit: :integer, help: :boolean],
    run: [json: :boolean, components: :string, wait: :boolean, timeout: :integer, help: :boolean],
    verify: [json: :boolean, help: :boolean],
    prune: [json: :boolean, dry_run: :boolean, help: :boolean],
    rescan: [json: :boolean, help: :boolean],
    help: [json: :boolean]
  }

  @aliases [h: :help]

  @doc false
  # Each command's switches: the one list `parse/1` reads. The mix tasks
  # repeat theirs literally (the switch contract test reads task source) and
  # refuse to compile when it differs from this.
  @spec switches(command()) :: keyword()
  def switches(command), do: Map.fetch!(@switches, command)

  # Need the serving node (its queue, its importer backoff): refused under eval.
  @node_commands [:run, :rescan, :prune]
  # Run beside it: refused under rpc.
  @beside_commands [:verify]

  @default_limit 20
  @max_limit 100
  @default_timeout_s 3 * 3600
  @max_timeout_s 24 * 3600
  @chunk_ms 10_000
  @poll_ms 2_000

  @type exit_code :: 0 | 1 | 2
  @type command :: :list | :run | :verify | :prune | :rescan | :help

  @doc """
  Parse `argv` into `{:ok, command, args}` or `{:usage, message}`. Never
  reads or writes anything, so it is safe on any input. `args` always has
  `:json`.
  """
  @spec parse([String.t()]) :: {:ok, command(), map()} | {:usage, String.t()}
  def parse([]), do: {:usage, "no command given"}

  def parse([flag | _rest]) when flag in ["--help", "-h"], do: {:ok, :help, %{json: false}}

  def parse(["-" <> _ = flag | _rest]),
    do: {:usage, "#{inspect(flag)} comes before the command; put flags after it"}

  def parse([name | rest]) do
    case Map.fetch(@commands, name) do
      {:ok, command} -> parse_command(command, rest)
      :error -> {:usage, "unknown command #{inspect(name)}"}
    end
  end

  defp parse_command(command, rest) do
    case OptionParser.parse(rest, strict: Map.fetch!(@switches, command), aliases: @aliases) do
      {opts, positional, []} ->
        if opts[:help],
          do: {:ok, :help, %{json: opts[:json] == true}},
          else: args(command, Map.new(opts), positional)

      {_opts, _positional, [{flag, _value} | _]} ->
        {:usage, "#{command}: #{inspect(flag)} is not an option here"}
    end
  end

  defp args(:help, opts, []), do: {:ok, :help, json(opts)}

  defp args(:list, opts, []) do
    case Map.get(opts, :limit, @default_limit) do
      n when n in 1..@max_limit -> {:ok, :list, Map.put(json(opts), :limit, n)}
      _other -> {:usage, "list: --limit takes a whole number from 1 to #{@max_limit}"}
    end
  end

  defp args(:run, opts, []) do
    wait? = opts[:wait] == true

    with {:ok, components} <- components(opts[:components]),
         {:ok, timeout} <- timeout(opts[:timeout], wait?) do
      {:ok, :run,
       Map.merge(json(opts), %{components: components, wait: wait?, timeout_s: timeout})}
    end
  end

  defp args(:verify, opts, [target]) do
    cond do
      WorkState.valid_stamp?(target) ->
        {:ok, :verify, Map.put(json(opts), :target, {:stamp, target})}

      match?({:ok, _}, Ecto.UUID.cast(target)) ->
        {:ok, id} = Ecto.UUID.cast(target)
        {:ok, :verify, Map.put(json(opts), :target, {:id, id})}

      true ->
        {:usage,
         "verify: #{inspect(target)} is neither a backup stamp (YYYYMMDD-HHMMSS) nor a run id"}
    end
  end

  defp args(:verify, _opts, _positional),
    do: {:usage, "verify takes one backup: its stamp (YYYYMMDD-HHMMSS) or its run id"}

  defp args(:prune, opts, []), do: {:ok, :prune, json(opts)}
  defp args(:rescan, opts, []), do: {:ok, :rescan, json(opts)}

  defp args(command, _opts, [extra | _]),
    do: {:usage, "#{command}: unexpected argument #{inspect(extra)}"}

  defp json(opts), do: %{json: Map.get(opts, :json) == true}

  defp components(nil), do: {:ok, nil}

  defp components(text) do
    names = text |> String.split(",") |> Enum.map(&String.trim/1)
    known = Enum.map(Lock.components(), &Atom.to_string/1)

    cond do
      names == [] or "" in names ->
        {:usage, "run: --components takes a list like db,media"}

      Enum.any?(names, &(&1 not in known)) ->
        {:usage, "run: --components names #{Enum.join(known, " and ")} only"}

      Enum.uniq(names) != names ->
        {:usage, "run: --components names each component once"}

      true ->
        {:ok, names}
    end
  end

  defp timeout(nil, _wait?), do: {:ok, @default_timeout_s}
  defp timeout(_seconds, false), do: {:usage, "run: --timeout only applies with --wait"}
  defp timeout(seconds, true) when seconds in 1..@max_timeout_s, do: {:ok, seconds}

  defp timeout(_seconds, true),
    do: {:usage, "run: --timeout takes seconds, from 1 to #{@max_timeout_s}"}

  @doc false
  # The commands the overlay sends through `rpc`; `KilnCMS.Release` refuses
  # them under `eval` before it starts anything.
  @spec node_command?(command()) :: boolean()
  def node_command?(command), do: command in @node_commands

  @doc false
  # The commands that read the database beside the node: `eval` starts the
  # repo for them, and only them.
  @spec reads_database?(command()) :: boolean()
  def reads_database?(command), do: command in [:list, :verify]

  @doc """
  Run `argv` and return `{exit_code, output}`; see the moduledoc.

  Options: `:mode` (`:rpc`, `:eval` or `:mix`; absent allows everything, as
  `:mix`), and test seams, each defaulting to the real call: `:retention`
  (`&Retention.run/2`), `:importer` (`&Importer.retry_failed/0`), `:await`
  (`&Backups.await/2`), `:read_runs` (`&Backups.list_runs/1`), `:caller_ref`
  (a monitor on the caller, for `run --wait`), `:now`, `:dir`, and
  `KilnCMS.Backups.Verify.run/2`'s `:pg_restore` and `:held_stamp`.
  """
  @spec main([String.t()], keyword()) :: {exit_code(), iodata()}
  def main(argv, opts \\ []) when is_list(argv) do
    case parse(argv) do
      {:usage, message} ->
        usage_error(message, "--json" in argv, opts)

      {:ok, :help, args} ->
        render(:help, args, {0, %{}, nil, usage(opts)})

      {:ok, command, args} ->
        result =
          case refusal(command, opts[:mode]) do
            nil -> run(command, args, opts)
            refused -> refused
          end

        render(command, args, result)
    end
  end

  @doc false
  # For `KilnCMS.Release`: the output of a command that failed before it
  # could run (`code` and `message` as the JSON `error`), exit 1.
  @spec failure([String.t()], String.t(), String.t()) :: {exit_code(), iodata()}
  def failure(argv, code, message) do
    case parse(argv) do
      {:ok, command, args} -> render(command, args, {1, %{}, {code, message}, []})
      {:usage, usage} -> usage_error(usage, "--json" in argv, [])
    end
  end

  @doc false
  # `mix kiln.backup.<command>`: start the app without its job queues, print,
  # and exit non-zero the Mix way. `start` is a test seam.
  @spec mix_main(String.t(), [String.t()], (-> term())) :: :ok
  def mix_main(command, argv, start \\ &mix_start/0) do
    start.()
    {code, output} = main([command | argv], mode: :mix)
    IO.write(output)
    if code == 0, do: :ok, else: exit({:shutdown, code})
  end

  @doc false
  # A checkout's `app.start` boots a whole second node against the database
  # it is pointed at: every Oban queue would start draining that database's
  # jobs (its `:mail`, `:billing`, `:webhooks`, and this very backup's steps,
  # which the task's exit then kills mid-`pg_dump`), and the backup heartbeat
  # would beat and sweep the lock as one more backup node. So Oban starts in
  # `testing: :manual` (no queues, no plugins, never the leader; jobs are
  # inserted, and the serving application runs them) and the heartbeat is off.
  @spec mix_start() :: :ok
  def mix_start do
    Mix.Task.run("app.config")
    quiet_node_env()
    Mix.Task.run("app.start")
    :ok
  end

  @doc false
  @spec quiet_node_env() :: :ok
  def quiet_node_env do
    oban = Application.get_env(:kiln_cms, Oban, [])
    Application.put_env(:kiln_cms, Oban, Keyword.put(oban, :testing, :manual))
    backups = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(backups, :heartbeat?, false))
  end

  @doc "The usage text."
  @spec usage(keyword()) :: String.t()
  def usage(opts \\ []) do
    p = prefix(opts[:mode])

    """
    Usage:
      #{p}list [--limit N] [--json]
          The newest backups (default 20, at most 100), whether each one's files
          are on this host's disk, and what is running now.
      #{p}run [--components db,media] [--wait [--timeout SECONDS]] [--json]
          Ask for a backup now, as the Backups page does. --wait follows it until
          it ends (default 3 hours, at most 24); stopping the wait doesn't stop
          the backup.
      #{p}verify <stamp|id> [--json]
          Re-check a backup's files here: digests, sidecar, and the dump's table
          of contents. Records nothing.
      #{p}prune [--dry-run] [--json]
          Report what retention would delete. Nothing is deleted: a real prune
          runs inside every backup (#{p}run).
      #{p}rescan [--json]
          Import backups cron made in this host's backup directory.

    Exit status: 0 success, 1 the command failed, 2 a usage error.
    """
  end

  defp prefix(:mix), do: "mix kiln.backup."
  defp prefix(_mode), do: "bin/backup "

  defp usage_error(message, json?, opts) do
    if json?,
      do: {2, encode(nil, 2, %{}, {"usage", message})},
      else: {2, [message, "\n\n", usage(opts)]}
  end

  ## Where it runs

  defp refusal(command, :eval) when command in @node_commands do
    {1, %{}, {"needs_running_node", needs_running_node(command)}, []}
  end

  defp refusal(command, :rpc) when command in @beside_commands do
    message =
      "#{command} runs beside the application, not inside it: run `bin/backup #{command}` " <>
        "(it uses bin/kiln_cms eval)"

    {2, %{}, {"runs_beside_node", message}, []}
  end

  defp refusal(_command, _mode), do: nil

  defp needs_running_node(command) do
    "#{command} needs the running application on this host (its job queue and its " <>
      "importer), and this node has not started it. `bin/backup #{command}` runs it " <>
      "there through bin/kiln_cms rpc; check that the application is up."
  end

  ## Rendering

  # A command's result: `{exit_code, data, error | nil, text}`, where `error`
  # is `{code, message}`.
  # The caller left during `run --wait`: there is no one to print to.
  defp render(_command, _args, {code, _data, {"detached", _message}, _text}), do: {code, []}

  defp render(command, %{json: true}, {code, data, error, _text}),
    do: {code, encode(command, code, data, error)}

  defp render(_command, _args, {code, _data, nil, text}), do: {code, text}

  defp render(_command, _args, {code, _data, {_code, message}, text}),
    do: {code, [text, "error: ", message, "\n"]}

  defp encode(command, code, data, error) do
    envelope = %{
      schema: @schema,
      command: command && Atom.to_string(command),
      ok: code == 0,
      exit_code: code,
      error: error && %{code: elem(error, 0), message: elem(error, 1)}
    }

    [Jason.encode!(Map.merge(data, envelope)), "\n"]
  end

  ## Commands

  defp run(:list, args, opts), do: list(args, opts)
  defp run(:run, args, opts), do: request(args, opts)
  defp run(:verify, args, opts), do: verify(args, opts)
  defp run(:prune, _args, opts), do: prune(opts)
  defp run(:rescan, _args, opts), do: rescan(opts)

  ## list

  defp list(args, opts) do
    query = Run |> Ash.Query.sort(started_at: :desc, id: :desc) |> Ash.Query.limit(args.limit)

    case read_runs(opts, query) do
      {:ok, runs} ->
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        view = DiskView.read(dir(opts), runs, now, cron_prunes: cron_prunes(runs, opts))
        in_flight = Backups.in_flight()

        rows = Enum.map(runs, &run_row(&1, view, in_flight))
        data = %{limit: args.limit, runs: rows, in_flight: in_flight_json(in_flight)}
        {0, data, nil, list_text(rows, in_flight)}

      {:error, error} ->
        read_failure(error, "couldn't read the backup history")
    end
  end

  defp run_row(%Run{} = run, view, in_flight) do
    presence = Map.get(view.presence, run.id, %{state: :none, artifacts: []})

    %{
      id: run.id,
      stamp: run.stamp,
      status: run.status,
      origin: run.origin,
      trigger: run.trigger,
      components: run.components,
      started_at: run.started_at,
      finished_at: run.finished_at,
      error: run.error,
      offsite_status: run.offsite_status,
      dir_id: run.dir_id,
      presence: presence.state,
      in_flight: match?(%{stamp: stamp} when stamp == run.stamp, in_flight),
      resumable: MapSet.member?(view.resumable, run.id),
      artifacts:
        run.artifacts
        |> Enum.with_index()
        |> Enum.map(fn {artifact, index} ->
          judged = Enum.at(presence.artifacts, index, %{})

          %{
            kind: artifact.kind,
            name: artifact.name,
            bytes: artifact.bytes,
            verified: artifact.verified,
            sha256: artifact.sha256,
            parts: if(artifact.parts == [], do: nil, else: length(artifact.parts)),
            presence: Map.get(judged, :state),
            gone: Map.get(judged, :gone, [])
          }
        end)
    }
  end

  defp list_text([], in_flight), do: [in_flight_text(in_flight), "No backups recorded.\n"]

  defp list_text(rows, in_flight) do
    lines =
      for row <- rows do
        size = row.artifacts |> Enum.map(& &1.bytes) |> Enum.sum()

        [
          row.stamp,
          "  ",
          pad(row.status, 10),
          pad(row.origin, 9),
          pad(Enum.join(row.components, ","), 9),
          pad(row.presence, 17),
          format_bytes(size),
          if(row.in_flight, do: "  (running now)", else: ""),
          "\n"
        ]
      end

    [in_flight_text(in_flight) | lines]
  end

  defp pad(value, width), do: value |> to_string() |> String.pad_trailing(width)

  defp format_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MiB"
  defp format_bytes(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"
  defp format_bytes(bytes), do: "#{bytes} B"

  # The prunes cron recorded after the oldest imported row, read as
  # `KilnCMSWeb.BackupLive` reads them, with the `:read` grant the system
  # actor has (`:prune_windows` and `:newest_import` are the platform
  # admin's): the same filters, so presence matches the History page. A read
  # that fails passes none, the documented fallback.
  defp cron_prunes(runs, opts) do
    case for(%Run{origin: :imported, started_at: %DateTime{} = at} <- runs, do: at) do
      [] ->
        nil

      starts ->
        oldest = Enum.min(starts, DateTime)

        windows =
          Run
          |> Ash.Query.filter(
            origin == :imported and started_at > ^oldest and not is_nil(keep_days)
          )
          |> Ash.Query.select([:id, :started_at, :finished_at, :keep_days])
          |> Ash.Query.sort(started_at: :asc, id: :asc)

        newest =
          Run
          |> Ash.Query.filter(origin == :imported)
          |> Ash.Query.select([:id, :started_at])
          |> Ash.Query.sort(started_at: :desc, id: :desc)
          |> Ash.Query.limit(1)

        with {:ok, windows} <- read_runs(opts, windows),
             {:ok, newest} <- read_runs(opts, newest) do
          Presence.cron_prunes(windows, Enum.find_value(newest, & &1.started_at))
        else
          _refused -> nil
        end
    end
  end

  defp read_runs(opts, query) do
    reader = Keyword.get(opts, :read_runs, &Backups.list_runs/1)
    reader.(query: query, actor: Backups.system(), authorize_with: :error)
  end

  # A database that can't be reached gets a message that says so, and how to
  # check files without it; anything else is the read's own error.
  defp read_failure(error, what) do
    if unreachable?(error),
      do: {1, %{}, {"database_unreachable", unreachable_message()}, []},
      else: {1, %{}, {"read_failed", "#{what}: #{message(error)}"}, []}
  end

  @doc false
  @spec unreachable_message() :: String.t()
  def unreachable_message do
    "the database is unreachable; on the host, `scripts/backup.sh verify` checks a " <>
      "backup's files without it"
  end

  defp unreachable?(%DBConnection.ConnectionError{}), do: true

  defp unreachable?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &unreachable?/1)

  defp unreachable?(%{error: error}), do: unreachable?(error)
  # How Ash's unknown error carries an exception it caught: its message.
  defp unreachable?("** (DBConnection.ConnectionError)" <> _message), do: true
  defp unreachable?(_other), do: false

  defp message(%{__exception__: true} = error), do: Exception.message(error)
  defp message(other), do: inspect(other)

  ## run

  defp request(args, opts) do
    request_opts = [trigger: "console", components: args.components]

    case Backups.request(request_opts, Backups.system()) do
      {:ok, %{status: status, chain: chain}} ->
        stamp =
          case Backups.in_flight() do
            %{chain: ^chain, stamp: stamp} when status == :started -> stamp
            _other -> nil
          end

        base = %{
          status: status,
          chain: chain,
          stamp: stamp,
          components: args.components,
          waited: false,
          outcome: nil,
          run: nil
        }

        cond do
          not args.wait ->
            {0, base, nil, started_text(base)}

          status == :started ->
            waited(base, args, opts)

          true ->
            {1, base, not_waited(status), started_text(base)}
        end

      {:error, reason} ->
        {1, %{status: nil, chain: nil}, {reason_code(reason), describe_request(reason)}, []}
    end
  end

  # `--wait` follows only a backup this request started: the chain a queued
  # or folded request returns is the running one, not the one that will run
  # this request.
  defp not_waited(:queued) do
    {"queued",
     "queued behind the running backup, which --wait doesn't follow; run `bin/backup run " <>
       "--wait` again after it ends, or drop --wait"}
  end

  defp not_waited(:folded) do
    {"not_started",
     "a backup of the same kind is already queued behind the running one, and it covers " <>
       "this request; --wait doesn't follow it: run `bin/backup list` to see it start, " <>
       "or drop --wait"}
  end

  defp started_text(%{status: :started} = base),
    do: "Backup started#{stamp_text(base.stamp)} (chain #{base.chain}).\n"

  defp started_text(%{status: :queued} = base),
    do: "Backup queued: it starts when the running one (chain #{base.chain}) ends.\n"

  defp started_text(%{status: :folded} = base),
    do:
      "A backup of the same kind is already queued behind chain #{base.chain}; it covers " <>
        "this request.\n"

  defp stamp_text(nil), do: ""
  defp stamp_text(stamp), do: " as #{stamp}"

  defp waited(base, args, opts) do
    deadline = System.monotonic_time(:millisecond) + args.timeout_s * 1000

    case wait(base.chain, deadline, opts) do
      :detached ->
        # The caller is gone: nothing can be printed to it.
        {1, %{base | waited: true, outcome: :detached}, {"detached", "the caller left"}, []}

      outcome ->
        run = finished_run(base.chain, opts)
        data = %{base | waited: true, outcome: outcome_name(outcome), run: run}
        text = [started_text(base), outcome_text(outcome, run)]

        case outcome do
          :ok -> {0, data, nil, text}
          {:error, reason} -> {1, data, {outcome_code(reason), outcome_message(reason)}, text}
        end
    end
  end

  # `Backups.await/2` in chunks, so a caller that left (its group leader is
  # on the `bin/backup` node under rpc) is noticed within a chunk and the wait
  # stops; the backup itself carries on in its chain.
  defp wait(chain, deadline, opts) do
    await = Keyword.get(opts, :await, &Backups.await/2)
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      caller_gone?(opts[:caller_ref]) ->
        :detached

      remaining <= 0 ->
        {:error, :timeout}

      true ->
        case await.(chain, timeout: min(@chunk_ms, remaining), interval: @poll_ms) do
          {:error, :timeout} -> wait(chain, deadline, opts)
          outcome -> outcome
        end
    end
  end

  @doc false
  # Whether the monitor `ref` (on the caller) has fired. Consumes the
  # `:DOWN`, so callers check once.
  @spec caller_gone?(reference() | nil) :: boolean()
  def caller_gone?(nil), do: false

  def caller_gone?(ref) when is_reference(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> true
    after
      0 -> false
    end
  end

  defp finished_run(chain, opts) do
    query = Run |> Ash.Query.filter(chain_id == ^chain) |> Ash.Query.limit(1)

    case read_runs(opts, query) do
      {:ok, [%Run{} = run | _]} ->
        %{id: run.id, stamp: run.stamp, status: run.status, error: run.error}

      _none ->
        nil
    end
  end

  defp outcome_name(:ok), do: :succeeded
  defp outcome_name({:error, :canceled}), do: :canceled
  defp outcome_name({:error, {:skipped, _}}), do: :skipped
  defp outcome_name({:error, :no_run}), do: :no_run
  defp outcome_name({:error, :timeout}), do: :timeout
  defp outcome_name({:error, _other}), do: :failed

  defp outcome_code(:canceled), do: "canceled"
  defp outcome_code({:skipped, _}), do: "skipped"
  defp outcome_code(:no_run), do: "no_run"
  defp outcome_code(:timeout), do: "timeout"
  defp outcome_code(_other), do: "failed"

  defp outcome_message(:canceled), do: "the backup was canceled"
  defp outcome_message({:skipped, error}), do: "the backup was skipped: #{text(error)}"
  defp outcome_message(:no_run), do: "the chain ended without a backup run"

  defp outcome_message(:timeout),
    do: "stopped waiting at --timeout; the backup carries on (bin/backup list shows it)"

  defp outcome_message(reason), do: "the backup failed: #{text(reason)}"

  defp outcome_text(:ok, run), do: "Backup succeeded#{run_stamp(run)}.\n"
  defp outcome_text({:error, _reason}, _run), do: ""

  defp run_stamp(%{stamp: stamp}), do: " (#{stamp})"
  defp run_stamp(_none), do: ""

  defp text(value) when is_binary(value), do: value
  defp text(value), do: inspect(value)

  defp describe_request({:queue_busy, :backup}),
    do: "a backup is already queued; ask again once it has started"

  defp describe_request({:queue_busy, {:resume, stamp}}),
    do: "a resume of #{stamp} is queued; ask again once it has started"

  defp describe_request(:disabled), do: "in-app backups are turned off (BACKUP_ENABLED=false)"
  defp describe_request(:no_database_url), do: "no database URL to back up is configured"
  defp describe_request(:no_pg_dump), do: "pg_dump is not installed on this node"
  defp describe_request(:no_pg_restore), do: "pg_restore is not installed on this node"
  defp describe_request(:invalid_components), do: "--components names db and media only"

  defp describe_request(:no_media_dir),
    do: "there is no media directory to back up on this deployment"

  defp describe_request(:forbidden), do: "the backup system actor was refused"
  defp describe_request(reason), do: text(reason)

  ## verify

  defp verify(args, opts) do
    case find_run(args.target, opts) do
      {:ok, %Run{} = run} ->
        verify_opts =
          [cron_prunes: cron_prunes([run], opts)] ++
            Keyword.take(opts, [:dir, :now, :pg_restore, :held_stamp])

        case Verify.run(run, verify_opts) do
          {:ok, report} -> verify_result(run, report)
          {:error, :in_progress} -> in_progress(run)
          {:error, {:lock_unreadable, reason}} -> lock_unreadable(run, reason)
          {:error, reason} -> {1, %{}, {reason_code(reason), text(reason)}, []}
        end

      {:ok, nil} ->
        {1, %{}, {"not_found", "no backup #{target_text(args.target)} is recorded"}, []}

      {:error, error} ->
        read_failure(error, "couldn't read the backup")
    end
  end

  defp find_run({:stamp, stamp}, opts) do
    query = Run |> Ash.Query.filter(stamp == ^stamp) |> Ash.Query.limit(1)
    with {:ok, runs} <- read_runs(opts, query), do: {:ok, List.first(runs)}
  end

  defp find_run({:id, id}, opts) do
    query = Run |> Ash.Query.filter(id == ^id) |> Ash.Query.limit(1)
    with {:ok, runs} <- read_runs(opts, query), do: {:ok, List.first(runs)}
  end

  defp target_text({_kind, value}), do: value

  defp lock_unreadable(run, reason) do
    message =
      "the backup lock couldn't be read (#{text(reason)}), so whether backup #{run.stamp} " <>
        "is still being written can't be told; nothing was checked. Try again"

    {1, %{run: run_ref(run)}, {"lock_unreadable", message}, []}
  end

  defp in_progress(run) do
    message = "backup #{run.stamp} is still running; verify it once it has finished"
    {1, %{run: run_ref(run)}, {"in_progress", message}, []}
  end

  defp verify_result(run, report) do
    data = %{
      run: run_ref(run),
      verified: report.verified,
      hashed: report.hashed,
      failed: report.failed,
      dir_id_mismatch: report.dir_id_mismatch,
      dir_id_error: report.dir_id_error,
      artifacts: report.artifacts,
      checks: report.checks
    }

    text = verify_text(run, report)

    cond do
      report.verified ->
        {0, data, nil, text}

      report.failed > 0 ->
        {1, data, {"not_verified", "#{report.failed} check(s) failed"}, text}

      true ->
        message =
          "none of this backup's files is on this host's disk to check (pruned or off-site only)"

        {1, data, {"nothing_local", message}, text}
    end
  end

  defp run_ref(run), do: %{id: run.id, stamp: run.stamp, status: run.status, dir_id: run.dir_id}

  defp verify_text(run, report) do
    lines =
      for check <- report.checks do
        ["  ", pad(check.result, 8), pad(check.check, 11), check.file, ": ", check.detail, "\n"]
      end

    verdict =
      if report.verified,
        do: "Backup #{run.stamp} verified here (#{report.hashed} file(s) hashed).\n",
        else: "Backup #{run.stamp} is NOT verified here.\n"

    ["Backup #{run.stamp}:\n", lines, verdict]
  end

  ## prune

  defp prune(opts) do
    retention = Keyword.get(opts, :retention, &Retention.run/2)
    in_flight = Backups.in_flight()
    destinations = destinations()

    base = %{
      report_only: true,
      in_flight: in_flight_json(in_flight),
      destinations: destinations.entries
    }

    # The only Retention pass here, and always a dry run: it plans and
    # deletes nothing (no file, no marker, no `mark_pruned`).
    case retention.(dir(opts), dry_run: true) do
      {:ok, %{plan: plan}} ->
        would_delete = Enum.map(plan.delete, &plan_entry/1)

        data =
          Map.merge(base, %{
            would_delete: would_delete,
            kept: length(plan.keep),
            last_good: plan.last_good
          })

        text = prune_text(would_delete, length(plan.keep), destinations.entries)

        case destinations.error do
          nil -> {0, data, nil, text}
          message -> {1, data, {"destinations_unreadable", message}, text}
        end

      {:error, reason} ->
        data = Map.merge(base, %{would_delete: nil, kept: nil, last_good: nil})
        message = "retention couldn't plan: #{Retention.describe(reason)}"
        {1, data, {reason_code(reason), message}, [report_only_line()]}
    end
  end

  defp report_only_line,
    do:
      "Report only — nothing is deleted. A real prune runs inside every backup (bin/backup run).\n"

  defp plan_entry(entry) do
    %{
      stamp: entry.stamp,
      kind: entry.kind,
      sub: entry.sub,
      files: entry.files,
      reason_code: reason_code(entry.reason)
    }
  end

  defp prune_text(would_delete, kept, destinations) do
    deletes =
      case would_delete do
        [] ->
          ["Nothing would be deleted here; ", Integer.to_string(kept), " kept.\n"]

        entries ->
          [
            "Would delete here (#{length(entries)}; #{kept} kept):\n"
            | for(
                e <- entries,
                do: "  #{e.sub}/#{Enum.join(e.files, ", ")}  (#{e.reason_code})\n"
              )
          ]
      end

    dests =
      for d <- destinations do
        reason = if d.reason, do: ": #{d.reason}", else: ""
        "  #{d.name} (#{d.kind}): pruning #{d.state}#{reason}\n"
      end

    [report_only_line(), deletes, if(dests == [], do: [], else: ["Destinations:\n" | dests])]
  end

  # Each enabled destination's pruning state, as the Destinations tab works it
  # out: settings only, no secrets. Every stored row (enabled or not) is
  # passed to `prune_blocker/3`, as retention passes it.
  defp destinations do
    env_location = Destination.env_location()
    query = Ash.Query.sort(DestinationConfig, position: :asc, inserted_at: :asc, id: :asc)

    case Backups.list_backup_destinations(
           query: query,
           actor: Backups.system(),
           authorize_with: :error
         ) do
      {:ok, rows} ->
        stored = for row <- rows, row.enabled, do: stored_entry(row, rows, env_location)

        %{entries: env_entry(rows, env_location) ++ stored, error: nil}

      {:error, error} ->
        %{
          entries: env_entry(:unreadable, env_location),
          error: "couldn't read the stored backup destinations: #{message(error)}"
        }
    end
  end

  defp stored_entry(row, rows, env_location) do
    config = %Config{id: row.id, key: "dest:" <> row.id, kind: row.kind, settings: row.settings}

    state =
      cond do
        not row.prune -> {:off, nil}
        reason = Retention.prune_blocker(config, rows, env_location) -> {:blocked, reason}
        true -> {:on, nil}
      end

    destination_entry(config.key, row.name, row.kind, state)
  end

  defp env_entry(rows, env_location) do
    case Destination.env_destination() do
      nil ->
        []

      env ->
        state =
          cond do
            not Backups.rclone_remote_prune?() -> {:off, nil}
            rows == :unreadable -> {:blocked, :unreadable}
            reason = Retention.prune_blocker(:env, rows, env_location) -> {:blocked, reason}
            true -> {:on, nil}
          end

        [destination_entry(env["key"], env["label"], env["kind"], state)]
    end
  end

  defp destination_entry(key, name, kind, {state, reason}) do
    %{
      key: key,
      name: name,
      kind: kind,
      state: state,
      reason_code: reason && reason_code(reason),
      reason: reason && blocker_text(reason)
    }
  end

  defp blocker_text(:unreadable), do: "the stored destinations couldn't be read"
  defp blocker_text(reason), do: Retention.describe(reason)

  ## rescan

  defp rescan(opts) do
    importer = Keyword.get(opts, :importer, &Importer.retry_failed/0)

    case importer.() do
      {:ok, summary} ->
        counts = for {key, value} <- summary, is_integer(value), into: %{}, do: {key, value}
        data = %{scope: :local, summary: counts}
        text = ["Rescanned this host's backup directory: ", summary_text(counts), "\n"]

        case Map.get(counts, :failed, 0) do
          0 ->
            {0, data, nil, text}

          failed ->
            message = "#{failed} backup(s) couldn't be imported; the server log says why"
            {1, data, {"import_failed", message}, text}
        end

      {:error, reason} ->
        {1, %{scope: :local, summary: nil}, {"rescan_failed", "couldn't rescan: #{text(reason)}"},
         []}
    end
  end

  defp summary_text(counts) do
    counts
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(", ", fn {key, value} -> "#{value} #{key}" end)
  end

  ## Shared

  defp dir(opts), do: Keyword.get_lazy(opts, :dir, &Backups.dir/0)

  defp in_flight_json(nil), do: nil

  defp in_flight_json(in_flight) do
    in_flight
    |> Map.take([:chain, :stamp, :resume, :trigger, :step, :part, :phase, :acquired_at])
    |> Map.put(:components, in_flight[:components])
    |> Map.put(:waiting, in_flight[:waiting])
  end

  defp in_flight_text(nil), do: ""

  defp in_flight_text(in_flight) do
    step = if in_flight.part, do: "#{in_flight.step} #{in_flight.part}", else: in_flight.step
    "Running now: #{in_flight.stamp || "a backup"} (#{in_flight.trigger}), step #{step}.\n"
  end

  # The leading atom of a reason term, as a string: `{:expired, rule, days}`
  # is `"expired"`. The whole term only reaches the text output.
  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_code(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      atom when is_atom(atom) -> Atom.to_string(atom)
      _other -> "error"
    end
  end

  defp reason_code(_reason), do: "error"
end
