defmodule KilnCMS.Firing.Checks.DocumentReadable do
  @moduledoc """
  Authorizes an artifact row only when the actor may read the **document it was
  fired from** (#565).

  `PublishedArtifact` holds the *rendered* body of a document, so leaving its
  read `authorize_if always()` meant the audience axis enforced on `Content`
  (`Checks.InAudience` + the published/`:public` grant) was not re-enforced one
  layer down: paid, gated content is readable in artifact form by anyone who can
  reach the resource. This check closes that by **delegating** rather than
  duplicating — it re-reads the source document under the actor's own
  authorization and keeps only the artifacts whose document came back.

  ## Why delegation, and why a manual check

  The obvious alternatives are both worse here:

    * **Denormalizing `audience`/`state` onto the artifact** would be SQL-filterable
      and cheap, but firing is asynchronous (`Changes.FireArtifacts` enqueues a
      `FireWorker`), so the copy would lag the document by however long the
      `:firing` queue is backed up — a stale *security* attribute. Delegation has
      no such window.
    * **Re-stating the `Content` policy as a filter** can't be expressed anyway:
      `document_type` is polymorphic (`:page`, `:post`, … plus `:entry` for every
      admin-defined type — D17), and there is no relationship to join through. It
      would also drift the moment the content read policy changes.

  So this is an `Ash.Policy.Check` of type `:manual`: `strict_check/3` returns
  `:unknown` and `check/4` filters the fetched rows. The containing policy must
  therefore declare `access_type :runtime`. That means a read of *many* artifacts
  fetches them before filtering, plus one document query per `{org, type}` group.
  That cost is acceptable because no production path reads artifacts this way —
  the delivery hot path (`Firing.Delivery`, `Firing.Engine.read/4`) runs as the
  system with `authorize?: false`, having already resolved the record through the
  audience-gated `Content` read. This is defence in depth for *future* callers.

  Resolution failures (unknown document type, an errored read) drop the record:
  denying is the safe direction for a read check. Note this is the opposite of the
  entitlement path, where swallowing an error into an empty default silently
  *revokes* access — see `KilnCMS.Billing.Entitlements`.
  """
  use Ash.Policy.Check

  require Ash.Query

  alias KilnCMS.CMS.ContentTypes

  @impl Ash.Policy.Check
  def describe(_opts), do: "the actor may read the artifact's source document"

  @impl Ash.Policy.Check
  def type, do: :manual

  @impl Ash.Policy.Check
  def strict_check(_actor, _authorizer, _opts), do: {:ok, :unknown}

  @impl Ash.Policy.Check
  def check(actor, records, _context, _opts) do
    records
    # One document query per {org, type} rather than per row. The org is taken
    # from the artifact itself, so the delegated read is scoped to the tenant that
    # owns the row — never the ambient one.
    |> Enum.group_by(&{&1.org_id, &1.document_type})
    |> Enum.flat_map(fn {{org_id, type}, artifacts} ->
      readable = readable_ids(actor, org_id, type, Enum.map(artifacts, & &1.document_id))
      Enum.filter(artifacts, &MapSet.member?(readable, &1.document_id))
    end)
  end

  # Every branch yields a plain list and the MapSet is built once, at the end.
  # That is a dialyzer constraint, not a style choice: on Elixir 1.20+ MapSet
  # sits on `:sets` v2, where `MapSet.new/1,2` build the internal via the opaque
  # `:sets.from_list/2` while `MapSet.new/0` returns a raw `%{map: %{}}` literal.
  # Returning both across branches unions the two representations, OTP 29's
  # dialyzer strips opacity from the union, and the `MapSet.member?/2` at the
  # call site then trips `call_without_opaque` (#599). One construction path
  # keeps the opacity intact. Behaviour is identical either way.
  defp readable_ids(actor, org_id, type, ids) do
    case ContentTypes.get(type, org_id) do
      %{resource: resource} when not is_nil(resource) ->
        resource
        |> Ash.Query.filter(id in ^ids)
        |> Ash.read(actor: actor, tenant: org_id, authorize?: true)
        |> case do
          {:ok, documents} -> Enum.map(documents, & &1.id)
          {:error, _reason} -> []
        end

      # No backing resource: a dynamic type's descriptor (its rows are stored as
      # `:entry`, which does have one) or a type that has since been removed.
      # Either way there is nothing to authorize against — fail closed.
      _ ->
        []
    end
    |> MapSet.new()
  end
end
