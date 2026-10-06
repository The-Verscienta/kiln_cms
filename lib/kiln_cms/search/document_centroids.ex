defmodule KilnCMS.Search.DocumentCentroids do
  @moduledoc """
  Per-document embedding centroids, averaged in Postgres (#1596).

  Backs `KilnCMS.Search.BlockEmbedding`'s `:document_centroids` action. A
  document's centroid is the element-wise mean of its block vectors — the same
  quantity `KilnCMS.Search.Related` computes in the BEAM for one document at a
  time. For the library-level surfaces in `KilnCMS.Organize`, which need a few
  hundred at once, pgvector's `avg(vector)` does the arithmetic where the rows
  are: 300 documents come back as 300 vectors rather than every block of every
  one of them (at ~50 blocks a document, 15 000 lists of 384 floats).

  ## Isolation

  This is a raw Ecto query, so Ash's attribute multitenancy does not apply to
  it. The `org_id` clause below is the only thing keeping one site's vectors
  out of another's centroids, and a call without a tenant answers `[]` — never
  "every org", which is what dropping the clause would mean. Only rows with a
  stored embedding count; an unindexed (never-published) document simply has
  no centroid here.
  """
  import Ecto.Query

  @typedoc "One document's centroid."
  @type centroid :: %{
          document_type: atom(),
          document_id: Ash.UUID.t(),
          centroid: [float()]
        }

  @doc "Centroids for `document_ids` under `tenant` (an org id or `Organization`)."
  @spec for_documents(term(), [Ash.UUID.t()]) :: [centroid()]
  def for_documents(_tenant, []), do: []

  def for_documents(tenant, document_ids) when is_list(document_ids) do
    case org_id(tenant) do
      nil -> []
      org_id -> query(org_id, document_ids)
    end
  end

  defp query(org_id, document_ids) do
    {:ok, org_id} = Ecto.UUID.dump(org_id)
    ids = Enum.map(document_ids, &(&1 |> Ecto.UUID.dump() |> elem(1)))

    from(b in "block_embeddings",
      where: b.org_id == ^org_id and b.document_id in ^ids and not is_nil(b.embedding),
      group_by: [b.document_type, b.document_id],
      select: %{
        document_type: b.document_type,
        document_id: b.document_id,
        centroid: fragment("avg(?)", b.embedding)
      }
    )
    |> KilnCMS.Repo.all()
    |> Enum.map(fn row ->
      %{
        document_type: String.to_existing_atom(row.document_type),
        document_id: Ecto.UUID.cast!(row.document_id),
        centroid: Pgvector.to_list(row.centroid)
      }
    end)
  end

  # Not `KilnCMS.Accounts.org_id/1`: that resolves `nil` to the default org,
  # which here would quietly answer for a site the caller never named.
  defp org_id(%KilnCMS.Accounts.Organization{id: id}) when is_binary(id), do: id
  defp org_id(id) when is_binary(id), do: id
  defp org_id(_other), do: nil
end
