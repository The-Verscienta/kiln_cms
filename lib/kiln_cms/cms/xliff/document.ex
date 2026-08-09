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
  `KilnCMS.Portability.Wxr` does both.
  """

  require Record

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

  # Same ceiling and the same reasoning as the WXR importer: `xmerl` builds the
  # whole tree in memory off a charlist expansion of the input, so the honest
  # failure is an up-front refusal naming the limit, not an OOM kill.
  @max_bytes 16 * 1024 * 1024

  # Characters XML 1.0 cannot represent at all. Stored prose should never hold
  # one, but a single stray control byte would otherwise produce a document no
  # vendor tool can open, which is a worse failure than dropping the byte.
  @illegal_xml ~r/[\x{0000}-\x{0008}\x{000B}\x{000C}\x{000E}-\x{001F}\x{FFFE}\x{FFFF}]/u

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
      ~s(  <file id="#{escape(file.id)}" original="#{escape(file.original)}">\n),
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
        ~s(      <note category="#{escape(category)}">#{escape(value)}</note>\n)
      end),
      "    </notes>\n"
    ]
  end

  defp build_unit(unit) do
    data = original_data(unit)

    [
      ~s(    <unit id="#{escape(unit.id)}" name="#{escape(unit.name)}"),
      position_attribute(unit),
      ">\n",
      build_original_data(data),
      "      <segment",
      segment_state(unit),
      ">\n",
      "        <source xml:space=\"preserve\">",
      inline(unit.source, data),
      "</source>\n",
      build_target(unit, data),
      "      </segment>\n",
      "    </unit>\n"
    ]
  end

  # The unit's positional address, when it differs from its id. This is the
  # migration path, not the addressing scheme: a target-locale record created
  # before block ids were shared across locales (`ContentCopy.dump_blocks/2`)
  # has a structurally identical tree under different ids, and this is the only
  # thing in the file that can still reach it. `Units.apply_translations/3`
  # tries it strictly second, and reports every unit that needed it.
  defp position_attribute(%{position_id: position, id: id}) when position != id,
    do: ~s( kiln:pos="#{escape(position)}")

  defp position_attribute(_unit), do: []

  defp segment_state(%{target: nil}), do: []
  defp segment_state(_unit), do: ~s( state="translated")

  defp build_target(%{target: nil}, _data), do: []

  defp build_target(%{target: target}, data),
    do: ["        <target xml:space=\"preserve\">", inline(target, data), "</target>\n"]

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
        ~s(        <data id="#{escape(id)}">#{escape(href)}</data>\n)
      end),
      "      </originalData>\n"
    ]
  end

  # Runs → mixed content. Each run's marks nest outermost-first in the order
  # they appear on the span, so the code structure a translator sees matches
  # the order the marks were authored in.
  defp inline(runs, data) do
    {iodata, _next_id} =
      Enum.map_reduce(runs, 1, fn run, next_id ->
        wrap(run.marks, escape(run.text), data, next_id)
      end)

    iodata
  end

  defp wrap([], text, _data, next_id), do: {text, next_id}

  defp wrap([mark | rest], text, data, id) do
    {inner, next_id} = wrap(rest, text, data, id + 1)

    {[
       "<pc id=\"#{id}\" kiln:mark=\"#{escape(mark)}\"",
       pc_type(mark, data),
       ">",
       inner,
       "</pc>"
     ], next_id}
  end

  defp pc_type(mark, data) do
    case {Map.get(@mark_types, mark), Map.get(data, mark)} do
      {_known, {id, _href}} -> ~s( type="link" dataRefStart="#{escape(id)}")
      {{type, subtype}, nil} -> ~s( type="#{type}" subType="#{subtype}")
      {nil, nil} -> ~s( type="other" subType="kiln:mark")
    end
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace(@illegal_xml, "")
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

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
        do_parse(xml)
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

  defp parse_notes(element) do
    element
    |> descendants("note")
    |> Enum.flat_map(fn note ->
      case attribute(note, "category") do
        nil -> []
        category -> [{category, note |> runs_of([]) |> Enum.map_join(& &1.text)}]
      end
    end)
    |> Map.new()
  end

  # A unit's target is the concatenation of its segments' targets: XLIFF 2.0
  # lets a tool re-segment a unit into several `<segment>`s, and a file that
  # came back split into sentences must still restore as one slot of prose.
  defp unit_target(unit) do
    targets =
      unit
      |> children("segment")
      |> Enum.flat_map(&children(&1, "target"))
      |> Enum.flat_map(&runs_of(&1, []))

    if targets == [], do: nil, else: merge_runs(targets)
  end

  defp runs_of(element, marks) do
    element
    |> xml_element(:content)
    |> Enum.flat_map(&node_runs(&1, marks))
  end

  defp node_runs(node, marks) do
    cond do
      Record.is_record(node, :xmlText) ->
        text = node |> xml_text(:value) |> List.to_string()
        if text == "", do: [], else: [%{text: text, marks: marks}]

      Record.is_record(node, :xmlElement) ->
        element_runs(node, local_name(node), marks)

      true ->
        []
    end
  end

  # `<pc>` opens a mark; `<mrk>` (and anything else with content we do not
  # model) is transparent so its text survives; standalone codes carry no text
  # and are dropped.
  defp element_runs(element, "pc", marks) do
    case mark_of(element) do
      nil -> runs_of(element, marks)
      mark -> runs_of(element, marks ++ [mark])
    end
  end

  defp element_runs(_element, name, _marks) when name in ~w(ph sc ec cp), do: []
  defp element_runs(element, _name, marks), do: runs_of(element, marks)

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

  defp attribute(element, name) do
    element
    |> xml_element(:attributes)
    |> Enum.find_value(fn attribute ->
      attribute_name = attribute |> xml_attribute(:name) |> Atom.to_string()

      if attribute_name == name, do: attribute |> xml_attribute(:value) |> value_to_string()
    end)
  end

  defp value_to_string(value) when is_list(value), do: List.to_string(value)
  defp value_to_string(value) when is_binary(value), do: value
  defp value_to_string(value), do: to_string(value)
end
