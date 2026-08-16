defmodule KilnCMS.Experiments.Promotion do
  @moduledoc """
  Writing a winning variant's patch into the document it was tested against
  (#982) — the *separate, explicit act* the plan and `Experiment`'s moduledoc
  insist promotion is.

  Concluding an experiment records a result; it does not touch the document.
  Promoting does, and it does so through the ordinary `:update` action of the
  document's own content type (`KilnCMS.CMS.ContentTypes.update/4`), under the
  **actor** who asked — so it cuts a normal version, fires artifacts, notifies
  webhooks and is authorized exactly as if that editor had typed the change.
  Nothing here bypasses a policy, and nothing writes as the system.

  The patch is applied with the same code the delivery path uses to *serve* it
  (`KilnCMS.Experiments.Assignment.apply_to_record/2` for the scalar fields,
  `apply_to_blocks/2` for the block tree), so what a visitor saw and what the
  document becomes cannot drift. Blocks are patched on the stored map shape
  (`TypedBlocks.input_map/1`) and written back whole, the shape the XLIFF
  importer already writes.

  ## What it refuses

    * an experiment that is not `concluded` with a `winner_variant_id` — the
      winner is a fact the conclusion recorded, not something a promote may
      choose;
    * a winner that is the **control** — there is nothing to write, and saying
      so is better than an empty update that still cuts a version;
    * a document that no longer exists (or a type no longer on this site).

  It does not refuse a second promotion: the update is idempotent in effect
  (the same values), and whether it cuts another version is the content
  type's business, not this module's.
  """

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Experiments.Assignment

  @type error ::
          :not_concluded
          | :no_winner
          | :winner_is_control
          | :winner_missing
          | :type_unknown
          | :document_missing
          | {:update_failed, term()}

  @doc """
  Promote `experiment`'s recorded winner into its document as `actor`.

  `opts`: `:actor` (required — the editor promoting), `:tenant` (the org).
  Returns `{:ok, updated_document}`.
  """
  @spec promote(KilnCMS.Experiments.Experiment.t(), keyword()) ::
          {:ok, struct()} | {:error, error()}
  def promote(experiment, opts) do
    with :ok <- concluded?(experiment),
         {:ok, winner} <- winner(experiment),
         :ok <- not_control?(winner),
         {:ok, descriptor} <- descriptor(experiment, opts),
         {:ok, record} <- document(descriptor, experiment, opts) do
      write(descriptor, record, winner, opts)
    end
  end

  @doc """
  The attrs `promote/2` would write for `record` under `winner` — the sparse
  patch expressed as an update: only the patchable scalars the patch names, and
  `blocks` only if the patch touches any. Public so a caller (or a test) can
  show what promotion will change before it does.
  """
  @spec attrs(struct(), KilnCMS.Experiments.Variant.t()) :: map()
  def attrs(record, winner) do
    fields =
      winner.patch
      |> Map.get("fields", %{})
      |> Map.take(KilnCMS.Experiments.Variant.patchable_fields())
      |> Map.new(fn {field, value} -> {String.to_existing_atom(field), value} end)

    if Assignment.patches_blocks?(winner) do
      blocks =
        record
        |> Map.get(:blocks)
        |> List.wrap()
        |> Enum.map(&TypedBlocks.input_map/1)
        |> Assignment.apply_to_blocks(winner)

      Map.put(fields, :blocks, blocks)
    else
      fields
    end
  end

  defp concluded?(%{state: :concluded}), do: :ok
  defp concluded?(_experiment), do: {:error, :not_concluded}

  defp winner(%{winner_variant_id: nil}), do: {:error, :no_winner}

  defp winner(%{winner_variant_id: id, variants: variants}) when is_list(variants) do
    case Enum.find(variants, &(&1.id == id)) do
      nil -> {:error, :winner_missing}
      variant -> {:ok, variant}
    end
  end

  defp winner(experiment) do
    # Variants not loaded on the struct handed in: load them.
    case Ash.load(experiment, :variants, authorize?: false) do
      {:ok, loaded} -> winner(loaded)
      _ -> {:error, :winner_missing}
    end
  end

  defp not_control?(%{control: true}), do: {:error, :winner_is_control}
  defp not_control?(_variant), do: :ok

  defp descriptor(experiment, opts) do
    case ContentTypes.get(experiment.content_type, Keyword.get(opts, :tenant)) do
      nil -> {:error, :type_unknown}
      descriptor -> {:ok, descriptor}
    end
  end

  defp document(descriptor, experiment, opts) do
    case ContentTypes.get_record(
           descriptor,
           experiment.document_id,
           Keyword.take(opts, [:actor, :tenant])
         ) do
      {:ok, record} -> {:ok, record}
      _ -> {:error, :document_missing}
    end
  end

  defp write(descriptor, record, winner, opts) do
    case ContentTypes.update(
           descriptor,
           record,
           attrs(record, winner),
           Keyword.take(opts, [:actor, :tenant])
         ) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, {:update_failed, reason}}
    end
  end
end
