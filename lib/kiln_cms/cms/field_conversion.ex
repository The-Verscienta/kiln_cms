defmodule KilnCMS.CMS.FieldConversion do
  @moduledoc """
  Moves JSON-in-text custom-field values into a `:group` field, or into a
  multiple `:select` (several terms) — `mix kiln.fields.convert`
  (docs/field-conversion.md).

  Lists that predate `:group` were stored as JSON strings in `:text` fields,
  in whatever shape the importer left: an array of objects, one object, or an
  array encoded twice. This parses each record's source string, renames keys
  (`renames`), and writes the rows to the target group through the content
  resource's internal `:convert_custom_field` action, as the
  `:field_conversion` system actor. `Changes.ApplyCustomFields` coerces them
  exactly as an editor's save of the group would, so the rules are the
  field's own: sub-field types, `required`, `:select` options and
  `min_items`/`max_items`.

  A multiple `:select` target takes the same source shapes, but its rows are
  terms: `["adaptogen","tonic"]`, or that encoded again. Each term must be one
  of the field's `options` unless it takes terms of its own (`allow_custom`),
  so the report lists every **distinct term** with its count, and the ones
  not yet in `options` — what an admin reviews before deciding whether to
  add them as options or open the vocabulary. Renames do not apply.

  Every report counts the **published** records a run would write (or wrote):
  each of those writes re-fires the record's artifact.

  ## All or nothing, unless told otherwise

  A run first checks every record: parses the source and builds the write
  without submitting it. A record that does not fit is reported — the source
  is not JSON (prose, the known case), or a row fails coercion, with the
  path (`dosages[2].unit`). Nothing is written while any record is invalid,
  unless `skip_invalid: true`, in which case only the valid ones are written
  and the rest keep their string. A dry run (the default) stops after the
  check.

  The source field is never touched: the old field is dropped a release
  later (expand/migrate/contract).

  ## Re-running

  A record whose group already holds rows is left alone (`kept`) unless
  `overwrite: true`, so a second run writes nothing, and a run after fixing
  the invalid records writes just those.

  ## What a write costs

  The same as `mix kiln.media.resnapshot`'s: one versioned update per record
  (the sync delta API reads changes from version rows), and one artifact fire
  job for a published record. No webhook, no notification, `updated_at` and
  `lock_version` kept, and a write loses to an editor's save in between
  (reported, and picked up by the next run). Drafts are converted too; a live
  record's pending working copy gets its own held value converted alongside.
  Trashed records are not visited.
  """

  require Logger

  alias KilnCMS.CMS.Changes.ApplyCustomFields
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.WorkingCopy

  @batch 100

  # A string still decoding to a string after this many passes is not a list
  # that was encoded twice by accident.
  @max_decodes 3

  @typedoc "One record that was not converted, and why."
  @type problem :: %{
          id: Ash.UUID.t(),
          slug: String.t() | nil,
          kind: :unparseable | :invalid | :not_written,
          messages: [String.t()]
        }

  @typedoc """
  A run's outcome. `convertible` counts the records whose write is valid;
  `written` the ones actually written (always 0 on a dry run, or when
  `blocked?` — an invalid record stopped the run before any write).
  `published` counts the convertible records that are published. For a
  multiple `:select` target, `terms` counts each distinct term across the
  convertible and invalid records' values (live and held), and `new_terms`
  lists the ones not in the field's `options`, most used first; both are
  empty for a group.
  """
  @type report :: %{
          type: String.t(),
          source: String.t(),
          target: String.t(),
          dry_run?: boolean(),
          blocked?: boolean(),
          scanned: non_neg_integer(),
          convertible: non_neg_integer(),
          written: non_neg_integer(),
          empty: non_neg_integer(),
          kept: non_neg_integer(),
          published: non_neg_integer(),
          terms: %{String.t() => pos_integer()},
          new_terms: [String.t()],
          problems: [problem()]
        }

  @doc """
  Convert `source` into the group `target` on every record of `type` in
  `org_id`.

  Options: `dry_run?` (default `true`), `skip_invalid?`, `overwrite?`,
  `renames` (`%{"old_key" => "new_key"}`) and `:batch` (read page size).
  Returns `{:error, message}` when the fields themselves do not fit (no such
  type or field, a target that is not a group, a rename to no sub-field).
  """
  @spec run(Ash.UUID.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, report()} | {:error, String.t()}
  def run(org_id, type, source, target, opts \\ []) do
    with {:ok, descriptor} <- descriptor(type, org_id),
         definitions = definitions(descriptor, org_id),
         {:ok, source_def} <- source_definition(definitions, source, target),
         {:ok, group} <- target_definition(definitions, target),
         renames = Map.new(Keyword.get(opts, :renames, %{})),
         :ok <- check_renames(renames, group) do
      # `group` is the target either way: a group, or a multiple select.
      plan = %{
        descriptor: descriptor,
        org_id: org_id,
        source: source_def.name,
        group: group,
        renames: renames,
        overwrite?: Keyword.get(opts, :overwrite?, false),
        batch: Keyword.get(opts, :batch, @batch)
      }

      dry_run? = Keyword.get(opts, :dry_run?, true)
      skip_invalid? = Keyword.get(opts, :skip_invalid?, false)

      report =
        cond do
          dry_run? -> pass(plan, false)
          skip_invalid? -> pass(plan, true)
          true -> checked_then_written(plan)
        end

      {:ok,
       report
       |> put_terms(group)
       |> Map.merge(%{
         type: to_string(descriptor.type),
         source: source_def.name,
         target: group.name,
         dry_run?: dry_run?
       })}
    end
  end

  @doc """
  The organization a run targets: the default one for `nil`, else the one
  with this slug (an operator's `--org` / `org:`).
  """
  @spec org_id(String.t() | nil) :: {:ok, Ash.UUID.t()} | {:error, String.t()}
  def org_id(nil), do: {:ok, KilnCMS.Accounts.default_org_id()}

  def org_id(slug) do
    # authorize?: false — the operator's --org lookup at a shell on the host, before any actor exists
    case KilnCMS.Accounts.list_organizations!(
           authorize?: false,
           query: [filter: [slug: slug], limit: 1]
         ) do
      [org | _] -> {:ok, org.id}
      [] -> {:error, "No organization with slug #{slug}"}
    end
  end

  @doc """
  Parse one stored source value into rows.

  Accepts a JSON array (each element a row), a single JSON object (one row),
  either of those encoded as a JSON string again (up to #{@max_decodes} times),
  and an already-decoded list or map. Blank, `null`, `[]` and `{}` are
  `:empty`. Anything else — prose, a bare number — is an error naming what it
  found. The rows are not checked here: a non-object element is the
  coercion's to report, with its path.
  """
  @spec parse(term()) :: :empty | {:ok, list()} | {:error, String.t()}
  def parse(value), do: parse(value, 0)

  defp parse(nil, _decodes), do: :empty
  defp parse([], _decodes), do: :empty
  defp parse(list, _decodes) when is_list(list), do: {:ok, list}
  defp parse(map, _decodes) when map == %{}, do: :empty
  defp parse(%{} = map, _decodes) when not is_struct(map), do: {:ok, [map]}

  defp parse(string, decodes) when is_binary(string) do
    case String.trim(string) do
      "" ->
        :empty

      _text when decodes >= @max_decodes ->
        {:error, "is still a JSON string after #{@max_decodes} decodes"}

      trimmed ->
        trimmed |> Jason.decode() |> decoded(trimmed, decodes)
    end
  end

  defp parse(other, _decodes), do: {:error, "is #{inspect(other)}, not text"}

  defp decoded({:ok, string}, _text, decodes) when is_binary(string),
    do: parse(string, decodes + 1)

  defp decoded({:ok, value}, _text, decodes)
       when is_list(value) or is_map(value) or is_nil(value),
       do: parse(value, decodes)

  defp decoded({:ok, other}, _text, _decodes),
    do: {:error, "is JSON #{inspect(other)}, not an object or a list of objects"}

  defp decoded({:error, _}, text, _decodes), do: {:error, "is not JSON: #{excerpt(text)}"}

  defp excerpt(text) do
    if String.length(text) > 60,
      do: inspect(String.slice(text, 0, 60) <> "…"),
      else: inspect(text)
  end

  @doc "A plain-text summary of `report` for the task's output."
  @spec describe(report()) :: String.t()
  def describe(report) do
    problems =
      Enum.map(report.problems, fn problem ->
        "\n  #{problem.id}#{if problem.slug, do: " (#{problem.slug})"} — #{problem.kind}:" <>
          Enum.map_join(problem.messages, "", &"\n      #{&1}")
      end)

    "#{report.type}: #{report.source} → #{report.target}: scanned #{report.scanned}, " <>
      "#{verb(report)} (#{report.published} published), #{report.empty} empty, " <>
      "#{report.kept} already converted, " <>
      "#{length(report.problems)} invalid" <>
      if(report.problems == [], do: ".", else: ":") <>
      Enum.join(problems) <> terms_summary(report) <> hint(report)
  end

  defp terms_summary(%{terms: terms}) when map_size(terms) == 0, do: ""

  defp terms_summary(%{terms: terms, new_terms: new_terms}) do
    "\n#{map_size(terms)} distinct term(s)" <>
      case new_terms do
        [] ->
          ", all of them options."

        new ->
          ", #{length(new)} not in the options:" <>
            Enum.map_join(new, "", &"\n  #{&1} (#{Map.fetch!(terms, &1)})")
      end
  end

  defp verb(%{dry_run?: true} = report), do: "would convert #{report.convertible}"

  defp verb(%{blocked?: true} = report),
    do: "converted 0 (nothing written: #{length(report.problems)} invalid)"

  defp verb(report), do: "converted #{report.written}"

  defp hint(%{dry_run?: true, problems: [_ | _]}),
    do:
      "\nFix the records above (or pass --skip-invalid to leave them as strings), " <>
        "then run with --apply."

  defp hint(%{dry_run?: true, convertible: n}) when n > 0,
    do: "\nRun again with --apply to write."

  defp hint(%{blocked?: true}),
    do: "\nFix the records above, or pass --skip-invalid to leave them as strings."

  defp hint(_report), do: ""

  # --- setup -----------------------------------------------------------------

  defp descriptor(type, org_id) do
    case ContentTypes.get(type, org_id) do
      nil -> {:error, "No content type #{inspect(type)}"}
      descriptor -> {:ok, descriptor}
    end
  end

  defp definitions(%{source: :dynamic, definition: %{id: id}}, org_id),
    do: ApplyCustomFields.definitions(KilnCMS.CMS.Entry, id, org_id)

  defp definitions(%{resource: resource}, org_id),
    do: ApplyCustomFields.definitions(resource, nil, org_id)

  defp source_definition(_definitions, same, same),
    do: {:error, "The source and the target are the same field (#{same})"}

  defp source_definition(definitions, source, _target) do
    case Enum.find(definitions, &(&1.name == source)) do
      nil -> {:error, "No field #{inspect(source)} on this type (#{names(definitions)})"}
      %{field_type: :group} -> {:error, "#{source} is already a group"}
      definition -> {:ok, definition}
    end
  end

  defp target_definition(definitions, target) do
    case Enum.find(definitions, &(&1.name == target)) do
      nil ->
        {:error,
         "No field #{inspect(target)} on this type (#{names(definitions)}) — " <>
           "create the group and its sub-fields first"}

      %{field_type: :group} = group ->
        if FieldDefinition.group_fields(group) == [],
          do: {:error, "The group #{target} has no sub-fields yet"},
          else: {:ok, group}

      %{field_type: :select, multiple: true} = select ->
        {:ok, select}

      %{field_type: :select} ->
        {:error, "#{target} is a select that holds one choice — make it hold several terms first"}

      %{field_type: type} ->
        {:error, "#{target} is a #{type} field, not a group or a multiple select"}
    end
  end

  defp check_renames(renames, _select) when map_size(renames) == 0, do: :ok

  defp check_renames(_renames, %{field_type: :select} = select),
    do: {:error, "--map renames the keys of rows; #{select.name} holds terms, which have none"}

  defp check_renames(renames, group) do
    subs = group |> FieldDefinition.group_fields() |> Enum.map(& &1.name)

    case Enum.reject(Map.values(renames), &(&1 in subs)) do
      [] ->
        :ok

      unknown ->
        {:error,
         "--map names #{Enum.join(unknown, ", ")}, not a sub-field of #{group.name} " <>
           "(sub-fields: #{Enum.join(Enum.sort(subs), ", ")})"}
    end
  end

  defp names(definitions),
    do: definitions |> Enum.map(& &1.name) |> Enum.sort() |> Enum.join(", ")

  # --- the pass ---------------------------------------------------------------

  # The check pass, then — only if every record fits — the write pass, which
  # re-reads: a record an editor saved in between is judged on what it holds
  # now.
  defp checked_then_written(plan) do
    checked = pass(plan, false)
    if checked.problems == [], do: pass(plan, true), else: %{checked | blocked?: true}
  end

  defp pass(plan, write?) do
    plan
    |> records()
    |> Enum.map(&visit(&1, plan, write?))
    |> Enum.reduce(
      %{
        blocked?: false,
        scanned: 0,
        convertible: 0,
        written: 0,
        empty: 0,
        kept: 0,
        published: 0,
        terms: %{},
        problems: []
      },
      &tally/2
    )
    |> Map.update!(:problems, &Enum.reverse/1)
  end

  # Keyset pages, read without a policy check as `Media.Resnapshot` reads
  # them: one tenant, one type, and it must see drafts and gated records. The
  # write is authorized.
  defp records(%{descriptor: descriptor, org_id: org_id, batch: batch}) do
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

  # Each outcome is tagged with the record's terms (a multiple select target
  # only) and whether it is published, for the report's counts.
  defp visit(record, plan, write?) do
    {visited(record, plan, write?), terms(record, plan), record_published?(record)}
  end

  defp record_published?(record), do: Map.get(record, :state) == :published

  defp terms(_record, %{group: %{field_type: :group}}), do: []

  defp terms(record, plan) do
    held =
      case held_rows(record, plan) do
        {:ok, rows} -> rows
        _other -> []
      end

    live =
      case rows((record.custom_fields || %{})[plan.source], plan) do
        {:ok, rows} -> rows
        _other -> []
      end

    (live ++ held)
    |> Enum.filter(&(is_binary(&1) or is_number(&1)))
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp visited(record, plan, write?) do
    stored = record.custom_fields || %{}

    if converted?(stored[plan.group.name]) and not plan.overwrite? do
      :kept
    else
      live = rows(stored[plan.source], plan)
      held = held_rows(record, plan)

      case {live, held} do
        {{:error, message}, _held} ->
          problem(record, :unparseable, [message])

        {_live, {:error, message}} ->
          problem(record, :unparseable, ["(working copy) " <> message])

        {:empty, held} when held in [:empty, :none] ->
          :empty

        {live, held} ->
          build(record, plan, live, held, write?)
      end
    end
  end

  defp converted?(value), do: value not in [nil, [], %{}]

  # The working copy's value, when the record has one holding `custom_fields`.
  defp held_rows(record, plan) do
    case WorkingCopy.held_fields(record) do
      %{"custom_fields" => %{} = held} when record.working_copy_at != nil ->
        rows(held[plan.source], plan)

      _not_held ->
        :none
    end
  end

  defp rows(value, plan) do
    case parse(value) do
      {:ok, rows} -> rows |> Enum.map(&rename(&1, plan.renames)) |> fit(plan.group)
      other -> other
    end
  end

  defp rename(%{} = row, renames) when not is_struct(row) do
    Map.new(row, fn {key, value} ->
      key = to_string(key)
      {Map.get(renames, key, key), value}
    end)
  end

  defp rename(row, _renames), do: row

  # A group that holds one row keeps only the first of a list it is handed; a
  # conversion must not lose the rest without saying so.
  defp fit([_, _ | _] = rows, %{multiple: false} = group),
    do:
      {:error,
       "holds #{length(rows)} rows, but #{group.label} (#{group.name}) takes one — " <>
         "make the group repeating first"}

  defp fit(rows, _group), do: {:ok, rows}

  defp build(record, plan, live, held, write?) do
    conversion =
      case held do
        :none -> %{name: plan.group.name, live: value(live)}
        held -> %{name: plan.group.name, live: value(live), held: value(held)}
      end

    changeset =
      Ash.Changeset.for_update(record, :convert_custom_field, %{},
        actor: KilnCMS.SystemActor.resolve(:field_conversion),
        tenant: plan.org_id,
        context: %{convert_custom_field: conversion}
      )

    cond do
      not changeset.valid? -> problem(record, :invalid, messages(changeset.errors))
      write? -> write(changeset, record)
      true -> :convertible
    end
  end

  defp value({:ok, rows}), do: rows
  defp value(:empty), do: nil

  defp write(changeset, record) do
    case Ash.update(changeset) do
      {:ok, _record} ->
        :written

      {:error, error} ->
        Logger.warning("field conversion: #{record.id} not written: #{inspect(messages(error))}")
        problem(record, :not_written, messages(error))
    end
  end

  defp problem(record, kind, messages),
    do: {:problem, %{id: record.id, slug: Map.get(record, :slug), kind: kind, messages: messages}}

  defp messages(errors) when is_list(errors), do: Enum.map(errors, &message/1)
  defp messages(%{errors: [_ | _] = errors}), do: messages(errors)
  defp messages(error), do: [message(error)]

  defp message(%{message: message}) when is_binary(message), do: message
  defp message(error) when is_exception(error), do: Exception.message(error)
  defp message(error), do: inspect(error)

  defp tally({outcome, terms, published?}, acc) do
    acc = tally(outcome, acc)

    acc =
      if outcome in [:kept, :empty],
        do: acc,
        else: %{
          acc
          | terms: Enum.reduce(terms, acc.terms, &Map.update(&2, &1, 1, fn n -> n + 1 end))
        }

    if published? and outcome in [:convertible, :written],
      do: %{acc | published: acc.published + 1},
      else: acc
  end

  defp tally(:kept, acc), do: %{acc | scanned: acc.scanned + 1, kept: acc.kept + 1}
  defp tally(:empty, acc), do: %{acc | scanned: acc.scanned + 1, empty: acc.empty + 1}

  defp tally(:convertible, acc),
    do: %{acc | scanned: acc.scanned + 1, convertible: acc.convertible + 1}

  defp tally(:written, acc),
    do: %{
      acc
      | scanned: acc.scanned + 1,
        convertible: acc.convertible + 1,
        written: acc.written + 1
    }

  defp tally({:problem, problem}, acc),
    do: %{acc | scanned: acc.scanned + 1, problems: [problem | acc.problems]}

  # The terms not yet options, most used first — empty for a group target.
  defp put_terms(report, %{field_type: :select, options: options}) do
    new_terms =
      report.terms
      |> Enum.reject(fn {term, _count} -> term in options end)
      |> Enum.sort_by(fn {term, count} -> {-count, term} end)
      |> Enum.map(&elem(&1, 0))

    Map.put(report, :new_terms, new_terms)
  end

  defp put_terms(report, _group), do: Map.merge(report, %{terms: %{}, new_terms: []})
end
