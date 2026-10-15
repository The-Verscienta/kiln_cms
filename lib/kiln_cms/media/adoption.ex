defmodule KilnCMS.Media.Adoption do
  @moduledoc """
  Hands an image backend (`Kiln.ImageBackend`, #1955) the media rows whose
  images it already holds.

  A library imported from another CMS can arrive as rows carrying only a URL
  into the backend — Verscienta's Directus import recorded each file's
  Cloudflare Images delivery URL, with no file in Kiln's storage. Kiln can show
  such an image but can't do anything else with it: no variants, no rotation,
  no transforms, and deleting the row leaves the image behind.

  Adoption asks the active backend which of those URLs are its own
  (`c:Kiln.ImageBackend.key_for_url/1`), and for each one records the backend
  and key on the row (`:adopt_into_image_backend`) and enqueues
  `KilnCMS.Media.VariantWorker`, which reads the image's dimensions back from
  the backend and records its variants. From then on the row is an ordinary
  backend item.

  Only rows with no `storage_key` and no backend are considered — a file Kiln
  holds is never re-pointed, and the action refuses it anyway. Published
  content keeps whatever URL its snapshot recorded; the backend still serves
  it.
  """

  require Ash.Query
  require Logger

  alias Kiln.ImageBackend.Registry
  alias KilnCMS.CMS
  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.Media
  alias KilnCMS.Media.VariantWorker

  @batch 500

  @type report :: %{
          scanned: non_neg_integer(),
          adopted: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc """
  Adopt every recognised row in `org_id` into the active backend. Returns the
  report, or `{:error, :no_active_backend}` when no backend is selected and
  configured.

  `dry_run?: true` counts what would be adopted (as `adopted`) and writes
  nothing.
  """
  @spec run(Ash.UUID.t(), keyword()) :: {:ok, report()} | {:error, :no_active_backend}
  def run(org_id, opts \\ []) do
    case Registry.active() do
      nil -> {:error, :no_active_backend}
      backend -> {:ok, adopt_all(org_id, backend, Keyword.get(opts, :dry_run?, false))}
    end
  end

  @doc """
  The one-line report `mix kiln.media.adopt_image_backend` and
  `KilnCMS.Release.adopt_image_backend/1` print for `run/2`'s result.
  """
  @spec describe(report(), Ash.UUID.t(), boolean()) :: String.t()
  def describe(%{scanned: scanned, adopted: adopted, failed: failed}, org_id, dry_run?) do
    verb = if dry_run?, do: "Would adopt", else: "Adopted"

    "#{verb} #{adopted} of #{scanned} row(s) with no stored file in org #{org_id}" <>
      if(failed > 0, do: "; #{failed} refused (see the log)", else: "") <> "."
  end

  @doc "What to tell an operator when `run/2` finds no active backend."
  @spec no_active_backend_message() :: String.t()
  def no_active_backend_message,
    do:
      "No image backend is active. Select one with `config :kiln_cms, :image_backend, " <>
        "Module` and give it its settings; `mix kiln.plugins.doctor` checks the selection."

  @type census :: %{
          held: non_neg_integer(),
          awaiting: non_neg_integer(),
          unrecognised: non_neg_integer()
        }

  @doc """
  Where `org_id`'s library stands with `backend`, for System → Image backend:

    * `held` — rows whose file the backend holds, uploaded or adopted;
    * `awaiting` — rows with no stored file whose URL the backend recognises,
      which `run/2` would adopt;
    * `unrecognised` — rows with no stored file whose URL it doesn't, which
      stay as links (another service's images, or a backend that recognises
      none of them).

  Asks `backend` whether or not it is the active one, so an operator can see
  what adoption would do before giving it its settings. Reads every row with
  no stored file, so it is for a page that asks on demand, not a hot path.
  """
  @spec census(Ash.UUID.t(), module()) :: census()
  def census(org_id, backend) do
    # The scan goes first: it reads with `authorize_with: :error`, so a
    # missing grant raises there rather than letting the count below — which
    # can't fail on a refused read — report an empty library.
    {awaiting, unrecognised} =
      org_id
      |> stream_unheld()
      |> Enum.reduce({0, 0}, fn item, {yes, no} ->
        if recognised(item, backend) == :error, do: {yes, no + 1}, else: {yes + 1, no}
      end)

    name = backend.name()

    held =
      MediaItem
      |> Ash.Query.filter(image_backend == ^name)
      |> Ash.count!(actor: Media.system(), tenant: org_id)

    %{held: held, awaiting: awaiting, unrecognised: unrecognised}
  end

  defp adopt_all(org_id, backend, dry_run?) do
    org_id
    |> stream_unheld()
    |> Enum.reduce(%{scanned: 0, adopted: 0, failed: 0}, fn item, report ->
      report = %{report | scanned: report.scanned + 1}

      case adopt(item, backend, org_id, dry_run?) do
        :adopted -> %{report | adopted: report.adopted + 1}
        :failed -> %{report | failed: report.failed + 1}
        :not_ours -> report
      end
    end)
  end

  defp adopt(item, backend, org_id, dry_run?) do
    case recognised(item, backend) do
      {:ok, key} -> if dry_run?, do: :adopted, else: record(item, backend, key, org_id)
      :error -> :not_ours
    end
  end

  # The backend's key for the image `item`'s URL names, if it names one.
  defp recognised(%{url: url}, backend) when is_binary(url) do
    case backend.key_for_url(url) do
      {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> :error
    end
  end

  defp recognised(_item, _backend), do: :error

  defp record(item, backend, key, org_id) do
    attrs = %{image_backend: backend.name(), storage_key: key, url: backend.url(key)}

    case CMS.adopt_media_item_into_image_backend(item, attrs,
           actor: Media.system(),
           tenant: org_id
         ) do
      {:ok, adopted} ->
        # Straight to the worker rather than `Ingest.enqueue_processing/1`:
        # that routes on `content_type`, which an imported row may not have.
        %{media_item_id: adopted.id, org_id: org_id}
        |> VariantWorker.new()
        |> Oban.insert()

        :adopted

      {:error, reason} ->
        Logger.warning("Image backend adoption refused media item #{item.id}: #{inspect(reason)}")
        :failed
    end
  end

  # Batched by id, as `KilnCMS.Media.Regeneration` scans. Adopted rows drop
  # out of the filter as the run goes, which an id cursor tolerates.
  defp stream_unheld(org_id) do
    Stream.resource(
      fn -> nil end,
      fn
        :done ->
          {:halt, :done}

        cursor ->
          case fetch_batch(org_id, cursor) do
            [] -> {:halt, :done}
            rows when length(rows) < @batch -> {rows, :done}
            rows -> {rows, List.last(rows).id}
          end
      end,
      fn _ -> :ok end
    )
  end

  defp fetch_batch(org_id, cursor) do
    MediaItem
    |> Ash.Query.filter(is_nil(storage_key) and is_nil(image_backend) and not is_nil(url))
    |> after_cursor(cursor)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(@batch)
    # As the media pipeline's system actor, `authorize_with: :error` (#1659):
    # a refused read must fail the run, not report a library it never saw.
    |> Ash.read!(actor: Media.system(), authorize_with: :error, tenant: org_id)
  end

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, cursor), do: Ash.Query.filter(query, id > ^cursor)
end
