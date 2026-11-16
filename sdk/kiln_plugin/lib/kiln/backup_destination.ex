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
  Why a call failed. A string is shown to the admin, after Kiln has removed
  the destination's secrets from it, so make it a sentence they can act on.
  Any other term is shown `inspect`ed.
  """
  @type reason :: String.t() | term()

  @doc """
  The stable identifier stored on each destination of this adapter. Rows
  outlive module names, so this must never change once destinations carry
  it. Lowercase letters, digits and `_`, at most 32 characters. `local` and
  `rclone` are Kiln's own.
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
  there. `:ok` only once the whole file is stored. `opts` is empty today;
  `:resume` is reserved for resumable uploads.
  """
  @callback put(Config.t(), file(), opts :: keyword()) :: :ok | {:error, reason()}

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
  Which of `:list` and `:delete` actually work. Retention runs only on a
  destination that supports both. The default, `[]`, means neither, so
  nothing is ever deleted from a destination that didn't say it can be.
  """
  @callback supports() :: [:list | :delete]

  @optional_callbacks supports: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour Kiln.BackupDestination

      @impl Kiln.BackupDestination
      def supports, do: []

      defoverridable supports: 0
    end
  end
end
