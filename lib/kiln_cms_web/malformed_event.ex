defmodule KilnCMSWeb.MalformedEvent do
  @moduledoc """
  Appends a catch-all `handle_event/3` to every Kiln LiveView, so a pushed event
  whose payload arrived in a shape no clause matches is **ignored** rather than
  crashing the view (#764).

  ## The problem it closes

  A `handle_event/3` payload is entirely client-controlled — the browser can
  push any JSON — so `%{"name" => name}` constrains the key and never the value.
  `String.trim/1`, `Integer.parse/1` and friends have no clause for a list or a
  map and raise, which takes down the LiveView.

  Lower severity than the public-HTTP version of the same bug (#751): every one
  of these needs an authenticated editor or admin session, so it is
  crash-your-own-session plus noise in the error tracker, not an anonymous
  denial of service. It is still a crash a bookmark or a stale build can cause.

  The fix has two halves, and this is only the second:

    1. **A guard on the clause head** — `when is_binary(id)` — so a
       wrong-shaped payload does not match a handler that would then raise
       inside its body. That is per-handler work and cannot be automated: only
       the handler knows which of its keys is a string and which is a list.
    2. **A catch-all**, so an unmatched event is a no-op instead of a
       `FunctionClauseError`. That *is* automatable, and doing it here rather
       than in twenty-five modules is what makes the next handler inherit it.

  Without (2), adding a guard in (1) would turn a crash-in-the-body into a
  crash-at-the-head — no improvement. They only work together.

  ## Why `@before_compile` rather than a plain `quote`

  A catch-all that precedes a more specific clause of the same name silently
  wins, so injecting one from `use KilnCMSWeb, :live_view` at the *top* of the
  module would turn every real handler in it into a no-op. `@before_compile`
  emits after the module body instead.

  The guarantee is narrower than "last", and worth stating precisely because the
  failure is silent: `@before_compile` hooks fire in **registration** order, so
  this lands after the module body and after any hook registered *earlier* — but
  before one registered later. `use KilnCMSWeb, :live_view` sits at the top of
  every view, which is the losing position if a second `use` ever injects
  `handle_event/3` from its own `__before_compile__`. No Kiln LiveView does
  today, and `KilnCMSWeb.MalformedPayloadTest` pins it.

  ## Ignored, not crashed — and said out loud outside production

  No reply, ever: replying with an error would tell a prober which event names
  exist. But the log level is deliberately environment-dependent — see `log/2`.
  Silence is the right answer for a stale JS build in production and the wrong
  one for a developer whose handler is unreachable.

  The event name is logged, the payload is not — it is attacker-controlled and
  may carry whatever the author had typed into a form.

  ## What this does not do

  It cannot rescue a handler that *matches* and then raises inside its body.
  That is what the head guards are for, and the ones this ships alongside are
  listed in the #764 PR; the rest of the enumeration in that issue is still
  open work.
  """
  require Logger

  @doc false
  defmacro __using__(_opts) do
    quote do
      @before_compile KilnCMSWeb.MalformedEvent
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    # Injected unconditionally, including into views that define no
    # `handle_event/3` at all.
    #
    # An earlier version gated this on `Module.defines?/2`, to preserve a
    # `Phoenix.LiveView` warning for events nothing handles. That warning does
    # not exist: `Phoenix.LiveView.Channel` calls `socket.view.handle_event/3`
    # unconditionally, and only `handle_info` has the graceful
    # "undefined ..." path. So the gate did the opposite of its stated purpose —
    # it left `AnalyticsLive`, `CalendarLive`, `MembershipLive`, `OverviewLive`,
    # `ReleasePreviewLive` and `SignInLive` raising `UndefinedFunctionError` on
    # *any* pushed event, which is exactly the crash #764 is about.
    quote do
      @impl Phoenix.LiveView
      def handle_event(event, _payload, socket) do
        KilnCMSWeb.MalformedEvent.log(__MODULE__, event)
        {:noreply, socket}
      end
    end
  end

  # Warning outside production, debug in it.
  #
  # The two failure modes pull opposite ways. In production a user-triggerable
  # warning is an error-tracker flood (#700), so it must not be one. In
  # development the whole risk of this mechanism is that it turns a loud
  # `FunctionClauseError` into silence — and it does: it found a live bug in the
  # Columns block's heading-level select, where a `phx-change` on an unnamed
  # `<select>` drops its `phx-value-*` and the handler had never been reachable.
  # A no-op that says nothing is how that stays hidden for another year.
  @level if Mix.env() == :prod, do: :debug, else: :warning

  @doc false
  @spec log(module(), term()) :: :ok
  def log(module, event) do
    Logger.log(@level, fn ->
      "#{inspect(module)} ignoring unhandled or malformed event #{inspect(event)}"
    end)
  end
end
