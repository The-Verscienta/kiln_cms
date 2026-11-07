defmodule KilnDepFixture.HookPlug do
  @moduledoc """
  A plain Plug mounted through `c:Kiln.Plugin.plug_routes/0` (#2272). A
  Phoenix controller is a Plug whose opts is the action atom; this is the same
  shape with nothing but `plug` underneath it.

    * `:ping` answers a fixed body, so a route test can tell the mount works.
    * `:echo` answers the exact request bytes the core preserved for this path
      (`conn.private[:raw_body]`) — what a webhook receiver needs to verify an
      HMAC — or an empty body if nothing was preserved.
    * `:tenant` answers the request's tenant id as the core's endpoint
      resolved it (`conn.assigns.current_org`), proving a plugin endpoint is
      tenant-scoped without the plugin asking.
    * `:webhook` is the worked example in `docs/plugin-extensibility.md`
      ("A webhook receiver"): it authenticates its own caller with an HMAC over
      the raw body, then reads and writes content as an explicit actor in the
      request's tenant. See `webhook/1` below.
  """
  @behaviour Plug

  import Plug.Conn

  # The plugin compiles before the core, so the core's modules are not known
  # here; they are called at run time, once the host application is up.
  @compile {:no_warn_undefined, [KilnCMS.CMS, KilnCMS.Accounts]}

  @impl Plug
  def init(action) when action in [:ping, :echo, :tenant, :webhook], do: action

  @impl Plug
  def call(conn, :ping), do: send_resp(conn, 200, "pong")
  def call(conn, :echo), do: send_resp(conn, 200, conn.private[:raw_body] || "")

  def call(conn, :tenant) do
    case conn.assigns[:current_org] do
      %{id: id} -> send_resp(conn, 200, to_string(id))
      _none -> send_resp(conn, 200, "")
    end
  end

  def call(conn, :webhook), do: webhook(conn)

  # --- :webhook ------------------------------------------------------------
  #
  # A plug route runs in the `:plugin_endpoint` pipeline: no session, so there
  # is no `conn.assigns.current_user`, and nothing sets an Ash tenant. The
  # plugin therefore does three things itself, in this order, and fails closed
  # at each:
  #
  #   1. AUTHENTICATE the caller: HMAC-SHA256 over the exact request bytes.
  #   2. Take the TENANT from `conn.assigns.current_org`, which the endpoint
  #      resolved from the Host header, and pass `tenant:` on every Ash call.
  #      Without it, a missing org is silently the default org.
  #   3. Name the ACTOR: a service account, passed as `actor:` so the
  #      resource's own policies decide what the hook may do. Never
  #      `authorize?: false` for content.
  #
  # Configuration (`config :kiln_dep_fixture, :webhook, secret: ..., actor_id: ...`)
  # is read per request; an unconfigured hook answers 503 instead of accepting.

  defp webhook(conn) do
    with {:ok, secret, actor_id} <- webhook_config(),
         :ok <- verify_signature(conn, secret),
         {:ok, org} <- fetch_org(conn),
         {:ok, actor} <- fetch_actor(actor_id),
         {:ok, event} <- decode_event(conn) do
      record_event(conn, event, actor, org)
    else
      {:error, status, message} -> send_resp(conn, status, message)
    end
  end

  defp webhook_config do
    with config when is_list(config) <- Application.get_env(:kiln_dep_fixture, :webhook),
         secret when is_binary(secret) and secret != "" <- config[:secret],
         actor_id when is_binary(actor_id) <- config[:actor_id] do
      {:ok, secret, actor_id}
    else
      _unset -> {:error, 503, "webhook not configured"}
    end
  end

  defp verify_signature(conn, secret) do
    raw = conn.private[:raw_body]
    given = conn |> get_req_header("x-fixture-signature") |> List.first()

    cond do
      # The core keeps the raw body for every content type but multipart.
      not is_binary(raw) ->
        {:error, 400, "a raw body is required"}

      is_binary(given) and Plug.Crypto.secure_compare(given, sign(secret, raw)) ->
        :ok

      true ->
        {:error, 401, "bad signature"}
    end
  end

  # What a sender computes: `sha256=` and the lowercase hex HMAC of the body.
  defp sign(secret, body) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  defp fetch_org(conn) do
    case conn.assigns[:current_org] do
      %{id: _} = org -> {:ok, org}
      _none -> {:error, 500, "no organization resolved"}
    end
  end

  # The one place the plugin loads a record without the actor's own say-so: the
  # service account has to exist before it can act. A user may read only
  # itself, so the lookup runs unauthorized and is by id, from operator
  # configuration, never from the request.
  defp fetch_actor(actor_id) do
    case KilnCMS.Accounts.get_user(actor_id, authorize?: false) do
      {:ok, user} -> {:ok, user}
      _error -> {:error, 503, "webhook actor not found"}
    end
  end

  defp decode_event(conn) do
    case conn.private[:raw_body] |> to_string() |> decode_json() do
      %{"id" => id, "title" => title} = event when is_binary(id) and is_binary(title) ->
        {:ok, event}

      _other ->
        {:error, 422, "expected {\"id\": ..., \"title\": ...}"}
    end
  end

  # `Jason` is not a dependency of this plugin; the core ships `JSON` (Elixir
  # 1.18+), which is.
  defp decode_json(raw) do
    case JSON.decode(raw) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end

  # Idempotent on the provider's event id: a redelivery finds the draft the
  # first delivery wrote. Read and write both carry the actor and the tenant.
  defp record_event(conn, %{"id" => id, "title" => title}, actor, org) do
    slug = "evt-" <> String.downcase(String.replace(id, ~r/[^A-Za-z0-9]+/, "-"))
    opts = [actor: actor, tenant: org]

    case KilnCMS.CMS.list_posts(Keyword.put(opts, :query, filter: [slug: slug])) do
      {:ok, [%{id: post_id}]} ->
        send_resp(conn, 200, post_id)

      {:ok, []} ->
        case KilnCMS.CMS.create_post(%{title: title, slug: slug}, opts) do
          {:ok, post} -> send_resp(conn, 201, post.id)
          {:error, error} -> error_resp(conn, error)
        end

      {:error, error} ->
        error_resp(conn, error)
    end
  end

  # A policy refusal is the actor's lack of authority in this tenant, not a bad
  # request: say 403, and say nothing about why.
  defp error_resp(conn, %{__struct__: Ash.Error.Forbidden}), do: send_resp(conn, 403, "forbidden")
  defp error_resp(conn, _other), do: send_resp(conn, 422, "could not record the event")
end
