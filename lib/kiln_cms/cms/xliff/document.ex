defmodule KilnCMS.CMS.Xliff.Document do
  @moduledoc """
  The XLIFF 2.0 codec (#502): `build/1` writes a file for a translation vendor,
  `parse/1` reads one back.

  XLIFF 2.0 (OASIS) is the interchange format every professional translation
  vendor and TMS speaks — Smartling, Lokalise, Crowdin, Phrase, memoQ, Trados.
  Supporting it is what makes a direct API connector to any of them a thin
  plugin instead of a second content pipeline.

  ## Shape

      <xliff version="2.0" srcLang="en" trgLang="fr"
             xmlns="urn:oasis:names:tc:xliff:document:2.0"
             xmlns:kiln="urn:kiln-cms:xliff:1.0">
        <file id="f1" original="post/hello-world">
          <notes>…the record this file came from…</notes>
          <unit id="b:9f3c…/body/k:b2" name="rich_text / body / normal">
            <originalData><data id="d1">https://example.com</data></originalData>
            <segment>
              <source xml:space="preserve">See <pc id="1" kiln:mark="lk0"
                type="link" dataRefStart="d1">the docs</pc>.</source>
            </segment>
          </unit>
        </file>
      </xliff>

  One `<file>` per content record, so a batch export from the coverage
  dashboard is one document a vendor quotes and returns as a unit.

  ## Inline codes carry marks, and cannot retarget a link

  Portable Text formatting travels as XLIFF **inline codes** (`<pc>`), which is
  what "non-translatable markup protected as inline codes" means in practice: a
  translator moves them around the sentence, and cannot type into them.

  Each `<pc>` carries `type`/`subType` so vendor tooling renders it as bold or
  a link, *and* a `kiln:mark` attribute holding the Portable Text mark name
  verbatim. `kiln:mark` is the authoritative round-trip key; `subType` is the
  fallback for a file that has been through a tool which dropped foreign
  attributes.

  A link's href goes in `<originalData>` — the XLIFF 2.0 slot for exactly this
  — so the translator can see where a link points. It is context only. The
  importer restores links by mark name against the `markDefs` the record
  already has (`KilnCMS.CMS.Xliff.Units`), so a returned file can reword the
  anchor text of a link but can never change its target. That is deliberate:
  the file comes back from outside the deployment, and "a vendor can rewrite
  any URL on the site" is not a property to hand out with a translation job.

  ## Parsing is defensive

  `parse/1` accepts what the spec allows and ignores what it does not
  understand rather than failing: `<mrk>` annotations are transparent,
  standalone codes (`<ph>`, `<sc>`, `<ec>`) are skipped, and a `<unit>` with no
  `<target>` is simply not translated yet. `xmerl` is invoked with
  `dtd: :none`, and the input is size-capped, for the same reasons
  `KilnCMS.Portability.WXR` does both.
  """

  require Record

  alias KilnCMS.Xml

  Record.defrecordp(
    :xml_element,
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_text,
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_attribute,
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  @xliff_ns "urn:oasis:names:tc:xliff:document:2.0"
  @kiln_ns "urn:kiln-cms:xliff:1.0"

  # `xmerl` builds the whole tree in memory off a charlist expansion of the
  # input, so the honest failure is an up-front refusal naming the limit rather
  # than an OOM kill — the same reasoning as `KilnCMS.Portability.WXR`, at a
  # quarter of its ceiling because a translation job is prose, not a site dump.
  #
  # Distinct names are a sharper cost (#1105): `xmerl_scan` interns every
  # element and attribute name, and atoms are never reclaimed. The byte cap
  # alone is not enough — `KilnCMS.Xml.check_name_budget/2` refuses a crafted
  # vocabulary before SweetXml runs.
  @max_bytes 4 * 1024 * 1024

  # Portable Text mark name → the `<pc>` type/subType a vendor tool renders.
  # `xlf:` subTypes are the ones XLIFF 2.0 defines; the rest are ours, and the
  # spec requires exactly this prefixing for user-defined values.
  @mark_types %{
    "strong" => {"fmt", "xlf:b"},
    "em" => {"fmt", "xlf:i"},
    "underline" => {"fmt", "xlf:u"},
    "strike" => {"fmt", "kiln:s"},
    "code" => {"fmt", "kiln:code"}
  }

  @subtype_marks Map.new(@mark_types, fn {mark, {_type, subtype}} -> {subtype, mark} end)

  @typedoc "A file element: one content record's units."
  @type file :: %{
          id: String.t(),
          original: String.t(),
          notes: [{String.t(), String.t()}],
          units: [unit()]
        }

  @typedoc """
  One trans-unit. `target` is `nil` for prose not yet translated; `mark_defs`
  is the slot's Portable Text `markDefs`, from which link hrefs are resolved
  into `<originalData>`.
  """
  @type unit :: %{
          id: String.t(),
          position_id: String.t(),
          name: String.t(),
          source: [KilnCMS.CMS.Xliff.Units.run()],
          target: [KilnCMS.CMS.Xliff.Units.run()] | nil,
          mark_defs: [map()]
        }

  @doc "Serialize an XLIFF 2.0 document."
  @spec build(%{
          source_locale: String.t(),
          target_locale: String.t(),
          files: [file()]
        }) :: String.t()
  def build(%{source_locale: source, target_locale: target, files: files}) do
    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<xliff xmlns="#{@xliff_ns}" xmlns:kiln="#{@kiln_ns}" version="2.0"),
      ~s( srcLang="#{escape(source)}" trgLang="#{escape(target)}">\n),
      Enum.map(files, &build_file/1),
      "</xliff>\n"
    ])
  end

  defp build_file(file) do
    [
      ~s(  <file id="#{attr(file.id)}" original="#{attr(file.original)}">\n),
      build_notes(Map.get(file, :notes, [])),
      Enum.map(file.units, &build_unit/1),
      "  </file>\n"
    ]
  end

  defp build_notes([]), do: []

  defp build_notes(notes) do
    [
      "    <notes>\n",
      Enum.map(notes, fn {category, value} ->
        ~s(      <note category="#{attr(category)}">#{escape(value)}</note>\n)
      end),
      "    </notes>\n"
    ]
  end

  defp build_unit(unit) do
    data = original_data(unit)

    # Inline-code ids are allocated from the SOURCE and reused by the target.
    # XLIFF 2.0 pairs a target's codes to the source's *by id*, so numbering the
    # two independently — which is what restarting the counter did — hands a CAT
    # tool a target code that either names a different mark or has no source
    # counterpart at all. Trados, memoQ and Phrase all treat that as a tag
    # mismatch and refuse the segment.
    pool = code_pool(unit.source)
    {source, _left, next} = inline(unit.source, data, pool, pool_next(pool))

    [
      ~s(    <unit id="#{attr(unit.id)}" name="#{attr(unit.name)}"),
      position_attribute(unit),
      ">\n",
      build_original_data(data),
      "      <segment",
      segment_state(unit),
      ">\n",
      "        <source xml:space=\"preserve\">",
      source,
      "</source>\n",
      build_target(unit, data, pool, next),
      "      </segment>\n",
      "    </unit>\n"
    ]
  end

  # `mark name => [id, ...]`, allocated in source order.
  defp code_pool(runs) do
    {pairs, _next} =
      runs
      |> Enum.flat_map(& &1.marks)
      |> Enum.map_reduce(1, fn mark, id -> {{mark, id}, id + 1} end)

    Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))
  end

  defp pool_next(pool) do
    pool |> Map.values() |> List.flatten() |> Enum.max(fn -> 0 end) |> Kernel.+(1)
  end

  # The unit's positional address, when it differs from its id. This is the
  # migration path, not the addressing scheme: a target-locale record created
  # before block ids were shared across locales (`ContentCopy.dump_blocks/2`)
  # has a structurally identical tree under different ids, and this is the only
  # thing in the file that can still reach it. `Units.apply_translations/3`
  # tries it strictly second, and reports every unit that needed it.
  defp position_attribute(%{position_id: position, id: id}) when position != id,
    do: ~s( kiln:pos="#{attr(position)}")

  defp position_attribute(_unit), do: []

  defp segment_state(%{target: nil}), do: []
  defp segment_state(_unit), do: ~s( state="translated")

  defp build_target(%{target: nil}, _data, _pool, _next), do: []

  defp build_target(%{target: target}, data, pool, next) do
    {iodata, _left, _next} = inline(target, data, pool, next)
    ["        <target xml:space=\"preserve\">", iodata, "</target>\n"]
  end

  # `markDefs` key → {data id, href}. Only link definitions get one; a mark with
  # no resolvable href still round-trips through `kiln:mark`, it just has no
  # context to show the translator.
  defp original_data(unit) do
    unit
    |> Map.get(:mark_defs, [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "_type") == "link"))
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {def, index} ->
      case {Map.get(def, "_key"), Map.get(def, "href")} do
        {key, href} when is_binary(key) and is_binary(href) -> [{key, {"d#{index}", href}}]
        _incomplete -> []
      end
    end)
    |> Map.new()
  end

  defp build_original_data(data) when map_size(data) == 0, do: []

  defp build_original_data(data) do
    [
      "      <originalData>\n",
      data
      |> Map.values()
      |> Enum.sort()
      |> Enum.map(fn {id, href} ->
        ~s(        <data id="#{attr(id)}">#{escape(href)}</data>\n)
      end),
      "      </originalData>\n"
    ]
  end

  # Runs → mixed content. Each run's marks nest outermost-first in the order
  # they appear on the span, so the code structure a translator sees matches
  # the order the marks were authored in.
  defp inline(runs, data, pool, next) do
    Enum.reduce(runs, {[], pool, next}, fn run, {acc, pool, next} ->
      {iodata, pool, next} = wrap(run.marks, escape(run.text), data, pool, next)
      {acc ++ [iodata], pool, next}
    end)
  end

  defp wrap([], text, _data, pool, next), do: {text, pool, next}

  defp wrap([mark | rest], text, data, pool, next) do
    {id, pool, next} = take_code_id(pool, mark, next)
    {inner, pool, next} = wrap(rest, text, data, pool, next)

    {[
       "<pc id=\"#{id}\" kiln:mark=\"#{attr(mark)}\"",
       pc_type(mark, data),
       ">",
       inner,
       "</pc>"
     ], pool, next}
  end

  # The id the source gave this mark, in source order. A mark the source never
  # carried mints a fresh id past the end rather than colliding with one.
  defp take_code_id(pool, mark, next) do
    case Map.get(pool, mark) do
      [id | rest] -> {id, Map.put(pool, mark, rest), next}
      _exhausted -> {next, pool, next + 1}
    end
  end

  defp pc_type(mark, data) do
    case {Map.get(@mark_types, mark), Map.get(data, mark)} do
      {_known, {id, _href}} -> ~s( type="link" dataRefStart="#{attr(id)}")
      {{type, subtype}, nil} -> ~s( type="#{type}" subType="#{subtype}")
      {nil, nil} -> ~s( type="other" subType="kiln:mark")
    end
  end

  defdelegate escape(value), to: Xml
  defdelegate attr(value), to: Xml, as: :escape_attribute

  # ── parsing ────────────────────────────────────────────────────────────────

  @typedoc """
  A parsed file: the record it names, and the translations it carries as
  `unit id => runs`. `untranslated` is the unit ids present with no `<target>`,
  reported so a half-finished delivery reads as half-finished.
  """
  @type parsed_file :: %{
          original: String.t() | nil,
          notes: %{String.t() => String.t()},
          translations: %{String.t() => [KilnCMS.CMS.Xliff.Units.run()]},
          aliases: %{String.t() => String.t()},
          untranslated: [String.t()]
        }

  @doc """
  Parse an XLIFF 2.0 document.

  Fails on input that is not XLIFF at all — a wrong file picked in an upload
  dialog is the common case and deserves a real error, not a silent zero-unit
  import.
  """
  @spec parse(binary()) ::
          {:ok,
           %{
             source_locale: String.t() | nil,
             target_locale: String.t() | nil,
             files: [parsed_file()]
           }}
          | {:error, term()}
  def parse(xml) when is_binary(xml) do
    cond do
      byte_size(xml) > @max_bytes ->
        {:error, {:too_large, byte_size(xml), @max_bytes}}

      byte_size(xml) == 0 ->
        {:error, :empty_file}

      true ->
        with :ok <- Xml.check_name_budget(xml) do
          do_parse(xml)
        end
    end
  end

  defp do_parse(xml) do
    root = SweetXml.parse(xml, dtd: :none)

    if local_name(root) == "xliff" do
      {:ok,
       %{
         source_locale: attribute(root, "srcLang"),
         target_locale: attribute(root, "trgLang"),
         files: root |> children("file") |> Enum.map(&parse_file/1)
       }}
    else
      {:error, :not_an_xliff_file}
    end
  rescue
    # xmerl throws and exits on malformed input rather than returning an error,
    # and the shapes are not worth enumerating — every failure to parse is the
    # same answer to the caller (the WXR importer takes the same position).
    error -> {:error, {:malformed_xml, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:malformed_xml, reason}}
    thrown -> {:error, {:malformed_xml, thrown}}
  end

  defp parse_file(element) do
    {translations, aliases, untranslated} =
      element
      |> descendants("unit")
      |> Enum.reduce({%{}, %{}, []}, fn unit, {translations, aliases, untranslated} ->
        case {attribute(unit, "id"), unit_target(unit)} do
          {nil, _target} ->
            {translations, aliases, untranslated}

          {id, nil} ->
            {translations, aliases, [id | untranslated]}

          {id, runs} ->
            {Map.put(translations, id, runs), put_alias(aliases, unit, id), untranslated}
        end
      end)

    %{
      original: attribute(element, "original"),
      notes: parse_notes(element),
      translations: translations,
      aliases: aliases,
      untranslated: Enum.reverse(untranslated)
    }
  end

  defp put_alias(aliases, unit, id) do
    case attribute(unit, "kiln:pos") || attribute(unit, "pos") do
      position when is_binary(position) and position != "" -> Map.put(aliases, position, id)
      _absent -> aliases
    end
  end

  # `<file>`'s own `<notes>` only. `descendants/2` would walk into `<unit>`, and
  # a per-unit `<note>` is the ordinary XLIFF slot for a translator comment —
  # with `Map.new/1` being last-wins and units coming after `<notes>` in
  # document order, one commented unit could retarget the whole import at a
  # different record.
  defp parse_notes(element) do
    element
    |> children("notes")
    |> Enum.flat_map(&children(&1, "note"))
    |> Enum.flat_map(fn note ->
      case attribute(note, "category") do
        nil -> []
        category -> [{category, note |> runs_of([]) |> Enum.map_join(& &1.text)}]
      end
    end)
    |> Map.new()
  end

  # A unit's target is the concatenation of its parts, in document order: XLIFF
  # 2.0 lets a tool re-segment a unit into several `<segment>`s, and a file that
  # came back split into sentences must still restore as one slot of prose.
  #
  # `<ignorable>` counts. A unit's content model is `(segment | ignorable)+`,
  # and `<ignorable>` is exactly where a segmenter parks the whitespace
  # *between* sentences — reading only the segments fuses "Bonjour." and
  # "Au revoir." into one word. Its content is non-translatable by definition,
  # so its source stands in when it carries no target of its own.
  #
  # A unit where some segment has no target at all is **not** partially
  # applied: writing the translated half and dropping the rest would silently
  # truncate the paragraph, so the whole unit reads as untranslated.
  defp unit_target(unit) do
    parts =
      unit
      |> xml_element(:content)
      |> Enum.filter(
        &(Record.is_record(&1, :xmlElement) and local_name(&1) in ~w(segment ignorable))
      )

    cond do
      parts == [] -> nil
      Enum.any?(parts, &missing_target?/1) -> nil
      true -> parts |> Enum.flat_map(&part_runs/1) |> blank_to_nil()
    end
  end

  defp missing_target?(part) do
    local_name(part) == "segment" and children(part, "target") == []
  end

  defp part_runs(part) do
    case {children(part, "target"), local_name(part)} do
      {[_ | _] = targets, _kind} -> Enum.flat_map(targets, &runs_of(&1, []))
      {[], "ignorable"} -> part |> children("source") |> Enum.flat_map(&runs_of(&1, []))
      {[], _segment} -> []
    end
  end

  # A `<target>` holding nothing but the tool's own indentation is not a
  # translation. `xmerl` preserves whitespace, so without this every unit of a
  # pretty-printed but untranslated file reports as delivered.
  defp blank_to_nil(runs) do
    if runs |> Enum.map_join(& &1.text) |> String.trim() == "",
      do: nil,
      else: merge_runs(runs)
  end

  # `open` is the stack of marks opened by an `<sc>` that has not been closed by
  # its `<ec>` yet — see `element_runs/4`.
  defp runs_of(element, marks) do
    {runs, _open} =
      element
      |> xml_element(:content)
      |> Enum.reduce({[], []}, fn node, {runs, open} -> node_runs(node, marks, runs, open) end)

    runs
  end

  defp node_runs(node, marks, runs, open) do
    cond do
      Record.is_record(node, :xmlText) ->
        text = node |> xml_text(:value) |> List.to_string()

        if text == "",
          do: {runs, open},
          else: {runs ++ [%{text: text, marks: marks ++ open_marks(open)}], open}

      Record.is_record(node, :xmlElement) ->
        element_runs(node, local_name(node), marks, runs, open)

      true ->
        {runs, open}
    end
  end

  defp open_marks(open), do: open |> Enum.reverse() |> Enum.map(&elem(&1, 1))

  # `<pc>` wraps its own content. `<sc>`/`<ec>` are the *spanning* pair — the
  # spec-sanctioned form a CAT tool emits when a translator moves a code or when
  # one crosses a re-segmentation boundary — so they open and close a mark over
  # their *siblings*, not their children. Treating them as standalone dropped
  # the mark and kept the text, which deleted every link and every bold run in
  # exactly the re-segmented files `unit_target/1` exists to support.
  defp element_runs(element, "pc", marks, runs, open) do
    inner_marks = marks ++ open_marks(open)

    inner =
      case mark_of(element) do
        nil -> runs_of(element, inner_marks)
        mark -> runs_of(element, inner_marks ++ [mark])
      end

    {runs ++ inner, open}
  end

  defp element_runs(element, "sc", _marks, runs, open) do
    case mark_of(element) do
      nil -> {runs, open}
      mark -> {runs, [{attribute(element, "id"), mark} | open]}
    end
  end

  defp element_runs(element, "ec", _marks, runs, open) do
    {runs, close_span(open, attribute(element, "startRef"))}
  end

  # A standalone placeholder carries no text of its own.
  defp element_runs(_element, name, _marks, runs, open) when name in ~w(ph cp), do: {runs, open}

  # `<mrk>`, `<sm>`/`<em>` annotations and anything else we do not model are
  # transparent: their text is content, and losing it would lose the sentence.
  defp element_runs(element, _name, marks, runs, open),
    do: {runs ++ runs_of(element, marks ++ open_marks(open)), open}

  # `startRef` names the `<sc>` being closed. A tool that omits it (or names one
  # that was never opened) closes the innermost span, which is what a
  # well-formed nesting would have done anyway.
  defp close_span([], _start_ref), do: []

  defp close_span(open, nil), do: tl(open)

  defp close_span(open, start_ref) do
    case Enum.find_index(open, fn {id, _mark} -> id == start_ref end) do
      nil -> tl(open)
      index -> List.delete_at(open, index)
    end
  end

  # `kiln:mark` is authoritative. `subType` is the fallback for a file that has
  # been through a tool which dropped foreign-namespace attributes; a link's
  # mark name cannot be recovered that way, so the run keeps its text and loses
  # only the annotation — which `Units.apply_translations/2` would have dropped
  # anyway if it named a `markDefs` key this record does not have.
  defp mark_of(element) do
    case attribute(element, "kiln:mark") || attribute(element, "mark") do
      mark when is_binary(mark) and mark != "" ->
        mark

      _absent ->
        Map.get(@subtype_marks, attribute(element, "subType") || "")
    end
  end

  # Adjacent runs sharing a mark set are one run: a vendor tool that split a
  # sentence across two text nodes must not turn one span into two.
  defp merge_runs(runs) do
    runs
    |> Enum.reduce([], fn
      run, [%{marks: marks} = previous | rest] when marks == run.marks ->
        [%{previous | text: previous.text <> run.text} | rest]

      run, acc ->
        [run | acc]
    end)
    |> Enum.reverse()
  end

  # ── xmerl helpers ──────────────────────────────────────────────────────────

  # Element names keep whatever prefix the document used (`xmerl_scan` does not
  # process namespaces by default), so every lookup is on the local part. A
  # vendor emitting `<xlf:unit>` and one emitting `<unit>` read the same.
  defp local_name(element) do
    element
    |> xml_element(:name)
    |> Atom.to_string()
    |> String.split(":")
    |> List.last()
  end

  defp children(element, name) do
    element
    |> xml_element(:content)
    |> Enum.filter(&(Record.is_record(&1, :xmlElement) and local_name(&1) == name))
  end

  # `<unit>` may sit directly under `<file>` or inside a `<group>`, and groups
  # nest; the same is true of `<note>` and `<data>` relative to their owner.
  defp descendants(element, name) do
    element
    |> xml_element(:content)
    |> Enum.filter(&Record.is_record(&1, :xmlElement))
    |> Enum.flat_map(fn child ->
      if local_name(child) == name, do: [child], else: descendants(child, name)
    end)
  end

  # Exact name first, then the local part — the same prefix-insensitivity
  # `local_name/1` gives elements, and for the same reason: a namespace prefix
  # is not part of a name, so a tool that re-serializes the document binding
  # `kiln:` to `k:` must still be readable. Without it, a rebound prefix silently
  # loses every `kiln:pos` and every link's `kiln:mark`.
  defp attribute(element, name) do
    attributes = xml_element(element, :attributes)
    wanted = local_part(name)

    find_attribute(attributes, &(&1 == name)) ||
      find_attribute(attributes, &(local_part(&1) == wanted))
  end

  defp find_attribute(attributes, match?) do
    Enum.find_value(attributes, fn attribute ->
      if match?.(attribute |> xml_attribute(:name) |> Atom.to_string()),
        do: attribute |> xml_attribute(:value) |> value_to_string()
    end)
  end

  defp local_part(name), do: name |> String.split(":") |> List.last()

  defp value_to_string(value) when is_list(value), do: List.to_string(value)
  defp value_to_string(value) when is_binary(value), do: value
  defp value_to_string(value), do: to_string(value)
end
