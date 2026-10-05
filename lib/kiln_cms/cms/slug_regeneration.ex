defmodule KilnCMS.CMS.SlugRegeneration do
  @moduledoc """
  Bulk slug regeneration (#455) — pathauto's "update all aliases".

  Re-derives every record's slug through the same `Slugs.derive_base/3` chain
  the editor and `DeriveSlug` use (per-type pattern, else focus keyphrase →
  title), with the same dedupe. `preview/3` is the dry run: it reports every
  record whose slug would change, plus how many were skipped as author-pinned
  (`Slugs.underived?/2` — the editor's heuristic). `run/3` applies.

  Two safety properties:

    * **hand-picked slugs are skipped by default** — pass `include_pinned:
      true` after a deliberate convention change (e.g. a new slug pattern),
      where every old slug necessarily looks hand-picked;
    * **renames go through each type's normal `:update` action**, so a
      published rename leaves a 301 behind (`RecordSlugRedirect`), re-fires
      artifacts, busts caches, and lands in version history.

  Records are streamed and updated one at a time, so each `ensure_unique`
  sees the renames before it.
  """

  require Ash.Query

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs

  @type change :: %{
          kind: String.t(),
          id: Ash.UUID.t(),
          title: String.t(),
          locale: String.t(),
          state: atom(),
          current: String.t(),
          new: String.t(),
          pinned?: boolean()
        }

  @type summary :: %{
          scanned: non_neg_integer(),
          changes: [change()],
          pinned_skipped: non_neg_integer(),
          failed: [change()],
          changed: non_neg_integer()
        }

  @doc """
  Dry run: every record (of `kind`, or `:all`) whose slug would change.

  Options: `include_pinned: true` also proposes new slugs for records whose
  current slug doesn't match its own derivation (default: counted and
  skipped).
  """
  @spec preview(atom() | String.t() | :all, term(), keyword()) :: summary()
  def preview(kind, tenant, opts \\ []) do
    reduce(kind, tenant, opts, fn _ct, _record, _change -> :ok end)
  end

  @doc """
  Apply: rename every previewable record through its type's `:update` action.
  Same options as `preview/3`, plus `actor:` (history attribution) and
  `on_progress:` (arity-1 fun called with the running summary every 100
  records scanned). Failed updates are collected under `:failed`; `:changed`
  counts the renames that actually landed.
  """
  @spec run(atom() | String.t() | :all, term(), keyword()) :: summary()
  def run(kind, tenant, opts \\ []) do
    actor = opts[:actor]
    field = Keyword.get(opts, :field, :slug)

    reduce(kind, tenant, opts, fn ct, record, change ->
      # authorize?: false — a bulk admin/operator tool: the admin was checked
      # when the run was enqueued (`SlugRegenLive`, #1160), and the mix task is
      # an operator at the host's shell, which has no actor at all. `actor:` is
      # attribution for the version history only.
      case ContentTypes.update(ct, record, %{field => change.new},
             actor: actor,
             tenant: tenant,
             authorize?: false
           ) do
        {:ok, _updated} -> :ok
        {:error, _error} -> :error
      end
    end)
  end

  # One traversal serves both modes: `handle` is invoked per would-change
  # record (a no-op for preview, the update for run) and reports :ok/:error.
  defp reduce(kind, tenant, opts, handle) do
    context = %{
      tenant: tenant,
      # `:slug` (the default, #455) or `:path_alias` (#1597). Everything else
      # about the traversal is shared: the same streaming, the same
      # author-pinned skip, and the same write through each type's `:update`
      # so a rename leaves a 301 behind, re-fires artifacts and lands in
      # history. A second bulk path would have had to re-earn all of that.
      field: Keyword.get(opts, :field, :slug),
      # Restrict to these ids — how a move regenerates just the subtree it
      # moved rather than the whole type.
      ids: Keyword.get(opts, :ids),
      # `id => ancestor slugs` as they were BEFORE whatever moved them, when a
      # caller knows. The author-pinned verdict is made against the derivation
      # from THESE, not from the current chain: after a move the stored alias
      # differs from the current derivation for every record in the subtree,
      # which is indistinguishable from a hand-written one (#1890). Comparing
      # against the prior derivation separates them — a stale value matches it,
      # a pinned value matches neither.
      #
      # Absent for an operator's bulk run, which has no "before" and correctly
      # falls back to comparing against the current derivation.
      prior_ancestors: Keyword.get(opts, :prior_ancestors) || %{},
      include_pinned?: Keyword.get(opts, :include_pinned, false),
      on_progress: Keyword.get(opts, :on_progress, fn _summary -> :ok end),
      handle: handle
    }

    initial = %{scanned: 0, changes: [], pinned_skipped: 0, failed: []}

    summary =
      kind
      |> types(tenant)
      |> Enum.reduce(initial, fn ct, acc ->
        # ONE read per type, not one walk per record: every chain in the type
        # comes out of the same `(id, parent_id, slug)` rows. Walking per record
        # would make a subtree regeneration cost N × depth reads, which is the
        # fan-out D21 said to measure rather than assume.
        context = Map.put(context, :ancestors, ancestor_chains(ct, context))

        ct
        |> records(tenant, context.ids)
        |> Enum.reduce(acc, &step(ct, &1, &2, context))
      end)

    %{
      summary
      | changes: Enum.reverse(summary.changes),
        failed: Enum.reverse(summary.failed)
    }
    |> Map.put(:changed, length(summary.changes) - length(summary.failed))
  end

  defp step(ct, record, acc, context) do
    acc = %{acc | scanned: acc.scanned + 1}
    if rem(acc.scanned, 100) == 0, do: context.on_progress.(acc)

    case candidate(ct, record, context) do
      nil -> acc
      :pinned -> %{acc | pinned_skipped: acc.pinned_skipped + 1}
      change -> apply_change(acc, ct, record, change, context.handle)
    end
  end

  defp apply_change(acc, ct, record, change, handle) do
    acc = %{acc | changes: [change | acc.changes]}

    case handle.(ct, record, change) do
      :ok -> acc
      :error -> %{acc | failed: [change | acc.failed]}
    end
  end

  defp candidate(ct, record, %{field: :path_alias} = context) do
    %{tenant: tenant, include_pinned?: include_pinned?} = context
    pattern = ct.alias_pattern

    # A type with no alias pattern has nothing to derive: its aliases are
    # manual, and rewriting them from an absent pattern would blank live URLs.
    extra = Slugs.descriptor_token_definitions(ct, pattern, :alias, tenant)
    chain = Map.get(context.ancestors, record.id)

    derive =
      &(pattern &&
          KilnCMS.Slug.Pattern.expand_path(pattern, Slugs.record_context(record, &1), extra))

    derived = derive.(chain)
    # What the pattern WOULD have produced before the move. Defaults to the
    # current chain, so a run with no prior knowledge behaves exactly as the
    # slug path does.
    was_derived = derive.(Map.get(context.prior_ancestors, record.id, chain))

    current = Map.get(record, :path_alias)

    cond do
      is_nil(derived) ->
        nil

      # The author's value is one the pattern would not have produced at either
      # point. `-2` dedupe variants count as derived, as they do for slugs.
      not Slugs.underived?(current, was_derived) and not include_pinned? ->
        :pinned

      true ->
        new = unique_alias(derived, record, tenant)

        if new == current do
          nil
        else
          %{
            kind: to_string(ct.type),
            id: record.id,
            title: record.title,
            locale: record.locale,
            state: record.state,
            current: current,
            new: new,
            pinned?: not Slugs.underived?(current, was_derived)
          }
        end
    end
  end

  defp candidate(ct, record, %{tenant: tenant, include_pinned?: include_pinned?}) do
    # The type's own tokens (#804) must be in scope here, or `underived?/2`
    # below compares the stored slug against a derivation that never had them
    # and calls every record author-pinned.
    extra = Slugs.descriptor_token_definitions(ct, ct.slug_pattern, :slug, tenant)
    base = Slugs.derive_base(ct.slug_pattern, Slugs.record_context(record), extra)
    pinned? = not Slugs.underived?(record.slug, base)

    cond do
      base == "" ->
        nil

      pinned? and not include_pinned? ->
        :pinned

      true ->
        new = Slugs.ensure_unique(base, Slugs.unique_scope(ct, record, tenant))

        if new == record.slug do
          nil
        else
          %{
            kind: to_string(ct.type),
            id: record.id,
            title: record.title,
            locale: record.locale,
            state: record.state,
            current: record.slug,
            new: new,
            pinned?: pinned?
          }
        end
    end
  end

  # Every chain in the type, from one read: `id => [ancestor slug, …]` root
  # first. Only when an alias run's pattern actually names `[ancestors]` —
  # otherwise the map is dead weight and the read is waste.
  defp ancestor_chains(ct, %{field: :path_alias} = context) do
    if KilnCMS.Slug.Pattern.uses?(ct.alias_pattern, "ancestors") do
      rows =
        ct
        |> Slugs.storage_resource()
        |> Ash.Query.select([:id, :parent_id, :slug])
        # authorize?: false — a chain must include ancestors the caller cannot
        # read. A draft section still contributes its segment to a descendant's
        # path, and a read that skipped it would derive a DIFFERENT path than the
        # document gets once that ancestor publishes: a URL that moves on someone
        # else's workflow. Same gate as `records/3` below — a bulk admin/operator
        # tool, checked when the run was enqueued. Ids and slugs only.
        |> Ash.read!(authorize?: false, tenant: context.tenant)

      by_id = Map.new(rows, &{&1.id, &1})
      Map.new(rows, &{&1.id, chain_for(by_id, &1.parent_id, [], 0)})
    else
      %{}
    end
  end

  defp ancestor_chains(_ct, _context), do: %{}

  # Bounded by the tree's own cap plus one: a longer chain is a cycle, which is
  # not something a URL regeneration should discover by looping.
  defp chain_for(_by_id, nil, acc, _depth), do: acc

  defp chain_for(by_id, id, acc, depth) do
    if depth > KilnCMS.CMS.ContentTree.max_depth() do
      acc
    else
      case Map.get(by_id, id) do
        nil -> acc
        row -> chain_for(by_id, row.parent_id, [row.slug | acc], depth + 1)
      end
    end
  end

  # Alias collisions span every content table, so they cannot be a DB
  # constraint: dedupe on the last segment the way `Changes.DeriveAlias` does,
  # and with the same ceiling.
  defp unique_alias(alias_path, record, tenant) do
    taken? = &Slugs.alias_taken?(&1, record.locale, tenant, record.id)

    if taken?.(alias_path) do
      Enum.find_value(2..50, alias_path, fn n ->
        candidate = "#{alias_path}-#{n}"
        not taken?.(candidate) && candidate
      end)
    else
      alias_path
    end
  end

  defp types(:all, tenant), do: ContentTypes.all_for_org(tenant)
  defp types(kind, tenant), do: kind |> ContentTypes.get(tenant) |> List.wrap()

  defp records(ct, tenant, ids) do
    query =
      Slugs.storage_resource(ct)
      |> Ash.Query.load(:category)
      |> Ash.Query.sort(inserted_at: :asc)

    query = if is_list(ids), do: Ash.Query.filter(query, id in ^ids), else: query

    query =
      case ct do
        %{source: :dynamic, definition: definition} ->
          Ash.Query.filter(query, type_definition_id == ^definition.id)

        _compiled ->
          query
      end

    # authorize?: false — the regeneration has to see every record of the type,
    # drafts included, to rename them; the same admin/operator gate as `run/3`
    # applies. The system actor holds no content read by design (#1402).
    Ash.stream!(query, authorize?: false, tenant: tenant, batch_size: 100)
  end
end
