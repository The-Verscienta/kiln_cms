defmodule KilnCMS.CMS.Changes.RestoreVersion do
  @moduledoc """
  Restores a Page/Post's content fields to the state captured at a given
  PaperTrail version.

  Versions are tracked in `:changes_only` mode (each stores only what changed),
  so the full state at the target version is reconstructed by folding every
  version's `changes` from creation up to and including the target —
  `KilnCMS.CMS.VersionSnapshot`, shared with the version-compare UI (#467). The
  restore itself is captured as a new version.

  ## What moves

  Every editorial attribute the compare view reports, less workflow and
  attribution — the list is `KilnCMS.CMS.VersionFields.restorable_fields/1`, and
  it is derived from the same declaration the diff is, so the two can't drift
  apart again (#691). Values are force-changed rather than accepted, so the
  action takes no content input of its own; `Changes.EnforceFieldGrants` refuses
  the verb outright to a field-granted editor, because no param inspection can
  scope a write that never passed through params.

  ### A field the fold never wrote is restored to its default, not skipped

  `:changes_only` records an attribute only on the write that changed it, so a
  field first set *after* the target version has no key in the fold at all —
  and a field that predates its own migration has no key in any version below
  it. Leaving those alone is what #691 was filed about: the compare view reports
  `SEO title: — → Added later` and offers Restore, and the SEO title does not
  move. So an absent key restores the attribute's **default** (`nil` where there
  isn't one), which is exactly the value the record carried at that instant.

  ### `custom_fields` restores wholesale

  The stored map replaces the current one, so a key added after the target
  version is gone afterwards. That is what the compare view promises — it
  reports such a key as *added* between the two versions — and a key-wise merge
  would make that report a lie. The fold writes the map as it was stored, then
  `apply_custom_field_registry/2` runs it back through
  `Changes.ApplyCustomFields.apply_restored/2` (#710): against an EMPTY base, so
  the wholesale semantics hold, but with every registry pass an ordinary save
  gets — coercion, `:select` membership, media/reference resolution under the
  tenant, computed-field refresh from the restored document, and dropping keys
  for retired definitions. A restore therefore lands in a shape an ordinary save
  could also produce.

  ## References

  `category_id` and `featured_image_id` restore as raw ids, and the record they
  named may be gone. Rather than write a dangling reference (or half-restore the
  document and say nothing), a restore whose reference this org can no longer
  read fails with a field error naming the relationship.

  Every non-nil restored reference is checked, including one the record already
  carries. Skipping the unchanged ones would read the id off `changeset.data` —
  a caller-supplied struct that the editor LiveView holds across a whole session
  — so a reference another editor moved and trashed in the meantime would sail
  past the check on a stale comparison.

  The pairs aren't listed here: they're every `belongs_to` whose source attribute
  is restorable, read off the resource, so a future relationship is covered
  without a second list to forget.

  ## As the caller

  The history and the reference checks are read as the restoring actor
  (#1659), not around the policies: a restore can only put back what its
  caller may read. Each read uses `authorize_with: :error`, so a refusal raises
  a `Forbidden` rather than filtering — a filtered history would fold to an
  empty snapshot and restore every field to its default, and a filtered
  reference would read as "no longer exists".

  ## Planning and previewing

  `plan/3` is the whole of what a restore does to the changeset, as a function
  of the changeset and the target version, so the real action's `before_action`
  and `preview/3` run the very same code. A `%Plan{}` carries the planned
  changeset, the value each restorable attribute will be set to, the final
  `custom_fields` map, the stored custom keys the restore will DROP (no
  definition declares them any more) and the errors the restore would fail
  with. `preview/3` builds the changeset without running the action: it reads
  history and references as the caller and writes nothing, fires no
  notification and records no severity, because none of those hooks run.

  ## Re-validation

  Ash validations run while the changeset is built, and these writes land in a
  `before_action` hook — so a value from history reaches the row after every
  `validate` on the action has already passed. The ones that guard a *stored*
  value rather than user input are therefore re-run by hand once the fold has
  been applied: history is full of values that were legal when written and are
  not now (a `path_alias` another record has since claimed, a `canonical_url`
  predating `Validations.SeoUrls`).
  """
  use Ash.Resource.Change
  require Ash.Query

  alias KilnCMS.CMS.Changes.ApplyCustomFields
  alias KilnCMS.CMS.Validations
  alias KilnCMS.CMS.VersionFields
  alias KilnCMS.CMS.VersionSnapshot

  # Guard stored values, so a fold can violate them; re-run after the restore.
  # `ScheduleOrder` is deliberately absent — the schedule isn't restorable.
  @revalidate [
    Validations.SlugAvailable,
    Validations.PathAliasValid,
    Validations.SeoUrls
  ]

  @impl true
  def change(changeset, _opts, context) do
    version_id = Ash.Changeset.get_argument(changeset, :version_id)
    # `EnforceBlockFieldPolicy` exempts an id-less fold from its nested id
    # binding (#954), keyed on the action name `:restore_version` rather than
    # any flag we set — the action is `accept []` with only a `version_id`, so
    # the tree it writes is wholly our own vetted history. Nothing to mark here.
    Ash.Changeset.before_action(changeset, &plan(&1, version_id, context).changeset)
  end

  defmodule Plan do
    @moduledoc """
    What restoring a version will do: see `KilnCMS.CMS.Changes.RestoreVersion.plan/3`.

      * `:changeset` - the changeset with every restored value force-changed;
      * `:values` - the value each restorable attribute will hold afterwards;
      * `:custom_fields` - the final `custom_fields` map, after the registry
        pass (`nil` when the resource has no restorable `custom_fields`);
      * `:dropped` - stored custom-field keys with a non-blank value that no
        definition declares any more, so the restore discards them (sorted);
      * `:errors` - what the restore would fail with (empty when it would land).
    """
    defstruct [:changeset, values: %{}, custom_fields: nil, dropped: [], errors: []]

    @type t :: %__MODULE__{
            changeset: Ash.Changeset.t(),
            values: %{atom() => term()},
            custom_fields: map() | nil,
            dropped: [String.t()],
            errors: [term()]
          }
  end

  @doc """
  Plans the restore of `version_id` onto `changeset`: the restore itself, up to
  but not including the write. Used by the action's `before_action` and by
  `preview/3`, so a preview cannot disagree with the restore it previews.
  """
  @spec plan(Ash.Changeset.t(), Ash.UUID.t(), Ash.Resource.Change.Context.t()) :: Plan.t()
  def plan(changeset, version_id, context) do
    planned = apply_version(changeset, version_id, context)
    restorable = VersionFields.restorable_fields(changeset.resource)

    %Plan{
      changeset: planned,
      values: Map.new(restorable, &{&1, Ash.Changeset.get_attribute(planned, &1)}),
      custom_fields:
        if(:custom_fields in restorable,
          do: Ash.Changeset.get_attribute(planned, :custom_fields)
        ),
      dropped: planned.context[:kiln_restore_dropped] || [],
      errors: planned.errors
    }
  end

  @doc """
  The plan for restoring `version_id` onto `record`, without running the action.

  `opts` are the action's: `:actor` and `:tenant`. Policies are not evaluated
  here (that is the action's job); the history and reference reads inside the
  plan are, as the caller. Nothing is written.
  """
  @spec preview(struct(), Ash.UUID.t(), keyword()) :: Plan.t()
  def preview(record, version_id, opts) do
    changeset =
      Ash.Changeset.for_update(record, :restore_version, %{version_id: version_id}, opts)

    context = %Ash.Resource.Change.Context{
      actor: opts[:actor],
      tenant: opts[:tenant],
      authorize?: Keyword.get(opts, :authorize?, true)
    }

    plan(changeset, version_id, context)
  end

  defp apply_version(changeset, version_id, context) do
    version_module = Module.concat(changeset.resource, Version)
    source_id = changeset.data.id
    restorable = VersionFields.restorable_fields(changeset.resource)

    # Version twins are tenant-strict (#419) — reads carry the record org. As
    # the caller, failing closed: see "As the caller" in the moduledoc.
    read_opts =
      context
      |> Ash.Context.to_opts()
      |> Keyword.merge(tenant: changeset.data.org_id, authorize_with: :error)

    with {:ok, target} <- fetch_target(version_module, version_id, source_id, read_opts),
         {:ok, state} <- VersionSnapshot.at(version_module, source_id, target, read_opts) do
      changeset
      |> restore_fields(state, restorable)
      |> apply_custom_field_registry(restorable, context)
      |> revalidate(context)
      |> revalidate_alt_text(context)
      |> revalidate_claims(context)
      |> validate_references(restorable, read_opts)
    else
      :error ->
        Ash.Changeset.add_error(changeset,
          field: :version_id,
          message: "is not a version of this record"
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp fetch_target(version_module, version_id, source_id, read_opts) do
    version_module
    |> Ash.Query.filter(id == ^version_id and version_source_id == ^source_id)
    |> Ash.read_one(read_opts)
    |> case do
      {:ok, %{} = version} -> {:ok, version}
      {:ok, nil} -> :error
      {:error, error} -> {:error, error}
    end
  end

  # `custom_fields` restores as the raw stored map (`restore_fields/3`, wholesale
  # by design), which never passes through `Changes.ApplyCustomFields` on its own
  # (#710). Run the registry pass by hand once the fold has landed — the same
  # shape the `@revalidate` set uses for the "validates a stored value but runs
  # too early" problem — so a `:select` outside a since-narrowed list is caught,
  # computed fields refresh from the just-restored document, `:media`/`:reference`
  # ids resolve under the tenant (a trashed one fails the restore, like
  # `featured_image_id`), and a key whose definition was retired is dropped
  # rather than made publicly readable again. Only when `custom_fields` is
  # actually restorable for this resource.
  defp apply_custom_field_registry(changeset, restorable, context) do
    if :custom_fields in restorable do
      stored = Ash.Changeset.get_attribute(changeset, :custom_fields) || %{}
      restored = ApplyCustomFields.apply_restored(changeset, context)
      note_dropped_keys(restored, stored)
    else
      changeset
    end
  end

  # Robots flags (#2256) added after most history was written. A version from
  # before them has no key, and "what the record carried then" (`false`) would
  # make a page that has since been hidden from search engines indexable again
  # as a side effect of restoring its text. Absent means: leave the current
  # value alone. A snapshot that does carry the key restores it like any field.
  @keep_current_when_absent [:noindex, :nofollow]

  # The stored keys the registry pass just discarded: no definition declares
  # them (retired since the version was written). A blank value is not news.
  defp note_dropped_keys(changeset, stored) do
    declared =
      case ApplyCustomFields.stashed_definitions(changeset) do
        nil ->
          nil

        # A held field (#2605) is declared too: its value was kept.
        definitions ->
          MapSet.new(
            Enum.map(definitions, &to_string(&1.name)) ++
              ApplyCustomFields.held_names(changeset)
          )
      end

    dropped =
      if declared do
        stored
        |> Enum.reject(fn {key, value} ->
          MapSet.member?(declared, to_string(key)) or blank?(value)
        end)
        |> Enum.map(fn {key, _value} -> to_string(key) end)
        |> Enum.sort()
      else
        []
      end

    Ash.Changeset.set_context(changeset, %{kiln_restore_dropped: dropped})
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(value) when is_map(value), do: map_size(value) == 0
  defp blank?(_value), do: false

  defp restore_fields(changeset, state, restorable) do
    Enum.reduce(restorable, changeset, &restore_field(&2, &1, state))
  end

  defp restore_field(changeset, name, state) do
    if name in @keep_current_when_absent and not Map.has_key?(state, to_string(name)) do
      changeset
    else
      # Values arrive in the shape PaperTrail stored (JSON), which
      # `force_change_attribute/3` casts back.
      value = Map.get_lazy(state, to_string(name), fn -> default(changeset.resource, name) end)
      value = changeset |> restorable_value(name, value) |> upcast_blocks(name)
      Ash.Changeset.force_change_attribute(changeset, name, value)
    end
  end

  # A working copy is only meaningful beside a published text
  # (`KilnCMS.CMS.WorkingCopy`): restoring a version from a record's live period
  # onto the draft it has since become would leave a shadow the draft's own
  # autosave never clears. `state` is not restorable, so `changeset.data.state`
  # is the effective one.
  @working_copy_fields [
    :working_title,
    :working_blocks,
    :working_fields,
    :working_base,
    :working_copy_at
  ]

  defp restorable_value(%{data: %{state: :published}}, name, value)
       when name in [:working_fields, :working_base],
       do: value || %{}

  defp restorable_value(%{data: %{state: :published}}, _name, value), do: value
  defp restorable_value(_changeset, :working_blocks, _value), do: []

  defp restorable_value(_changeset, name, _value) when name in [:working_fields, :working_base],
    do: %{}

  defp restorable_value(_changeset, name, _value) when name in @working_copy_fields, do: nil
  defp restorable_value(_changeset, _name, value), do: value

  # A version from before the storage flip holds its block tree in the
  # pre-typed `type`/`content`/`data` shape, and history is hash-chained, so it
  # stays that way. The write cast refuses that shape since 1.0 (#1543), so the
  # tree goes through the read conversion first — the same one every read of
  # that version already shows — and is written back typed. A post-flip
  # snapshot (union `type`/`value` envelopes) converts to itself.
  @block_trees [:blocks, :working_blocks]

  defp upcast_blocks(value, name) when name in @block_trees and is_list(value) do
    value
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> Enum.map(&KilnCMS.CMS.TypedBlocks.input_map/1)
  end

  defp upcast_blocks(value, _name), do: value

  # The value the attribute held before anything wrote it — which is what the
  # record carried at a version whose fold has no key for it.
  defp default(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      %{default: fun} when is_function(fun, 0) -> fun.()
      %{default: {module, function, args}} -> apply(module, function, args)
      %{default: value} -> value
      nil -> nil
    end
  end

  # ── Re-validation ─────────────────────────────────────────────────────────

  defp revalidate(changeset, context) do
    Enum.reduce(@revalidate, changeset, fn module, acc ->
      case module.validate(acc, [], context) do
        :ok -> acc
        {:error, error} -> Ash.Changeset.add_error(acc, error)
      end
    end)
  end

  # Restoring `blocks` onto a PUBLISHED record can ship an alt-less image just
  # as an ordinary edit can (#722). This action force-changes blocks in a
  # `before_action`, so the publish gate (a plain `validate`) never sees them —
  # re-run it by hand after the fold, like the `@revalidate` set. Gated on the
  # record being published, since a draft restore makes no public claim and
  # `state` isn't restorable, so `changeset.data.state` is the effective state.
  defp revalidate_alt_text(changeset, context) do
    if changeset.data.state == :published do
      # `only_new: true`, like the `:update` gate: a restore that reintroduces an
      # image already live undescribed is not this write's doing, but one that
      # brings back an undescribed image the current page had fixed is refused.
      case Validations.MediaAltText.validate(changeset, [only_new: true], context) do
        :ok -> changeset
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    else
      changeset
    end
  end

  # Exactly the same hole for claim checking (#377): this action force-changes
  # `blocks`, `title`, `seo_title` and `seo_description` in a `before_action`,
  # so the plain `validate` on `:update` has already run, and `:restore_version`
  # fires artifacts of its own when the record is published. Restoring a live
  # page to a version that said "government approved" would put the claim back on the
  # public site having passed no gate at all.
  #
  # `only_new: true` for the same reason as above: restoring a claim that is
  # already live is not this write's doing.
  defp revalidate_claims(changeset, context) do
    if changeset.data.state == :published do
      case Validations.ComplianceClaims.validate(changeset, [only_new: true], context) do
        :ok -> changeset
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    else
      changeset
    end
  end

  # ── References ────────────────────────────────────────────────────────────

  defp validate_references(changeset, restorable, read_opts) do
    changeset.resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&(&1.type == :belongs_to and &1.source_attribute in restorable))
    |> Enum.reduce(changeset, &check_reference(&2, &1, read_opts))
  end

  defp check_reference(changeset, relationship, read_opts) do
    id = Ash.Changeset.get_attribute(changeset, relationship.source_attribute)

    cond do
      is_nil(id) ->
        changeset

      reference_exists?(relationship, id, read_opts) ->
        changeset

      true ->
        Ash.Changeset.add_error(changeset,
          field: relationship.source_attribute,
          message: "from that version no longer exists"
        )
    end
  end

  # Through the destination's primary read, so a soft-deleted record reads as
  # gone: an archived media item's row survives, and the FK would accept it, but
  # restoring a featured image the editor has trashed just puts a broken hero
  # back on the page. Deliberately unrescued — an unreadable destination or a
  # dropped connection is not evidence that the record was deleted, and
  # answering "no longer exists" to a pool timeout tells the editor to go hunting
  # for an image that is sitting in the media library. Read as the caller with
  # `authorize_with: :error` (#1659) for the same reason: a row the caller may
  # not read raises `Forbidden` rather than answering "no longer exists".
  # `Ash.exists?` cannot take `authorize_with`, hence the one-row read.
  defp reference_exists?(relationship, id, read_opts) do
    destination_attribute = relationship.destination_attribute

    relationship.destination
    |> Ash.Query.filter(^ref(destination_attribute) == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(read_opts)
    |> is_struct()
  end
end
