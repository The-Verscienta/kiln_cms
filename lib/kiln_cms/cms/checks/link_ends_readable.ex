defmodule KilnCMS.CMS.Checks.LinkEndsReadable do
  @moduledoc """
  Authorizes a `KilnCMS.CMS.ContentLink` row only when the actor may read
  **both** of its ends (#1594).

  An edge names two documents. Until 1.1 the table was world-readable, so a
  published page loaded with `?include=incoming_links` listed the ids of the
  drafts that linked to it — a draft's existence, which the read API otherwise
  promises never to reveal (a draft answers 404, not 403). Reference edges made
  that worse, since every `:reference` custom field now writes one.

  Delegation, exactly as `KilnCMS.Firing.Checks.DocumentReadable` does it: the
  ends are re-read under the actor's own authorization, and only the edges
  whose source and target both came back are kept. The `Content` read policy
  (published, audience, org) is not restated here, so it cannot drift from it.

  Ends are polymorphic and a link written before 1.1 carries no type, so each
  org's ids are looked up in every resource that holds content
  (`ContentTypes.blocks_resources/0` — each compiled type plus the shared
  `Entry` tier): a handful of `id in ^ids` reads per org, not one per row.

  A `:manual` check, so the policy declares `access_type :runtime`. Editors
  never reach it — `Checks.OrgEditor` is a simple check ahead of it.
  Resolution failures drop the edge: denying is the safe direction for a read.

  A preview grant (`KilnCMS.CMS.PreviewGrant`, #1887) on the link read is
  carried into the ends' re-read, so a shared draft's edges to published
  documents (and theirs to it) are kept. An edge to another draft still is
  not: the grant names one record.
  """
  use Ash.Policy.Check

  require Ash.Query

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.PreviewGrant

  @impl Ash.Policy.Check
  def describe(_opts), do: "the actor may read both ends of the link"

  @impl Ash.Policy.Check
  def type, do: :manual

  @impl Ash.Policy.Check
  def strict_check(_actor, _authorizer, _opts), do: {:ok, :unknown}

  @impl Ash.Policy.Check
  def check(actor, records, authorizer, _opts) do
    grant = PreviewGrant.from_context(authorizer)

    records
    |> Enum.group_by(& &1.org_id)
    |> Enum.flat_map(fn {org_id, links} ->
      ids = links |> Enum.flat_map(&[&1.source_id, &1.target_id]) |> Enum.uniq()
      readable = readable_ids(actor, org_id, ids, grant)

      Enum.filter(
        links,
        &(MapSet.member?(readable, &1.source_id) and MapSet.member?(readable, &1.target_id))
      )
    end)
  end

  @doc """
  The subset of `ids` (content record ids in `org_id`) that `actor` may read,
  as a `MapSet`. Shared with the editor's backlinks panel, which must not
  offer a link to a source it cannot open. `grant`, a verified preview grant,
  adds the record it names, as it does on any read.
  """
  @spec readable_ids(term(), Ash.UUID.t() | nil, [Ash.UUID.t()], PreviewGrant.t() | nil) ::
          MapSet.t()
  def readable_ids(actor, org_id, ids, grant \\ nil)
  def readable_ids(_actor, _org_id, [], _grant), do: MapSet.new([])

  def readable_ids(actor, org_id, ids, grant) do
    # One construction path for the MapSet (see `DocumentReadable` on OTP 29's
    # dialyzer and `:sets` opacity).
    ContentTypes.blocks_resources()
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.flat_map(&readable_in(&1, actor, org_id, ids, [:id], grant))
    |> MapSet.new()
  end

  @doc """
  Like `readable_ids/3`, but answers each readable record's current label:
  `%{id => %{"slug" => slug, "title" => title}}`. The same reads, so the
  same rule decides what is readable; an id absent from the map is one
  `actor` may not read (or that no longer exists). `grant` as for
  `readable_ids/4`.
  """
  @spec readable_labels(term(), Ash.UUID.t() | nil, [Ash.UUID.t()], PreviewGrant.t() | nil) ::
          %{optional(Ash.UUID.t()) => %{String.t() => String.t() | nil}}
  def readable_labels(actor, org_id, ids, grant \\ nil)
  def readable_labels(_actor, _org_id, [], _grant), do: %{}

  def readable_labels(actor, org_id, ids, grant) do
    ContentTypes.blocks_resources()
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.flat_map(&readable_in(&1, actor, org_id, ids, [:id, :slug, :title], grant))
    |> Map.new(&{&1.id, %{"slug" => &1.slug, "title" => &1.title}})
  end

  defp readable_in(resource, actor, org_id, ids, select, grant) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select(select)
    |> Ash.read(
      actor: actor,
      tenant: org_id,
      authorize?: true,
      context: PreviewGrant.context(grant)
    )
    |> case do
      {:ok, documents} when select == [:id] -> Enum.map(documents, & &1.id)
      {:ok, documents} -> documents
      {:error, _reason} -> []
    end
  end
end
