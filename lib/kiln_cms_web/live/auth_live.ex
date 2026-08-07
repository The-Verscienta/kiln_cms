defmodule KilnCMSWeb.AuthLive do
  @moduledoc """
  Wraps an `AshAuthentication.Phoenix` LiveView so it joins under Kiln's own
  `use KilnCMSWeb, :live_view` (#701).

  ## What this is for

  #688 refuses a LiveView join that carries no URL, because such a join matches
  no route and therefore skips its `live_session`'s `on_mount` hooks. That guard
  rides `use KilnCMSWeb, :live_view` — which the library's views cannot use, so
  they were the one hole left in it.

  The hole is not academic. Their routes carry
  `{KilnCMSWeb.LiveUserAuth, :assign_current_org}`, and a url-less join skips it,
  leaving `:current_org` unassigned. `KilnCMSWeb.Layouts.brand_or_unbranded/1`
  now fails closed on that — but it never gets the chance here, because the
  LiveView channel reads the layout from the *matched route*, and a join that
  matched no route falls back to `view.__live__()[:layout]`. For a library view
  that is the library's layout,
  not Kiln's, so Kiln's fail-closed rendering never runs and the page draws the
  **default organization's** name and logo — another tenant's identity on a
  tenant host, the leak #48 exists to prevent.

  Wrapping fixes it a step earlier and more completely: the guard refuses the
  join outright, so there is no render to get right.

  `KilnCMSWeb.SignInLive` is the same pattern arrived at for a different reason
  (#715), and already closed `/sign-in`, `/register` and `/reset`'s sign-in
  form this way. This generalizes it to the rest.

  ## Why a macro rather than three hand-written modules

  Each wrapper is the same four lines, and two of them are subtle enough that
  three copies would drift:

  * **`on_mount AshAuthentication.Phoenix.Utils.Flash` must be restated.** A
    module's `on_mount` list is compile-time, so delegating `mount/3` does not
    carry it, and dropping it would be a silent divergence from the library's
    own `:live_view` macro.

    It is restated for parity, not because these pages need it today: the only
    two components in the dependency that call `put_flash!/3` are the magic-link
    and password-reset *request* forms, which belong to the sign-in tree, not to
    any of the views wrapped here. (`KilnCMSWeb.SignInLive` says the hook is
    load-bearing, and for that view it is.) Restating it means an upstream
    release that starts flashing from one of these pages does not quietly lose
    the message.

    Worth knowing if you ever rely on it: `KilnCMSWeb.Layouts.auth/1` renders no
    flash group, so a flash set on any Kiln auth page is currently held in the
    socket and never drawn.
  * **`mount/3` is delegated whole, not matched on.** These wrappers add
    nothing to the socket, so there is no reason to destructure the reply;
    passing the return value straight through keeps working if a release starts
    answering `{:ok, socket, temporary_assigns: …}`. (`SignInLive` does match,
    because it has to modify the socket — and documents why the strict match is
    right there.)
  * **`handle_params/3` is emitted only when upstream defines it.** It is
    optional in the LiveView behaviour and `SignOutLive` has no params to read.
    An unconditional delegation compiles cleanly and then raises
    `UndefinedFunctionError` on the first mount of that page — a failure that
    only appears at runtime, on one of four wrappers.

  Everything below `mount/3` — the component tree, the overrides, the templates
  — stays the library's, so an upstream change to these pages arrives with the
  dependency instead of being frozen here.

  ## Usage

      defmodule KilnCMSWeb.ResetLive do
        use KilnCMSWeb.AuthLive, upstream: AshAuthentication.Phoenix.ResetLive
      end

  and point the router's `live_view:` option at the wrapper.
  """

  @doc false
  defmacro __using__(opts) do
    upstream = opts |> Keyword.fetch!(:upstream) |> Macro.expand(__CALLER__)

    # `handle_params/3` is optional in the LiveView behaviour and upstream does
    # not define it on every view — `SignOutLive` has no params to read. A
    # delegation emitted unconditionally compiles fine and then raises
    # `UndefinedFunctionError` on the first mount, so the clause is emitted only
    # when there is something to delegate to.
    Code.ensure_loaded!(upstream)
    handle_params? = function_exported?(upstream, :handle_params, 3)

    quote do
      use KilnCMSWeb, :live_view

      # See the moduledoc: a compile-time list, not carried by delegation.
      on_mount AshAuthentication.Phoenix.Utils.Flash

      @upstream unquote(upstream)

      @impl true
      def mount(params, session, socket), do: @upstream.mount(params, session, socket)

      if unquote(handle_params?) do
        # The `uri` is laundered rather than passed on, for the reason
        # `KilnCMSWeb.SignInLive` gives at its own `handle_params/3` (#687): it
        # is the URL the client put in its `live_patch` payload, and LiveView
        # checks the view and the live_session but never the host.
        #
        # Upstream discards it today — all three of these views spell it
        # `_uri` — but "a dependency ignores this argument" is not a property we
        # control across upgrades. `vouch_uri/2` keeps the path and re-roots it
        # on the authority the server vouched for at mount, so a patch naming
        # another org's host cannot reach AshAuthentication.
        @impl true
        def handle_params(params, uri, socket) do
          @upstream.handle_params(params, KilnCMSWeb.LiveUserAuth.vouch_uri(socket, uri), socket)
        end
      end

      @impl true
      def render(assigns), do: @upstream.render(assigns)
    end
  end
end
