defmodule KilnCMS.CMS.SectionLayoutSweep do
  @moduledoc """
  Deletes the section layouts (`KilnCMS.CMS.FieldSection`) no field carries
  any more, on every site (#3060).

  Since #3059 every field write prunes the layouts it leaves empty, and since
  #3061 a layout cannot be created for a section no field is in. Rows that
  1.9.x and 1.10.x left behind stay, though, and they are not harmless: a
  field later filed under such a name inherits the stale tab or fieldset.
  When no field of the type has a section, the fields admin's **Sections
  of** panel (whose save prunes) is not even shown, so nothing in the
  console removes them.

  Each owner that has a layout (a compiled type or a dynamic one, per site)
  is read through `KilnCMS.CMS.SectionLayouts.uncarried/2`: a fresh read of
  the owner's fields and layouts, failing closed, in which a field of a type
  this release does not register (#2605) still carries its section. Each
  layout it finds is then deleted on its own, through
  `SectionLayouts.prune_if_uncarried/3`, which checks again for a carrier in
  the delete's transaction, locking it `FOR SHARE`: a field an admin filed
  under that section since the read keeps its layout, and a field moved out
  of it meanwhile waits for the delete. A layout another writer deleted
  first is simply gone: neither deleted by this run nor a failure. Each
  deleted layout is logged at info (site, owner, name, display, initially),
  so an operator can recreate one by hand.

  A field created in such a section after that second check, and before the
  delete commits, renders the section with the default layout: the same
  race, and the same outcome, as the fields admin's own prune.

  The layouts of a compiled type this release no longer registers (a removed
  plugin's) are left alone and counted as skipped: their fields are still
  stored, and the type may come back.

  ## When it runs

  `KilnCMS.Application` enqueues it on boot, ten minutes out, so migrations
  and a rolling deploy are normally over first; an old node still serving
  during the rollover can leave a row, and the next boot's run takes it.
  Deduplicated for a day at the database level, and idempotent: a second run
  finds nothing to delete. `config :kiln_cms, :section_layout_sweep_on_boot,
  false` turns the boot enqueue off (the test and e2e builds do);
  `KilnCMS.Release.prune_section_layouts/1` runs it by hand, with
  `dry_run: true` to only list what it would delete.

  An owner whose fields or layouts cannot be read, or one of whose layouts
  cannot be checked or deleted, is logged (at warning) and counted under
  `:failed`, and the sweep goes on to the next owner; what it deleted of that
  owner before the failure stays deleted and is reported. A layout row the database holds
  but this release cannot load (a newer release's display) fails its owner
  on every run, by design: the sweep cannot tell what it would delete. A run
  with any failure ends the job in error, so Oban retries it with backoff,
  up to three attempts.

  Once no supported upgrade path starts at 1.10.x or earlier, this module
  can be removed (in the next major release, at the latest): it runs on
  every boot, as `KilnCMS.Accounts.ErasureBackfill` does, and finds nothing.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 86_400,
      fields: [:worker],
      states: [:scheduled, :available, :executing, :retryable, :suspended, :completed]
    ]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.SectionLayouts

  @typedoc """
  What a run did: the layouts deleted (or, in a dry run, that would be),
  each as `%{org_id, owner, name, display, initially}`; how many layouts of
  an unregistered compiled type were left alone; and how many owners
  failed.
  """
  @type result :: %{
          pruned: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          layouts: [map()]
        }

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    result = run()

    if result.failed > 0 do
      Logger.warning("section layout sweep: #{summary(result)}; retrying")
      {:error, "section layout sweep failed for #{result.failed} owner(s)"}
    else
      if result.pruned > 0, do: Logger.info("section layout sweep: #{summary(result)}")
      :ok
    end
  end

  @doc """
  Run the sweep. Options: `dry_run: true` reads and reports without
  deleting; `org_id:` limits it to one site. See the moduledoc.

  `before_prune:` is a test seam: a one-argument function called with each
  layout between the read that found it and its delete, so a test can act
  in that window. Nothing else passes it.
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    run_opts = %{
      dry_run?: opts[:dry_run] == true,
      before_prune: Keyword.get(opts, :before_prune, fn _layout -> :ok end)
    }

    empty = %{pruned: 0, skipped: 0, failed: 0, layouts: []}

    opts[:org_id]
    |> owners()
    |> Enum.reduce(empty, &sweep(&1, &2, run_opts))
    |> Map.update!(:layouts, &Enum.reverse/1)
  end

  @doc "A one-line summary of a run's result."
  @spec summary(result()) :: String.t()
  def summary(result),
    do:
      "#{result.pruned} pruned, #{result.skipped} skipped (unknown type), " <>
        "#{result.failed} failed"

  # Each owner that has a layout, per site, with how many it has. Read
  # through Ecto across every site: this is a sweep over the whole instance,
  # and each owner is then read and pruned through `SectionLayouts`, in its
  # own site.
  defp owners(org_id) do
    query =
      from(s in "field_sections",
        group_by: [s.org_id, s.content_type, s.type_definition_id],
        order_by: [s.org_id, s.content_type, s.type_definition_id],
        select:
          {type(s.org_id, Ecto.UUID), s.content_type, type(s.type_definition_id, Ecto.UUID),
           count(s.id)}
      )

    query =
      if org_id,
        do: from(s in query, where: s.org_id == type(^org_id, Ecto.UUID)),
        else: query

    # A row stored with both owners (an older release's) groups apart from
    # its owner's other rows: each owner is swept once.
    query
    |> KilnCMS.Repo.all()
    |> Enum.group_by(
      fn {org, type, definition, _count} -> {org, owner(type, definition)} end,
      fn {_org, _type, _definition, count} -> count end
    )
    |> Enum.map(fn {{org, owner}, counts} -> {org, owner, Enum.sum(counts)} end)
    |> Enum.sort()
  end

  defp owner(_type, definition) when is_binary(definition), do: {:dynamic, definition}

  defp owner(type, nil) do
    case Enum.find(ContentTypes.types(), &(Atom.to_string(&1) == type)) do
      nil -> {:unknown, type}
      atom -> {:compiled, atom}
    end
  end

  defp sweep({_org_id, {:unknown, _type}, count}, acc, _run_opts),
    do: %{acc | skipped: acc.skipped + count}

  defp sweep({org_id, owner, _count}, acc, run_opts) do
    # authorize?: false — an operator sweep over every site, run by the job
    # queue or a release rpc with no actor; `FieldSection`'s destroy is
    # admin-only, and the reads behind it are scoped to this owner and site.
    opts = [tenant: org_id, authorize?: false]

    with {:ok, rows} <- SectionLayouts.uncarried(owner, opts),
         {:ok, pruned} <- prune(rows, owner, opts, run_opts) do
      record(acc, pruned, org_id, owner, run_opts.dry_run?)
    else
      {:error, error, pruned} ->
        acc |> record(pruned, org_id, owner, false) |> failed(error, org_id, owner)

      {:error, error} ->
        failed(acc, error, org_id, owner)
    end
  end

  defp prune(rows, _owner, _opts, %{dry_run?: true}), do: {:ok, rows}

  # One at a time, each re-checked in its own transaction; see the moduledoc.
  defp prune(rows, owner, opts, run_opts) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, pruned} ->
      run_opts.before_prune.(row)

      case SectionLayouts.prune_if_uncarried(owner, row, opts) do
        {:ok, :pruned} -> {:cont, {:ok, [row | pruned]}}
        {:ok, _carried_or_gone} -> {:cont, {:ok, pruned}}
        {:error, error} -> {:halt, {:error, error, pruned}}
      end
    end)
    |> case do
      {:ok, pruned} -> {:ok, Enum.reverse(pruned)}
      {:error, error, pruned} -> {:error, error, Enum.reverse(pruned)}
    end
  end

  defp record(acc, rows, org_id, owner, dry_run?) do
    layouts = Enum.map(rows, &describe(&1, org_id, owner))
    Enum.each(layouts, &log(&1, dry_run?))
    %{acc | pruned: acc.pruned + length(layouts), layouts: Enum.reverse(layouts, acc.layouts)}
  end

  defp failed(acc, error, org_id, owner) do
    Logger.warning(
      "section layout sweep could not prune #{inspect(owner)} in org #{org_id}: " <>
        Exception.message(Ash.Error.to_error_class(error))
    )

    %{acc | failed: acc.failed + 1}
  end

  defp describe(row, org_id, owner),
    do: %{
      org_id: org_id,
      owner: owner,
      name: row.name,
      display: row.display,
      initially: row.initially
    }

  defp log(layout, dry_run?) do
    verb = if dry_run?, do: "would delete", else: "deleted"

    Logger.info(
      "section layout sweep #{verb} the layout of section #{inspect(layout.name)} " <>
        "of #{inspect(layout.owner)} in org #{layout.org_id} " <>
        "(display: #{layout.display}, initially: #{layout.initially}): no field is in it"
    )
  end

  @doc """
  Queue the sweep ten minutes out, unless one is already queued or ran
  today. Never raises: a node must not fail to start because this could not
  be queued.
  """
  @spec enqueue() :: :ok
  def enqueue do
    case %{} |> new(schedule_in: 600) |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> log_failure(reason)
    end
  rescue
    error -> log_failure(error)
  end

  defp log_failure(reason) do
    Logger.warning("section layout sweep not queued: #{inspect(reason)}")
    :ok
  end
end
