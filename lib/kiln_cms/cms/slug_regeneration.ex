defmodule KilnCMS.CMS.SlugRegeneration do
  @moduledoc """
  Bulk slug regeneration (#455) — pathauto's "update all aliases".

  Re-derives every record's slug through the same `Slugs.derive_base/2` chain
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

    reduce(kind, tenant, opts, fn ct, record, change ->
      case ContentTypes.update(ct, record, %{slug: change.new},
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
      include_pinned?: Keyword.get(opts, :include_pinned, false),
      on_progress: Keyword.get(opts, :on_progress, fn _summary -> :ok end),
      handle: handle
    }

    initial = %{scanned: 0, changes: [], pinned_skipped: 0, failed: []}

    summary =
      kind
      |> types(tenant)
      |> Enum.reduce(initial, fn ct, acc ->
        ct
        |> records(tenant)
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

    case candidate(ct, record, context.tenant, context.include_pinned?) do
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

  defp candidate(ct, record, tenant, include_pinned?) do
    base = Slugs.derive_base(ct.slug_pattern, Slugs.record_context(record))
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

  defp types(:all, tenant),
    do: ContentTypes.all() ++ ContentTypes.dynamic_all(org_id(tenant))

  defp types(kind, tenant), do: kind |> ContentTypes.get(org_id(tenant)) |> List.wrap()

  defp records(ct, tenant) do
    query =
      Slugs.storage_resource(ct)
      |> Ash.Query.load(:category)
      |> Ash.Query.sort(inserted_at: :asc)

    query =
      case ct do
        %{source: :dynamic, definition: definition} ->
          Ash.Query.filter(query, type_definition_id == ^definition.id)

        _compiled ->
          query
      end

    Ash.stream!(query, authorize?: false, tenant: tenant, batch_size: 100)
  end

  defp org_id(%{id: id}), do: id
  defp org_id(tenant) when is_binary(tenant), do: tenant
  defp org_id(_tenant), do: KilnCMS.Accounts.default_org_id()
end
