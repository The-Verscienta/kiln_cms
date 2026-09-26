defmodule KilnCMSWeb.Tenant.OrgCount do
  @moduledoc """
  Whether this deployment has more than one organization — the fact
  `TENANT_STRICT_HOST`'s default hangs on (#1547).

  Unset, `TENANT_STRICT_HOST` means **auto**: strict host matching is on if and
  only if a second organization exists (`KilnCMSWeb.Tenant.strict_host?/0`).
  That question is asked on every request, through `fetch_org/1`, so it cannot
  be a `COUNT(*)`. This module answers it from a `:persistent_term` holding one
  of three verdicts:

    * `:single` — one organization (or none). Unknown hosts get the default org.
    * `:multi` — two or more. Unknown hosts are refused.
    * `:unknown` — nobody has managed to count yet.

  ## Where the verdict comes from

    * **Boot.** `init/1` counts synchronously, and this process starts before
      the endpoint, so the first request already has an answer.
    * **The org create path.** `KilnCMS.Accounts.Changes.RecordOrgCount` calls
      `org_created/0` after the create commits — the same moment #660's warning
      fires — so the second org switches strict matching on with no restart.
    * **Every other node.** `org_created/0` records the verdict locally first
      (so the creating node is read-your-writes consistent) and then broadcasts
      it on `Phoenix.PubSub`, the project's native cross-node channel. Each
      node's instance of this process records what it hears.
    * **A slow recount.** PubSub is at-most-once: a node that was partitioned or
      booting when the second org was created misses the message. Until the
      verdict is `:multi`, this process recounts on an interval (every five
      minutes while `:single`, every 30 seconds while `:unknown`), so a missed broadcast costs minutes, not "until the next
      deploy". Once `:multi`, it stops: organizations have no destroy action,
      so the count only ever rises and `:multi` is final.

  ## Only ever upwards

  The verdict never moves from `:multi` back down, and a recount that fails
  never replaces an answer already known. A failed recount on a `:single` node
  is a database blip, not evidence of a second organization, and flipping to
  strict there would refuse unknown hosts during exactly the outage #341 keeps
  the lenient path serving through.

  ## Fail direction: `:unknown` counts as strict

  `:unknown` only exists before the first successful count — in practice a
  node that booted while Postgres was unreachable. Auto treats it as **strict**,
  because the two ways of being wrong are not symmetric:

    * Lenient-but-actually-multi serves an unrecognized, possibly
      attacker-chosen `Host` another tenant's content, branding and analytics —
      a disclosure that cannot be taken back.
    * Strict-but-actually-single refuses non-canonical hosts on a single-site
      install for as long as the count stays unknown. With the database down
      the host lookup behind them fails too, so the answer is the retryable
      `503` (`:unavailable`) strict mode already gives an outage, not a leak;
      the canonical host (`PHX_HOST`), the console host, the health probes and
      the payment webhook are never refused either way; and the recount below
      settles the verdict within 30 seconds of the database coming back.

  A committed create whose own recount fails records `:multi` rather than
  `:unknown`: the seeded default org is created by migration, not through the
  action, so a create that committed means a second organization exists.

  ## Tests

  `config/test.exs` pins `TENANT_STRICT_HOST` to `false` and switches the
  periodic recount off: the verdict is VM-global, and a test sandbox's rows are
  invisible to this process. Tests that exercise auto set `:auto` and the
  verdict themselves (`put/1`).
  """
  use GenServer

  require Logger

  @key {__MODULE__, :verdict}
  @topic "kiln:tenant_org_count"

  @single_interval :timer.minutes(5)
  @unknown_interval :timer.seconds(30)

  @type verdict :: :single | :multi | :unknown

  @doc false
  def topic, do: @topic

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The current verdict. One `:persistent_term` read — safe on every request.
  """
  @spec verdict() :: verdict()
  def verdict, do: :persistent_term.get(@key, :unknown)

  @doc """
  Count organizations **in the calling process** and record the verdict.

  Returns the count (or `:unknown`). In the calling process so that a caller
  inside a database sandbox sees its own rows.
  """
  @spec refresh() :: non_neg_integer() | :unknown
  def refresh do
    count = KilnCMSWeb.Tenant.org_count()
    record(verdict_for(count))
    count
  end

  @doc """
  Record that an organization was just created, here and on every node.

  Called after the create commits (`KilnCMS.Accounts.Changes.RecordOrgCount`).
  Counts in the calling process, records locally, then broadcasts the verdict so
  the other nodes' routing flips too. Returns the count, or `:unknown` if it
  could not be read — in which case `:multi` is recorded anyway (see the
  moduledoc). Total: an advisory-adjacent hook must never raise into a
  committed create.
  """
  @spec org_created() :: non_neg_integer() | :unknown
  def org_created do
    count = KilnCMSWeb.Tenant.org_count()

    verdict =
      case verdict_for(count) do
        :unknown -> :multi
        known -> known
      end

    record(verdict)
    _ = Phoenix.PubSub.broadcast(KilnCMS.PubSub, @topic, {:org_verdict, node(), verdict})
    count
  rescue
    _error ->
      record(:multi)
      :unknown
  end

  @doc false
  # Test hook: set the verdict outright, bypassing the only-upwards rule, so a
  # test can put the VM back the way it found it.
  @spec put(verdict()) :: :ok
  def put(verdict) when verdict in [:single, :multi, :unknown] do
    :persistent_term.put(@key, verdict)
  end

  @doc false
  @spec verdict_for(non_neg_integer() | :unknown) :: verdict()
  def verdict_for(count) when is_integer(count) and count > 1, do: :multi
  def verdict_for(count) when is_integer(count), do: :single
  def verdict_for(_unknown), do: :unknown

  # Only upwards: `:multi` is final, and `:unknown` never replaces an answer.
  # `:persistent_term.put/2` triggers a global GC scan, so write only on a real
  # transition — there are at most two in a node's lifetime.
  defp record(new) do
    current = verdict()

    next =
      case {current, new} do
        {:multi, _} -> :multi
        {known, :unknown} -> known
        {_, new} -> new
      end

    if next != current do
      :persistent_term.put(@key, next)

      if next == :multi do
        Logger.info(
          "More than one organization exists; with TENANT_STRICT_HOST unset, " <>
            "requests whose Host matches no organization are now refused."
        )
      end
    end

    :ok
  end

  # --- GenServer ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(KilnCMS.PubSub, @topic)
    _ = refresh()
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info({:org_verdict, from, _verdict}, state) when from == node(),
    do: {:noreply, state}

  def handle_info({:org_verdict, _from, verdict}, state)
      when verdict in [:single, :multi, :unknown] do
    record(verdict)
    {:noreply, state}
  end

  def handle_info(:recount, state) do
    _ = refresh()
    schedule()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule do
    if Application.get_env(:kiln_cms, :tenant_org_recount, true) do
      case verdict() do
        :multi -> :ok
        :single -> Process.send_after(self(), :recount, @single_interval)
        :unknown -> Process.send_after(self(), :recount, @unknown_interval)
      end
    end

    :ok
  end
end
