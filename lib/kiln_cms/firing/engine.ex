defmodule KilnCMS.Firing.Engine do
  @moduledoc """
  Fires a document into immutable per-surface artifacts (Kiln v2 — decision D9).

  `fire/2` walks the document's block tree (converting legacy storage to typed
  blocks via `KilnCMS.CMS.TypedBlocks`), renders each v1 surface through the typed
  serializers, upserts a `PublishedArtifact` per surface, warms the cache, and
  broadcasts `{:fired, type, id}`. `mode: :preview` compiles to memory only (no DB,
  no cache) for live editor previews.

  `read/3` is the delivery path: cache → artifact table, **never** the live tree.
  """
  alias KilnCMS.Blocks
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Firing
  alias KilnCMS.Firing.Cache

  @surfaces [:web, :json, :json_ld]
  # Bumped when a surface's serialized shape changes (decision A2).
  @format_version 1

  @doc "Fire a document. Returns `{:ok, %{surface => body}}`."
  @spec fire(struct(), keyword()) :: {:ok, %{atom() => map()}}
  def fire(document, opts \\ []) do
    mode = Keyword.get(opts, :mode, :persist)
    typed = document |> Map.get(:blocks) |> TypedBlocks.from_legacy()
    type = document_type(document)
    artifacts = Map.new(@surfaces, fn surface -> {surface, compose(document, typed, surface)} end)

    if mode == :persist do
      persist(document, type, artifacts)
      # Keep the dependency graph current (decision D13). Invalidation of
      # referrers is enqueued by the caller (publish hook / re-fire worker), not
      # here, to keep fire/2 free of recursion.
      KilnCMS.Firing.References.rebuild(type, document.id, typed)
    end

    {:ok, artifacts}
  end

  @doc "Read a fired artifact body for a surface: cache, then the artifact table."
  @spec read(atom(), Ash.UUID.t(), atom()) :: {:ok, map()} | :error
  def read(type, id, surface) do
    case Cache.get(type, id, surface) do
      {:ok, body} ->
        {:ok, body}

      :miss ->
        case Firing.get_artifact(type, id, surface, authorize?: false) do
          {:ok, %{body: body}} ->
            Cache.put(type, id, surface, body)
            {:ok, body}

          _ ->
            :error
        end
    end
  end

  @doc "Delete every fired artifact for a document and evict the cache (unpublish)."
  @spec purge(atom(), Ash.UUID.t()) :: :ok
  def purge(type, id) do
    {:ok, artifacts} = Firing.artifacts_for(type, id, authorize?: false)
    Enum.each(artifacts, &Ash.destroy!(&1, authorize?: false))
    Cache.evict(type, id)
    :ok
  end

  @doc "The content type atom for a document struct (`:page` / `:post`)."
  @spec document_type(struct()) :: atom()
  def document_type(%{__struct__: module}) do
    module |> Module.split() |> List.last() |> String.downcase() |> String.to_existing_atom()
  end

  defp persist(document, type, artifacts) do
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
          authorize?: false
        )

      Cache.put(type, document.id, surface, artifacts[surface])
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
      "type" => to_string(document_type(document)),
      "title" => Map.get(document, :title),
      "slug" => Map.get(document, :slug),
      "blocks" => Enum.map(typed, &Blocks.render(&1, :json))
    }
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
    # has a schema.org representation contributes a node to the document @graph.
    block_nodes = typed |> Enum.map(&Blocks.render(&1, :json_ld)) |> Enum.reject(&is_nil/1)

    %{"@context" => "https://schema.org", "@graph" => [article | block_nodes]}
  end
end
