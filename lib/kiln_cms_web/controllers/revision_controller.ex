defmodule KilnCMSWeb.RevisionController do
  @moduledoc """
  Version history over the headless API — list a document's revisions, read one,
  restore one.

      GET  /api/content/:type/:id/revisions
      GET  /api/content/:type/:id/revisions/:version_id
      POST /api/content/:type/:id/revisions/:version_id/restore

  The same history the editor's version panel shows (`KilnCMSWeb.ContentEditorLive`),
  for a headless editorial tool, a migration script or an audit export. It is an
  **authenticated** surface: history carries every draft a document ever held,
  so there is no anonymous reading of it at all.

  ## Who sees what

  Authorization is the version resources' own Ash policies
  (`KilnCMS.CMS.VersionPolicies`), evaluated with the caller's real actor and the
  host's org as tenant — never `authorize?: false` on a read that returns data.

    * **No actor** (no JWT, no API key) → `401`.
    * **Can't read this document's history** → `404`, whether the document
      exists or not: a viewer, an editor whose `readable_types` scope leaves the
      type out, a document of another org, a document of a different (dynamic)
      type than the route names, a trashed document. A `403` here would confirm
      the document exists to a caller who may not know that.
    * **Can read the history but may not write the document** → `403` on
      restore: a `:read` API key (refused by the content resources'
      `ApiKeyWithoutWriteAccess` policy, not by this controller), or an editor
      the type's write scope or a field grant refuses.

  Every response — the refusals included — is `Cache-Control: private,
  no-store`: it is a function of the caller's identity, never of the URL.

  ## Shapes

  A **revision** in the list carries the version id, the action that wrote it,
  when, the acting user's **id** (User is deliberately not exposed over the
  API — #183) and the *names* of the editorial fields that write changed
  (bookkeeping such as the derived `search_text` column is left out). Values
  only come back from the single-revision read, which adds that version's own
  raw `changes` and the full `snapshot` of the document at that version.

  History is stored `:changes_only`, so no version row holds the whole document;
  the snapshot is the fold `KilnCMS.CMS.VersionSnapshot.at/4` computes — the
  same fold restore and the compare view use, so what this endpoint says a
  version contained is what restoring it writes. Values are in their stored
  (JSON-dumped) shape.

  ## Pagination

  Newest first. `?limit=` (1–100, default 20) and an opaque `?cursor=` taken
  from the previous page's `meta.next_cursor` (`null` on the last page). The
  cursor is a keyset on `(version_inserted_at, id)`, so autosave coalescing
  pruning rows between two page reads cannot shift or repeat the page.
  """
  use KilnCMSWeb, :controller

  require Ash.Expr

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.VersionFields
  alias KilnCMS.CMS.VersionSnapshot
  alias KilnCMSWeb.ApiError
  alias KilnCMSWeb.Params

  @default_limit 20
  @max_limit 100

  # Every response from this surface — refusals included — is per-actor.
  plug :no_store

  @doc "`GET /api/content/:type/:id/revisions` — the document's history, newest first."
  def index(conn, %{"type" => type, "id" => id} = params) do
    limit = Params.integer(params, "limit", @default_limit, 1..@max_limit)

    with {:ok, scope} <- authorize(conn, type, id),
         {:ok, cursor} <- decode_cursor(Params.string(params, "cursor")) do
      rows = list_versions(scope, cursor, limit + 1)
      {page, rest} = Enum.split(rows, limit)

      json(conn, %{
        data: Enum.map(page, &summary(&1, scope)),
        meta: %{limit: limit, next_cursor: next_cursor(page, rest)}
      })
    else
      error -> refuse(conn, error)
    end
  end

  @doc "`GET /api/content/:type/:id/revisions/:version_id` — one version, with its snapshot."
  def show(conn, %{"type" => type, "id" => id, "version_id" => version_id}) do
    with {:ok, scope} <- authorize(conn, type, id),
         {:ok, version} <- fetch_version(scope, version_id),
         {:ok, snapshot} <-
           VersionSnapshot.at(scope.version_module, scope.record.id, version, scope.opts) do
      json(conn, %{
        data:
          version
          |> summary(scope)
          |> Map.merge(%{changes: stringify(version.changes), snapshot: snapshot})
      })
    else
      # `VersionSnapshot.at/4`'s membership miss: the version is not in this
      # record's history as the actor can read it.
      :error -> refuse(conn, :not_found)
      error -> refuse(conn, error)
    end
  end

  @doc """
  `POST /api/content/:type/:id/revisions/:version_id/restore` — revert the
  document's content to that version, as the caller.

  Runs the type's own `:restore_version` action, so workflow state is left
  alone and the restore is itself recorded as a new revision — which is what the
  response carries, alongside the document's id and state.
  """
  def restore(conn, %{"type" => type, "id" => id, "version_id" => version_id}) do
    with {:ok, scope} <- authorize(conn, type, id),
         {:ok, version} <- fetch_version(scope, version_id),
         {:ok, record} <- run_restore(scope, version) do
      newest = scope |> Map.put(:record, record) |> list_versions(nil, 1)

      json(conn, %{
        data: %{
          id: record.id,
          type: to_string(scope.ct.type),
          state: record.state,
          restored_version_id: version.id,
          revision: newest |> List.first() |> summary(scope)
        }
      })
    else
      error -> refuse(conn, error)
    end
  end

  # --- resolution -----------------------------------------------------------

  # Everything every action needs, in the order the refusals must come: who is
  # asking (401), what they named (400/404), whether they may read this
  # document's history at all (404).
  defp authorize(conn, type, id) do
    org_id = KilnCMSWeb.Tenant.current_org_id(conn)
    actor = Ash.PlugHelpers.get_actor(conn)
    opts = [actor: actor, tenant: org_id]

    with {:actor, true} <- {:actor, not is_nil(actor)},
         {:ok, id} <- uuid(id),
         ct when not is_nil(ct) <- ContentTypes.get(type, org_id),
         {:ok, record} <- fetch_record(ct, id, opts),
         version_module = Module.concat(record.__struct__, Version),
         true <- history_readable?(version_module, actor, org_id) do
      {:ok, %{ct: ct, record: record, version_module: version_module, opts: opts}}
    else
      {:actor, false} -> :unauthenticated
      :bad_id -> :bad_id
      _ -> :not_found
    end
  end

  # The version read policies (`KilnCMS.CMS.VersionPolicies`) are actor-only
  # checks — org admin, or an editor whose read scope covers the type — so the
  # policy settles this document's whole history before a row is read.
  #
  # `Ash.can?/3` alone would not do: for a read, a refusal becomes a `false` row
  # filter and `can?` answers `true` ("you may run this query, it just returns
  # nothing"), which would hand a viewer an empty 200 instead of the 404 every
  # other refusal gets. So the query the policies would run is inspected: the
  # history is readable only when they add no filter at all. A `false` filter is
  # a refusal; any other filter — one that would need rows to settle — fails
  # closed too, because a partial history is not something this surface serves.
  defp history_readable?(version_module, actor, org_id) do
    case Ash.can({version_module, :read}, actor,
           tenant: org_id,
           run_queries?: false,
           alter_source?: true
         ) do
      {:ok, true} -> true
      {:ok, true, %Ash.Query{filter: nil}} -> true
      {:ok, true, %Ash.Query{filter: %Ash.Filter{expression: true}}} -> true
      _refused_or_conditional -> false
    end
  end

  # Through the type's own get interface, as the caller: a dynamic type's read is
  # scoped to its `type_definition_id` (`ContentTypes.get_record/3`), so one
  # dynamic type's route cannot reach another's document in the shared entry
  # table, and a compiled type's route only ever reads its own table.
  defp fetch_record(ct, id, opts) do
    case ContentTypes.get_record(ct, id, opts) do
      {:ok, record} -> {:ok, record}
      _ -> :not_found
    end
  end

  # Membership is the filter: a version id from another document — or another
  # org, which the tenant already excludes — is simply not found.
  defp fetch_version(scope, version_id) do
    with {:ok, version_id} <- uuid(version_id) do
      case ContentTypes.list_versions!(
             scope.ct,
             scope.opts ++
               [query: [filter: [id: version_id, version_source_id: scope.record.id], limit: 1]]
           ) do
        [version] -> {:ok, version}
        [] -> :not_found
      end
    end
  end

  defp list_versions(scope, cursor, limit) do
    query = [
      filter: [version_source_id: scope.record.id],
      sort: [version_inserted_at: :desc, id: :desc],
      limit: limit
    ]

    query =
      case cursor do
        nil ->
          query

        {at, last_id} ->
          # A second `:filter` entry — `Ash.Query.build/2` ANDs every one.
          query ++
            [
              filter:
                Ash.Expr.expr(
                  version_inserted_at < ^at or (version_inserted_at == ^at and id < ^last_id)
                )
            ]
      end

    ContentTypes.list_versions!(scope.ct, scope.opts ++ [query: query])
  end

  defp run_restore(scope, version) do
    case ContentTypes.restore_version(scope.ct, scope.record, version.id, scope.opts) do
      {:ok, record} -> {:ok, record}
      {:error, error} -> {:restore_failed, Ash.Error.to_error_class(error)}
    end
  end

  # --- shapes ---------------------------------------------------------------

  # `changed_fields` names the EDITORIAL fields a write touched — the ones
  # `VersionFields.content_fields/1` says the compare view reports. Bookkeeping
  # PaperTrail also records (`search_text`, `org_id`, …) would put a derived
  # column on every single row and bury the field a caller is looking for; it is
  # still in the single revision's raw `changes`.
  # The restore's own version, read back after the write — `nil` rather than a
  # crash should that read come back empty.
  defp summary(nil, _scope), do: nil

  defp summary(version, scope) do
    editorial =
      scope.record.__struct__ |> VersionFields.content_fields() |> Enum.map(&to_string/1)

    %{
      id: version.id,
      action: version.version_action_name,
      action_type: version.version_action_type,
      inserted_at: version.version_inserted_at,
      user_id: version.user_id,
      changed_fields:
        version.changes
        |> stringify()
        |> Map.keys()
        |> Enum.filter(&(&1 in editorial))
        |> Enum.sort()
    }
  end

  # `changes` arrives string-keyed from JSONB, but one built in the same
  # transaction as its write (the restore's own) has not round-tripped yet.
  defp stringify(changes) when is_map(changes),
    do: Map.new(changes, fn {key, value} -> {to_string(key), value} end)

  defp stringify(_changes), do: %{}

  # --- cursor ---------------------------------------------------------------

  defp next_cursor(_page, []), do: nil

  defp next_cursor(page, _rest) do
    last = List.last(page)

    Base.url_encode64("#{DateTime.to_iso8601(last.version_inserted_at)}|#{last.id}",
      padding: false
    )
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(raw) do
    with {:ok, decoded} <- Base.url_decode64(raw, padding: false),
         [at, id] <- String.split(decoded, "|"),
         {:ok, at, 0} <- DateTime.from_iso8601(at),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _ -> :bad_cursor
    end
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> :bad_id
    end
  end

  # --- refusals -------------------------------------------------------------

  defp refuse(conn, :unauthenticated) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> ApiError.send(
      :unauthorized,
      "unauthenticated",
      "Version history needs an editor's bearer token or API key."
    )
  end

  defp refuse(conn, :bad_id),
    do: ApiError.send(conn, :bad_request, "invalid_id", "Ids must be UUIDs.")

  defp refuse(conn, :bad_cursor),
    do: ApiError.send(conn, :bad_request, "invalid_cursor", "That cursor is not valid.")

  defp refuse(conn, {:restore_failed, %Ash.Error.Forbidden{}}) do
    ApiError.send(
      conn,
      :forbidden,
      "forbidden",
      "This credential may not change this document (a read-only API key, or no write access to the type)."
    )
  end

  defp refuse(conn, {:restore_failed, error}) do
    ApiError.send(conn, :unprocessable_entity, "restore_failed", restore_detail(error))
  end

  defp refuse(conn, _not_found),
    do: ApiError.send(conn, :not_found, "not_found", "Revision not found.")

  # A restore can fail for a reason the caller can act on — a category deleted
  # or a media item trashed since the version was written (#691) — so the field
  # errors are named, as the editor's flash names them.
  defp restore_detail(error) do
    error
    |> Map.get(:errors, [])
    |> Enum.filter(&match?(%{field: field} when not is_nil(field), &1))
    |> Enum.map_join(" ", &Exception.message/1)
    |> case do
      "" -> "That version could not be restored."
      detail -> detail
    end
  end

  defp no_store(conn, _opts), do: put_resp_header(conn, "cache-control", "private, no-store")
end
