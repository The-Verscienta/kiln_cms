defmodule Kiln.Plugins.Health.PluginStatus do
  @moduledoc """
  The health of one installed plugin (#2244), along three dimensions and one
  rollup. Built by `Kiln.Plugins.Health.Evaluate`; every field is an atom or
  data, never display text.

  ## integrity

  Whether the package this build locked is still the one hex.pm publishes at
  that version.

    * `:ok` — Hex reports the locked outer checksum;
    * `{:mismatch, %{locked: c, registry: c}}` — Hex reports a different one:
      the release was replaced on Hex after this build, the build resolved
      against a mirror or offline cache, or the lock was edited by hand
      without `mix deps.get` (which refuses a mismatch). It does **not** say
      the compiled code in this release was tampered with; nothing here
      re-hashes the running release;
    * `:not_found` — Hex has no such package or release (definitive);
    * `{:unverifiable, reason}` — no registry checksum to compare:
      `:git`, `:path`, `:private_repo`, `:no_checksum` (an old lock shape) or
      `:unknown_source`;
    * `:not_applicable` — built from this project (`:overlay`);
    * `:unknown` — Hex could not be asked or did not answer usably;
    * `:disabled` — the check is turned off.

  ## advisories

  `{:ok, notices}` when every source that applies answered, `{:unknown,
  notices}` when one did not (or a notice names the plugin but its range
  cannot be read): the notices are what *was* found, and unknown never reads
  as clean.

  ## abandonment

  A list of reasons, empty when none apply:
  `{:retired, reason, message}` (Hex retired the installed release; `reason`
  is `:security`, `:deprecated`, `:invalid`, `:renamed` or `:other`),
  `{:stale, last_release_at}`, `{:sdk_unsupported, requirement, bundled}`,
  `{:sdk_requirement_invalid, requirement}`. `abandonment_known?` is false when
  a source it needs was unavailable.

  ## overall

  The first that applies of `:fail`, `:warn`, `:unknown`, `:unverifiable`,
  `:not_applicable`, `:ok` — see `Kiln.Plugins.Health.Evaluate.rollup/1`.
  """

  alias Kiln.Plugins.Health.Installed
  alias Kiln.Plugins.Health.Notice

  @enforce_keys [:plugin, :name, :source]
  defstruct [
    :plugin,
    :name,
    :source,
    :package,
    :version,
    :latest_version,
    :sdk_requirement,
    :outer_checksum,
    :git_ref,
    integrity: :unknown,
    advisories: {:unknown, []},
    abandonment: [],
    abandonment_known?: false,
    overall: :unknown
  ]

  @type integrity ::
          :ok
          | {:mismatch, %{locked: String.t(), registry: String.t()}}
          | :not_found
          | {:unverifiable, :git | :path | :private_repo | :no_checksum | :unknown_source}
          | :not_applicable
          | :unknown
          | :disabled

  @type advisories :: {:ok, [Notice.t()]} | {:unknown, [Notice.t()]}

  @type retirement_reason :: :security | :deprecated | :invalid | :renamed | :other

  @type abandonment_reason ::
          {:retired, retirement_reason(), String.t() | nil}
          | {:stale, DateTime.t()}
          | {:sdk_unsupported, String.t(), String.t()}
          | {:sdk_requirement_invalid, String.t()}

  @type overall :: :fail | :warn | :unknown | :unverifiable | :not_applicable | :ok

  @type t :: %__MODULE__{
          plugin: module(),
          name: String.t(),
          source: Installed.source(),
          package: String.t() | nil,
          version: String.t() | nil,
          latest_version: String.t() | nil,
          sdk_requirement: String.t() | nil | :unknown,
          outer_checksum: String.t() | nil,
          git_ref: String.t() | nil,
          integrity: integrity(),
          advisories: advisories(),
          abandonment: [abandonment_reason()],
          abandonment_known?: boolean(),
          overall: overall()
        }
end
