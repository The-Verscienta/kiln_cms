defmodule KilnCMS.CMS.VersionSnapshot do
  @moduledoc """
  Reconstructs a content record's full attribute state at a given PaperTrail
  version.

  History is tracked in `:changes_only` mode (the `paper_trail` block in
  `KilnCMS.CMS.Content`), so **no single version row holds the whole document** —
  each stores only the attributes that write changed. The state at a version is
  therefore the fold of every version's `changes`, in chronological order, from
  creation up to and including it.

  Two callers share it: `KilnCMS.CMS.Changes.RestoreVersion`, which writes the
  reconstruction back onto the record, and the version-compare UI (#467), which
  diffs two reconstructions against each other. It lives here rather than in
  either one so a fix to the fold can't reach only half of them.

  > #### Not yet the only fold {: .warning}
  >
  > `KilnCMS.Firing.PointInTime` still carries its own copy, and
  > `KilnCMS.CMS.Changes.CoalesceAutosaveVersions` folds a run of autosaves with
  > the same `Map.merge`. Migrating them is tracked separately — until then a fix
  > here reaches restore and compare only.

  ## Snapshot shape

  A snapshot is a plain map keyed by attribute **name as a string**, holding the
  *dumped* value — the same JSON shape PaperTrail wrote into the `changes` JSONB
  column (`Ash.Type.dump_to_embedded/3`, then a trip through Postgres). Nothing
  here casts back to runtime types: the diff compares stored shapes, and the
  restore hands values to `force_change_attribute/3`, which casts them itself.

  `current/1` puts a live record through the same dump-and-encode so the working
  draft can be compared against a saved version on equal terms.

  ## Ordering, and why the cutoff is the timestamp alone

  Versions are merged in `(version_inserted_at, id)` order, matching the
  composite index in `KilnCMS.CMS.VersionPolicies` and the governance chain's own
  ordering (#598). That makes the merge order of two versions sharing an instant
  *deterministic* — but not *meaningful*: `id` is a random v4 UUID, so which of
  two same-transaction writes sorts first is a coin flip.

  So the cutoff is **inclusive on the timestamp**, never on the tuple. A fold up
  to some version takes every version at or before its instant, including a
  sibling that happens to carry a higher UUID. Cutting on the tuple would drop
  that sibling about half the time, and a restore would silently revert a field
  to a state the document was never in.

  Membership is checked separately: folding a version that isn't in this record's
  history is an error, not a plausible-looking snapshot of the wrong state.
  """

  require Ash.Query

  @typedoc "Attribute name (string) => dumped value, as stored in `changes`."
  @type t :: %{optional(String.t()) => term()}

  @doc """
  The state at `version`, folding that record's history up to and including it.

  `opts` are passed to `Ash.read!/2` and must carry the tenant (version twins are
  tenant-strict, #419) plus either an `:actor` or `authorize?: false`. Returns
  `:error` when `version` is not part of `source_id`'s history.
  """
  @spec at(module(), term(), struct(), keyword()) :: {:ok, t()} | :error
  def at(version_module, source_id, version, opts) do
    version_module
    |> history(source_id, version.version_inserted_at, opts)
    |> fold_through(version)
  end

  @doc """
  The state at each of `version_a` and `version_b`, from a single read.

  Both folds share one history: bounding the read at the later of the two cursors
  covers the earlier one as well, so comparing two versions costs the same query
  as restoring one. Returns `:error` if either version is outside `source_id`'s
  history.
  """
  @spec pair(module(), term(), struct(), struct(), keyword()) :: {:ok, t(), t()} | :error
  def pair(version_module, source_id, version_a, version_b, opts) do
    a_first? = before?(version_a, version_b)
    {earlier, later} = if a_first?, do: {version_a, version_b}, else: {version_b, version_a}
    history = history(version_module, source_id, later.version_inserted_at, opts)

    if member?(history, earlier) and member?(history, later) do
      # One pass, not two folds: the earlier snapshot is a prefix of the later
      # one, so the later fold resumes from it rather than re-merging every
      # version below the cursor — each of which carries a whole block tree.
      {prefix, rest} = Enum.split_while(history, &at_or_before?(&1, earlier))
      first = fold(prefix, %{})
      second = rest |> Enum.filter(&at_or_before?(&1, later)) |> fold(first)

      if a_first?, do: {:ok, first, second}, else: {:ok, second, first}
    else
      :error
    end
  end

  @doc """
  A live record's state in snapshot shape — the unsaved working draft as the
  compare view's "current" side.

  Mirrors what `AshPaperTrail.ChangeBuilders.ChangesOnly` would have written had
  the record been saved right now: the same attributes (primary key and
  `ignore_attributes` dropped), dumped with the same call, then JSON round-tripped
  because a snapshot read back from JSONB has lost its atoms, structs and
  `DateTime`s. Without that trip every field would read as changed.
  """
  @spec current(struct()) :: t()
  def current(%resource{} = record) do
    skip =
      Ash.Resource.Info.primary_key(resource) ++
        AshPaperTrail.Resource.Info.ignore_attributes(resource)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reject(&(&1.name in skip))
    |> Map.new(&{to_string(&1.name), dump(&1, Map.get(record, &1.name))})
  end

  @doc """
  Chronological history of `source_id`, bounded at `up_to`.

  Exposed so a caller holding a fold cursor can reuse one read; prefer `at/4` or
  `pair/5`.
  """
  @spec history(module(), term(), DateTime.t(), keyword()) :: [struct()]
  def history(version_module, source_id, up_to, opts) do
    version_module
    |> Ash.Query.filter(version_source_id == ^source_id and version_inserted_at <= ^up_to)
    |> Ash.Query.sort(version_inserted_at: :asc, id: :asc)
    |> Ash.read!(opts)
  end

  @doc """
  Folds an ascending `history` up to and including `version`'s instant.

  Inclusive on the timestamp rather than on `version` itself — see the module's
  ordering note: a sibling written in the same transaction belongs in the
  snapshot regardless of how its random UUID happens to sort.

  `:error` when `version` isn't in the list — the caller asked for a version of a
  different record (or one it can't read), and a fold of everything else would be
  a plausible-looking snapshot of the wrong state.
  """
  @spec fold_through([struct()], struct()) :: {:ok, t()} | :error
  def fold_through(history, version) do
    if member?(history, version) do
      {:ok, history |> Enum.filter(&at_or_before?(&1, version)) |> fold(%{})}
    else
      :error
    end
  end

  defp fold(versions, acc), do: Enum.reduce(versions, acc, &Map.merge(&2, changes(&1)))

  defp member?(history, %{id: id}), do: Enum.any?(history, &(&1.id == id))

  defp at_or_before?(version, %{version_inserted_at: cursor}),
    do: DateTime.compare(version.version_inserted_at, cursor) != :gt

  # `changes` arrives string-keyed from JSONB, but a version struct built in the
  # same transaction as its source write hasn't round-tripped yet.
  defp changes(%{changes: changes}) when is_map(changes),
    do: Map.new(changes, fn {key, value} -> {to_string(key), value} end)

  defp changes(_version), do: %{}

  defp dump(attribute, value) do
    case Ash.Type.dump_to_embedded(attribute.type, value, attribute.constraints) do
      {:ok, dumped} -> jsonify(dumped)
      _other -> nil
    end
  end

  # Per attribute rather than over the whole map: a type whose dump isn't
  # JSON-encodable drops that one field out of the comparison instead of taking
  # the entire snapshot down.
  #
  # Both of Jason's raise paths, not just the obvious one: a struct with no
  # encoder raises `Protocol.UndefinedError`, but a binary that isn't valid UTF-8
  # raises `Jason.EncodeError`, and catching only the first let one bad byte
  # anywhere in the record take down the whole comparison.
  defp jsonify(value) do
    value |> Jason.encode!() |> Jason.decode!()
  rescue
    Protocol.UndefinedError -> nil
    Jason.EncodeError -> nil
  end

  @doc """
  Whether `a` precedes `b` in `(version_inserted_at, id)` order.

  The ordering authority for version history — callers that need to put two
  versions in order use this rather than rolling their own, and nothing may
  compare the `DateTime`s by Erlang term order, which sorts the structs by map
  layout rather than chronology.
  """
  @spec before?(struct(), struct()) :: boolean()
  def before?(a, b) do
    case DateTime.compare(a.version_inserted_at, b.version_inserted_at) do
      :lt -> true
      :gt -> false
      :eq -> a.id <= b.id
    end
  end
end
