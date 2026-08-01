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

  It is refused *at the next connect*, not immediately: nothing calls
  `Endpoint.disconnect/1` on the `id/1` value below, and `join/3` runs once, so
  an already-established session keeps the access it was granted until its
  socket drops. Deleting an account, demoting it, or narrowing its scopes does
  not evict a live collab session. Tracked separately.

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
  def connect(%{"token" => token}, socket, connect_info) do
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
  def id(socket), do: "collab:user:#{socket.assigns.actor.id}"

  # A token outlives the account it names by up to a day. Resolving now means a
  # deleted editor cannot keep collaborating on the strength of a token minted
  # before they were removed.
  defp fetch_actor(user_id) when is_binary(user_id) do
    Accounts.get_user(user_id, authorize?: false)
  end

  defp fetch_actor(_other), do: :error

  defp fetch_org(connect_info) do
    KilnCMSWeb.Tenant.fetch_org_from_connect_info(connect_info)
  end
end
