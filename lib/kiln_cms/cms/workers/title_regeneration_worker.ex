defmodule KilnCMS.CMS.Workers.TitleRegenerationWorker do
  @moduledoc """
  Re-derives a dynamic type's existing titles after its `title_template`
  changed (#2287). One job is one page (`KilnCMS.CMS.TitleRegeneration`); a
  full page enqueues the next, so a large type is a chain of short jobs rather
  than one long one, and a failure costs a page, not the run.

  A page with refused records chains the next page first, then fails with the
  count, so Oban shows it (the records are logged by id). `max_attempts: 1`: a
  record the `:update` refused refuses again, and a retry would only re-chain
  the pages after it.

  `unique` collapses a sweep enqueued while an identical one (same type, site
  and page) is still waiting — a template saved twice in a row. It leaves out
  `:executing`, or a page could not enqueue its own successor.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [
      period: 60,
      fields: [:worker, :args],
      keys: [:kind, :org_id, :after],
      states: [:available, :scheduled, :retryable]
    ]

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.TitleRegeneration

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => kind, "org_id" => org_id} = args}) do
    # `nil` for a type archived since the job was enqueued: nothing to do.
    case ContentTypes.get(kind, org_id) do
      nil ->
        :ok

      ct ->
        page = TitleRegeneration.run_page(ct, org_id, args["after"])
        if page.next, do: enqueue(kind, org_id, page.next)

        if page.failed > 0,
          do: {:error, "#{page.failed} of #{page.scanned} titles refused; see the log"},
          else: :ok
    end
  end

  @doc "Enqueue a sweep of the dynamic type `kind` (its `name`), from `after`."
  @spec enqueue(String.t(), Ash.UUID.t(), Ash.UUID.t() | nil) :: :ok
  def enqueue(kind, org_id, after_id \\ nil) do
    %{"kind" => kind, "org_id" => org_id, "after" => after_id}
    |> new()
    |> Oban.insert!()

    :ok
  end
end
