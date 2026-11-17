defmodule KilnCMS.CMS.TitleRegeneration do
  @moduledoc """
  Re-derives the titles of a type's existing records from its `title_template`
  (#2287), one bounded page at a time.

  A template change reaches new saves at once; this brings the records already
  stored in line. The same module backs the sweep job
  (`KilnCMS.CMS.Workers.TitleRegenerationWorker`, enqueued when a dynamic type's
  template changes) and `mix kiln.titles.regenerate` (the route for a compiled
  type, whose template changes with a deploy).

  Every rewrite goes through the type's normal `:update` action, so search, the
  change feed, webhooks and revisions fire exactly as for an editor's retitle —
  and `Changes.DeriveTitle` derives the same value on the way through. A
  **published** record is rewritten live, as an admin's retitle would be: the
  template defines what the title *is*, so a published title that no longer
  follows it is stale, not a draft in progress. A record with a **pending
  working copy** is skipped: its held title was derived from its held fields,
  and `PromoteWorkingCopy` re-derives it when the copy goes live, so rewriting
  the live title underneath it would only plant a conflict.

  Idempotent: a record whose title already equals the derivation is not
  written, so a re-run, or a retried job, does nothing the first did not.
  """

  require Ash.Query
  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs
  alias KilnCMS.CMS.Titles

  @page_size 100

  @type page :: %{
          scanned: non_neg_integer(),
          changed: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          next: Ash.UUID.t() | nil
        }

  @doc """
  Process one page of `ct`'s records after the id `after_id` (`nil` for the
  first), writing the changed titles. `next` is the id to continue after, or
  `nil` when the type is done. Options: `actor:` (history attribution only),
  `limit:`.
  """
  @spec run_page(ContentTypes.t(), term(), Ash.UUID.t() | nil, keyword()) :: page()
  def run_page(ct, tenant, after_id \\ nil, opts \\ []) do
    limit = Keyword.get(opts, :limit, @page_size)
    template = ct.title_template
    records = if template, do: page(ct, tenant, after_id, limit), else: []
    definitions = if template, do: definitions(ct, tenant), else: []

    initial = %{scanned: 0, changed: 0, skipped: 0, failed: 0, next: nil}

    summary =
      Enum.reduce(records, initial, fn record, acc ->
        acc = %{acc | scanned: acc.scanned + 1, next: record.id}

        case step(ct, record, template, definitions, tenant, opts) do
          :unchanged -> acc
          :skipped -> %{acc | skipped: acc.skipped + 1}
          :changed -> %{acc | changed: acc.changed + 1}
          :error -> %{acc | failed: acc.failed + 1}
        end
      end)

    # A short page is the last one.
    if summary.scanned < limit, do: %{summary | next: nil}, else: summary
  end

  @doc "Every page of `ct`, summed — what the mix task runs."
  @spec run(ContentTypes.t(), term(), keyword()) :: page()
  def run(ct, tenant, opts \\ []),
    do:
      run_all(ct, tenant, nil, opts, %{scanned: 0, changed: 0, skipped: 0, failed: 0, next: nil})

  defp run_all(ct, tenant, cursor, opts, total) do
    page = run_page(ct, tenant, cursor, opts)

    total =
      Map.merge(total, page, fn
        :next, _old, new -> new
        _key, old, new -> old + new
      end)

    if page.next, do: run_all(ct, tenant, page.next, opts, total), else: total
  end

  defp step(_ct, %{state: :published, working_copy_at: %DateTime{}}, _t, _d, _tenant, _opts),
    do: :skipped

  defp step(ct, record, template, definitions, tenant, opts) do
    with {:ok, title} <- Titles.derive(template, Titles.record_context(record, definitions)),
         true <- title != record.title do
      # authorize?: false — a bulk admin/operator pass: the admin who saved the
      # template (or the operator at the shell) was checked when it was
      # enqueued, and the system actor holds no content write by design
      # (#1402). `actor:` is attribution for the version history only.
      case ContentTypes.update(ct, record, %{title: title},
             actor: opts[:actor],
             tenant: tenant,
             authorize?: false
           ) do
        {:ok, _updated} ->
          :changed

        {:error, error} ->
          Logger.warning(
            "title regeneration: #{ct.type} #{record.id} refused its new title: " <>
              Exception.message(error)
          )

          :error
      end
    else
      _blank_or_same -> :unchanged
    end
  end

  defp page(ct, tenant, after_id, limit) do
    query =
      ct
      |> Slugs.storage_resource()
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(limit)

    query = if after_id, do: Ash.Query.filter(query, id > ^after_id), else: query

    query =
      case ct do
        %{source: :dynamic, definition: definition} ->
          Ash.Query.filter(query, type_definition_id == ^definition.id)

        _compiled ->
          query
      end

    # authorize?: false — the pass has to see every record of the type, drafts
    # included, to retitle it; the same admin/operator gate as `step/6`.
    Ash.read!(query, authorize?: false, tenant: tenant)
  end

  defp definitions(%{source: :dynamic, definition: %{id: id}}, tenant),
    do: KilnCMS.CMS.field_definitions_for_definition!(id, registry_opts(tenant))

  defp definitions(%{type: type}, tenant),
    do: KilnCMS.CMS.field_definitions_for!(type, registry_opts(tenant))

  # The registry read runs as the system and fails closed, like the write
  # path's: a refused read must not blank every computed field a template reads.
  defp registry_opts(tenant) do
    [
      actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
      authorize_with: :error,
      tenant: tenant
    ]
  end
end
