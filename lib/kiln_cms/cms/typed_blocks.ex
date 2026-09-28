defmodule KilnCMS.CMS.TypedBlocks do
  @moduledoc """
  The Kiln v2 typed block representation (decision D11): converting whatever is
  stored or submitted into typed block structs and union input.

  `to_typed/1` is the canonical read-direction conversion that firing,
  rendering, search, history and embeddings use to obtain typed block structs
  from whatever is stored — typed or legacy. It is **total**: any legacy/unknown
  block maps to `KilnCMS.Blocks.Custom` so downstream serializers never crash
  (decision A4). It keeps reading the pre-typed `type`/`content`/`data` shape:
  version history is hash-chained and never rewritten, and
  `mix kiln.blocks.backfill` (`KilnCMS.CMS.BlockBackfill`) reports, rather than
  rewrites, a row it cannot convert without loss.

  **The write side of the legacy bridge was removed at 1.0 (#1543)**, after 0.12
  deprecated it (#1537): `to_legacy/1`, `from_legacy/1` (use `to_typed/1`), the
  the `KilnCMS.CMS.Block` embedded resource, and the legacy shape as write input —
  `to_union_input/1` raises `LegacyInputError` for it, which `BlockUnion` turns
  into a cast error. Write the typed shape (`%{"_type" => "heading", "text" =>
  …}`).

  Stored legacy blocks are plain maps, atom- or string-keyed (nested `children`
  come back from jsonb string-keyed), so the accessors tolerate both.
  """

  alias KilnCMS.Blocks.{Accordion, Claim, Columns, Custom, Divider, Embed, Faq, Form}
  alias KilnCMS.Blocks.{Gallery, Heading, HowTo, Image, Quote, RichText}
  alias KilnCMS.HTMLSanitizer

  defmodule InvalidChildBlockError do
    @moduledoc """
    Raised by `TypedBlocks.sanitize_children/2` when a nested block child fails
    the same Ash cast a top-level block already goes through — e.g. a `field
    ..., required: true` (`allow_nil?: false`) attribute is missing (#935).

    `struct_from_typed_map/1` used to rebuild a container's children with a bare
    `struct/2`, which never ran that cast, so a required nested field could be
    `nil` in delivery while the same block at the top level could not. Raising
    here and rescuing at `KilnCMS.CMS.BlockUnion`'s cast entry points turns that
    into an ordinary `{:error, ...}` cast failure, so an invalid nested child
    fails the whole write exactly like an invalid top-level block does, instead
    of being silently stored with the gap.
    """
    defexception [:block_type, :errors]

    @impl true
    def message(%{block_type: type, errors: errors}) do
      "nested #{type} block is invalid: " <> format_errors(errors)
    end

    defp format_errors(errors) do
      Enum.map_join(errors, "; ", fn
        # The common shape: `Ash.Type.cast_input` on an embedded resource
        # returns a list of Splode exception structs (`Ash.Error.Changes.Required`
        # for a missing `required: true` field, `Ash.Error.Changes.InvalidAttribute`
        # for a constraint violation, ...), not keyword lists — the clause below
        # never matched them, so this fell through to `inspect(other)` and leaked
        # a raw struct dump instead of a human-readable message.
        # `Exception.message/1` also substitutes any Splode `:vars` into the
        # message template, so a constraint error's `%{min}`-style placeholder
        # comes back with the real value rather than the literal token.
        error when is_exception(error) -> Exception.message(error)
        kw when is_list(kw) -> "#{Keyword.get(kw, :field)}: #{Keyword.get(kw, :message)}"
        other -> inspect(other)
      end)
    end
  end

  defmodule LegacyInputError do
    @moduledoc """
    Raised by `TypedBlocks.to_union_input/1` for a block written in the
    pre-typed `Block` shape (`%{type: :heading, content: …, data:
    …}`). 0.12 deprecated that write shape and 1.0 removed it (#1543); write
    the typed shape (`%{"_type" => "heading", "text" => …}`) instead.

    Rescued at every `KilnCMS.CMS.BlockUnion` cast entry point and turned into
    an ordinary cast error, like `InvalidChildBlockError`. Stored rows in the
    legacy shape are unaffected: the read direction still converts them.
    """
    defexception [:block]

    @impl true
    def message(%{block: block}) do
      type = Map.get(block, :type) || Map.get(block, "type")

      "a #{inspect(to_string(type))} block is in the legacy `type`/`content`/`data` shape, " <>
        "which 1.0 no longer accepts (#1543); write the typed shape, tagged with `_type`"
    end
  end

  # Guards recursion for the nested `columns` block: hostile API input can't force
  # unbounded nesting on cast (columns nested past this depth are dropped). The
  # editor caps nesting well below this, so real content is never affected.
  @max_nesting 5

  # Every block module in the storage union — core + plugin (D18), from the
  # same compile-time source as `BlockUnion` itself.
  @block_modules Enum.map(KilnCMS.Blocks.union_types(), fn {_name, opts} -> opts[:type] end)

  # String `_type` → atom, for *registered* block types only (core + plugin).
  # Used both by the legacy/typed-map struct builder below and by nested-child
  # write validation (`validate_child!/2`) to tell "unrecognized type" (left
  # untouched — it becomes `Custom` lazily on read, same as any unknown legacy
  # block) from "known type, invalid data" (rejected on write, see
  # `InvalidChildBlockError`).
  @type_atoms Map.new(KilnCMS.Blocks.union_types(), fn {name, _opts} ->
                {to_string(name), name}
              end)

  # Type atom → the union member's declared constraints, for `cast_child!/3`
  # (currently none do, but a future one might). Hoisted alongside
  # `@block_modules`/`@type_atoms` from the same compile-time source rather
  # than calling `KilnCMS.Blocks.union_types()` fresh per nested cast.
  @type_constraints Map.new(KilnCMS.Blocks.union_types(), fn {name, opts} ->
                      {name, Keyword.get(opts, :constraints, [])}
                    end)

  @doc """
  Normalize any block representation to typed block structs.

  Handles legacy maps/structs, typed maps (`_type`), typed structs, and the
  `%Ash.Union{}` wrapper produced once `blocks` is stored as `BlockUnion`. This is
  what firing/search/history/delivery call so they are agnostic to how a block was
  obtained.
  """
  @spec to_typed([term()] | nil) :: [struct()]
  def to_typed(blocks), do: blocks |> List.wrap() |> Enum.map(&one_to_typed/1)

  defp one_to_typed(%Ash.Union{value: value}), do: one_to_typed(value)

  # An `Ash.Union` that has been through JSON — `%{"type" => tag, "value" => …}`
  # — which is how a union lands in a paper-trail version's freeform `changes`
  # map. Without this clause it misses `typed_map?/1` (the `_type` tag is one
  # level down), falls through to the legacy branch, and every block in a
  # replayed document comes back as `Custom` (#917).
  #
  # That is why a point-in-time read rendered a bare `<!-- fragment block -->`:
  # `Fragments.expand/3` never saw a `%Fragment{}` to expand. It was mis-typing
  # every OTHER block the same way, silently, since replay existed.
  #
  # `map_size/1` pins the shape: the serialized union has exactly these two
  # keys, while a legacy block carries its kind in `"type"` alongside its own
  # attributes, so a bare size check is what keeps the two apart.
  defp one_to_typed(%{"type" => _tag, "value" => %{} = value} = map) when map_size(map) == 2,
    do: one_to_typed(value)

  defp one_to_typed(%mod{} = struct) when mod in @block_modules, do: struct
  defp one_to_typed(%{} = map), do: one_from_typed_or_legacy(map)
  defp one_to_typed(_other), do: %Custom{_type: "custom", data: %{}}

  defp one_from_typed_or_legacy(map) do
    map = normalize_rich_text_map(map)
    if typed_map?(map), do: struct_from_typed_map(map), else: one_from_legacy(map)
  end

  # The editor's form carries `body` as a JSON string of the live TipTap doc;
  # normalize it here too (not only in the cast) so the in-editor preview —
  # which routes unsaved form values through `to_typed/1` — renders the prose
  # being typed rather than falling back to an empty legacy_html.
  defp normalize_rich_text_map(%{} = map) do
    if (map["_type"] || map[:_type]) in ["rich_text", :rich_text] do
      cond do
        Map.has_key?(map, "body") -> Map.update!(map, "body", &normalize_body/1)
        Map.has_key?(map, :body) -> Map.update!(map, :body, &normalize_body/1)
        true -> map
      end
    else
      map
    end
  end

  # ── BlockUnion cast normalization (legacy/stored-shape tolerance) ──────────
  # These keep `BlockUnion` accepting legacy block params (no test churn) and
  # legacy stored rows (lazy conversion, no data migration).

  @doc false
  # cast_input target: a tag-shaped map (`%{"_type" => name, ...attrs}`) the union
  # matches by its `_type` tag. Everything is sanitized (this is user input).
  #
  # Can RAISE `InvalidChildBlockError` (not reflected in a `!` suffix, since
  # every `KilnCMS.CMS.BlockUnion` cast entry point rescues it right at the
  # call site — see the note on each there) when `value` contains a `columns`
  # child that fails the same Ash cast a top-level block goes through (#935).
  def to_union_input(nil), do: nil

  def to_union_input(value) do
    if legacy_input?(value), do: raise(LegacyInputError, block: value)

    case typed_attrs(value) do
      {nil, _attrs} ->
        value

      {name, attrs} ->
        attrs |> Map.put("_type", name) |> adopt_artifact_id() |> sanitize_attrs() |> drop_nils()
    end
  end

  @doc false
  # The fired `:json` artifact names a block's id `_id`, not `id`
  # (`KilnCMS.Blocks.render/2`), because blocks are `_type`-tagged maps that
  # otherwise drop identity. That is the only surface on which a headless client
  # can read a block's id at all — `blocks` is not `public?`, and GraphQL and
  # JSON:API both hide it.
  #
  # So the one way such a client can round-trip ids is to read the artifact and
  # send it back, and that did not work: the write path reads `id`, so every
  # block arrived id-less (fresh ids minted, judged as new) while `_id` was
  # carried into storage as a junk key nothing reads (#954).
  #
  # Accepting it closes the loop for published content, at both levels — a
  # nested child's `_id` is emitted the same way, since `Columns` renders its
  # children through the same function.
  #
  # An explicit `id` wins: a client that knows the real name means it.
  defp adopt_artifact_id(%{} = attrs) do
    case {Map.get(attrs, "id"), Map.pop(attrs, "_id")} do
      {nil, {artifact_id, rest}} when is_binary(artifact_id) and artifact_id != "" ->
        Map.put(rest, "id", artifact_id)

      {_present, {_artifact_id, rest}} ->
        rest
    end
  end

  @doc false
  # cast_stored target: the `:type_and_value` envelope (`%{"type" => name,
  # "value" => attrs}`). Stored data is already sanitized, so we don't re-sanitize.
  def to_union_stored(nil), do: nil

  def to_union_stored(value) do
    envelope =
      if stored_envelope?(value) do
        value
      else
        case typed_attrs(value) do
          {nil, _attrs} -> value
          {name, attrs} -> %{"type" => name, "value" => drop_nils(attrs)}
        end
      end

    park_unreadable(envelope)
  end

  # Delivery must never crash on what is stored (decision A4, #1543). Two things
  # the union cannot load used to raise out of every read of their row: a block
  # of a type this build does not have — typically from a plugin since removed —
  # and an element that is not a block at all. Both are rows the backfill
  # refuses (`:unknown_type`, `:unrecognized`), so both stay at rest. On read
  # each becomes a `custom` block carrying the payload whole, which renders as a
  # marker comment; the row itself is not rewritten.
  defp park_unreadable(%{"type" => type, "value" => %{}} = envelope)
       when is_map_key(@type_atoms, type),
       do: envelope

  defp park_unreadable(%{"type" => type, "value" => %{} = attrs}) when is_binary(type),
    do: custom_envelope(type, attrs)

  defp park_unreadable(%{} = other), do: custom_envelope(nil, other)
  defp park_unreadable(_not_a_map), do: custom_envelope(nil, %{})

  defp uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp custom_envelope(legacy_type, %{} = payload) do
    %{
      "type" => "custom",
      "value" =>
        drop_nils(%{
          "_type" => "custom",
          "id" => uuid(payload["id"]),
          "legacy_type" => legacy_type,
          "data" => Map.drop(payload, ["id", "_type", "_version"])
        })
    }
  end

  defp drop_nils(%{} = map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  # Returns {type_name :: String.t() | nil, attrs :: %{String.t() => term()}}.
  defp typed_attrs(%Ash.Union{type: type, value: %_{} = value}),
    do: {to_string(type), attrs_of(value)}

  defp typed_attrs(%mod{} = struct) when mod in @block_modules,
    do: {struct._type, attrs_of(struct)}

  defp typed_attrs(%{} = map) do
    cond do
      typed_map?(map) -> {to_string(get(map, :_type)), stringify(map)}
      stored_envelope?(map) -> {to_string(get(map, :type)), stringify(get(map, :value))}
      legacy_map?(map) -> map |> one_from_legacy() |> typed_attrs()
      true -> {nil, map}
    end
  end

  defp typed_attrs(_other), do: {nil, %{}}

  defp attrs_of(%mod{} = struct) do
    keys = [:id, :_type, :_version | Enum.map(Kiln.Block.Info.fields(mod), & &1.name)]
    Map.new(keys, fn key -> {to_string(key), Map.get(struct, key)} end)
  end

  defp typed_map?(map), do: not is_nil(get(map, :_type))

  defp stored_envelope?(%{} = map),
    do: not is_nil(get(map, :value)) and not is_nil(get(map, :type))

  defp stored_envelope?(_), do: false

  defp legacy_map?(%{} = map), do: not is_nil(get(map, :type))

  # A write in the pre-typed `Block` shape (`type`/`content`/`data`),
  # which 0.12 deprecated and 1.0 refuses (#1543). A struct or `%Ash.Union{}`
  # never is one; neither is a typed map or a stored `type`/`value` envelope
  # (what a paper-trail version holds, which a restore writes back).
  defp legacy_input?(%_{}), do: false

  defp legacy_input?(%{} = map),
    do: not typed_map?(map) and not stored_envelope?(map) and legacy_map?(map)

  defp legacy_input?(_other), do: false

  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}

  defp sanitize_attrs(%{"_type" => "rich_text"} = m) do
    m = Map.update(m, "body", nil, &normalize_body/1)

    case m["body"] do
      [_ | _] ->
        # Portable Text is authoritative once present: the editor writes body
        # (TipTap JSON, converted above), so a stale legacy_html copy must not
        # shadow it in render fallbacks or linger as a second source of truth.
        m
        |> Map.put("legacy_html", nil)
        |> Map.update("body", nil, &KilnCMS.Blocks.PortableText.sanitize_body/1)

      _ ->
        m
        |> Map.update("legacy_html", nil, &HTMLSanitizer.sanitize_rich_text/1)
        |> Map.update("body", nil, &KilnCMS.Blocks.PortableText.sanitize_body/1)
    end
  end

  defp sanitize_attrs(%{"_type" => "image"} = m),
    do: Map.update(m, "url", nil, &(HTMLSanitizer.safe_image_src(&1) || ""))

  # Keeps the author's URL rather than rewriting it to a player URL (#489).
  #
  # This used to run `safe_embed_url/1`, which knows two hosts and rewrites
  # them — so a stored embed URL was a canonical YouTube/Vimeo player URL or the
  # empty string, and everything else an author pasted was destroyed on save.
  # Whether a URL may be *framed* is a render-time question both surfaces
  # already ask; making it the storage filter as well meant nothing downstream
  # could ever see what was actually embedded.
  #
  # The metadata fields are resolved server-side, but they are ordinary block
  # scalars — the editor's generic field renderer offers them as inputs and a
  # headless `block_tree` write can set them directly — so they are filtered
  # here on the same footing as anything else an author can type. In particular
  # `thumbnail_url` becomes an `<img src>`: without this, "checked against the
  # provider's CDN when it was resolved" would be true only of values that
  # actually came from a resolve.
  defp sanitize_attrs(%{"_type" => "embed"} = m) do
    m
    |> Map.update("url", nil, &(HTMLSanitizer.safe_external_url(&1) || ""))
    |> Map.update("thumbnail_url", nil, &KilnCMS.OEmbed.allowed_thumbnail(&1))
  end

  # A `gallery`'s urls live one level down, inside an `{:array, :map}` field, so
  # the `image` clause above never sees them. Without this a gallery item is the
  # one image url on the write path that reaches storage unfiltered — a
  # `javascript:` src straight through to delivery (#482).
  defp sanitize_attrs(%{"_type" => "gallery"} = m) do
    Map.update(m, "images", [], fn
      images when is_list(images) -> Enum.map(images, &sanitize_gallery_image/1)
      _other -> []
    end)
  end

  # A `columns` container: sanitize each child block through the same typed-input
  # pipeline a top-level block uses, so nested rich_text/image/embed are cleaned.
  defp sanitize_attrs(%{"_type" => "columns"} = m), do: sanitize_columns_block(m, 1)

  defp sanitize_attrs(m), do: m

  # String-keyed and url-filtered, whatever shape came in.
  #
  # Keys are normalized first because atom-keyed image maps are a real input —
  # seeds, in-Elixir importers and plugins all produce them, and
  # `KilnCMS.Blocks.Gallery.images/1` deliberately reads either. Updating only
  # the `"url"` key would leave an atom-keyed `:url` untouched *and* insert a
  # nil `"url"` beside it, so the unfiltered value is the one that wins on read
  # — reaching the fired JSON artifact, which is precisely the consumer the
  # sanitizer exists for (the HTML paths re-filter on the way out; JSON does
  # not).
  defp sanitize_gallery_image(image) when is_map(image) do
    image
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.update("url", "", fn
      url when is_binary(url) -> HTMLSanitizer.safe_image_src(url) || ""
      # A number or an object is not a url. Blanking it keeps a malformed API
      # write a no-op rather than a `FunctionClauseError` 500 out of cast.
      _other -> ""
    end)
  end

  defp sanitize_gallery_image(other), do: other

  # The editor's hidden input posts body as a JSON string of the live TipTap
  # document; the API/imports post decoded Portable Text. Normalize all input
  # shapes to a PT list: JSON strings are decoded, a TipTap doc is converted
  # (PortableText.from_tiptap/1), a PT list passes through.
  defp normalize_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> normalize_body(decoded)
      _ -> []
    end
  end

  defp normalize_body(%{"type" => "doc"} = doc), do: KilnCMS.Blocks.PortableText.from_tiptap(doc)
  defp normalize_body(body) when is_list(body), do: body
  defp normalize_body(_), do: []

  defp sanitize_columns_block(m, depth) do
    Map.update(m, "columns", [], fn cols ->
      cols
      |> List.wrap()
      |> Enum.map(fn
        %{} = col -> Map.update(col, "blocks", [], &sanitize_children(&1, depth))
        _ -> %{"blocks" => []}
      end)
    end)
  end

  defp sanitize_children(blocks, depth) do
    blocks
    |> List.wrap()
    |> Enum.flat_map(fn child ->
      case typed_attrs(child) do
        {nil, _attrs} ->
          []

        # A nested columns child recurses with the depth guard (bypassing the
        # sanitize_attrs columns clause, which would reset depth to 1).
        {"columns", _attrs} when depth >= @max_nesting ->
          []

        {"columns", attrs} ->
          [
            attrs
            |> Map.put("_type", "columns")
            |> adopt_artifact_id()
            |> sanitize_columns_block(depth + 1)
            |> drop_nils()
            |> validate_child!("columns")
          ]

        {name, attrs} ->
          [
            attrs
            |> Map.put("_type", name)
            |> adopt_artifact_id()
            |> sanitize_attrs()
            |> drop_nils()
            |> validate_child!(name)
          ]
      end
    end)
  end

  # Runs the SAME Ash cast a top-level block goes through (via `BlockUnion` →
  # `Ash.Type.Union.cast_input` → the embedded resource's `:create` action) on
  # a nested child, so `allow_nil?: false` (`field ..., required: true`), type
  # coercion, and any other Ash-level constraint apply to a nested block exactly
  # as they already do to a top-level one (#935). Raises `InvalidChildBlockError`
  # on failure — caught at `KilnCMS.CMS.BlockUnion`'s cast entry points and
  # turned into a normal cast error, so an invalid nested child fails the whole
  # write rather than being silently stored with a gap.
  #
  # An unregistered `name` (a plugin not currently installed, or a genuinely
  # unknown `_type`) is left untouched — there is no embedded resource to cast
  # against, and that already-existing "becomes Custom on read" tolerance
  # (`struct_from_typed_map/1`) is unrelated to this issue.
  defp validate_child!(attrs, name) do
    case Map.fetch(@type_atoms, name) do
      {:ok, type_atom} ->
        case KilnCMS.Blocks.fetch(type_atom) do
          {:ok, mod} -> cast_child!(mod, type_atom, attrs)
          :error -> attrs
        end

      :error ->
        attrs
    end
  end

  # Returns the CAST struct's own attrs, not the original `attrs` — so type
  # coercion (a string `"3"` cast to the integer `:level` field) and defaults
  # apply to a nested child exactly as they already do to a top-level one,
  # instead of leaving the pre-cast, possibly-wrong-typed value in storage
  # forever (`columns.columns` is untyped `{:array, :map}` with no downstream
  # re-cast to catch the divergence later).
  #
  # `child_constraints/1` passes the same constraints the top-level union
  # member declares (currently none do, but a future one might), rather than a
  # hardcoded `[]` — the point of this cast is to be *the same* Ash cast a
  # top-level block goes through.
  defp cast_child!(mod, type_atom, attrs) do
    case Ash.Type.cast_input(mod, attrs, child_constraints(type_atom)) do
      {:ok, struct} ->
        struct |> attrs_of() |> drop_nils() |> preserve_absent_id(attrs)

      # `mod`'s `cast_input/2` (an embedded resource — see
      # `Ash.EmbeddableType.single_embed_implementation/1`) already ran the
      # error through `Ash.EmbeddableType.handle_errors/1` before returning it.
      {:error, error} ->
        raise InvalidChildBlockError, block_type: attrs["_type"], errors: List.wrap(error)
    end
  end

  defp child_constraints(type_atom), do: Map.get(@type_constraints, type_atom, [])

  # The embedded resource's `:id` is a `uuid_primary_key`, which the `:create`
  # action `cast_child!` casts through always generates when the input carries
  # none — so `attrs_of/1`'s output must not be trusted for `id` verbatim, or
  # every id-less nested child would get silently stamped with one on write.
  # That stamping is `EnforceBlockFieldPolicy`'s (#865/#954) business, not
  # this cast's: whether a child carries an id at all decides whether its
  # restricted fields are bound by id or governed by the tree-wide multiset.
  defp preserve_absent_id(coerced_attrs, original_attrs) do
    if Map.has_key?(original_attrs, "id"),
      do: coerced_attrs,
      else: Map.delete(coerced_attrs, "id")
  end

  # Build a typed struct from a typed map (string or atom keys), upcasting first.
  defp struct_from_typed_map(map) do
    map = map |> stringify() |> KilnCMS.Blocks.Upcaster.upcast_block_map()

    case KilnCMS.Blocks.fetch(block_type_atom(map)) do
      {:ok, mod} ->
        struct(mod, typed_struct_kv(mod, map))

      :error ->
        # Carry the id so an unknown/plugin block keeps its identity across a
        # typed round-trip (known blocks already keep it via typed_struct_kv).
        %Custom{
          _type: "custom",
          id: get(map, :id),
          content: get(map, :content),
          data: get(map, :data) || %{}
        }
    end
  end

  defp block_type_atom(map), do: Map.get(@type_atoms, to_string(get(map, :_type)), :custom)

  defp typed_struct_kv(mod, map) do
    keys = [:id, :_type, :_version | Enum.map(Kiln.Block.Info.fields(mod), & &1.name)]
    Enum.flat_map(keys, fn key -> kv_for(map, key) end)
  end

  defp kv_for(map, key) do
    case Map.get(map, to_string(key)) do
      nil -> []
      value -> [{key, value}]
    end
  end

  @doc """
  A typed block (struct or `%Ash.Union{}`) as a string-keyed input map — the
  shape `BlockUnion.cast_input` accepts. Used by callers that rebuild a
  record's `blocks` param from its current value with targeted edits (e.g.
  the collab checkpoint materializer replacing one block's `legacy_html`).
  """
  @spec input_map(struct() | Ash.Union.t()) :: %{String.t() => term()}
  def input_map(%Ash.Union{value: value}), do: input_map(value)
  def input_map(%_{} = struct), do: struct |> attrs_of() |> drop_nils()

  # The read-only legacy reader: a pre-flip stored block map (`type`/`content`/
  # `data`) as a typed struct. Reached only from the read direction —
  # `to_typed/1` and `to_union_stored/1` — and from `legacy_loss/1`, which the
  # backfill runs. A write in this shape is refused (`to_union_input/1`).
  defp one_from_legacy(block) do
    id = get(block, :id)
    type = block |> get(:type) |> to_type()
    content = get(block, :content)
    data = get(block, :data) || %{}

    typed(type, id, content, data, block)
  end

  defp typed(:heading, id, content, data, _block),
    do: %Heading{id: id, _type: "heading", text: content, level: data_int(data, "level", 2)}

  defp typed(:rich_text, id, content, _data, _block) do
    # Stored prose is TipTap HTML/JSON; keep it in legacy_html (the Phase C data
    # migration converts it to canonical Portable Text — decision D12).
    %RichText{id: id, _type: "rich_text", body: [], legacy_html: content}
  end

  defp typed(:image, id, content, data, _block) do
    %Image{
      id: id,
      _type: "image",
      url: data_str(data, "url") || content,
      alt: data_str(data, "alt"),
      caption: data_str(data, "caption"),
      media_id: data_str(data, "media_id")
    }
  end

  defp typed(:quote, id, content, data, _block),
    do: %Quote{id: id, _type: "quote", text: content, citation: data_str(data, "citation")}

  # The oEmbed metadata (#489) rides in `data`, like every other block's
  # non-primary fields. Dropping it here loses the card on any legacy→typed
  # path, which is every delivery and preview read.
  defp typed(:embed, id, content, data, _block) do
    %Embed{
      id: id,
      _type: "embed",
      url: content,
      title: data_str(data, "title"),
      author_name: data_str(data, "author_name"),
      provider_name: data_str(data, "provider_name"),
      thumbnail_url: data_str(data, "thumbnail_url"),
      resolved_url: data_str(data, "resolved_url"),
      resolved_at: data_str(data, "resolved_at")
    }
  end

  defp typed(:divider, id, _content, _data, _block),
    do: %Divider{id: id, _type: "divider"}

  defp typed(:form, id, content, data, _block),
    do: %Form{id: id, _type: "form", form_slug: data_str(data, "form_slug") || content}

  # Repeating-item blocks: the item list rides in `data` as a raw string-keyed
  # map list, and the section heading rides in `content`.
  defp typed(:gallery, id, content, data, _block) do
    %Gallery{
      id: id,
      _type: "gallery",
      title: content,
      layout: data_str(data, "layout"),
      images: data_maps(data, "images")
    }
  end

  defp typed(:accordion, id, content, data, _block) do
    %Accordion{
      id: id,
      _type: "accordion",
      title: content,
      first_open: data_bool(data, "first_open"),
      panels: data_maps(data, "panels")
    }
  end

  # GEO blocks (#357): items/steps ride in `data` as raw string-keyed map lists.
  defp typed(:faq, id, content, data, _block),
    do: %Faq{id: id, _type: "faq", title: content, items: data_maps(data, "items")}

  defp typed(:how_to, id, content, data, _block) do
    %HowTo{
      id: id,
      _type: "how_to",
      name: content,
      description: data_str(data, "description"),
      steps: data_maps(data, "steps")
    }
  end

  defp typed(:claim, id, content, data, _block) do
    %Claim{
      id: id,
      _type: "claim",
      text: content,
      source_title: data_str(data, "source_title"),
      source_url: data_str(data, "source_url"),
      rating: data_str(data, "rating")
    }
  end

  # A legacy `columns` block carried its layout and child tree in `data` — the
  # shape `one_to_legacy/1` still writes for a typed one. It used to fall
  # through to `Custom` below, which rendered only because delivery converted
  # it straight back to `type: :columns` at the boundary; anything reading the
  # typed struct (search, references, the fired artifacts) saw an opaque
  # custom block with its children hidden in `data`. Found by the #1537
  # backfill corpus. The children stay raw maps, as on a typed `Columns`, and
  # are typed lazily wherever they are read.
  defp typed(:columns, id, _content, data, _block) do
    %Columns{
      id: id,
      _type: "columns",
      layout: data_str(data, "layout"),
      gap: data_str(data, "gap"),
      columns: data_maps(data, "columns")
    }
  end

  # custom, and anything unmapped → the total fallback.
  #
  # `legacy_type` is the type as STORED, not the atom it resolved to: a type
  # name that was never an atom in this build (`to_type/1` refuses to mint
  # one) resolved to `:custom`, so a stored `"pricing_table"` came back as
  # `legacy_type: "custom"` and its name was gone from every typed read. Found
  # by the #1537 backfill corpus, where it would have been gone from the row.
  defp typed(other, id, content, data, block) do
    %Custom{
      id: id,
      _type: "custom",
      legacy_type: stored_type_name(get(block, :type), other),
      content: content,
      data: data
    }
  end

  defp stored_type_name(raw, _resolved) when is_binary(raw) and raw != "", do: raw
  defp stored_type_name(_raw, resolved), do: to_string(resolved)

  @doc false
  # What converting one stored **legacy** block (`%{"type" => …, "content" =>
  # …, "data" => …}`, string or atom keys) to its typed struct would lose, as
  # the names of the keys that do not survive — `[]` when nothing does.
  #
  # The legacy→typed mapping above reads a fixed set of `data` keys per type
  # and ignores the rest, which is fine for a read (the stored row still holds
  # them) and silent data loss for a rewrite. `KilnCMS.CMS.BlockBackfill`
  # refuses to rewrite a row this reports anything for, and reports it
  # instead (#1537).
  #
  # The oracle is the mapping itself run both ways, not a second table of
  # "which keys each type reads": a key survives when converting to the typed
  # struct and back reproduces it. A second table would drift from the clauses
  # it describes the first time a block type grew a field.
  @spec legacy_loss(map()) :: [String.t()]
  def legacy_loss(%{} = block) do
    typed = one_from_legacy(block)
    back = one_to_legacy(typed)

    content_loss(block, typed) ++
      data_loss(get(block, :data), back.data) ++
      children_loss(get(block, :children)) ++ extra_key_loss(block)
  end

  # `content` survives when the typed struct holds it in some field — `text`
  # for a heading, `legacy_html` for rich text, `url` for an image whose `data`
  # carried no url of its own. A divider has nowhere to put it.
  defp content_loss(block, typed) do
    content = get(block, :content)

    if present?(content) and content not in (typed |> Map.from_struct() |> Map.values()),
      do: ["content"],
      else: []
  end

  defp data_loss(nil, _back), do: []

  defp data_loss(%{} = data, back) do
    for {key, value} <- data,
        present?(value),
        not loosely_equal?(value, Map.get(back, to_string(key))),
        do: "data.#{key}"
  end

  defp data_loss(_not_a_map, _back), do: ["data"]

  # `children` was the legacy block's nesting escape hatch; nothing typed reads
  # it (a typed `columns` keeps its tree in `data["columns"]`).
  defp children_loss(children), do: if(present?(children), do: ["children"], else: [])

  @legacy_keys ~w(id type content data order children)

  # `order` is deliberately not a loss: position in the list has been the order
  # since the storage flip, on every read.
  defp extra_key_loss(block) do
    for {key, value} <- block,
        to_string(key) not in @legacy_keys,
        present?(value),
        do: to_string(key)
  end

  defp present?(value), do: value not in [nil, "", [], %{}]

  # Equal as far as a reader could tell: a form-posted `"3"` for a heading
  # level the typed side holds as `3`, or a gallery image map the typed side
  # filled out with blank defaults for keys it did not have.
  defp loosely_equal?(same, same), do: true

  defp loosely_equal?(%{} = original, %{} = converted) do
    Enum.all?(original, fn {key, value} ->
      not present?(value) or
        loosely_equal?(value, Map.get(converted, to_string(key), Map.get(converted, key)))
    end)
  end

  defp loosely_equal?(original, converted)
       when is_list(original) and is_list(converted) and length(original) == length(converted),
       do: original |> Enum.zip(converted) |> Enum.all?(fn {a, b} -> loosely_equal?(a, b) end)

  defp loosely_equal?(original, converted) do
    scalar?(original) and scalar?(converted) and to_string(original) == to_string(converted)
  end

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  # The typed → legacy direction, kept private for one reader: `legacy_loss/1`
  # uses it as the round-trip oracle for what a rewrite would drop. The public
  # `to_legacy/1` it used to back was removed at 1.0 (#1543).
  defp one_to_legacy(%Heading{} = b),
    do: %{type: :heading, content: b.text, data: %{"level" => b.level}, id: b.id}

  # The single sanitize boundary for delivered/previewed rich text: stored
  # legacy_html is untrusted editor/API HTML and is scrubbed HERE, at
  # payload/preview build time (cached on delivery), while PT-rendered HTML is
  # trusted by construction (escaped text + allowlisted URLs + closed markup).
  # BlockComponents renders `content` raw — it must never receive rich-text
  # HTML that didn't come through this function.
  defp one_to_legacy(%RichText{} = b),
    do: %{
      type: :rich_text,
      content: rich_text_content(b),
      data: %{},
      id: b.id
    }

  defp one_to_legacy(%Image{} = b),
    do: %{
      type: :image,
      content: b.url,
      data: %{"url" => b.url, "alt" => b.alt, "caption" => b.caption, "media_id" => b.media_id},
      id: b.id
    }

  defp one_to_legacy(%Quote{} = b),
    do: %{type: :quote, content: b.text, data: %{"citation" => b.citation}, id: b.id}

  defp one_to_legacy(%Embed{} = b),
    do: %{
      type: :embed,
      content: b.url,
      data: %{
        "title" => b.title,
        "author_name" => b.author_name,
        "provider_name" => b.provider_name,
        "thumbnail_url" => b.thumbnail_url,
        "resolved_url" => b.resolved_url,
        "resolved_at" => b.resolved_at
      },
      id: b.id
    }

  defp one_to_legacy(%Divider{} = b), do: %{type: :divider, content: nil, data: %{}, id: b.id}

  defp one_to_legacy(%Form{} = b),
    do: %{type: :form, content: b.form_slug, data: %{"form_slug" => b.form_slug}, id: b.id}

  # Repeating-item blocks (#482): heading in `content`, item list in `data` as a
  # raw map list, normalized through the block module so delivery never has to
  # tell a missing key from a blank one.
  defp one_to_legacy(%Gallery{} = b),
    do: %{
      type: :gallery,
      content: b.title,
      data: %{"layout" => b.layout, "images" => Gallery.images(b)},
      id: b.id
    }

  defp one_to_legacy(%Accordion{} = b),
    do: %{
      type: :accordion,
      content: b.title,
      data: %{"first_open" => b.first_open == true, "panels" => Accordion.panels(b)},
      id: b.id
    }

  # GEO blocks (#357): the primary text rides in `content`, the rest in `data`
  # (items/steps stay raw map lists — see the block modules).
  defp one_to_legacy(%Faq{} = b),
    do: %{type: :faq, content: b.title, data: %{"items" => KilnCMS.Blocks.Faq.items(b)}, id: b.id}

  defp one_to_legacy(%HowTo{} = b),
    do: %{
      type: :how_to,
      content: b.name,
      data: %{"description" => b.description, "steps" => KilnCMS.Blocks.HowTo.steps(b)},
      id: b.id
    }

  defp one_to_legacy(%Claim{} = b),
    do: %{
      type: :claim,
      content: b.text,
      data: %{
        "source_title" => b.source_title,
        "source_url" => b.source_url,
        "rating" => b.rating
      },
      id: b.id
    }

  # The container's layout + child tree ride in `data` (`content`/`children` stay
  # empty). Delivery reads `data["columns"]` to render the nested tree — see
  # `KilnCMSWeb.BlockComponents`.
  defp one_to_legacy(%Columns{} = b),
    do: %{
      type: :columns,
      content: nil,
      data: %{"layout" => b.layout, "gap" => b.gap, "columns" => b.columns || []},
      id: b.id
    }

  defp one_to_legacy(%Custom{} = b),
    do: %{type: to_type(b.legacy_type), content: b.content, data: b.data || %{}, id: b.id}

  defp rich_text_content(%RichText{legacy_html: html}) when is_binary(html) and html != "",
    do: KilnCMS.HTMLSanitizer.sanitize_rich_text(html)

  defp rich_text_content(%RichText{body: body}), do: KilnCMS.Blocks.PortableText.to_html(body)

  # ── accessors tolerant of struct (atom keys) and jsonb map (string keys) ──
  defp get(block, key), do: Map.get(block, key) || Map.get(block, to_string(key))

  defp to_type(nil), do: :custom
  defp to_type(type) when is_atom(type), do: type

  defp to_type(type) when is_binary(type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> :custom
  end

  # `data` originates from jsonb, so keys are strings.
  defp data_str(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  # A jsonb list-of-maps value (faq items / how_to steps); anything else → [].
  defp data_maps(data, key) do
    case Map.get(data, key) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  # A jsonb boolean. Strings are accepted because form params are always strings
  # and `one_to_legacy/1` writes a real boolean — the value has to survive a
  # round trip through both.
  defp data_bool(data, key) do
    case Map.get(data, key) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> value in ["true", "1", "on"]
      _ -> false
    end
  end

  defp data_int(data, key, default) do
    case Map.get(data, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> default
    end
  rescue
    ArgumentError -> default
  end
end
