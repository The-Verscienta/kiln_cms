defmodule Kiln.Plugins.Health.Report do
  @moduledoc """
  One plugin health check's answer (#2244), as `Kiln.Plugins.Health.check/1`
  and `Kiln.Plugins.Health.cached/1` return it.

    * `plugins` — one `Kiln.Plugins.Health.PluginStatus` per installed plugin,
      in registration order;
    * `checked_at` — when the remote data was fetched; `nil` when nothing was
      (`:disabled`, `:nothing_to_check`);
    * `state` — `:fresh` (every request answered), `:partial` (at least one
      failed; those plugins read `:unknown`), `:disabled` (checks are off; only
      the local SDK check ran) or `:nothing_to_check` (no plugin comes from
      Hex, git or a path, so no request was made);
    * `notices` — the security notices feed: `:ok`, `:unknown` (it failed) or
      `:disabled` (turned off, or off by default for a fork; see
      `Kiln.SecurityNotices.url/0`).
  """

  alias Kiln.Plugins.Health.PluginStatus

  @enforce_keys [:plugins, :state]
  defstruct [:checked_at, plugins: [], state: :fresh, notices: :disabled]

  @type state :: :fresh | :partial | :disabled | :nothing_to_check

  @type t :: %__MODULE__{
          plugins: [PluginStatus.t()],
          checked_at: DateTime.t() | nil,
          state: state(),
          notices: :ok | :unknown | :disabled
        }
end
