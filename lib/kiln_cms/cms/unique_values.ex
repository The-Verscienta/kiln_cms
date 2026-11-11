defmodule KilnCMS.CMS.UniqueValues do
  @moduledoc """
  Enforces a `FieldDefinition`'s `validation: %{"unique" => true}` (#2276) on
  the records that carry the field.

  A dynamic field has no column of its own — every field lives in the shared
  `custom_fields` jsonb, and the set is admin-defined — so there is no unique
  index to lean on. Uniqueness is enforced by the write path instead, in three
  layers:

    1. **Advisory pre-check** (`register/3`, in the change): one indexed
       lookup (`custom_fields @> {name: value}`, the GIN index of #2321) so
       the editor sees the field error while validating, with its path. It
       only runs when the value, the locale or the type changed, and a racing
       writer can slip past it.
    2. **Lock** (`before_action`): a transaction-scoped advisory lock on the
       value, `pg_advisory_xact_lock(hashtextextended(key, 0))` — the shape of
       `KilnCMS.CMS.ContentLinks.lock_target/4`. Keys are sorted, so one record
       with several unique fields cannot deadlock against another.
    3. **Check** (`after_action`): the same lookup again, inside the
       transaction and after the lock was granted. Under `READ COMMITTED` the
       waiter's lookup starts after the winner committed, so it sees the
       winner's row and fails with a validation error rather than a constraint
       crash. Checking *after* the write also catches two records of one bulk
       insert carrying the same value.

  Where the write already is in a `before_action` (a version restore, the fold
  of a working copy on unpublish) the lock and the check run inline.

  ## Scope

  Same organization, same table — or, for a dynamic type, the same
  `type_definition_id` — and the same locale: translations of one document
  may share a value. A record never conflicts with itself. Soft-deleted
  (trashed) records are ignored; drafts and workflow-`:archived` records
  count. Version history does not. The match is exact and case-sensitive, on
  the trimmed, coerced value.

  ## What it guarantees

  Every writer that goes through the Ash change — the editor, JSON:API,
  GraphQL, MCP, importers, version restore, publishing a working copy, and
  restoring from the trash — and nothing else: raw SQL, `update_all` and a
  database restore are not covered, and there is no database backstop.
  `mix kiln.fields.duplicates` audits for what slipped through.

  A working copy only *stages* a value; the lock and the check run when it
  reaches the live `custom_fields` (publish, or the fold on unpublish), and the
  check at staging time is advisory.

  ## Errors

  The lookup reads every record in scope, whatever the writer may see, so the
  error says only that the value is in use. It never names the other record —
  that would let a writer who cannot read it learn that it exists.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  require Ash.Query

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.FieldConstraints
  alias KilnCMS.CMS.Preparations.CustomFieldQuery

  @type claim :: %{name: String.t(), label: String.t(), value: term()}

  @doc """
  Register the unique checks for the `unique` fields among `defs` on
  `changeset`, whose `custom_fields` has just been resolved.

  Options: `all?: true` checks every unique field with a value, not only the
  ones that changed (the trash restore, whose value is unchanged but whose
  record is coming back); `kind: :restored` words the error for a value that
  was valid when it was written (a restore, a promote, a copy).
  """
  @spec register(Ash.Changeset.t(), [map()], keyword()) :: Ash.Changeset.t()
  def register(changeset, defs, opts \\ []) do
    opts = Keyword.put_new(opts, :kind, kind(changeset))

    case Enum.filter(defs, &unique_def?/1) do
      [] ->
        changeset

      unique ->
        if changeset.phase == :before_action do
          enforce_now(changeset, unique, opts)
        else
          changeset
          |> Ash.Changeset.set_context(%{kiln_unique_plan: {unique, opts}})
          |> precheck(unique, opts)
          |> Ash.Changeset.before_action(&lock_hook(&1, unique, opts))
          |> Ash.Changeset.after_action(&check_hook(&1, &2, unique, opts))
        end
    end
  end

  @doc "Whether `def` asks for unique values."
  @spec unique_def?(map()) :: boolean()
  def unique_def?(def), do: FieldConstraints.unique?(Map.get(def, :validation))

  # `custom_fields_constraints: :skip` marks machinery that carries values the
  # record already held (restore, promote, copy).
  defp kind(changeset) do
    if changeset.context[:custom_fields_constraints] == :skip, do: :restored, else: :edited
  end

  # --- the three layers ----------------------------------------------------------

  # A restore, promote or copy reports through the authoritative check alone:
  # the pre-check is the editor's courtesy while typing.
  defp precheck(changeset, unique, opts) do
    if opts[:kind] == :restored,
      do: changeset,
      else: precheck_claims(changeset, unique, opts)
  end

  defp precheck_claims(changeset, unique, opts) do
    scope = scope(changeset)

    changeset
    |> claims(unique, Ash.Changeset.get_attribute(changeset, :custom_fields), opts)
    |> Enum.reduce(changeset, &precheck_claim(&1, &2, scope, opts))
  end

  defp precheck_claim(claim, changeset, scope, opts) do
    if taken?(scope, claim),
      do: Ash.Changeset.add_error(changeset, conflict(claim, opts[:kind])),
      else: changeset
  end

  defp lock_hook(changeset, unique, opts) do
    case lock(lock_keys(changeset, unique, opts), opts) do
      :ok ->
        changeset

      # An error on the changeset, not `{:error, _}`: a bulk batch cannot
      # take the latter from a hook.
      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp lock_keys(changeset, unique, opts) do
    scope = scope(changeset)

    changeset
    |> claims(unique, Ash.Changeset.get_attribute(changeset, :custom_fields), opts)
    |> Enum.map(&{&1, key(scope, &1)})
  end

  @doc """
  Take, in one sorted pass, every lock the records of a bulk batch will need
  (`Changes.ApplyCustomFields.before_batch/3`).

  The per-record `before_action` locks the same keys again, which a held
  advisory lock allows. Without this a batch locks its records' values one
  record at a time, in batch order, and two batches that overlap in opposite
  order can deadlock; Postgres then aborts one transaction, and Ash goes on
  to report that as an unknown error rather than a validation one.
  """
  @spec lock_batch([Ash.Changeset.t()]) :: [Ash.Changeset.t()]
  def lock_batch(changesets) do
    keyed =
      Enum.flat_map(changesets, fn changeset ->
        case changeset.context do
          %{kiln_unique_plan: {unique, opts}} when changeset.valid? ->
            lock_keys(changeset, unique, opts)

          _other ->
            []
        end
      end)

    case lock(keyed, kind: :edited) do
      :ok -> changesets
      {:error, error} -> Enum.map(changesets, &Ash.Changeset.add_error(&1, error))
    end
  end

  defp check_hook(changeset, result, unique, opts) do
    scope = scope(changeset, result)

    changeset
    |> claims(unique, result.custom_fields, opts)
    |> Enum.find(&taken?(scope, &1))
    |> case do
      nil -> {:ok, result}
      claim -> {:error, conflict(claim, opts[:kind])}
    end
  end

  # A hook already running (a restore, a fold) cannot register another: Ash
  # walks a fixed list. The lock and the check happen here, before the UPDATE;
  # the lock holds to the end of the transaction, so a racing writer's own
  # check waits for this commit.
  defp enforce_now(changeset, unique, opts) do
    scope = scope(changeset)

    claims =
      claims(changeset, unique, Ash.Changeset.get_attribute(changeset, :custom_fields), opts)

    keys = Enum.map(claims, &{&1, key(scope, &1)})

    with :ok <- lock(keys, opts),
         nil <- Enum.find(claims, &taken?(scope, &1)) do
      changeset
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
      %{} = claim -> Ash.Changeset.add_error(changeset, conflict(claim, opts[:kind]))
    end
  end

  # --- claims ----------------------------------------------------------------------

  # The values this write puts in play: the unique fields with a value that
  # changed — or all of them when the record is new, moves locale or type, or
  # the caller asked for `all?`.
  defp claims(changeset, unique, fields, opts) do
    fields = fields || %{}
    stored = stored(changeset)
    all? = all?(changeset, opts)

    for def <- unique,
        value <- [Map.get(fields, def.name)],
        not blank?(value),
        all? or value != Map.get(stored, def.name) do
      %{name: def.name, label: def.label, value: value}
    end
  end

  defp stored(%{action_type: :create}), do: %{}

  defp stored(changeset) do
    for {key, value} <- changeset.data.custom_fields || %{},
        into: %{},
        do: {to_string(key), value}
  end

  defp all?(changeset, opts) do
    opts[:all?] == true or changeset.action_type == :create or
      Ash.Changeset.changing_attribute?(changeset, :locale) or
      Ash.Changeset.changing_attribute?(changeset, :type_definition_id)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(_value), do: false

  # --- scope and lookup -------------------------------------------------------------

  defp scope(changeset) do
    %{
      resource: changeset.resource,
      tenant: changeset.to_tenant,
      org: Ash.Changeset.get_attribute(changeset, :org_id) || changeset.to_tenant,
      id: Ash.Changeset.get_attribute(changeset, :id),
      locale: Ash.Changeset.get_attribute(changeset, :locale),
      type_id:
        type_id(changeset.resource, Ash.Changeset.get_attribute(changeset, :type_definition_id))
    }
  end

  defp scope(changeset, record) do
    %{
      resource: changeset.resource,
      tenant: changeset.to_tenant,
      org: Map.get(record, :org_id) || changeset.to_tenant,
      id: record.id,
      locale: Map.get(record, :locale),
      type_id: type_id(changeset.resource, Map.get(record, :type_definition_id))
    }
  end

  defp type_id(resource, id) do
    if function_exported?(resource, :__kiln_dynamic_entry__, 0), do: id
  end

  # One row is enough. A refused read is not a concern: this is an existence
  # probe on the field's own value, the question a unique index answers for
  # every writer whatever they may read.
  defp taken?(scope, claim) do
    scope.resource
    |> Ash.Query.new()
    |> other_than(scope.id)
    |> locale_filter(scope.locale)
    |> type_filter(scope.type_id)
    |> Ash.Query.filter(^CustomFieldQuery.contains(:custom_fields, claim.name, claim.value))
    |> Ash.Query.limit(1)
    # authorize?: false — an existence probe on the unique value itself, the
    # same question a unique index answers for every writer regardless of what
    # they may read; the answer is never more than "in use" (no id, no title).
    |> Ash.exists?(authorize?: false, tenant: scope.tenant)
  end

  # A record being created has no id yet before the insert: nothing to exclude.
  defp other_than(query, nil), do: query
  defp other_than(query, id), do: Ash.Query.filter(query, id != ^id)

  defp locale_filter(query, nil), do: Ash.Query.filter(query, is_nil(locale))
  defp locale_filter(query, locale), do: Ash.Query.filter(query, locale == ^locale)

  defp type_filter(query, nil), do: query
  defp type_filter(query, type_id), do: Ash.Query.filter(query, type_definition_id == ^type_id)

  # --- locking -----------------------------------------------------------------------

  defp key(scope, claim) do
    where = scope.type_id || AshPostgres.DataLayer.Info.table(scope.resource)

    # The canonical JSON of the coerced value, not a rendered string: `1` and
    # `"1"` are different values and take different locks.
    "kiln:unique:#{scope.org}:#{where}:#{scope.locale}:#{claim.name}:#{Jason.encode!(canonical(claim.value))}"
  end

  # jsonb `@>` treats `1` and `1.0` as one value, so they must take one lock.
  defp canonical(value) when is_float(value) and value == trunc(value), do: trunc(value)
  defp canonical(value), do: value

  # Sorted, so two writers each holding several values take them in one order.
  # A deadlock between two bulk batches (their records lock one at a time)
  # becomes a validation error for the victim, not a crash.
  defp lock(keys, opts) do
    keys
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.each(fn {_claim, key} ->
      KilnCMS.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    end)

    :ok
  rescue
    error in Postgrex.Error ->
      if match?(%{postgres: %{code: :deadlock_detected}}, error) do
        {claim, _key} = List.first(keys)
        {:error, retry(claim, opts[:kind])}
      else
        reraise error, __STACKTRACE__
      end
  end

  # --- errors --------------------------------------------------------------------------

  defp conflict(claim, :restored) do
    error(
      claim,
      dgettext(
        "errors",
        "%{field} holds a value another record already uses. Change it, then try again",
        field: field(claim)
      )
    )
  end

  defp conflict(claim, _kind) do
    error(claim, dgettext("errors", "%{field} is already in use", field: field(claim)))
  end

  defp retry(claim, _kind) do
    error(
      claim,
      dgettext(
        "errors",
        "%{field} is being changed by another save at the same time. Try again",
        field: field(claim)
      )
    )
  end

  defp field(claim), do: "#{claim.label} (#{claim.name})"

  defp error(claim, message),
    do: InvalidAttribute.exception(field: :custom_fields, message: message, value: claim.name)

  # --- audit ----------------------------------------------------------------------------

  @doc """
  The values of the field `name` that more than one live record of the same
  scope holds, scoped the way the runtime check is (organization, table or
  dynamic type, locale; trashed records ignored).

  `scope` is `%{resource: module, org_id: uuid, type_definition_id: uuid | nil}`.
  Returns `%{groups: total, samples: [%{locale:, value:, count:}]}` with at most
  `limit` samples, the most repeated first. Read-only.
  """
  @spec duplicates(map(), String.t(), pos_integer()) :: %{
          groups: non_neg_integer(),
          samples: list()
        }
  # sobelow_skip ["SQL.Query"] — `table` is the compiled resource's own table name.
  def duplicates(%{resource: resource, org_id: org_id} = scope, name, limit \\ 3) do
    table = AshPostgres.DataLayer.Info.table(resource)

    {type_sql, type_args} =
      case type_id(resource, scope[:type_definition_id]) do
        nil -> {"", []}
        id -> {" AND type_definition_id = $3", [Ecto.UUID.dump!(id)]}
      end

    # `table` is the compiled resource's own table name, never user input.
    sql = """
    SELECT locale, custom_fields -> $1::text AS value, count(*) AS n, count(*) OVER () AS groups
    FROM #{table}
    WHERE org_id = $2 AND archived_at IS NULL#{type_sql}
      AND custom_fields ? $1::text
      AND (custom_fields -> $1::text) NOT IN ('null'::jsonb, '""'::jsonb, '[]'::jsonb)
    GROUP BY locale, custom_fields -> $1::text
    HAVING count(*) > 1
    ORDER BY n DESC, locale, value
    LIMIT #{limit}
    """

    %{rows: rows} =
      KilnCMS.Repo.query!(sql, [name, Ecto.UUID.dump!(org_id)] ++ type_args)

    %{
      groups: rows |> List.first() |> then(&if(&1, do: Enum.at(&1, 3), else: 0)),
      samples:
        Enum.map(rows, fn [locale, value, count, _groups] ->
          %{locale: locale, value: value, count: count}
        end)
    }
  end

  @doc """
  `duplicates/3` for every `unique` field of every content type of an
  organization (or just `type`, a type name): the rows of
  `mix kiln.fields.duplicates`. Only fields that actually repeat are returned.
  """
  @spec audit(Ash.UUID.t(), String.t() | nil, pos_integer()) :: [map()]
  def audit(org_id, type \\ nil, limit \\ 5) do
    for descriptor <- KilnCMS.CMS.ContentTypes.all_for_org(org_id),
        type in [nil, to_string(descriptor.type)],
        {resource, type_id} = audit_target(descriptor),
        def <- KilnCMS.CMS.Changes.ApplyCustomFields.definitions(resource, type_id, org_id),
        unique_def?(def),
        %{groups: groups} = found <-
          [
            duplicates(
              %{resource: resource, org_id: org_id, type_definition_id: type_id},
              def.name,
              limit
            )
          ],
        groups > 0 do
      Map.merge(found, %{type: to_string(descriptor.type), field: def.name, label: def.label})
    end
  end

  defp audit_target(%{source: :dynamic, definition: %{id: id}}), do: {KilnCMS.CMS.Entry, id}
  defp audit_target(%{resource: resource}), do: {resource, nil}
end
