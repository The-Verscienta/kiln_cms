defmodule KilnCMS.Media.Resnapshot do
  @moduledoc """
  Re-takes the stored `:media` custom-field snapshots (`KilnCMS.Media.Snapshot`)
  from the current library items — `mix kiln.media.resnapshot`.

  A snapshot is taken when a record is saved. One saved before the shape grew
  `width`/`height`/`mime_type`/`focal`/`variants`, or before its item's
  variants were derived, keeps what it had until the record is saved again.
  Fired artifacts refresh themselves (`Snapshot`, "When it is taken"); the
  stored value — what JSON:API and GraphQL read off the row — is what this
  brings up to date.

  ## Through the write path

  Each record goes through the content resource's internal `:resnapshot_media`
  action as the `:media` system actor: `Changes.ApplyCustomFields` re-resolves
  the stored media values exactly as an editor's save would, and leaves every
  other field alone. So the result is a value a save could have produced; the
  write is versioned, keeps `updated_at` and `lock_version`, loses to an editor
  who saved in between, and re-fires a published record. See that action in
  `KilnCMS.CMS.Content`.

  The changeset is built first and submitted only when a media value would
  change, so a second run writes nothing — and a dry run (the default) reports
  exactly what a real run would write.

  Every record of every type with a `:media` field is visited, drafts
  included: their stored value is served to editors on the same APIs. A
  snapshot whose item no longer resolves (deleted, or not readable) fails that
  record, as a save of it would, and is reported rather than rewritten.
  """

  require Logger

  alias KilnCMS.CMS.ContentTypes

  @batch 100

  @typedoc "Per-run counts. `failed` lists `{type, id, message}`."
  @type report :: %{
          scanned: non_neg_integer(),
          stale: non_neg_integer(),
          written: non_neg_integer(),
          failed: [{String.t(), Ash.UUID.t(), String.t()}]
        }

  @doc """
  Resnapshot one organization. `dry_run?: true` builds every changeset and
  writes nothing; `:batch` sizes each read.
  """
  @spec run(Ash.UUID.t(), keyword()) :: report()
  def run(org_id, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run?, false)
    batch = Keyword.get(opts, :batch, @batch)

    org_id
    |> media_types()
    |> Enum.flat_map(fn {descriptor, names} ->
      descriptor
      |> records(org_id, batch)
      |> Enum.map(&visit(&1, descriptor, names, org_id, dry_run?))
    end)
    |> Enum.reduce(%{scanned: 0, stale: 0, written: 0, failed: []}, &tally/2)
    |> Map.update!(:failed, &Enum.reverse/1)
  end

  @doc "A one-paragraph summary of `report` for the task's output."
  @spec describe(report(), Ash.UUID.t(), boolean()) :: String.t()
  def describe(report, org_id, dry_run?) do
    verb = if dry_run?, do: "would re-snapshot", else: "re-snapshotted"

    failures =
      Enum.map(report.failed, fn {type, id, message} -> "\n  #{type} #{id}: #{message}" end)

    "org #{org_id}: scanned #{report.scanned} record(s), #{verb} " <>
      "#{if dry_run?, do: report.stale, else: report.written}" <>
      if(report.failed == [], do: ".", else: ", #{length(report.failed)} failed:") <>
      Enum.join(failures) <>
      if(dry_run? and report.stale > 0, do: "\nRun again with --apply to write.", else: "")
  end

  # The types with a top-level `:media` field, each with those fields' names.
  # A link field (`link_of_id`) lives inside a reference's snapshot, not at
  # the top of `custom_fields`, so it is not one of them.
  defp media_types(org_id) do
    definitions =
      KilnCMS.CMS.list_field_definitions!(
        actor: KilnCMS.CMS.Bookkeeping.system(),
        # A refused read must not look like "no media fields": the run would
        # report a clean site having looked at nothing.
        authorize_with: :error,
        tenant: org_id,
        query: [filter: [field_type: :media, link_of_id: [is_nil: true]]]
      )

    org_id
    |> ContentTypes.all_for_org()
    |> Enum.flat_map(fn descriptor ->
      case Enum.filter(definitions, &belongs?(&1, descriptor)) do
        [] -> []
        defs -> [{descriptor, Enum.map(defs, & &1.name)}]
      end
    end)
  end

  defp belongs?(definition, %{source: :dynamic, definition: %{id: id}}),
    do: definition.type_definition_id == id

  defp belongs?(definition, %{type: type}), do: definition.content_type == type

  # Keyset pages, read without a policy check as `Computed.DailyRefresh` reads
  # its records: one tenant, one type, and it must see drafts, gated and
  # locked records — a system grant on the content READ policy would hand
  # every system caller the whole corpus. The write is authorized.
  defp records(descriptor, org_id, batch) do
    Stream.unfold(:start, fn
      :done ->
        nil

      cursor ->
        filter = if cursor == :start, do: [], else: [id: [greater_than: cursor]]

        ContentTypes.list!(descriptor,
          # authorize?: false — one tenant, one type, the write is authorized (above)
          authorize?: false,
          tenant: org_id,
          query: [filter: filter, sort: [id: :asc], limit: batch]
        )
        |> case do
          [] -> nil
          records when length(records) < batch -> {records, :done}
          records -> {records, List.last(records).id}
        end
    end)
    |> Stream.flat_map(& &1)
  end

  defp visit(record, descriptor, names, org_id, dry_run?) do
    stored = Map.take(record.custom_fields || %{}, names)

    if Enum.all?(stored, fn {_name, value} -> value in [nil, []] end) do
      :empty
    else
      changeset =
        Ash.Changeset.for_update(record, :resnapshot_media, %{},
          actor: KilnCMS.Media.system(),
          tenant: org_id
        )

      cond do
        not changeset.valid? ->
          {:failed, failure(descriptor, record, changeset.errors)}

        Map.take(Ash.Changeset.get_attribute(changeset, :custom_fields) || %{}, names) ==
            stored ->
          :current

        dry_run? ->
          :stale

        true ->
          write(changeset, descriptor, record)
      end
    end
  end

  defp write(changeset, descriptor, record) do
    case Ash.update(changeset) do
      {:ok, _record} ->
        :written

      {:error, error} ->
        Logger.warning("media resnapshot: #{record.id} not written: #{message(error)}")
        {:failed, failure(descriptor, record, error)}
    end
  end

  defp failure(descriptor, record, error),
    do: {to_string(descriptor.type), record.id, message(error)}

  defp message(errors) when is_list(errors), do: errors |> Ash.Error.to_error_class() |> message()
  defp message(error), do: error |> Ash.Error.to_error_class() |> Exception.message()

  defp tally(:empty, acc), do: %{acc | scanned: acc.scanned + 1}
  defp tally(:current, acc), do: %{acc | scanned: acc.scanned + 1}
  defp tally(:stale, acc), do: %{acc | scanned: acc.scanned + 1, stale: acc.stale + 1}

  defp tally(:written, acc),
    do: %{acc | scanned: acc.scanned + 1, stale: acc.stale + 1, written: acc.written + 1}

  defp tally({:failed, failure}, acc),
    do: %{acc | scanned: acc.scanned + 1, failed: [failure | acc.failed]}
end
