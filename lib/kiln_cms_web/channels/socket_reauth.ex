defmodule KilnCMSWeb.SocketReauth do
  @moduledoc """
  The bounds and the actor reload behind periodic socket re-authorization (#775).

  `KilnCMS.Accounts.SessionEviction` (#675) drops a user's sockets from the
  actions that narrow a grant. This is the other half: every long-lived socket
  re-runs the check it passed at connect/join, so an authorization change
  **nobody wired an eviction into** — a new action, a role-resource edit, a
  direct `Ash.update` from a migration or a mix task — and a change to the
  *document* rather than to the user are both caught anyway, within a bounded
  time and with no cooperation from the code that made the change.

  Two callers, `KilnCMSWeb.CollabChannel` and `KilnCMSWeb.BridgeSocket`, and one
  module so the exposure window `docs/threat-model.md` promises an operator is a
  single number rather than two that can drift apart. Each caller keeps its own
  check — what "still authorized" means differs (the collab room authorizes the
  `:autosave` **write**, the bridge the read) and that difference is deliberate.

  The window and the reload are both here because both are easy to get subtly
  wrong: see `interval_ms/0` for where the number comes from, and
  `reload_actor/1` for why re-running the policies without it builds nothing.
  """

  require Logger

  alias KilnCMS.Accounts

  # 30s, chosen from measurement rather than taste — `priv/bench/socket_reauth.exs`
  # times the check against the per-message work a room already does, and
  # `docs/threat-model.md` carries the numbers and the arithmetic. The binding
  # constraint is not one room's CPU but the queries per second this adds at the
  # deployment's open-document ceiling (`KilnCMS.Collab.Crdt.max_documents/0`),
  # so halving the interval doubles that load.
  @interval_ms :timer.seconds(30)

  # The floor under the timer, for the socket that accepts writes: at most this
  # many updates are applied on one authorization. A timer bounds exposure in
  # wall-clock terms, which is what an operator reasons about and the only thing
  # that covers an idle-but-connected room; a count bounds it in damage done,
  # which is what matters on a channel that writes. Typing emits several updates
  # a second, so a timer alone would leave the number of writes unbounded.
  #
  # Set well above a normal room's rate between checks (a fast typist is ~5/s,
  # so ~150 in 30s) because it is a backstop against a room far busier than
  # that, not a second timer running at the same cadence.
  @update_floor 200

  @doc """
  How long a socket may go without re-running its check, in milliseconds.

  Overridable with `config :kiln_cms, :socket_reauth_interval_ms` so a
  deployment can tighten the window it publishes (and so tests need not wait
  #{div(@interval_ms, 1000)} seconds). Validated rather than trusted: a bad
  value here would silently disable the backstop, which is the one failure the
  mechanism exists to prevent.
  """
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: positive(:socket_reauth_interval_ms, @interval_ms)

  @doc """
  How many inbound updates a write socket may apply on one authorization.

  Overridable with `config :kiln_cms, :socket_reauth_update_floor`, validated
  the same way as `interval_ms/0`.
  """
  @spec update_floor() :: pos_integer()
  def update_floor, do: positive(:socket_reauth_update_floor, @update_floor)

  @doc """
  Reload the actor a socket connected as, or `:error` if it is no longer one.

  **This is the mechanism, not a detail of it.** The actor a socket holds is the
  struct resolved at connect, so re-running the policies against it re-derives
  the same answer from the same stale role, scopes, audiences and org
  memberships for as long as the tab stays open — a check that looks like it
  works and never refuses anything. A caller that skips this reload has built
  nothing.

  `nil` is a real answer, not a failure: `BridgeSocket` admits anonymous
  connections, which hold no account to reload but still have their *document*
  re-checked. The credential metadata is carried across the reload, so an
  API-key actor keeps the key scope its policies read (`using_api_key?` and the
  `ApiKey` record — see `KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess`)
  rather than quietly presenting as a session actor on the re-check.
  """
  @spec reload_actor(map() | nil) :: {:ok, map() | nil} | :error
  def reload_actor(nil), do: {:ok, nil}

  def reload_actor(%{id: id, __metadata__: metadata}) do
    case Accounts.get_user(id, authorize?: false) do
      # The struct match matters for the same reason it does at connect: an
      # interface declaring `not_found_error?: false` hands back `{:ok, nil}`,
      # and a nil actor reads published content rather than nothing.
      {:ok, %{} = actor} -> {:ok, carry_credential(actor, metadata)}
      _gone -> :error
    end
  rescue
    error ->
      # Fail closed, but distinguishable in the log from an ordinary refusal: a
      # pool timeout here would otherwise show up only as editors dropping to
      # solo mode for no stated reason.
      Logger.warning("Socket re-authorization actor reload failed, refusing: #{inspect(error)}")
      :error
  end

  # The credential keys only, never the whole metadata map: `__metadata__` also
  # carries Ash's own bookkeeping for the read that produced the struct
  # (`:selected`, `:keyset`), and pasting the connect read's over the reload's
  # would leave the fresh struct describing a projection it does not have — the
  # `Ash.NotLoaded`-is-truthy trap, arrived at from the other side.
  @credential_metadata [:using_api_key?, :api_key]

  defp carry_credential(actor, metadata) do
    %{
      actor
      | __metadata__: Map.merge(actor.__metadata__, Map.take(metadata, @credential_metadata))
    }
  end

  defp positive(key, default) do
    case Application.get_env(:kiln_cms, key, default) do
      n when is_integer(n) and n > 0 -> n
      _invalid -> default
    end
  end
end
