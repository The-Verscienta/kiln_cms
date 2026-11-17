defmodule Kiln.BackupDestination do
  @moduledoc """
  The contract for a **backup destination** (kiln_cms#2220): somewhere an
  in-app backup copies its finished files, beside the copy it keeps in
  `BACKUP_DIR`. Kiln's own Local and Rclone destinations implement it, and so
  can a plugin's.

  A plugin contributes one from its entry module:

      @impl Kiln.Plugin
      def backup_destinations, do: [MyPlugin.BackupDestination]

  Installing one changes nothing by itself. A platform admin adds a
  destination of its `kind/0` on the console's Backups → Destinations tab,
  filling in the fields it declares (`fields/0`), and only then do backups
  start to reach it. Cron backups (`scripts/backup.sh`) never use it.

  Since 1.5. A plugin using it should require `{:kiln_plugin, "~> 1.5"}`.

  ## What a destination is handed

  Every call but `kind/0`, `label/0`, `fields/0` and `supports/0` gets a
  `Kiln.BackupDestination.Config`: the destination's settings, as the admin
  entered them, and its secrets, decrypted just before the call. The config
  is never stored anywhere a secret could leak from, and its `Inspect` shows
  neither map. Keep it that way:

    * read secrets only from `config.secrets`, never from `config.settings`;
    * never put a secret in a return value, an error, a log line or
      `describe/1`. Kiln redacts the secrets it knows of from every error
      before showing it, but that is a backstop, not a license;
    * never keep the config, or a secret from it, in a process, an ETS
      table or `:persistent_term` beyond the call.

  ## Where it runs

  An adapter runs **in the calling process, or in processes linked to it**.
  Kiln bounds every call with a deadline and kills the process when a backup
  is canceled or a deadline passes, and a linked process dies with it. A
  process started any other way (unlinked, or under a supervisor of the
  plugin's) outlives the cancel and keeps uploading, so don't.

  A process an adapter spawns can be reported when it crashes: Erlang's crash
  reports and `Task`'s exit messages log the process's arguments and state. A
  secret must therefore never be an argument of a function a spawned process
  runs, or sit in its state. Pass it through the environment of an OS
  command (`System.cmd/3`'s `:env`), or read it from the config inside the
  calling process.

  A call can be killed at any point. `put/3` must leave nothing that a later
  `list/1` would mistake for a whole file: upload under a temporary name and
  rename, or use the store's own atomic upload.

  ## Files

  A backup's files are named the way `scripts/backup.sh` names them
  (`kiln-db-<stamp>.dump`, `kiln-media-<stamp>.partNN.tar.gz`, their
  `.sha256` sidecars, …) and live in a subdirectory, `"db"` or `"media"`. A
  destination keeps each one under `<subdir>/<name>`, under whatever root its
  settings name, so a restore can find a backup's files again. `list/1`
  answers every file it finds there; Kiln ignores names that are not a
  backup's.

  Retention (deleting a destination's old backups) only runs on a
  destination whose `supports/0` includes both `:list` and `:delete`, and
  only ever deletes files Kiln recorded sending there.

  ## What `put/3` answers

    * `:ok` once the whole file is stored;
    * `{:ok, :already_present}` when the destination already holds this very
      file (same size and sha256) and nothing was sent. Kiln records it as
      sent. Only answer it when the store can vouch for the content, not for
      a name alone;
    * `{:error, {:permanent, message}}` for a failure no retry fixes (the
      bucket does not exist, the credentials are refused for good). Kiln
      fails this destination at once, without spending the backup's
      remaining attempts on it;
    * `{:error, :deadline}` when the adapter stopped because `opts[:deadline]`
      was near, having saved its progress (see below);
    * `{:error, :superseded}` when a resumable upload's `save` answered it
      (see below);
    * `{:error, reason}` for anything else, which Kiln retries.

  `opts[:deadline]`, passed to every adapter, is the
  `System.monotonic_time(:millisecond)` instant by which the call must be
  done. Kiln kills the call there anyway; an adapter that watches it can stop
  cleanly first.

  ## Resumable uploads

  An adapter whose `supports/0` includes `:resume`, and which implements
  `abort_upload/3`, gets `opts[:resume]`, a `Kiln.BackupDestination.Resume`,
  on every `put/3`. Through it an upload interrupted by a timeout, a retry or
  a node going away continues where it stopped instead of starting over:

    * `resume.checkpoint` is what the adapter last saved for this file on
      this destination, or `nil` for a fresh start. Kiln hands it back only
      for the same file (same size and sha256): a file that changed starts
      over, and its old upload is aborted;
    * `resume.save.(checkpoint)` records progress. Call it right after the
      store upload is created, before any data is sent (so it can be found
      and aborted later), and after each part the store has acknowledged.
      `save` runs in the adapter's process and writes to Kiln's database;
    * a checkpoint is a map that survives a JSON round trip, at most 8 KiB
      encoded. It comes back with **string keys**, whatever keys it was saved
      with. Never put a secret in it: it is stored in the clear. An upload id
      and part numbers and their store tags are what it is for. A
      `bytes_done` key, a non-negative integer, is how far the upload got, as
      the backup's log reports it when a later attempt resumes;
    * when `save` answers `{:error, :superseded}`, a later attempt of the
      backup owns this upload now: stop at once and return
      `{:error, :superseded}`. An adapter that created a fresh store upload
      in this very call aborts that one itself before returning. On any other
      `{:error, reason}` from `save`, stop and return that error;
    * trust nothing in a checkpoint the store does not confirm: verify what
      the store already holds before sending only the rest.

  Kiln aborts a recorded upload (through `abort_upload/3`) only when it failed
  permanently, when the file changed, or when it lay unfinished for days.
  """

  defmodule Config do
    @moduledoc """
    One configured destination, as a `Kiln.BackupDestination` callback gets
    it.

      * `id` — the destination's id, or `nil` for one that is not stored (the
        one `BACKUP_RCLONE_REMOTE` defines, a form not saved yet);
      * `key` — the stable key backups record their results under, e.g.
        `"dest:<id>"`;
      * `kind` — the adapter's `c:Kiln.BackupDestination.kind/0`;
      * `settings` — the non-secret fields, keyed by field name;
      * `secrets` — the `:secret` fields, decrypted, keyed by field name.

    `inspect/1` shows only `id`, `key` and `kind`, so a config that reaches a
    log line, an error or a crash report carries no secret.
    """

    @derive {Inspect, only: [:id, :key, :kind]}
    @enforce_keys [:kind]
    defstruct [:id, :key, :kind, settings: %{}, secrets: %{}]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            key: String.t() | nil,
            kind: String.t(),
            settings: %{optional(String.t()) => term()},
            secrets: %{optional(String.t()) => String.t()}
          }
  end

  defmodule Resume do
    @moduledoc """
    A resumable upload's state, as `c:Kiln.BackupDestination.put/3` gets it in
    `opts[:resume]` (see "Resumable uploads" in `Kiln.BackupDestination`).

      * `checkpoint` — what the adapter last saved for this file, with string
        keys, or `nil` for a fresh start;
      * `attempt` — which attempt of the upload this is, from 1;
      * `save` — a function of one checkpoint map that records it:
        `:ok`, `{:error, :superseded}` (a later attempt owns the upload:
        stop) or `{:error, reason}` (stop, and return it).

    `inspect/1` shows only `attempt`.
    """

    @derive {Inspect, only: [:attempt]}
    @enforce_keys [:save]
    defstruct checkpoint: nil, attempt: 1, save: nil

    @type checkpoint :: %{optional(String.t() | atom()) => term()}

    @type t :: %__MODULE__{
            checkpoint: %{optional(String.t()) => term()} | nil,
            attempt: pos_integer(),
            save: (checkpoint() -> :ok | {:error, :superseded | term()})
          }
  end

  @typedoc """
  One field of a destination's form, in the order it is shown:

    * `name` — the key it is stored under in `settings` (or `secrets`);
    * `type` — `:string`, `:boolean`, `:integer`, or `:secret` (a string that
      is stored encrypted, goes to `config.secrets`, is never shown again,
      and is kept when the admin leaves it blank);
    * `required?` — whether a destination can be saved without it;
    * `help` — one line shown under the input, or `nil`.
  """
  @type field :: %{
          name: String.t(),
          type: :string | :boolean | :integer | :secret,
          required?: boolean(),
          help: String.t() | nil
        }

  @typedoc """
  A file to copy: its local `path`, the `subdir` (`"db"` or `"media"`) and
  `name` to keep it under, its size in `bytes` and its `sha256` (lowercase
  hex), both as verified on the local disk.
  """
  @type file :: %{
          path: Path.t(),
          subdir: String.t(),
          name: String.t(),
          bytes: non_neg_integer(),
          sha256: String.t()
        }

  @typedoc "A file a destination holds, as `list/1` answers it."
  @type entry :: %{
          subdir: String.t(),
          name: String.t(),
          bytes: non_neg_integer(),
          mtime: DateTime.t() | nil
        }

  @typedoc "Which file to `get/3` or `delete/2`."
  @type ref :: %{subdir: String.t(), name: String.t()}

  @typedoc """
  A recorded upload to abort, as `c:abort_upload/3` gets it: the file's
  `subdir` and `name`, and the `checkpoint` the adapter last saved for it
  (string keys).
  """
  @type upload :: %{subdir: String.t(), name: String.t(), checkpoint: map() | nil}

  @typedoc "A capability `supports/0` may declare."
  @type capability :: :list | :delete | :resume

  @typedoc """
  Why a call failed. A string is shown to the admin, after Kiln has removed
  the destination's secrets from it, so make it a sentence they can act on.
  Any other term is shown `inspect`ed.
  """
  @type reason :: String.t() | term()

  @doc """
  The stable identifier stored on each destination of this adapter. Rows
  outlive module names, so this must never change once destinations carry
  it. Lowercase letters, digits and `_`, at most 32 characters. `local`,
  `rclone` and `s3` are Kiln's own.
  """
  @callback kind() :: String.t()

  @doc "The name an admin picks the adapter by, e.g. `\"Backblaze B2\"`."
  @callback label() :: String.t()

  @doc "The fields the destination's form asks for. See `t:field/0`."
  @callback fields() :: [field()]

  @doc """
  Whether `config` is complete and well formed, without contacting anything.
  Called before a destination is saved. Kiln has already checked that the
  required fields are there.
  """
  @callback validate(Config.t()) :: :ok | {:error, reason()}

  @doc """
  Whether the destination works: reachable, the credentials accepted, and a
  file can be written there and removed again. Behind the form's **Test**
  button. Clean up whatever it wrote, also when it fails.
  """
  @callback test(Config.t()) :: :ok | {:error, reason()}

  @doc """
  Copy `file` to the destination as `<subdir>/<name>`, replacing any file
  there. `:ok` only once the whole file is stored; `{:ok, :already_present}`
  when the destination already holds this very file. See "What `put/3`
  answers" for the errors Kiln tells apart.

  `opts`:

    * `:deadline` — the `System.monotonic_time(:millisecond)` instant the
      call must be done by (since 1.5; every adapter gets it);
    * `:resume` — a `Kiln.BackupDestination.Resume`, only for an adapter
      that declares `:resume` in `supports/0` and implements
      `abort_upload/3`. See "Resumable uploads".

  Ignore any other option: later releases may add some.
  """
  @callback put(Config.t(), file(), opts :: keyword()) ::
              :ok | {:ok, :already_present} | {:error, reason()}

  @doc "Every file under the destination's `db` and `media` subdirectories."
  @callback list(Config.t()) :: {:ok, [entry()]} | {:error, reason()}

  @doc "Copy the destination's `<subdir>/<name>` to the local path `to`."
  @callback get(Config.t(), ref(), to :: Path.t()) :: :ok | {:error, reason()}

  @doc "Remove `<subdir>/<name>`. A file that is already gone is success."
  @callback delete(Config.t(), ref()) :: :ok | {:error, reason()}

  @doc """
  The destination, for people to read — `"s3://bucket/kiln"`,
  `"/mnt/nas/kiln"`. Never a secret.
  """
  @callback describe(Config.t()) :: String.t()

  @doc """
  Which of `:list`, `:delete` and `:resume` actually work. Retention runs
  only on a destination that supports both `:list` and `:delete`; resumable
  uploads only on one that supports `:resume` and implements
  `abort_upload/3`. The default, `[]`, means none, so nothing is ever deleted
  from a destination that didn't say it can be.
  """
  @callback supports() :: [capability()]

  @doc """
  Abort the store upload a resumable `put/3` started and recorded through
  `Kiln.BackupDestination.Resume`, freeing what the store keeps of it. An
  upload the store no longer knows is success. Required by an adapter that
  declares `:resume`. `opts` carries `:deadline`, as `put/3`'s does.
  """
  @callback abort_upload(Config.t(), upload(), opts :: keyword()) :: :ok | {:error, reason()}

  @optional_callbacks supports: 0, abort_upload: 3

  defmacro __using__(_opts) do
    quote do
      @behaviour Kiln.BackupDestination

      @impl Kiln.BackupDestination
      def supports, do: []

      defoverridable supports: 0
    end
  end
end
