defmodule KilnCMS.I18n.RefireInheritingWorker do
  @moduledoc """
  Re-fires every published translation that could inherit a value along the
  locale fallback chain, after a site's chain changes (#1327).

  A `:fallback` field is filled at fire time from the first sibling along
  `KilnCMS.I18n.Fallback.chain/4`, so a fired artifact carries the answer the
  chain gave *when it was fired*. Saving the chain at `/editor/locales` busts
  the delivery caches (`KilnCMS.CMS.Changes.BustLocaleSettings`), which fixes
  the live-rendered page, but not the artifacts. This re-fires them.

  Only the content types that declare a `:fallback` field are walked — a
  record attribute in the type's `localization:` option, a custom field, or
  any registered block with a `localized: :fallback` field — and only their
  published, non-default-locale rows (the default locale's chain is never
  walked: it is the end of every chain that does not say otherwise). A site
  that declares nothing queues nothing.
  """
  use Oban.Worker,
    queue: :firing,
    max_attempts: 3,
    unique: [
      period: 60,
      keys: [:org_id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing.Engine
  alias KilnCMS.Firing.FireWorker
  alias KilnCMS.I18n.FieldLocalization

  @doc "Queue the re-fire for `org_id`."
  @spec enqueue(Ash.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(org_id), do: %{"org_id" => org_id} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id}}) do
    org_id
    |> ContentTypes.all_for_org()
    |> Enum.filter(&FieldLocalization.inherits?(&1.resource, definitions(&1, org_id)))
    |> Enum.flat_map(&published_translations(&1, org_id))
    |> FireWorker.enqueue_backfill()

    :ok
  end

  defp definitions(%{source: :dynamic, definition: definition}, org_id),
    do: CMS.field_definitions_for_definition!(definition.id, actor: actor(), tenant: org_id)

  defp definitions(%{type: type}, org_id),
    do: CMS.field_definitions_for!(type, actor: actor(), tenant: org_id)

  defp published_translations(ct, org_id) do
    default = FieldLocalization.source_locale()

    ct
    |> ContentTypes.list!(
      tenant: org_id,
      # authorize?: false — a background re-fire with no actor, pinned to this
      # tenant and to published rows; only ids leave this function.
      authorize?: false,
      query: [filter: [state: :published]]
    )
    |> Enum.reject(&(&1.locale == default))
    |> Enum.map(&{org_id, Engine.document_type(&1), &1.id})
  end

  defp actor, do: KilnCMS.SystemActor.new(:localization)
end
