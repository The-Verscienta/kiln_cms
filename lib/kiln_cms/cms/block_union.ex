defmodule KilnCMS.CMS.BlockUnion do
  @moduledoc """
  The typed-block storage type (Kiln v2 — decision D11): an `Ash.Type.Union` over
  the typed block embedded resources, tagged by the `_type` discriminator.

  This is the canonical container for a document's block tree. It is decided over
  `polymorphic_embed` to stay within Ash idioms (no extra dependency). Members are
  the `Kiln.Block` modules; `KilnCMS.Blocks` is the registry they come from.

  Storage uses the default `:type_and_value` shape (`%{"type" => ..., "value" =>
  ...}`); at runtime each element is an `%Ash.Union{type: atom, value: struct}`.

  > The on-disk `Page.blocks`/`Post.blocks` columns still hold the legacy
  > `KilnCMS.CMS.Block` shape; `KilnCMS.CMS.TypedBlocks` bridges legacy → typed so
  > firing/search/embeddings (Phases D–J) operate on this typed representation.
  > Flipping the stored column + the native-union editor is the remaining Phase C
  > increment.
  """
  # The member list is the compile-time union of core + plugin blocks (D18) —
  # see `KilnCMS.Blocks.union_types/0`. A plugin's `blocks/0` joins storage,
  # the editor palette, and firing with no core edits.
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [types: KilnCMS.Blocks.union_types()]

  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.CMS.TypedBlocks.InvalidChildBlockError

  # Tolerant casts (Kiln v2 storage flip): accept legacy block params and legacy
  # stored rows by normalizing them to the typed shape before the union cast. This
  # keeps existing callers/tests working and converts old rows lazily on read — no
  # data migration required.
  #
  # `TypedBlocks.to_union_input/1` (via `sanitize_children/2`) also validates
  # every nested child through the same Ash cast a top-level block gets, and
  # raises `InvalidChildBlockError` on a violation (#935) — a plain map-transform
  # function has no error channel of its own, so the rescue here is what turns
  # that back into the ordinary `{:error, ...}` cast failure a caller expects.
  #
  # The rescue returns `e.errors` — the original Ash/Splode exception(s) the
  # nested cast failed with — rather than a formatted string. `Ash.Changeset`'s
  # `add_invalid_errors/5` recognizes a list of exceptions and adds each one as
  # its own error (preserving its own `field`/class), so a nested validation
  # failure surfaces with the same per-field error shape a top-level one already
  # gets, instead of collapsing to one generic `InvalidAttribute` on `:blocks`.
  #
  # KNOWN COST (deliberately not fixed here, see the code-review pass after
  # #935): `Ash.Changeset.do_change_attribute/3` runs `prepare_change` then
  # `cast_input` in sequence for every attribute *update* (not create, which
  # skips `prepare_change` entirely), and the real `Ash.Type.Union` array cast
  # additionally dispatches `cast_input/2` per element from inside
  # `cast_input_array/2` — so `TypedBlocks.to_union_input/1` (and, for a
  # `columns` block, the full nested-child validation it triggers) runs twice
  # on create and three times on update for the *same* input, confirmed by
  # tracing actual call counts. It is idempotent (the same input always
  # produces the same validated output), so this is a real but purely
  # performance cost, not a correctness one.
  #
  # A caching fix was considered and deliberately deferred: `Ash.Type`
  # callbacks receive only `(value, constraints)`, not the changeset, so there
  # is no changeset-scoped place to memoize a result across the three calls.
  # The alternative — a marker on the map saying "already validated, skip
  # me" — cannot be made safe: an attacker's own JSON payload could set that
  # same marker to smuggle an invalid nested child STRAIGHT PAST validation,
  # which is the exact vulnerability #935 exists to close. A content-addressed
  # cache (keyed by a hash of the exact input, so a hit can only ever return a
  # result this process already validated) would be safe but adds real
  # complexity — and unbounded memory growth risk in a long-lived process — for
  # a call-count optimization on a security-critical write path. Reusing the
  # cast struct instead of discarding it (below) removes the redundant *work*
  # each of those extra passes was doing on top of everything else; it does not
  # reduce how many times they run.
  @impl Ash.Type
  def cast_input(value, constraints) do
    value |> TypedBlocks.to_union_input() |> super(constraints)
  rescue
    e in InvalidChildBlockError -> {:error, e.errors}
  end

  @impl Ash.Type
  def cast_input_array(list, constraints) when is_list(list) do
    list |> Enum.map(&TypedBlocks.to_union_input/1) |> super(constraints)
  rescue
    e in InvalidChildBlockError -> {:error, e.errors}
  end

  def cast_input_array(other, constraints), do: super(other, constraints)

  # Updating an EXISTING embedded block (id set) routes through the union's
  # prepare_change/handle_change with the RAW input maps — cast_input's
  # normalization never sees them — and the member resource's update cast then
  # rejects e.g. a rich_text body posted as TipTap JSON. Normalize here too (see
  # the `cast_input/2` note above for the `InvalidChildBlockError` rescue).
  @impl Ash.Type
  def prepare_change(old_value, new_value, constraints) when is_list(new_value) do
    super(old_value, Enum.map(new_value, &TypedBlocks.to_union_input/1), constraints)
  rescue
    e in InvalidChildBlockError -> {:error, e.errors}
  end

  def prepare_change(old_value, new_value, constraints) do
    super(old_value, TypedBlocks.to_union_input(new_value), constraints)
  rescue
    e in InvalidChildBlockError -> {:error, e.errors}
  end

  @impl Ash.Type
  def handle_change_array?, do: true

  @impl Ash.Type
  def prepare_change_array(old_values, new_values, constraints) when is_list(new_values) do
    super(old_values, Enum.map(new_values, &TypedBlocks.to_union_input/1), constraints)
  rescue
    e in InvalidChildBlockError -> {:error, e.errors}
  end

  def prepare_change_array(old_values, new_values, constraints),
    do: super(old_values, new_values, constraints)

  @impl Ash.Type
  def cast_stored(value, constraints),
    do: value |> TypedBlocks.to_union_stored() |> super(constraints)

  @impl Ash.Type
  def cast_stored_array(list, constraints) when is_list(list),
    do: list |> Enum.map(&TypedBlocks.to_union_stored/1) |> super(constraints)

  def cast_stored_array(other, constraints), do: super(other, constraints)
end
