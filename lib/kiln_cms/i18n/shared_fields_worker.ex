defmodule KilnCMS.I18n.SharedFieldsWorker do
  @moduledoc """
  Runs field-level localization's follow-up to a publish (#1327), off the
  request path: enqueued by `KilnCMS.I18n.Changes.EnqueueSharedFields` after a
  locale variant publishes, or is edited while live.

  Two things, both no-ops on a type that opted nothing in:

    1. **Shared values.** When the published variant is the source (the
       default locale), its `:shared` values are copied into every sibling
       (`KilnCMS.I18n.SharedFields.sync/3`). When it is another locale, it
       takes the published source's current values, so a translation that goes
       live after the source changed is not left behind.
    2. **Inherited values.** A sibling whose `:fallback` fields inherit from
       this variant shows this variant's values, so every *published* sibling
       is re-fired (`KilnCMS.Firing.FireWorker`, which dedups per document).

  On the `:firing` queue, deduplicated per `{org, type, id}` like the fire
  jobs it sits beside.
  """
  use Oban.Worker,
    queue: :firing,
    max_attempts: 3,
    unique: [
      period: 60,
      keys: [:org_id, :type, :id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  alias KilnCMS.Firing.References
  alias KilnCMS.I18n.FieldLocalization
  alias KilnCMS.I18n.SharedFields

  @doc "Queue the follow-up for a variant that has just published or changed while live."
  @spec enqueue(struct()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(record) do
    %{
      "org_id" => record.org_id,
      "type" => to_string(KilnCMS.Firing.Engine.document_type(record)),
      "id" => record.id
    }
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id, "type" => type, "id" => id}}) do
    case References.type_atom(type) do
      nil -> :ok
      type -> run(org_id, type, id)
    end
  end

  defp run(org_id, type, id) do
    case References.load_published(org_id, type, id) do
      {:ok, record} ->
        definitions =
          FieldLocalization.definitions(record, KilnCMS.SystemActor.new(:localization))

        if FieldLocalization.any?(record, definitions),
          do: follow_up(record, definitions),
          else: :ok

      settled when settled in [:absent, :unknown_type] ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow_up(record, definitions) do
    with {:ok, _written} <- sync(record, definitions) do
      refire_siblings(record)
    end
  end

  defp sync(record, definitions) do
    if FieldLocalization.source?(record) do
      SharedFields.sync(record, definitions)
    else
      case SharedFields.source(record) do
        nil -> {:ok, 0}
        source -> SharedFields.sync(source, definitions, only: record.id)
      end
    end
  end

  defp refire_siblings(record) do
    targets =
      for sibling <- SharedFields.siblings(record),
          sibling.state == :published,
          do: {sibling.org_id, KilnCMS.Firing.Engine.document_type(sibling), sibling.id}

    KilnCMS.Firing.FireWorker.enqueue_backfill(targets)
    :ok
  end
end
