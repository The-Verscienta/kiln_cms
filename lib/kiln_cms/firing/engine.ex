defmodule KilnCMS.Firing.Engine do
  @moduledoc """
  Fires a document into immutable per-surface artifacts (Kiln v2 — decision D9).

  `fire/2` walks the document's block tree (converting legacy storage to typed
  blocks via `KilnCMS.CMS.TypedBlocks`), renders each v1 surface through the typed
  serializers, upserts a `PublishedArtifact` per surface, warms the cache, and
  broadcasts `{:fired, type, id}`. `mode: :preview` compiles to memory only (no DB,
  no cache) for live editor previews.

  `read/4` is the delivery path: cache → artifact table, **never** the live tree.
  Every read/write is scoped to the document's `org_id` tenant (epic #336).
  """
  alias KilnCMS.Blocks
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Firing
  alias KilnCMS.Firing.Cache

  # `:llm` (#357) is the Markdown surface answer engines extract from.
  @surfaces KilnCMS.Firing.Surfaces.all()
  # Bumped when a surface's serialized shape changes (decision A2).
  @format_version 1

  @doc "Fire a document. Returns `{:ok, %{surface => body}}`."
  @spec fire(struct(), keyword()) :: {:ok, %{atom() => map()}}
  def fire(document, opts \\ []) do
    mode = Keyword.get(opts, :mode, :persist)
    type = document_type(document)
    # The tenant rides on the document itself (epic #336): every content struct
    # carries `org_id`, so firing is scoped to the document's own org with no
    # extra plumbing at the call sites.
    org_id = document.org_id
    start = System.monotonic_time()

    typed = document |> Map.get(:blocks) |> TypedBlocks.to_typed()
    artifacts = Map.new(@surfaces, fn surface -> {surface, compose(document, typed, surface)} end)

    if mode == :persist do
      persist(document, type, org_id, artifacts)
      # Keep the dependency graph current (decision D13). Invalidation of
      # referrers is enqueued by the caller (publish hook / re-fire worker), not
      # here, to keep fire/2 free of recursion.
      KilnCMS.Firing.References.rebuild(org_id, type, document.id, typed)
    end

    # Firing-duration telemetry (#206): wall-clock of the per-surface render
    # (+ persist on :persist), tagged by mode so persist vs preview are separable.
    :telemetry.execute(
      [:kiln_cms, :firing, :fire],
      %{duration: System.monotonic_time() - start, count: 1},
      %{type: type, mode: mode}
    )

    {:ok, artifacts}
  end

  @doc "Read a fired artifact body for a surface: cache, then the artifact table."
  @spec read(Ash.UUID.t(), atom(), Ash.UUID.t(), atom()) :: {:ok, map()} | :error
  def read(org_id, type, id, surface) do
    case Cache.get(org_id, type, id, surface) do
      {:ok, body} ->
        {:ok, body}

      :miss ->
        case Firing.get_artifact(type, id, surface, authorize?: false, tenant: org_id) do
          {:ok, %{body: body}} ->
            Cache.put(org_id, type, id, surface, body)
            {:ok, body}

          _ ->
            :error
        end
    end
  end

  @doc "Delete every fired artifact for a document and evict the cache (unpublish)."
  @spec purge(Ash.UUID.t(), atom(), Ash.UUID.t()) :: :ok
  def purge(org_id, type, id) do
    {:ok, artifacts} = Firing.artifacts_for(type, id, authorize?: false, tenant: org_id)
    Enum.each(artifacts, &Ash.destroy!(&1, authorize?: false, tenant: org_id))
    Cache.evict(org_id, type, id)
    :ok
  end

  @doc "The content type atom for a document struct (`:page` / `:post` / `:entry`)."
  @spec document_type(struct()) :: atom()
  def document_type(%{__struct__: module}) do
    # A content resource declares its canonical type atom via the Content macro;
    # trust it rather than reverse-deriving from the module name. Downcasing the
    # module's last segment loses the underscores in a multi-word type
    # (`TcmIngredient` -> "tcmingredient", not `:tcm_ingredient`), so
    # `String.to_existing_atom/1` would raise for any multi-word content type.
    if function_exported?(module, :__kiln_content_type__, 0) do
      module.__kiln_content_type__()
    else
      module |> Module.split() |> List.last() |> String.downcase() |> String.to_existing_atom()
    end
  end

  @doc """
  The consumer-facing type string for a document: a compiled type's atom name,
  or the owning dynamic type's name for a generic entry (D17) — the `:entry`
  storage key is an implementation detail headless consumers never see.
  """
  @spec public_type(struct()) :: String.t()
  def public_type(%{type_definition_id: id}) when not is_nil(id) do
    case KilnCMS.CMS.get_type_definition(id, authorize?: false) do
      {:ok, definition} -> definition.name
      # Archived/removed definition — fall back to the storage key.
      _ -> "entry"
    end
  end

  def public_type(document), do: to_string(document_type(document))

  defp persist(document, type, org_id, artifacts) do
    fired_at = DateTime.utc_now()

    Enum.each(@surfaces, fn surface ->
      {:ok, _} =
        Firing.upsert_artifact(
          %{
            document_type: type,
            document_id: document.id,
            surface: surface,
            format_version: @format_version,
            body: artifacts[surface],
            source_version_id: Map.get(document, :published_version_id),
            fired_at: fired_at
          },
          # `org_id` is set from the tenant (writable? false), so pass it as the
          # tenant rather than in the attrs map.
          authorize?: false,
          tenant: org_id
        )

      Cache.put(org_id, type, document.id, surface, artifacts[surface])
    end)

    Phoenix.PubSub.broadcast(KilnCMS.PubSub, "firing", {:fired, type, document.id})
  end

  # ── per-surface composition (whole-doc artifact of per-block fragments, A1) ──

  defp compose(_document, typed, :web) do
    html = typed |> Enum.map(&Blocks.render(&1, :web)) |> IO.iodata_to_binary()
    %{"html" => html}
  end

  defp compose(document, typed, :json) do
    %{
      # `id` + `type` address the document for the visual-editing bridge (#355):
      # `(type, id, <field>)` locates a document scalar (title/slug), while each
      # block map carries its own `_id` for `(block_id, <field>)`. Additive and
      # non-sensitive (an opaque uuid) — safe on the public artifact.
      "id" => Map.get(document, :id),
      "type" => public_type(document),
      "title" => Map.get(document, :title),
      "slug" => Map.get(document, :slug),
      "blocks" => Enum.map(typed, &Blocks.render(&1, :json))
    }
  end

  # Clean chunked Markdown for LLM/answer-engine extraction (#357, GEO).
  defp compose(document, typed, :llm) do
    %{"markdown" => KilnCMS.Firing.LlmMarkdown.compose(document, typed)}
  end

  defp compose(document, typed, :json_ld) do
    body =
      typed
      |> Enum.map(&Blocks.search_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    article = %{
      "@type" => "Article",
      "headline" => Map.get(document, :title),
      "articleBody" => body
    }

    # Structured data falls out of the typed blocks (decision D9): each block that
    # has a schema.org representation contributes a node to the document @graph. A
    # block may yield nil (no node), one node, or — for a container block like
    # `columns` — a list of its children's nodes, so flatten before assembling.
    block_nodes = typed |> Enum.flat_map(&json_ld_nodes/1)

    %{"@context" => "https://schema.org", "@graph" => [article | block_nodes]}
  end

  # Normalize a block's `:json_ld` render (nil | node map | list of nodes) to a
  # flat list of nodes for the @graph.
  defp json_ld_nodes(block) do
    case Blocks.render(block, :json_ld) do
      nil -> []
      nodes when is_list(nodes) -> Enum.reject(nodes, &is_nil/1)
      node -> [node]
    end
  end
end
