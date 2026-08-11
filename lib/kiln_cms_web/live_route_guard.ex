defmodule KilnCMSWeb.LiveRouteGuard do
  @moduledoc """
  Refuses a LiveView join that skips its `live_session`'s `on_mount` hooks (#688).

  `Phoenix.LiveView`'s channel has a catch-all for a join payload carrying
  neither `"url"` nor `"redirect"`. It matches no route, and the channel attaches
  a `live_session`'s `on_mount` list only when a route matched:

      defp load_lifecycle(%{lifecycle: lifecycle}, %Route{live_session: %{extra: %{on_mount: on_mount}}}) do
        update_in(lifecycle.mount, &(on_mount ++ &1))
      end

      defp load_lifecycle(%{lifecycle: lifecycle}, _), do: lifecycle

  So for such a join **none** of the router's hooks run — not `:current_user`,
  not `:assign_current_org`, and not `:live_editor_required` or
  `:live_admin_required`, which are the router-level RBAC for `/editor/*` and
  the admin console. The credential needed to try it is the signed
  `data-phx-session` blob, scraped from any page the caller is served
  legitimately — a token that outlives both the visit and a later demotion.

  ## Why this is a hook on the view rather than in the router

  It has to be, because the router's hooks are exactly what does not run. What
  survives is the `on_mount` list declared by the LiveView **module**, so
  `KilnCMSWeb.live_view/0` declares this one and every LiveView built with
  `use KilnCMSWeb, :live_view` carries it.

  ## What it was, and what it is now

  Nothing rendered before this either: the swept authoring surface refused all
  26 parameterless routes. But 24 of them refused by *raising* — usually
  `KeyError` on `:current_user`, an assign the skipped hook was supposed to make
  — and two (`/editor/billing`, `/editor/system`) refused cleanly only because
  they also gate in their own `mount/3`. That is fail-closed by accident: every
  probe cost an unhandled exception and a crash report, and the property held
  only for as long as every LiveView happened to read an assign the router had
  promised it. A new LiveView that read none would have mounted and rendered,
  ungated.

  ## The condition, and why it is that one

  Refuse when a **connected** mount matched no route (`host_uri` is
  `:not_mounted_at_router`) *and* its session names a `live_session`.

  The second half is what makes the first safe, and it is not interchangeable
  with the obvious alternatives:

    * A **sticky** `live_render` child is signed with `parent_pid: nil` and the
      parent's `router` — that is what lets it outlive the parent — so it is a
      "main" session by the framework's own definition, and the JS client
      deliberately sends it no URL. Refusing on "root with no route" would 404
      every sticky child, and the client turns a 404 into a page reload, so the
      reload would re-render the child and 404 again: a loop, not a degradation.
    * `socket.sticky?` cannot be the exemption. It is `params["sticky"]` —
      unsigned client input — so keying off it would let a scraped root token
      through by adding one field, reopening this issue exactly.

  `live_session_name` is signed and is the difference: a root session always
  carries the key (`nil` when the route sits outside any `live_session`), and a
  nested or sticky session never carries it at all. So the condition reads
  literally as the question worth asking — *were there `live_session` hooks that
  should have run, and didn't?* A route outside a `live_session` has none to
  skip, and a child's gates belong to its parent's join.

  `plug_status: 404` puts the refusal in the range the channel turns into a
  client reload rather than a process crash, the same reason `KilnCMSWeb.Tenant`'s
  two errors carry it. A reload is also the right answer for the honest client
  this should never happen to: a full page load re-renders through the router,
  where every gate runs.

  ## What it does not cover

  Only LiveViews built with `use KilnCMSWeb, :live_view` — every one of Kiln's,
  and the convention plugin panels follow, which
  `KilnCMSWeb.LiveJoinWithoutUrlTest` enforces for every `live` route in the
  router. Third-party views mounted by dependencies keep the framework
  behaviour: AshAdmin's are compile-gated to `:dev_routes` and so do not exist
  in production.

  AshAuthentication's used to be the standing gap. A url-less join to one
  reached no authorization a signed-out visitor could not — they are
  unauthenticated pages — but it skipped `:assign_current_org`, leaving the page
  wearing the **default org's** branding rather than the host's (#701).

  There is no gap now: every one of them is routed to a thin Kiln wrapper, so
  they carry this guard like everything else. `/sign-in`, `/register` and
  `/reset` go through `KilnCMSWeb.SignInLive`, which #715 introduced for an
  unrelated reason — attaching the client address to the sign-in form — and
  picked this up on the way past; `/password-reset/:token`,
  `/confirm_new_user/:token`, `/magic_link/:token` and `/sign-out` go through
  `KilnCMSWeb.AuthLive`, which exists for this reason alone (#701).

  `/sign-out` is the one to know about: `sign_out_route/3` emits a `DELETE` to
  the auth controller **and** a `live` route, and only the first is visible at
  the call site.

  It also covers only a *well-formed* join. A payload whose `"url"` is present
  but not a binary — `nil`, a number, a map — never reaches a mount hook at all:
  `authorize_session/3` runs outside the channel's `try/rescue`, and
  Phoenix.LiveView.Route.live_link_info_without_checks/3 function-clauses on
  it. That is a crash rather than a refusal, so this guard cannot narrow it, and
  the clean 404 that makes a url-*less* probe cost nothing does not apply. What
  it costs is an error-tracker event per attempt, which #700 stops at
  `KilnCMS.SentryFilter` rather than pretending the crash is not happening.
  """

  require Logger

  defmodule UnroutedJoinError do
    @moduledoc """
    Raised when a **connected** LiveView mount that belongs to a `live_session`
    arrives with no route, and so with none of that session's hooks (#688).

    A real client never does this for a router-mounted root view:
    `phoenix_live_view.js` sends the current URL on every such join. It is
    reachable only by replaying a scraped `data-phx-session` token by hand.

    `plug_status: 404` rather than 403, for the reason
    `KilnCMSWeb.Tenant.HostMismatchError` gives: the answer to "may this socket
    be here" must not be distinguishable from "is there anything here at all".

    Built field by field rather than through `struct!/2` over the caller's opts,
    for the reason that error records too: an unrecognised key would raise
    `KeyError` inside the channel's rescue, and a `KeyError` is a 500 — turning
    the deliberately quiet 404 into a crash report per probe, which is the one
    thing the status buys.
    """
    defexception [:view, :live_session, :message, plug_status: 404]

    @impl true
    def exception(opts) when is_list(opts) do
      view = opts[:view]
      live_session = opts[:live_session]

      %__MODULE__{
        view: view,
        live_session: live_session,
        message:
          "LiveView join for #{inspect(view)} in live_session #{inspect(live_session)} carried no url"
      }
    end

    def exception(message) when is_binary(message), do: %__MODULE__{message: message}
  end

  @doc """
  Refuses a connected join that belongs to a `live_session` but matched no route.

  Declared by `KilnCMSWeb.live_view/0`, so it is attached to the LiveView module
  itself and runs even when the router's `live_session` hooks are skipped.
  """
  def on_mount(:default, _params, _session, socket) do
    case gated_live_session(socket) do
      nil ->
        {:cont, socket}

      live_session ->
        # Debug, not warning, for the reason `LiveUserAuth.refuse_foreign_claim!/3`
        # gives: this is client-triggerable, so a line per refusal is an
        # unbounded write. An operator investigating a stolen token drops the
        # level and sees which views it was replayed against.
        Logger.debug(fn ->
          "LiveRouteGuard: refused url-less join for #{inspect(socket.view)} (#{inspect(live_session)})"
        end)

        raise UnroutedJoinError, view: socket.view, live_session: live_session
    end
  end

  # The `live_session` whose hooks were skipped, or `nil` if none were.
  #
  # A disconnected mount is a plain HTTP request that already went through the
  # router, hooks and all, so only a connected join can arrive without a route.
  defp gated_live_session(socket) do
    with true <- Phoenix.LiveView.connected?(socket),
         :not_mounted_at_router <- socket.host_uri,
         name when not is_nil(name) <- live_session_name(socket) do
      name
    else
      _routed_or_ungated -> nil
    end
  end

  # `socket.private` is framework-internal, and this is the only place the
  # signed `live_session_name` surfaces — no public field carries it, and no
  # public field distinguishes a sticky child's session from a root one (see the
  # moduledoc). Reading it is deliberate: the alternatives are trusting
  # client-supplied `sticky?`, which reopens #688, or 404ing sticky children.
  # `KilnCMSWeb.LiveJoinWithoutUrlTest` fails loudly if it ever stops arriving.
  defp live_session_name(socket), do: socket.private[:live_session_name]
end
