defmodule KilnCMS.SchemaExport.Kotlin do
  @moduledoc """
  Kotlin emitter over the exported JSON Schema — kotlinx.serialization models
  for a native app (`mix kiln.export.schema --format kotlin`).

  Like `KilnCMS.SchemaExport.Swift` it reads the schema **document** through
  `KilnCMS.SchemaExport.Walk`, so the emitters cannot disagree about what a
  field is, and it names and nests types the same way. What is Kotlin's own:

    * Every content type, block, shared definition (`MediaSnapshot`) and
      inline object (a `:group` row, a `columns` column) becomes a
      `@Serializable public data class`. Inline objects nest inside the class
      that holds them, named after their key (`custom_fields` →
      `CustomFields`; an array's items take an `Item` suffix). An object with
      no keys is a `data object`, since a data class needs a property.
    * A key that is nullable **or** not required is a nullable property with a
      `= null` default, so an absent key and a `null` decode alike.
    * Kotlin names are `lowerCamelCase`; `@SerialName` pins the JSON key
      exactly whenever the two differ. Hard keywords are back-ticked, and a key
      that collides with another after conversion keeps a sanitized spelling
      of its own.
    * A string `enum` becomes a `@JvmInline value class` over `String` with a
      companion constant per listed value, so an option added on the server
      decodes as just another value instead of failing in an app already in
      the store.
    * The block union is `sealed interface Block`, read by a bundled
      `BlockSerializer` that switches on `_type` and keeps a block type this
      build does not know as `Block.Unknown(type, raw)`; the content types get
      the same treatment as `Document`, switching on `type`. The serializers
      name every member's serializer explicitly — no reflection, so nothing
      for R8 to strip — and re-stamp the tag on encode.
    * An open map (an object without `properties`) is a `JsonObject`; a
      multi-type union and anything unconstrained is a `JsonElement`.
    * `KilnJson`, the `Json` instance the models expect: `ignoreUnknownKeys`,
      because a delivery gains keys before an app is regenerated.

  What Kotlin cannot express is dropped, as the other emitters drop it:
  `format` (a `date-time` is a `String`), numeric bounds, a `const` (the field
  is typed by its value, not pinned to it), and an open object's unknown keys
  (ignored on decode). The file needs kotlinx.serialization's compiler plugin
  and `kotlinx-serialization-json`, nothing else.
  """

  alias KilnCMS.SchemaExport.Walk

  @indent "    "

  @default_package "kiln"

  # https://kotlinlang.org/docs/keyword-reference.html#hard-keywords — the soft
  # and modifier keywords are fine as names.
  @keywords ~w(as break class continue do else false for fun if in interface is null object
               package return super this throw true try typealias typeof val var when while)

  # Names a nested type must not take: the types the file spells (a nested
  # `String` would shadow `kotlin.String` for everything inside it), and the
  # `Companion` the serialization plugin generates on every class.
  @reserved_types ~w(String Long Int Double Boolean List Map Any Unit Nothing Companion
                     Serializable SerialName KSerializer Json JsonElement JsonObject
                     JsonPrimitive JvmInline Unknown)

  @doc "The package a file is emitted into when `:package` is not given."
  @spec default_package() :: String.t()
  def default_package, do: @default_package

  @doc """
  Whether `name` is a Kotlin package name the emitter can write: dotted
  identifiers, none a hard keyword.
  """
  @spec valid_package?(String.t()) :: boolean()
  def valid_package?(name) when is_binary(name) do
    name
    |> String.split(".")
    |> Enum.all?(
      &(&1 =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/ and &1 not in @keywords and
          not underscores?(&1))
    )
  end

  @doc """
  Emit Kotlin source for a schema document from
  `KilnCMS.SchemaExport.json_schema/1`.

  ## Options

    * `:package` — the file's `package` (default `#{@default_package}`).
  """
  @spec emit(map(), keyword()) :: String.t()
  def emit(document, opts \\ []) do
    package = Keyword.get(opts, :package, @default_package)

    unless valid_package?(package),
      do: raise(ArgumentError, "not a Kotlin package name: #{inspect(package)}")

    model = Walk.model(document)
    names = top_level_names(model)
    unions = [{"Block", model.block_union}, {"Document", model.document_union}]
    rows = Map.new(unions, fn {name, union} -> {name, union_rows(union, names, model.defs)} end)

    ctx = %{
      names: names,
      kinds: model.defs,
      reserved: MapSet.new(Map.values(names)),
      supertypes:
        Map.new(Enum.flat_map(rows, fn {union, rows} -> Enum.map(rows, &{&1.def, union}) end))
    }

    union? = Enum.any?(rows, fn {_name, rows} -> rows != [] end)

    [
      header(model, package, union?),
      section("Shared", Enum.map(model.shared, &declaration(&1, ctx))),
      section("Blocks", Enum.map(model.blocks, &declaration(&1, ctx))),
      section("Block union", [tagged_union("Block", model.block_union, rows["Block"], ctx)]),
      section("Documents", Enum.map(model.documents, &declaration(&1, ctx))),
      section("Document union", [
        tagged_union("Document", model.document_union, rows["Document"], ctx)
      ]),
      section("Json", [json_config(union?)])
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp header(model, package, union?) do
    imports =
      ~w(kotlinx.serialization.SerialName kotlinx.serialization.Serializable
         kotlinx.serialization.json.Json kotlinx.serialization.json.JsonElement
         kotlinx.serialization.json.JsonObject) ++
        if(union?,
          do: ~w(kotlinx.serialization.KSerializer kotlinx.serialization.SerializationException
               kotlinx.serialization.descriptors.SerialDescriptor
               kotlinx.serialization.descriptors.buildClassSerialDescriptor
               kotlinx.serialization.encoding.Decoder kotlinx.serialization.encoding.Encoder
               kotlinx.serialization.json.JsonDecoder kotlinx.serialization.json.JsonEncoder
               kotlinx.serialization.json.JsonPrimitive kotlinx.serialization.json.contentOrNull
               kotlinx.serialization.json.jsonObject),
          else: []
        )

    """
    // Generated by `mix kiln.export.schema --format kotlin`. Do not edit.
    //
    // The `:json` fired-artifact shape served by
    // `GET /api/content/:type/:slug?surface=json`.
    //
    // Artifact format version: #{model.format_version || "unknown"}
    //
    // Needs the kotlinx.serialization compiler plugin and
    // `org.jetbrains.kotlinx:kotlinx-serialization-json`. Decode with `KilnJson`.

    package #{package}

    #{imports |> Enum.sort() |> Enum.map_join("\n", &"import #{&1}")}
    """
  end

  defp section(title, declarations) do
    case Enum.reject(declarations, &(&1 == "")) do
      [] ->
        ""

      declarations ->
        "// region #{title}\n\n" <> Enum.join(declarations, "\n\n") <> "\n\n// endregion\n"
    end
  end

  # ── naming ──────────────────────────────────────────────────────────────────

  # `$defs` name → Kotlin type name, unique across the file. The bundled names
  # are claimed first, so a site whose shared definition is called `document`
  # gets a suffixed name rather than shadowing the union.
  defp top_level_names(model) do
    decls = model.shared ++ model.blocks ++ model.documents
    union = if model.block_union, do: [model.block_union.name], else: []
    taken = taken_set(~w(Block BlockSerializer Document DocumentSerializer KilnJson))

    {names, _taken} =
      Enum.reduce(Enum.map(decls, & &1.name), {%{}, taken}, fn name, {acc, taken} ->
        kotlin = unique(base_type_name(name), taken)
        {Map.put(acc, name, kotlin), MapSet.put(taken, fold(kotlin))}
      end)

    Map.merge(names, Map.new(union, &{&1, "Block"}))
  end

  defp base_type_name("block_" <> rest), do: upper_camel(rest) <> "Block"
  defp base_type_name("content_" <> rest), do: upper_camel(rest) <> "Document"
  defp base_type_name(name), do: upper_camel(name)

  # Type names are compared case-folded: each class is a `.class` file, and
  # `Seo` beside `SEO` would overwrite one another on a case-insensitive disk.
  defp fold(name), do: String.downcase(name)
  defp taken_set(names), do: MapSet.new(names, &fold/1)

  defp unique(name, taken) do
    if MapSet.member?(taken, fold(name)),
      do: Enum.find_value(Stream.iterate(2, &(&1 + 1)), &if_free("#{name}#{&1}", taken)),
      else: name
  end

  defp if_free(name, taken), do: if(MapSet.member?(taken, fold(name)), do: nil, else: name)

  defp words(key), do: String.split(key, ~r/[^A-Za-z0-9]+/, trim: true)

  defp upper_camel(key) do
    case words(key) do
      [] -> "Empty"
      words -> words |> Enum.map_join("", &capitalize_first/1) |> leading_digit()
    end
  end

  defp lower_camel(key) do
    case words(key) do
      [] ->
        "empty"

      [first | rest] ->
        (lower_first(first) <> Enum.map_join(rest, "", &capitalize_first/1)) |> leading_digit()
    end
  end

  defp capitalize_first(<<c::utf8, rest::binary>>), do: String.upcase(<<c::utf8>>) <> rest
  defp lower_first(<<c::utf8, rest::binary>>), do: String.downcase(<<c::utf8>>) <> rest

  defp leading_digit(<<c, _::binary>> = name) when c in ?0..?9, do: "_" <> name
  defp leading_digit(name), do: name

  # The raw key with everything Kotlin rejects replaced — the fallback when two
  # keys camel-case to one name (`_type` beside `type`). An all-underscore name
  # is reserved in Kotlin, so it gets a letter.
  defp sanitized(key) do
    name = key |> String.replace(~r/[^A-Za-z0-9_]/, "_") |> leading_digit()
    if name == "" or underscores?(name), do: name <> "x", else: name
  end

  defp underscores?(name), do: name =~ ~r/\A_+\z/

  # Kotlin property names for `fields`, in their order: keys whose camel-cased
  # form *is* the key claim it first, so a block's `type` field keeps `type`
  # and its `_type` discriminator falls back to `_type`.
  defp property_names(fields) do
    keys = Enum.map(fields, & &1.key)
    {exact, converted} = Enum.split_with(keys, &(lower_camel(&1) == &1))

    {names, _taken} =
      Enum.reduce(exact ++ converted, {%{}, MapSet.new()}, fn key, {acc, taken} ->
        name = pick_name([lower_camel(key), sanitized(key)], taken)
        {Map.put(acc, key, name), MapSet.put(taken, name)}
      end)

    names
  end

  defp pick_name(candidates, taken) do
    Enum.find(candidates, &(not MapSet.member?(taken, &1))) || unique_exact(hd(candidates), taken)
  end

  defp unique_exact(name, taken),
    do: Enum.find(Stream.map(Stream.iterate(2, &(&1 + 1)), &"#{name}#{&1}"), &(&1 not in taken))

  defp ident(name) when name in @keywords, do: "`#{name}`"
  defp ident(name), do: name

  # ── declarations ────────────────────────────────────────────────────────────

  defp declaration(%{shape: :opaque} = decl, ctx),
    do: doc(decl.description, "") <> "public typealias #{ctx.names[decl.name]} = JsonElement"

  defp declaration(%{shape: {:object, fields, _open?}} = decl, ctx) do
    class(ctx.names[decl.name], decl.description, fields, "", ctx, ctx.supertypes[decl.name])
  end

  defp class(name, description, fields, indent, ctx, supertype \\ nil) do
    inner = indent <> @indent
    props = property_names(fields)
    scope = %{ctx | reserved: MapSet.put(ctx.reserved, name)}

    {members, nested, _scope} =
      Enum.reduce(fields, {[], [], scope}, fn field, {members, nested, scope} ->
        {kotlin, nullable?, decls, scope} = kt_type(field.type, field.key, false, inner, scope)
        nullable? = nullable? or not field.required?
        member = %{field: field, name: props[field.key], type: kotlin, nullable?: nullable?}
        {[member | members], nested ++ decls, scope}
      end)

    members = Enum.reverse(members)
    extends = if supertype, do: " : #{supertype}", else: ""
    body = if nested == [], do: "", else: " {\n" <> Enum.join(nested, "\n\n") <> "\n#{indent}}"

    head =
      case members do
        [] ->
          "#{indent}public data object #{name}#{extends}"

        members ->
          params = Enum.map_join(members, "\n", &property(&1, inner))
          "#{indent}public data class #{name}(\n#{params}\n#{indent})#{extends}"
      end

    doc(description, indent) <> "#{indent}@Serializable\n" <> head <> body
  end

  defp property(member, indent) do
    serial_name =
      if member.name == member.field.key,
        do: "",
        else: "@SerialName(#{literal(member.field.key)}) "

    doc(field_doc(member.field), indent) <>
      "#{indent}#{serial_name}public val #{ident(member.name)}: #{type_ref(member)},"
  end

  defp type_ref(%{nullable?: true, type: type}), do: type <> "? = null"
  defp type_ref(%{type: type}), do: type

  defp field_doc(%{description: description, target_types: types}) do
    links = if types == [], do: nil, else: "Links to: #{Enum.map_join(types, ", ", &"`#{&1}`")}."
    [description, links] |> Enum.reject(&is_nil/1) |> Enum.join("\n\n") |> nil_if_empty()
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(text), do: text

  # ── type mapping ────────────────────────────────────────────────────────────

  # `{kotlin_type, nullable?, nested_declarations, scope}`. `key` names any
  # type this has to hoist; `item?` says it is a list's element (→ `…Item`).
  defp kt_type({:ref, name}, _key, _item?, _indent, scope) do
    kotlin =
      case scope.kinds[name] do
        kind when kind in [:object, :opaque] -> scope.names[name]
        :union -> if scope.names[name] == "Block", do: "Block", else: "JsonElement"
        nil -> "JsonElement"
      end

    {kotlin, false, [], scope}
  end

  defp kt_type({:nullable, inner}, key, item?, indent, scope) do
    {kotlin, _nullable?, decls, scope} = kt_type(inner, key, item?, indent, scope)
    {kotlin, true, decls, scope}
  end

  defp kt_type({:union, [one]}, key, item?, indent, scope),
    do: kt_type(one, key, item?, indent, scope)

  defp kt_type({:union, _many}, _key, _item?, _indent, scope),
    do: {"JsonElement", false, [], scope}

  defp kt_type({:const, value}, _key, _item?, _indent, scope),
    do: {value_type([value]), is_nil(value), [], scope}

  defp kt_type({:enum, values}, key, item?, indent, scope) do
    {nils, values} = Enum.split_with(values, &is_nil/1)
    nullable? = nils != []

    if values != [] and Enum.all?(values, &is_binary/1) do
      {name, scope} = nested_name(key, item?, scope)
      {name, nullable?, [open_enum(name, Enum.uniq(values), indent)], scope}
    else
      {value_type(values), nullable?, [], scope}
    end
  end

  defp kt_type({:array, items}, key, _item?, indent, scope) do
    {kotlin, nullable?, decls, scope} = kt_type(items, key, true, indent, scope)
    element = if nullable?, do: kotlin <> "?", else: kotlin
    {"List<" <> element <> ">", false, decls, scope}
  end

  defp kt_type({:object, fields, _open?}, key, item?, indent, scope) do
    {name, scope} = nested_name(key, item?, scope)
    {name, false, [class(name, nil, fields, indent, scope)], scope}
  end

  defp kt_type(:map, _key, _item?, _indent, scope), do: {"JsonObject", false, [], scope}
  # `Long`, not `Int`: JSON integers are not 32-bit (a file's byte size).
  defp kt_type(:integer, _key, _item?, _indent, scope), do: {"Long", false, [], scope}
  defp kt_type(:number, _key, _item?, _indent, scope), do: {"Double", false, [], scope}
  defp kt_type(:boolean, _key, _item?, _indent, scope), do: {"Boolean", false, [], scope}
  defp kt_type(:string, _key, _item?, _indent, scope), do: {"String", false, [], scope}
  defp kt_type(:null, _key, _item?, _indent, scope), do: {"JsonElement", true, [], scope}
  defp kt_type(:unknown, _key, _item?, _indent, scope), do: {"JsonElement", false, [], scope}

  # The Kotlin type of a literal's values — a `const` is typed, never pinned.
  defp value_type([]), do: "JsonElement"

  defp value_type(values) do
    cond do
      Enum.all?(values, &is_binary/1) -> "String"
      Enum.all?(values, &is_boolean/1) -> "Boolean"
      Enum.all?(values, &is_integer/1) -> "Long"
      Enum.all?(values, &is_number/1) -> "Double"
      true -> "JsonElement"
    end
  end

  # A nested type's name must not shadow a top-level type (a key `block`
  # would otherwise hide `Block` from everything nested below it), a sibling,
  # or an enclosing class.
  defp nested_name(key, item?, scope) do
    base = upper_camel(key) <> if(item?, do: "Item", else: "")
    taken = MapSet.union(taken_set(scope.reserved), taken_set(@reserved_types))
    name = if MapSet.member?(taken, fold(base)), do: unique(base <> "Value", taken), else: base
    {name, %{scope | reserved: MapSet.put(scope.reserved, name)}}
  end

  # ── enums ───────────────────────────────────────────────────────────────────

  defp open_enum(name, values, indent) do
    i1 = indent <> @indent
    i2 = i1 <> @indent
    constants = enum_constants(values)

    """
    #{indent}@Serializable
    #{indent}@JvmInline
    #{indent}public value class #{name}(public val value: String) {
    #{i1}public companion object {
    #{Enum.map_join(constants, "\n", fn {value, c} -> "#{i2}public val #{c}: #{name} = #{name}(#{literal(value)})" end)}

    #{i2}/** Every value the schema lists. */
    #{i2}public val entries: List<#{name}> = listOf(#{Enum.map_join(constants, ", ", &elem(&1, 1))})
    #{i1}}

    #{i1}/** False for a value the schema does not list — an option added since it was generated. */
    #{i1}public val isKnown: Boolean get() = this in entries

    #{i1}override fun toString(): String = value
    #{indent}}\
    """
  end

  # `{value, constant_name}` in value order; `Companion` is the companion's own.
  defp enum_constants(values) do
    {constants, _taken} =
      Enum.reduce(values, {[], MapSet.new(["Companion"])}, fn value, {acc, taken} ->
        name = pick_name([upper_camel(value), sanitized(value)], taken)
        {[{value, name} | acc], MapSet.put(taken, name)}
      end)

    Enum.reverse(constants)
  end

  # ── tagged unions ───────────────────────────────────────────────────────────

  # A member without a `const` tag cannot be told apart on the wire, and one
  # without a class cannot implement the interface; neither gets a branch, so
  # each decodes as `Unknown` like any other unlisted type.
  defp union_rows(nil, _names, _kinds), do: []

  defp union_rows(%{members: members}, names, kinds) do
    members
    |> Enum.filter(
      &(is_binary(&1.tag) and Map.has_key?(names, &1.def) and kinds[&1.def] == :object)
    )
    |> Enum.uniq_by(& &1.tag)
  end

  defp tagged_union(_name, _union, [], _ctx), do: ""

  defp tagged_union(name, %{tag: tag}, rows, ctx) do
    i1 = @indent
    i2 = i1 <> @indent
    i3 = i2 <> @indent
    what = if name == "Block", do: "block", else: "content"
    serializer = name <> "Serializer"

    """
    /** Any #{what} in a fired `:json` artifact, told apart by `#{tag}`. */
    @Serializable(with = #{serializer}::class)
    public sealed interface #{name} {
    #{i1}/** A #{what} type this build does not know — one added after it was generated. */
    #{i1}public data class Unknown(public val type: String, public val raw: JsonObject) : #{name}
    }

    /** Reads a [#{name}] by its `#{tag}`; JSON only. */
    public object #{serializer} : KSerializer<#{name}> {
    #{i1}override val descriptor: SerialDescriptor = buildClassSerialDescriptor(#{literal(name)})

    #{i1}override fun deserialize(decoder: Decoder): #{name} {
    #{i2}val input = decoder as? JsonDecoder ?: throw SerializationException(#{literal(name <> " decodes from JSON only")})
    #{i2}val raw = input.decodeJsonElement().jsonObject
    #{i2}return when (val type = (raw[#{literal(tag)}] as? JsonPrimitive)?.contentOrNull) {
    #{Enum.map_join(rows, "\n", fn m -> "#{i3}#{literal(m.tag)} -> input.json.decodeFromJsonElement(#{ctx.names[m.def]}.serializer(), raw)" end)}
    #{i3}else -> #{name}.Unknown(type.orEmpty(), raw)
    #{i2}}
    #{i1}}

    #{i1}override fun serialize(encoder: Encoder, value: #{name}) {
    #{i2}val output = encoder as? JsonEncoder ?: throw SerializationException(#{literal(name <> " encodes to JSON only")})
    #{i2}val raw = when (value) {
    #{Enum.map_join(rows, "\n", fn m -> "#{i3}is #{ctx.names[m.def]} -> output.json.encodeToJsonElement(#{ctx.names[m.def]}.serializer(), value).tagged(#{literal(tag)}, #{literal(m.tag)})" end)}
    #{i3}is #{name}.Unknown -> value.raw
    #{i2}}
    #{i2}output.encodeJsonElement(raw)
    #{i1}}
    }\
    """
  end

  defp json_config(union?) do
    tagged =
      if union?,
        do: """


        // A member always carries its tag, even one built with the tag left `null`.
        private fun JsonElement.tagged(key: String, tag: String): JsonObject =
            JsonObject(jsonObject + (key to JsonPrimitive(tag)))\
        """,
        else: ""

    """
    /**
     * The [Json] these models expect. `ignoreUnknownKeys`, because a delivery
     * gains keys (a new custom field, a new block attribute) before the app is
     * regenerated.
     */
    public val KilnJson: Json = Json { ignoreUnknownKeys = true }\
    """ <> tagged
  end

  # ── literals ────────────────────────────────────────────────────────────────

  # Kotlin block comments nest, so a `/*` inside a description would swallow
  # the rest of the file as surely as a `*/` would end the comment early.
  defp doc(nil, _indent), do: ""

  defp doc(text, indent) do
    lines =
      text
      |> String.replace("*/", "* /")
      |> String.replace("/*", "/ *")
      |> String.split(~r/\r\n|\r|\n/)

    case lines do
      [line] ->
        "#{indent}/** #{line} */\n"

      lines ->
        body =
          Enum.map_join(lines, "", fn
            "" -> "#{indent} *\n"
            line -> "#{indent} * #{line}\n"
          end)

        "#{indent}/**\n" <> body <> "#{indent} */\n"
    end
  end

  # Custom-field names and `:select` options are admin input with no charset
  # validation; a quote, a `$` (a string template) or a control character in
  # one must not end the literal early or break the file.
  defp literal(value) do
    escaped =
      value
      |> String.to_charlist()
      |> Enum.map_join(fn
        ?\\ ->
          "\\\\"

        ?" ->
          "\\\""

        ?$ ->
          "\\$"

        ?\n ->
          "\\n"

        ?\r ->
          "\\r"

        ?\t ->
          "\\t"

        c when c < 0x20 or c == 0x7F ->
          "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")

        c ->
          <<c::utf8>>
      end)

    ~s(") <> escaped <> ~s(")
  end
end
