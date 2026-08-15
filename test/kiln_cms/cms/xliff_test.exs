defmodule KilnCMS.CMS.XliffTest do
  @moduledoc """
  The translation-vendor seam (#502): the XLIFF 2.0 codec, the unit-id scheme,
  and the round trip through both.

  The centrepiece is `"round trip: export, pseudo-translate, import"` — export a
  document, transform every text node of every `<source>` mechanically, feed the
  file back, and assert the target-locale record has *identical structure* and
  *transformed text*. That is the property a vendor round trip has to have, and
  it is the one that catches a segmentation bug that no unit test of either
  half would notice.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Translations
  alias KilnCMS.CMS.Xliff
  alias KilnCMS.CMS.Xliff.Document
  alias KilnCMS.CMS.Xliff.Units

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "xliff-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "xliff-#{System.unique_integer([:positive])}"

  # A paragraph with a bold run and a link run, in the shape
  # `PortableText.from_tiptap/1` produces.
  defp paragraph(key, runs, defs \\ []) do
    %{
      "_type" => "block",
      "_key" => key,
      "style" => "normal",
      "children" => Enum.map(runs, fn {text, marks} -> span(text, marks) end),
      "markDefs" => defs
    }
  end

  defp span(text, marks), do: %{"_type" => "span", "text" => text, "marks" => marks}

  defp link_def(key, href), do: %{"_key" => key, "_type" => "link", "href" => href}

  defp rich_page(actor, opts \\ []) do
    CMS.create_page!(
      %{
        title: "Field guide",
        slug: Keyword.get(opts, :slug, slug()),
        locale: "en",
        seo_title: "Field guide to clouds",
        blocks: [
          %{"_type" => "heading", "text" => "Cirrus", "level" => 2},
          %{
            "_type" => "rich_text",
            "body" => [
              paragraph("b0", [{"Thin and ", []}, {"wispy", ["strong"]}, {".", []}]),
              paragraph(
                "b1",
                [{"See ", []}, {"the chart", ["lk0"]}, {" for more.", []}],
                [link_def("lk0", "https://example.com/chart")]
              )
            ]
          },
          %{
            "_type" => "faq",
            "title" => "Common questions",
            "items" => [%{"question" => "Is it rain?", "answer" => "Not yet."}]
          },
          %{
            "_type" => "columns",
            "layout" => "1-1",
            "columns" => [
              %{"blocks" => [%{"_type" => "quote", "text" => "Look up.", "citation" => "Anon"}]},
              %{"blocks" => []}
            ]
          }
        ]
      },
      actor: actor
    )
  end

  # ── the unit-id scheme ─────────────────────────────────────────────────────

  describe "Units.extract/1" do
    test "addresses record fields, block fields, Portable Text blocks and nested children" do
      actor = admin()
      page = rich_page(actor)
      page = CMS.get_page!(page.id, actor: actor)

      {units, warnings} = Units.extract(page)
      ids = Enum.map(units, & &1.id)

      assert warnings == []
      assert "title" in ids
      assert "seo_title" in ids

      [heading, rich, faq, columns] = page.blocks

      assert "b:#{heading.value.id}.text" in ids
      assert "b:#{rich.value.id}.body.k:b0" in ids
      assert "b:#{rich.value.id}.body.k:b1" in ids
      assert "b:#{faq.value.id}.title" in ids
      assert "b:#{faq.value.id}.items.i-0.question" in ids
      assert "b:#{faq.value.id}.items.i-0.answer" in ids

      # The nested child inside the first column is addressed under its parent.
      # Its own segment is positional: `columns` children are raw maps and only
      # the content editor stamps them an id, so a block tree written by any
      # other path has none to address by (#865/#954). The *parent* is still
      # addressed by identity, so reordering top-level blocks is still safe —
      # and every path here is NMTOKEN-legal, which `unit/@id` requires.
      assert "b:#{columns.value.id}.columns.i-0.b-0.text" in ids

      # Structural fields are not offered to a translator.
      refute Enum.any?(ids, &String.ends_with?(&1, ".layout"))
      refute Enum.any?(ids, &String.ends_with?(&1, ".level"))
    end

    test "carries Portable Text marks as runs, with the link's markDefs alongside" do
      actor = admin()
      page = actor |> rich_page() |> then(&CMS.get_page!(&1.id, actor: actor))
      {units, _warnings} = Units.extract(page)

      link_unit = Enum.find(units, &String.ends_with?(&1.id, ".body.k:b1"))

      assert link_unit.runs == [
               %{text: "See ", marks: []},
               %{text: "the chart", marks: ["lk0"]},
               %{text: " for more.", marks: []}
             ]

      assert [%{"_key" => "lk0", "href" => "https://example.com/chart"}] = link_unit.mark_defs
    end

    test "skips blank slots so a vendor is not billed for empty fields" do
      actor = admin()
      page = CMS.create_page!(%{title: "Bare", slug: slug(), locale: "en"}, actor: actor)

      {units, _warnings} = Units.extract(CMS.get_page!(page.id, actor: actor))

      assert Enum.map(units, & &1.id) == ["title"]
    end

    test "reports prose it cannot round-trip instead of dropping it silently" do
      # A `custom` block's payload is the honest end state (#1106 option 3): an
      # untyped map has no defensible extraction rule, so it is reported.
      actor = admin()

      page =
        CMS.create_page!(
          %{
            title: "Custom",
            slug: slug(),
            locale: "en",
            blocks: [%{"_type" => "custom", "data" => %{"headline" => "Some prose"}}]
          },
          actor: actor
        )

      {units, warnings} = Units.extract(CMS.get_page!(page.id, actor: actor))

      refute Enum.any?(units, &String.contains?(&1.id, "data"))
      assert [%{field: :data, reason: :unsupported_field}] = warnings
    end

    # #1106. Stored TipTap HTML used to be reported and left out; now it is
    # converted through `PortableText.from_html/1` and cut into the same body
    # units the editor's own Portable Text would give.
    test "legacy_html prose is exported as body units, with inline marks, and not warned about" do
      actor = admin()

      page =
        CMS.create_page!(
          %{
            title: "Legacy",
            slug: slug(),
            locale: "en",
            blocks: [
              %{
                "_type" => "rich_text",
                "legacy_html" =>
                  "<h2>Old title</h2><p>Old <strong>bold</strong> prose with <a href=\"https://x.test\">a link</a></p>"
              }
            ]
          },
          actor: actor
        )

      {units, warnings} = Units.extract(CMS.get_page!(page.id, actor: actor))

      assert warnings == []

      body_units = Enum.filter(units, &String.contains?(&1.id, ".body.k:"))
      assert length(body_units) == 2
      assert Enum.map(body_units, & &1.id) |> Enum.all?(&(&1 =~ ~r/\.body\.k:b\d$/))

      [heading, para] = body_units
      assert heading.runs == [%{text: "Old title", marks: []}]
      assert Enum.map(para.runs, & &1.text) == ["Old ", "bold", " prose with ", "a link"]
      assert Enum.at(para.runs, 1).marks == ["strong"]
      assert [%{"_type" => "link", "href" => "https://x.test"}] = para.mark_defs
      refute Enum.any?(units, &String.contains?(&1.id, "legacy_html"))
    end

    test "a legacy block whose HTML holds no prose at all is neither a unit nor a warning" do
      actor = admin()

      page =
        CMS.create_page!(
          %{
            title: "Empty legacy",
            slug: slug(),
            locale: "en",
            blocks: [%{"_type" => "rich_text", "legacy_html" => "<p></p>"}]
          },
          actor: actor
        )

      {units, warnings} = Units.extract(CMS.get_page!(page.id, actor: actor))
      assert Enum.map(units, & &1.id) == ["title"]
      assert warnings == []
    end
  end

  # ── the codec ──────────────────────────────────────────────────────────────

  describe "Document" do
    defp one_unit_doc(unit_overrides) do
      unit =
        Map.merge(
          %{
            id: "title",
            name: "page / title",
            source: [%{text: "Hello", marks: []}],
            target: nil,
            mark_defs: []
          },
          unit_overrides
        )

      Document.build(%{
        source_locale: "en",
        target_locale: "fr",
        files: [%{id: "f1", original: "page/hello", notes: [], units: [unit]}]
      })
    end

    test "escapes markup and entities in text" do
      xml = one_unit_doc(%{source: [%{text: ~s(Tom & "Jerry" <b>), marks: []}]})

      assert xml =~ "Tom &amp; &quot;Jerry&quot; &lt;b&gt;"

      as_target =
        xml |> String.replace("<source", "<target") |> String.replace("</source>", "</target>")

      assert {:ok, parsed} = Document.parse(as_target)
      assert [%{translations: %{"title" => [run]}}] = parsed.files
      assert run.text == ~s(Tom & "Jerry" <b>)
    end

    test "emits nested inline codes with unique ids and a link's href as originalData" do
      xml =
        one_unit_doc(%{
          source: [%{text: "docs", marks: ["strong", "lk0"]}],
          mark_defs: [%{"_key" => "lk0", "_type" => "link", "href" => "https://example.com"}]
        })

      assert xml =~ ~s(<data id="d1">https://example.com</data>)
      assert xml =~ ~s(<pc id="1" kiln:mark="strong" type="fmt" subType="xlf:b">)
      assert xml =~ ~s(<pc id="2" kiln:mark="lk0" type="link" dataRefStart="d1">)
    end

    test "marks a segment translated only when a target is present" do
      refute one_unit_doc(%{}) =~ ~s(state="translated")
      assert one_unit_doc(%{target: [%{text: "Bonjour", marks: []}]}) =~ ~s(state="translated")
    end

    test "reads marks back from kiln:mark, and from subType when it was stripped" do
      base =
        ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
          ~s(<xliff xmlns="urn:oasis:names:tc:xliff:document:2.0" version="2.0" srcLang="en" trgLang="fr">) <>
          ~s(<file id="f1" original="page/x"><unit id="u"><segment><source>a</source>) <>
          ~s(<target>MARKED</target></segment></unit></file></xliff>)

      with_kiln =
        String.replace(
          base,
          "<target>MARKED</target>",
          ~s(<target><pc id="1" ) <>
            ~s(kiln:mark="lk9" type="link">MARKED</pc></target>)
        )

      # `kiln:mark` needs its namespace declared to be well-formed XML.
      with_kiln =
        String.replace(
          with_kiln,
          ~s(version="2.0"),
          ~s(xmlns:kiln="urn:kiln-cms:xliff:1.0" version="2.0")
        )

      assert {:ok, %{files: [%{translations: %{"u" => [run]}}]}} = Document.parse(with_kiln)
      assert run == %{text: "MARKED", marks: ["lk9"]}

      stripped =
        String.replace(
          base,
          "<target>MARKED</target>",
          ~s(<target><pc id="1" ) <>
            ~s(type="fmt" subType="xlf:b">MARKED</pc></target>)
        )

      assert {:ok, %{files: [%{translations: %{"u" => [bold]}}]}} = Document.parse(stripped)
      assert bold == %{text: "MARKED", marks: ["strong"]}
    end

    test "is transparent to annotations and merges re-segmented text" do
      xml =
        ~s(<xliff xmlns="urn:oasis:names:tc:xliff:document:2.0" version="2.0" srcLang="en" trgLang="fr">) <>
          ~s(<file id="f1" original="page/x"><unit id="u">) <>
          ~s(<segment><source>a</source><target>Bon<mrk id="m1" type="comment">jour</mrk></target></segment>) <>
          ~s(<segment><source>b</source><target> tout le monde</target></segment>) <>
          ~s(</unit></file></xliff>)

      assert {:ok, %{files: [%{translations: %{"u" => runs}}]}} = Document.parse(xml)
      assert runs == [%{text: "Bonjour tout le monde", marks: []}]
    end

    test "rejects input that is not XLIFF, is empty, or is malformed" do
      assert {:error, :empty_file} = Document.parse("")
      assert {:error, :not_an_xliff_file} = Document.parse("<html><body>hi</body></html>")
      assert {:error, {:malformed_xml, _}} = Document.parse("<xliff><file>")
    end
  end

  describe "unit ids" do
    test "unit ids are valid NMTOKENs, as unit/@id requires" do
      actor = admin()
      page = actor |> rich_page() |> then(&CMS.get_page!(&1.id, actor: actor))
      {units, _warnings} = Units.extract(page)

      # NameChar excludes `/` and `#`, so a tool validating against
      # xliff_core_2.0.xsd on ingest rejects the whole document, not one unit.
      for unit <- units do
        assert unit.id =~ ~r/\A[A-Za-z0-9_:.-]+\z/, "not an NMTOKEN: #{unit.id}"
        assert unit.position_id =~ ~r/\A[A-Za-z0-9_:.-]+\z/
      end
    end

    test "reports prose in a non-string field it cannot round-trip" do
      actor = admin()

      page =
        CMS.create_page!(
          %{
            title: "Legacy map",
            slug: slug(),
            locale: "en",
            blocks: [%{"_type" => "custom", "data" => %{"body" => "Old prose"}}]
          },
          actor: actor
        )

      {_units, warnings} = Units.extract(CMS.get_page!(page.id, actor: actor))

      assert [%{field: :data, reason: :unsupported_field}] = warnings
    end
  end

  describe "codec hardening" do
    test "<ignorable> whitespace between re-segmented sentences survives" do
      xml =
        ~s(<xliff xmlns="urn:oasis:names:tc:xliff:document:2.0" version="2.0" srcLang="en" trgLang="fr">) <>
          ~s(<file id="f1" original="page/x"><unit id="u">) <>
          ~s(<segment><source>Hello there.</source><target>Bonjour.</target></segment>) <>
          ~s(<ignorable><source> </source></ignorable>) <>
          ~s(<segment><source>Goodbye.</source><target>Au revoir.</target></segment>) <>
          ~s(</unit></file></xliff>)

      assert {:ok, %{files: [%{translations: %{"u" => runs}}]}} = Document.parse(xml)
      assert runs == [%{text: "Bonjour. Au revoir.", marks: []}]
    end

    test "a half-translated unit is untranslated, not truncated" do
      xml =
        ~s(<xliff xmlns="urn:oasis:names:tc:xliff:document:2.0" version="2.0" srcLang="en" trgLang="fr">) <>
          ~s(<file id="f1" original="page/x"><unit id="u">) <>
          ~s(<segment><source>Hello.</source><target>Bonjour.</target></segment>) <>
          ~s(<segment><source>Goodbye.</source></segment>) <>
          ~s(</unit></file></xliff>)

      assert {:ok, %{files: [file]}} = Document.parse(xml)
      assert file.translations == %{}
      assert file.untranslated == ["u"]
    end

    test "a whitespace-only target is untranslated, not delivered" do
      xml =
        ~s(<xliff xmlns="urn:oasis:names:tc:xliff:document:2.0" version="2.0" srcLang="en" trgLang="fr">) <>
          ~s(<file id="f1" original="page/x"><unit id="u"><segment>) <>
          ~s(<source>Hello</source><target>\n      </target>) <>
          ~s(</segment></unit></file></xliff>)

      assert {:ok, %{files: [file]}} = Document.parse(xml)
      assert file.translations == %{}
      assert file.untranslated == ["u"]
    end

    test "<sc>/<ec> spanning codes keep their mark over sibling text" do
      xml =
        ~s(<xliff xmlns="urn:oasis:names:tc:xliff:document:2.0") <>
          ~s( xmlns:kiln="urn:kiln-cms:xliff:1.0" version="2.0" srcLang="en" trgLang="fr">) <>
          ~s(<file id="f1" original="page/x"><unit id="u"><segment>) <>
          ~s(<source>a</source>) <>
          ~s(<target>Voir <sc id="1" kiln:mark="lk0"/>la doc<ec startRef="1"/>.</target>) <>
          ~s(</segment></unit></file></xliff>)

      assert {:ok, %{files: [%{translations: %{"u" => runs}}]}} = Document.parse(xml)

      assert runs == [
               %{text: "Voir ", marks: []},
               %{text: "la doc", marks: ["lk0"]},
               %{text: ".", marks: []}
             ]
    end

    test "a unit-level note cannot retarget the import" do
      xml =
        ~s(<xliff xmlns="urn:oasis:names:tc:xliff:document:2.0" version="2.0" srcLang="en" trgLang="fr">) <>
          ~s(<file id="f1" original="page/real">) <>
          ~s(<notes><note category="kiln:slug">real</note></notes>) <>
          ~s(<unit id="u"><notes><note category="kiln:slug">hijacked</note></notes>) <>
          ~s(<segment><source>a</source><target>b</target></segment></unit>) <>
          ~s(</file></xliff>)

      assert {:ok, %{files: [file]}} = Document.parse(xml)
      assert file.notes == %{"kiln:slug" => "real"}
    end

    test "a rebound namespace prefix still reads kiln:pos and kiln:mark" do
      xml =
        ~s(<xliff xmlns="urn:oasis:names:tc:xliff:document:2.0") <>
          ~s( xmlns:k="urn:kiln-cms:xliff:1.0" version="2.0" srcLang="en" trgLang="fr">) <>
          ~s(<file id="f1" original="page/x"><unit id="b:new.text" k:pos="b-0.text"><segment>) <>
          ~s(<source>a</source>) <>
          ~s(<target><pc id="1" k:mark="strong">Gras</pc></target>) <>
          ~s(</segment></unit></file></xliff>)

      assert {:ok, %{files: [file]}} = Document.parse(xml)
      assert file.aliases == %{"b-0.text" => "b:new.text"}
      assert file.translations["b:new.text"] == [%{text: "Gras", marks: ["strong"]}]
    end

    test "a carriage return survives the round trip instead of being normalized" do
      actor = admin()

      page =
        CMS.create_page!(
          %{title: "Two\r\nlines", slug: slug(), locale: "en"},
          actor: actor
        )

      page = CMS.get_page!(page.id, actor: actor)
      {:ok, %{xliff: xml}} = Xliff.export(:page, page, "fr", actor: actor)

      # Echo the source back verbatim as the target. Nothing was translated, so
      # nothing may be written. A CR cannot survive the parser at all (xmerl
      # folds `&#13;` to LF along with literal line endings), so the CRLF the
      # record holds used to compare unequal to its own echo and be rewritten.
      echoed =
        Regex.replace(~r{<source([^>]*)>(.*?)</source>}s, xml, fn _w, attrs, inner ->
          "<source#{attrs}>#{inner}</source><target#{attrs}>#{inner}</target>"
        end)

      assert {:ok, [report]} = Xliff.import(echoed, actor: actor)
      assert report.applied == []
      assert "title" in report.unchanged
    end

    test "target inline codes reuse the source's ids" do
      actor = admin()
      shared = slug()
      en = rich_page(actor, slug: shared)
      en = CMS.get_page!(en.id, actor: actor)

      {:ok, %{xliff: first}} = Xliff.export(:page, en, "fr", actor: actor)
      {:ok, _reports} = Xliff.import(pseudo_translate(first), actor: actor)

      # The second round pre-fills <target>; every code id it uses must exist in
      # the same unit's <source>, or a CAT tool reports a tag mismatch.
      {:ok, %{xliff: second}} = Xliff.export(:page, en, "fr", actor: actor)

      for unit <- Regex.scan(~r{<unit .*?</unit>}s, second) |> Enum.map(&hd/1) do
        [source] = Regex.run(~r{<source[^>]*>(.*?)</source>}s, unit, capture: :all_but_first)
        target = Regex.run(~r{<target[^>]*>(.*?)</target>}s, unit, capture: :all_but_first)

        if target do
          source_ids = Regex.scan(~r{<pc id="(\d+)"}, source) |> Enum.map(&List.last/1)
          target_ids = Regex.scan(~r{<pc id="(\d+)"}, hd(target)) |> Enum.map(&List.last/1)
          assert target_ids -- source_ids == [], "target code id absent from source: #{unit}"
        end
      end
    end

    test "refuses a file too large to expand into an xmerl tree" do
      assert {:error, {:too_large, _size, max}} =
               Document.parse(String.duplicate("x", 5 * 1024 * 1024))

      assert max == 4 * 1024 * 1024
    end
  end

  # ── the round trip ─────────────────────────────────────────────────────────

  # Wrap every text node of every `<source>` in guillemets and emit it as the
  # `<target>`: a mechanical translation that changes every character of prose
  # and no character of structure. Entities survive because only the chunks
  # *between* tags are touched.
  defp pseudo_translate(xml) do
    Regex.replace(~r{<source([^>]*)>(.*?)</source>}s, xml, fn _whole, attrs, inner ->
      translated =
        ~r{<[^>]*>}
        |> Regex.split(inner, include_captures: true)
        |> Enum.map_join(fn
          "<" <> _rest = tag -> tag
          "" -> ""
          text -> "«" <> text <> "»"
        end)

      "<source#{attrs}>#{inner}</source><target#{attrs}>#{translated}</target>"
    end)
  end

  defp body_of(record, index) do
    record.blocks |> Enum.at(index) |> Map.fetch!(:value) |> Map.fetch!(:body)
  end

  test "round trip: export, pseudo-translate, import — structure identical, text transformed" do
    actor = admin()
    shared = slug()
    en = rich_page(actor, slug: shared)
    en = CMS.get_page!(en.id, actor: actor)

    assert {:ok, %{xliff: xml, units: unit_count}} = Xliff.export(:page, en, "fr", actor: actor)
    assert unit_count > 5

    assert {:ok, [report]} = Xliff.import(pseudo_translate(xml), actor: actor)

    assert report.error == nil
    assert report.created?, "the target draft is created by the import"
    assert report.unknown == []
    # Shared block ids mean nothing falls back to the positional address — but
    # map-array items and nested children are addressed by index even so, and
    # say so rather than passing as identity matches.
    assert Enum.all?(report.by_position, &(&1 =~ ~r/\.(i|b)-\d/))
    refute Enum.any?(report.by_position, &String.contains?(&1, ".body.k:"))
    refute "title" in report.by_position
    assert length(report.applied) == unit_count

    fr = CMS.get_page!(report.record.id, actor: actor)

    assert fr.locale == "fr"
    assert fr.slug == shared
    assert fr.title == "«Field guide»"
    assert fr.seo_title == "«Field guide to clouds»"

    # Structure identical: same blocks, same ids, same types, same order.
    assert Enum.map(fr.blocks, & &1.type) == Enum.map(en.blocks, & &1.type)
    assert Enum.map(fr.blocks, & &1.value.id) == Enum.map(en.blocks, & &1.value.id)

    # Non-translatable fields untouched.
    assert Enum.at(fr.blocks, 0).value.level == 2
    assert Enum.at(fr.blocks, 3).value.layout == "1-1"

    # Portable Text: same paragraph keys, same span marks, transformed text.
    for {fr_pt, en_pt} <- Enum.zip(body_of(fr, 1), body_of(en, 1)) do
      assert fr_pt["_key"] == en_pt["_key"]
      assert fr_pt["style"] == en_pt["style"]
      assert fr_pt["markDefs"] == en_pt["markDefs"]

      assert Enum.map(fr_pt["children"], & &1["marks"]) ==
               Enum.map(en_pt["children"], & &1["marks"])

      assert Enum.map(fr_pt["children"], & &1["text"]) ==
               Enum.map(en_pt["children"], &("«" <> &1["text"] <> "»"))
    end

    # Map-array items and nested children come back too.
    assert [%{"question" => "«Is it rain?»", "answer" => "«Not yet.»"}] =
             Enum.at(fr.blocks, 2).value.items

    assert [%{"blocks" => [child]}, _empty] = Enum.at(fr.blocks, 3).value.columns
    assert child["text"] == "«Look up.»"
  end

  test "a second round only asks the vendor for what changed" do
    actor = admin()
    en = actor |> rich_page() |> then(&CMS.get_page!(&1.id, actor: actor))

    {:ok, %{xliff: first}} = Xliff.export(:page, en, "fr", actor: actor)
    {:ok, _reports} = Xliff.import(pseudo_translate(first), actor: actor)

    {:ok, %{xliff: second}} = Xliff.export(:page, en, "fr", actor: actor)

    # Everything already translated comes back pre-filled and marked as such.
    assert {:ok, %{files: [file]}} = Document.parse(second)
    assert file.untranslated == []
    assert file.translations["title"] == [%{text: "«Field guide»", marks: []}]

    # And importing the unchanged file is a no-op rather than a version bump.
    fr_before = fr_variant(en, actor)
    {:ok, [report]} = Xliff.import(second, actor: actor)
    assert report.applied == []
    assert length(report.unchanged) > 5
    assert fr_variant(en, actor).updated_at == fr_before.updated_at
  end

  # #1106. Migrate-on-translate: the source keeps its stored HTML, the
  # translation is born as Portable Text — and only for the blocks the file
  # actually addressed.
  test "round trip on legacy_html: the translation lands in body as Portable Text" do
    actor = admin()
    shared = slug()

    en =
      CMS.create_page!(
        %{
          title: "Legacy round trip",
          slug: shared,
          locale: "en",
          blocks: [
            %{"_type" => "rich_text", "legacy_html" => "<p>First <em>legacy</em> paragraph</p>"},
            %{"_type" => "rich_text", "legacy_html" => "<p>Second legacy paragraph</p>"}
          ]
        },
        actor: actor
      )

    en = CMS.get_page!(en.id, actor: actor)
    assert {:ok, %{xliff: xml}} = Xliff.export(:page, en, "fr", actor: actor)

    # Translate only the FIRST block's unit; the second is echoed untranslated.
    first_only =
      Regex.replace(~r{<source([^>]*)>(.*?)</source>}s, xml, fn whole, attrs, inner ->
        if String.contains?(inner, "First"),
          do:
            "<source#{attrs}>#{inner}</source><target#{attrs}>#{String.replace(inner, "First", "Premier")}</target>",
          else: whole
      end)

    assert {:ok, [report]} = Xliff.import(first_only, actor: actor)
    assert report.error == nil
    assert report.unknown == []
    assert Enum.any?(report.applied, &String.contains?(&1, ".body.k:"))

    fr = CMS.get_page!(report.record.id, actor: actor)

    # The translated block: body is Portable Text carrying the translation with
    # its mark, and the stale HTML is gone (`TypedBlocks` nils it once body is
    # authoritative).
    first = fr.blocks |> Enum.at(0) |> Map.fetch!(:value)
    assert [%{"children" => children}] = first.body
    assert Enum.map(children, & &1["text"]) == ["Premier ", "legacy", " paragraph"]
    assert Enum.at(children, 1)["marks"] == ["em"]
    assert first.legacy_html in [nil, ""]

    # The untouched block is exactly as stored — nothing was migrated that
    # nothing translated.
    second = fr.blocks |> Enum.at(1) |> Map.fetch!(:value)
    assert second.body in [nil, []]
    assert second.legacy_html == "<p>Second legacy paragraph</p>"

    # And the source is untouched either way.
    en = CMS.get_page!(en.id, actor: actor)
    assert en.blocks |> Enum.at(0) |> Map.fetch!(:value) |> Map.fetch!(:legacy_html) =~ "First"
  end

  # ── import behaviour ───────────────────────────────────────────────────────

  test "an empty target never clears a field — a partial delivery is normal" do
    actor = admin()
    en = actor |> rich_page() |> then(&CMS.get_page!(&1.id, actor: actor))
    fr = Translations.create_translation!(:page, en, "fr", actor: actor)

    {:ok, %{xliff: xml}} = Xliff.export(:page, en, "fr", actor: actor)

    # Every unit answered with an empty target.
    blanked =
      String.replace(xml, ~r{</source>}, ~s(</source><target xml:space="preserve"></target>))

    assert {:ok, [report]} = Xliff.import(blanked, actor: actor)
    assert report.applied == []

    assert CMS.get_page!(fr.id, actor: actor).title == "Field guide"
  end

  test "a returned file can reword a link but cannot retarget it" do
    actor = admin()
    en = actor |> rich_page() |> then(&CMS.get_page!(&1.id, actor: actor))

    {:ok, %{xliff: xml}} = Xliff.export(:page, en, "fr", actor: actor)

    # A vendor rewriting the href in <originalData> and inventing a mark name.
    hostile =
      xml
      |> pseudo_translate()
      |> String.replace("https://example.com/chart", "https://evil.example/steal")
      |> String.replace(~s(kiln:mark="lk0"), ~s(kiln:mark="lkEVIL"))

    assert {:ok, [report]} = Xliff.import(hostile, actor: actor)
    assert report.error == nil

    fr = CMS.get_page!(report.record.id, actor: actor)
    [paragraph] = body_of(fr, 1) |> Enum.filter(&(&1["_key"] == "b1"))

    # markDefs are the record's own, never the file's.
    assert paragraph["markDefs"] == [
             %{"_key" => "lk0", "_type" => "link", "href" => "https://example.com/chart"}
           ]

    # And the invented mark name is filtered out rather than stored dangling.
    assert Enum.map(paragraph["children"], & &1["marks"]) == [[], [], []]

    assert Enum.map(paragraph["children"], & &1["text"]) == [
             "«See »",
             "«the chart»",
             "« for more.»"
           ]
  end

  test "units that match nothing are reported, not dropped" do
    actor = admin()
    en = actor |> rich_page() |> then(&CMS.get_page!(&1.id, actor: actor))

    {:ok, %{xliff: xml}} = Xliff.export(:page, en, "fr", actor: actor)
    stale = xml |> pseudo_translate() |> String.replace(~s(id="title"), ~s(id="b:gone.text"))

    assert {:ok, [report]} = Xliff.import(stale, actor: actor)
    assert report.unknown == ["b:gone.text"]
    refute "title" in report.applied
  end

  test "a file naming a record that no longer exists fails on its own, not the batch" do
    actor = admin()
    en = actor |> rich_page() |> then(&CMS.get_page!(&1.id, actor: actor))

    {:ok, %{xliff: xml}} = Xliff.export(:page, en, "fr", actor: actor)
    broken = String.replace(xml, ">#{en.slug}<", ">nothing-here<")

    assert {:ok, [report]} = Xliff.import(pseudo_translate(broken), actor: actor)
    assert {:source_not_found, "nothing-here", "en"} = report.error
  end

  test "falls back to position for a translation whose blocks do not share ids" do
    actor = admin()
    shared = slug()
    en = rich_page(actor, slug: shared)
    en = CMS.get_page!(en.id, actor: actor)

    # A variant created the way pre-#502 translations were: same structure,
    # different block ids.
    {blocks, _withheld} = KilnCMS.CMS.ContentCopy.dump_blocks(en)

    fr =
      CMS.create_page!(
        %{title: en.title, slug: shared, locale: "fr", blocks: blocks},
        actor: actor
      )

    {:ok, %{xliff: xml}} = Xliff.export(:page, en, "fr", actor: actor)

    assert {:ok, [report]} = Xliff.import(pseudo_translate(xml), actor: actor)
    refute report.created?
    # Reported by the id the *file* carries, so an operator can find the unit
    # in the document they sent out — the positional address is an internal
    # matching detail, not something a vendor ever sees.
    assert report.by_position != []
    assert Enum.all?(report.by_position, &(&1 in report.applied))
    refute "title" in report.by_position, "record-level fields never need position"

    assert Enum.any?(report.by_position, &String.contains?(&1, ".body.k:")),
           "a paragraph in a variant with unshared ids can only match by position"

    fr = CMS.get_page!(fr.id, actor: actor)
    assert Enum.at(fr.blocks, 0).value.text == "«Cirrus»"
  end

  # ── export guards ──────────────────────────────────────────────────────────

  test "refuses a target locale that is not configured, or is the source's own" do
    actor = admin()
    en = actor |> rich_page() |> then(&CMS.get_page!(&1.id, actor: actor))

    assert {:error, {:unknown_locale, "zz"}} = Xliff.export(:page, en, "zz", actor: actor)
    assert {:error, {:same_locale, "en"}} = Xliff.export(:page, en, "en", actor: actor)
  end

  test "refuses a batch spanning several source locales" do
    actor = admin()
    en = actor |> rich_page() |> then(&CMS.get_page!(&1.id, actor: actor))

    es =
      CMS.create_page!(%{title: "Nubes", slug: slug(), locale: "es"}, actor: actor)

    assert {:error, {:mixed_source_locales, ["en", "es"]}} =
             Xliff.export_many([{:page, en}, {:page, es}], "fr", actor: actor)
  end

  test "a batch is one document with one file per record" do
    actor = admin()
    a = actor |> rich_page() |> then(&CMS.get_page!(&1.id, actor: actor))
    b = actor |> rich_page() |> then(&CMS.get_page!(&1.id, actor: actor))

    assert {:ok, %{xliff: xml}} = Xliff.export_many([{:page, a}, {:page, b}], "fr", actor: actor)
    assert {:ok, %{files: [first, second]}} = Document.parse(xml)
    assert first.original == "page/#{a.slug}"
    assert second.original == "page/#{b.slug}"
  end

  test "dynamic entry types export and import through the same dispatch" do
    actor = admin()

    definition =
      CMS.create_type_definition!(
        %{name: "xl#{System.unique_integer([:positive])}", label: "Xl"},
        actor: actor
      )

    en =
      KilnCMS.CMS.ContentTypes.create!(
        definition.name,
        %{title: "Recipe", slug: slug(), locale: "en"},
        actor: actor
      )

    assert {:ok, %{xliff: xml}} = Xliff.export(definition.name, en, "fr", actor: actor)
    assert {:ok, [report]} = Xliff.import(pseudo_translate(xml), actor: actor)

    assert report.error == nil
    assert report.record.title == "«Recipe»"
    assert report.record.type_definition_id == definition.id
  end

  defp fr_variant(en, actor) do
    :page
    |> Translations.siblings(en, actor: actor)
    |> Enum.find(&(&1.locale == "fr"))
  end
end
