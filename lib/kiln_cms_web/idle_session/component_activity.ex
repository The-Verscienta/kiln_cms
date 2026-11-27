defmodule KilnCMSWeb.IdleSession.ComponentActivity do
  @moduledoc """
  Makes an event a LiveComponent handles count as the person's activity for
  the idle timeout (#2491), the way a LiveView's own events do.

  A component's events (`phx-target={@myself}`) go straight to its
  `handle_event/3`; the LiveView's `:handle_event` hook, where
  `KilnCMSWeb.IdleSession` notes a use, never sees them. So
  `use KilnCMSWeb, :live_component` registers this module's
  `__before_compile__/1`, which wraps the component's `handle_event/3`: before
  the component's own clauses run, `KilnCMSWeb.IdleSession.component_event/1`
  tells the LiveView process (a component runs inside it) that the person did
  something, and the LiveView's idle hook notes the use, throttled as usual.

  A component that defines no `handle_event/3` is left alone. Every Kiln
  component goes through `use KilnCMSWeb, :live_component`, never
  `use Phoenix.LiveComponent` directly; `KilnCMSWeb.IdleSession.ComponentActivityTest`
  fails on one that doesn't.
  """

  @doc false
  defmacro __before_compile__(env) do
    if Module.defines?(env.module, {:handle_event, 3}) do
      quote do
        defoverridable handle_event: 3

        @impl Phoenix.LiveComponent
        def handle_event(event, params, socket) do
          KilnCMSWeb.IdleSession.component_event(event)
          super(event, params, socket)
        end
      end
    end
  end
end
