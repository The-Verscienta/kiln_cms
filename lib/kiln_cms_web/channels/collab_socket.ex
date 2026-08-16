defmodule KilnCMSWeb.CollabSocket do
  @moduledoc """
  Socket for the collaborative-editing CRDT prototype (`KilnCMS.Collab.Crdt`).

  Connections authenticate with a `Phoenix.Token` minted by the content
  editor's LiveView mount — which is itself editor/admin-gated — so only
  signed-in editors can ever hold a valid token. No token, no socket.

  The token names a **user**, not a document: it is minted once per editor
  session and outlives a working day. So it establishes *who*, and nothing
  more — `KilnCMSWeb.CollabChannel` decides *what* they may join, per topic
  (#655). Resolving the user here rather than carrying a bare id also means a
  token naming a since-deleted account is refused at the next connect, instead
  of reaching the channel as an id nothing will look up.

  An *already-established* session used to keep whatever it was granted, since
  `join/3` runs once and nothing dropped the socket. `KilnCMS.Accounts.SessionEviction`
  now does, from the actions that demote, erase, or narrow a scope — the `id/1`
  below is the topic it broadcasts on (#675). The change nobody wired an
  eviction into is caught by `KilnCMSWeb.CollabChannel`'s own periodic re-check
  (#775), which reloads the actor this module resolved and re-runs the join.

  The tenant comes from the connect URI's host, the same source `SetTenant`
  uses for HTTP (epic #336, #563). Sockets bypass the plug pipeline, so
  `connect_info: [:uri]` in the endpoint is what makes the host reachable at
  all; without it every collab session resolved to the default org.
  """
  use Phoenix.Socket

  alias KilnCMS.Accounts

  channel "collab:*", KilnCMSWeb.CollabChannel

  # Editor sessions are long-lived; tokens outlive a working day.
  @max_age 60 * 60 * 24

  @impl true
  def connect(%{"token" => token}, socket, connect_info) when is_binary(token) do
    with {:ok, user_id} <-
           Phoenix.Token.verify(KilnCMSWeb.Endpoint, "collab", token, max_age: @max_age),
         # The struct match matters: a `not_found_error?: false` interface would
         # return `{:ok, nil}`, and an anonymous actor reads published content.
         {:ok, %{} = actor} <- fetch_actor(user_id),
         {:ok, org} <- fetch_org(connect_info) do
      {:ok, socket |> assign(:actor, actor) |> assign(:org, org)}
    else
      _refused -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  # Phoenix drops every socket whose `id/1` matches a `"disconnect"` broadcast,
  # which is how `KilnCMS.Accounts.SessionEviction` reaches this one. Built by
  # that module rather than spelled here, so the two cannot drift onto different
  # strings — a mismatch would leave the socket connected while the caller
  # believed it dropped (#675).
  def id(socket), do: KilnCMS.Accounts.SessionEviction.topic(socket.assigns.actor.id)

  # A token outlives the account it names by up to a day. Resolving now means a
  # deleted editor cannot keep collaborating on the strength of a token minted
  # before they were removed.
  defp fetch_actor(user_id) when is_binary(user_id) do
    Accounts.get_user(user_id, authorize?: false)
  end

  defp fetch_actor(_other), do: :error

  # The refusal alerts (#678) — from here, the decision point, not from
  # `Tenant.fetch_org_from_connect_info/1` itself.
  defp fetch_org(connect_info) do
    case KilnCMSWeb.Tenant.fetch_org_from_connect_info(connect_info) do
      {:ok, org} ->
        {:ok, org}

      :error ->
        KilnCMSWeb.TenantRefusalAlert.notify(
          :collab,
          KilnCMSWeb.Tenant.connect_info_host(connect_info)
        )

        :error

      # A failed lookup, not an unserved host: refused the same way (a socket
      # has no 503 to send) but never alerted — the alert counts hosts this
      # deployment does not serve, and this may be one it does.
      :unavailable ->
        :error
    end
  end
end
