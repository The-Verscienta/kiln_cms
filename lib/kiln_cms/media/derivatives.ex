defmodule KilnCMS.Media.Derivatives do
  @moduledoc """
  The derivative cache behind `/media/:id/t/…`: find a rendered transform, or
  render it under `KilnCMS.Media.TransformGate` and keep it.

  ## Where a derivative lives

  In blob storage, through `KilnCMS.Storage` like every other media file —
  so it is shared by every node, survives a redeploy, and needs no second
  cache to size. The key is `KilnCMS.Media.ImageTransform.Plan`'s
  `cache_key` plus its extension: a digest of the source's storage key, the
  crop window, the output size, format and quality. Everything that changes
  the pixels is in the key and nothing else is, so

    * a lookup is one storage read, with no database round trip, and
    * a derivative is never stale — a rotated original has a new storage key,
      a moved focal point a new crop window, so both simply miss.

  An item outside the `:public` audience keeps its derivatives in private
  storage, next to its original.

  ## What the table is for

  Each stored derivative gets a `KilnCMS.CMS.MediaDerivative` row, read only
  on a miss. It holds the per-item budget (`max_derivatives_per_item`,
  default 200): past it a transform is still rendered and served, just not
  kept, so an attacker walking the allowlist costs CPU the gate and rate limit
  already bound, and no storage. It also finds derivatives the item can no
  longer produce — cut from a replaced original or around a focal point that
  has since moved — and deletes them before counting, so edits don't eat the
  budget. And it is how a purge finds the blobs to delete (`blobs/1`).
  """

  require Logger

  alias KilnCMS.{CMS, ImageProcessor, Storage, SystemActor}
  alias KilnCMS.Media.{ImageTransform, TransformGate}
  alias KilnCMS.Media.ImageTransform.Plan

  @default_budget 200

  @doc "The storage key a planned derivative is kept under."
  @spec storage_key(Plan.t()) :: String.t()
  def storage_key(%Plan{cache_key: key, ext: ext}), do: key <> ext

  @doc "The cached bytes for `plan`, or `:miss`. One storage read."
  @spec lookup(map(), Plan.t()) :: {:ok, binary()} | :miss
  def lookup(item, %Plan{} = plan) do
    case read(item, storage_key(plan)) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      _missing_or_unreadable -> :miss
    end
  end

  @doc """
  Renders `plan` from `item`'s original, keeps it (within budget) and returns
  the bytes. Runs inside the render gate; `{:error, :busy}` when no slot came
  free. `opts` pass `:server`/`:timeout` through to `TransformGate.run/2`.
  """
  @spec render(map(), Plan.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def render(item, %Plan{} = plan, opts \\ []) do
    TransformGate.run(
      fn ->
        # A request queued behind the one rendering this same derivative finds
        # it done once it gets its slot — one render per derivative, not one
        # per request that raced for it.
        case lookup(item, plan) do
          {:ok, bytes} -> {:ok, bytes}
          :miss -> render_and_keep(item, plan)
        end
      end,
      Keyword.take(opts, [:server, :timeout])
    )
  end

  # `src` is server-built (System.tmp_dir! + a UUID), never user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp render_and_keep(item, plan) do
    src = Path.join(System.tmp_dir!(), "kiln-transform-src-#{Ecto.UUID.generate()}")

    try do
      with :ok <- Storage.copy_to_file(item.storage_key, src, private?: private?(item)),
           {:ok, out} <-
             ImageProcessor.render(src, plan, max_pixels: ImageTransform.max_source_pixels()) do
        keep_and_read(item, plan, out)
      end
    after
      File.rm(src)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp keep_and_read(item, plan, out) do
    bytes = File.read!(out.path)
    keep(item, plan, out, byte_size(bytes))
    {:ok, bytes}
  after
    File.rm(out.path)
  end

  # Best-effort: the bytes are already rendered and about to be served, so a
  # failure to keep them costs the next request a re-render, not this one its
  # image.
  defp keep(item, plan, out, size) do
    live = prune(item)

    if length(live) < budget() do
      store(item, plan, out, size)
    else
      Logger.info(
        "Media transform budget (#{budget()}) reached for media item #{item.id}; " <>
          "serving #{plan.width}x#{plan.height} #{plan.format} without keeping it"
      )
    end
  end

  defp store(item, plan, out, size) do
    key = storage_key(plan)
    put = if private?(item), do: &Storage.store_private/2, else: &Storage.store/2

    with {:ok, ^key} <- put.(key, out.path),
         {:ok, _row} <-
           CMS.record_media_derivative(
             %{
               media_item_id: item.id,
               storage_key: key,
               source_key: item.storage_key,
               focal: plan.focal,
               content_type: plan.content_type,
               byte_size: size,
               width: out.width,
               height: out.height,
               private: private?(item)
             },
             actor: actor(),
             tenant: item.org_id
           ) do
      :ok
    else
      error ->
        Logger.warning("Could not keep media transform #{key}: #{inspect(error)}")
        :error
    end
  end

  # Deletes the derivatives `item` can no longer produce and returns the rest.
  defp prune(item) do
    case CMS.list_media_derivatives(item.id, actor: actor(), tenant: item.org_id) do
      {:ok, rows} ->
        {stale, live} = Enum.split_with(rows, &stale?(&1, item))
        Enum.each(stale, &delete(&1, item.org_id))
        live

      {:error, error} ->
        Logger.warning("Could not list media transforms for #{item.id}: #{inspect(error)}")
        # Unknown count: treat the budget as spent rather than store blind.
        List.duplicate(nil, budget())
    end
  end

  defp stale?(row, item) do
    row.source_key != item.storage_key or
      (not is_nil(row.focal) and row.focal != ImageTransform.focal_key(item))
  end

  defp delete(row, org_id) do
    delete_blob(row.storage_key, row.private)
    CMS.destroy_media_derivative(row, actor: actor(), tenant: org_id)
  end

  @doc """
  The blobs `item`'s derivatives occupy, as `{key, private?}`. Read these
  **before** purging the item: the rows go with it through the foreign key,
  and then nothing knows where the blobs were. Pass them to `delete_blobs/1`
  once the purge has succeeded.
  """
  @spec blobs(map()) :: [{String.t(), boolean()}]
  def blobs(item) do
    case CMS.list_media_derivatives(item.id, actor: actor(), tenant: item.org_id) do
      {:ok, rows} -> Enum.map(rows, &{&1.storage_key, &1.private})
      _error -> []
    end
  end

  @doc "Deletes the blobs `blobs/1` returned."
  @spec delete_blobs([{String.t(), boolean()}]) :: :ok
  def delete_blobs(blobs) do
    Enum.each(blobs, fn {key, private?} -> delete_blob(key, private?) end)
  end

  defp delete_blob(key, true), do: Storage.delete_private(key)
  defp delete_blob(key, _public), do: Storage.delete(key)

  defp read(item, key) do
    if private?(item), do: Storage.fetch_private(key), else: Storage.fetch(key)
  end

  defp private?(item), do: Map.get(item, :audience, :public) != :public

  defp budget do
    :kiln_cms
    |> Application.get_env(:image_transforms, [])
    |> Keyword.get(:max_derivatives_per_item, @default_budget)
  end

  defp actor, do: SystemActor.new(:media_transforms)
end
