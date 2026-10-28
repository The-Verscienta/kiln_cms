defmodule KilnCMS.CMS.PortableFieldsTest do
  @moduledoc """
  `deliver_portable` on a rich `:text` field definition: the flag itself
  (what keeps it, what clears it), the Portable Text rendition
  `KilnCMS.CMS.PortableFields` delivers — prose that survives the trip with
  its marks, links, lists and headings — and the fired `:json` artifact that
  carries it.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.CMS
  alias KilnCMS.CMS.PortableFields

  doctest PortableFields

  setup do
    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "portable-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    %{actor: actor}
  end

  defp field(actor, attrs) do
    CMS.create_field_definition!(
      Map.merge(
        %{content_type: :page, name: "f#{System.unique_integer([:positive])}", label: "F"},
        attrs
      ),
      actor: actor
    )
  end

  describe "the flag" do
    test "is off by default", %{actor: actor} do
      refute field(actor, %{field_type: :text}).deliver_portable
    end

    test "a rich :text field keeps it", %{actor: actor} do
      assert field(actor, %{field_type: :text, deliver_portable: true}).deliver_portable
    end

    test "a plain :text field drops it", %{actor: actor} do
      refute field(actor, %{field_type: :text, format: :plain, deliver_portable: true}).deliver_portable
    end

    test "any other type drops it", %{actor: actor} do
      for type <- [:string, :integer, :url, :select] do
        attrs = %{field_type: type, deliver_portable: true}
        attrs = if type == :select, do: Map.put(attrs, :options, ["a"]), else: attrs
        refute field(actor, attrs).deliver_portable, "#{type} kept deliver_portable"
      end
    end

    test "retyping a flagged field, or making it plain, drops it", %{actor: actor} do
      retyped = field(actor, %{field_type: :text, deliver_portable: true})

      refute CMS.update_field_definition!(retyped, %{field_type: :string}, actor: actor).deliver_portable

      plained = field(actor, %{field_type: :text, deliver_portable: true})

      refute CMS.update_field_definition!(plained, %{format: :plain}, actor: actor).deliver_portable
    end

    test "is independent of deliver_plain", %{actor: actor} do
      both = field(actor, %{field_type: :text, deliver_plain: true, deliver_portable: true})
      assert both.deliver_plain and both.deliver_portable
    end

    test "a private field refuses it", %{actor: actor} do
      assert {:error, error} =
               CMS.create_field_definition(
                 %{
                   content_type: :page,
                   name: "f#{System.unique_integer([:positive])}",
                   label: "F",
                   field_type: :text,
                   private: true,
                   deliver_portable: true
                 },
                 actor: actor
               )

      assert Exception.message(error) =~ "can't be delivered as Portable Text"
    end
  end

  describe "project/2" do
    defp definition(name, attrs \\ %{}),
      do: Map.merge(%{name: name, field_type: :text, deliver_portable: true}, attrs)

    test "converts each flagged field and leaves the others out" do
      definitions = [
        definition("body"),
        definition("notes", %{deliver_portable: false}),
        definition("code", %{format: :plain}),
        definition("title", %{field_type: :string})
      ]

      values = %{
        "body" => "<p>x</p>",
        "notes" => "<p>y</p>",
        "code" => "<p>z</p>",
        "title" => "t"
      }

      assert %{"body" => [%{"_type" => "block"}]} = PortableFields.project(values, definitions)
      assert Map.keys(PortableFields.project(values, definitions)) == ["body"]
    end

    test "a flagged field holding no string, or JSON data, is nil; a blank one is []" do
      definitions = Enum.map(~w(a b c d e), &definition/1)

      assert PortableFields.project(
               %{"a" => nil, "b" => 3, "c" => ~s([{"dose":"5g"}]), "d" => "  "},
               definitions
             ) == %{"a" => nil, "b" => nil, "c" => nil, "d" => [], "e" => nil}
    end

    test "link fields and group sub-fields are never projected" do
      assert PortableFields.project(%{"a" => "x"}, [
               definition("a", %{link_of_id: Ash.UUID.generate()})
             ]) == nil

      assert PortableFields.project(%{"a" => "x"}, [
               definition("a", %{group_of_id: Ash.UUID.generate()})
             ]) == nil
    end
  end

  describe "the rendition" do
    test "keeps headings, marks, links, nested lists and decodes entities" do
      html = """
      <h2>Actions &amp; indications</h2>
      <p>Clears <strong>heat</strong>, <em>dries</em> damp &mdash; see <a href="https://example.com/huang-lian">Huang&nbsp;Lian</a>.</p>
      <ul>
        <li>Stomach
          <ul><li>nausea</li><li>reflux</li></ul>
        </li>
        <li>Heart</li>
      </ul>
      <ol><li>First</li><li>Second</li></ol>
      <blockquote>Bitter &lt;cold&gt;</blockquote>
      """

      [heading, para, l1, l2a, l2b, l1b, o1, o2, blockquote] = PortableFields.portable(html)

      assert %{"style" => "h2", "children" => [%{"text" => "Actions & indications"}]} = heading

      assert %{
               "style" => "normal",
               "markDefs" => [%{"_type" => "link", "_key" => link_key} = link]
             } =
               para

      assert link["href"] == "https://example.com/huang-lian"
      spans = para["children"]
      assert Enum.find(spans, &(&1["text"] == "heat"))["marks"] == ["strong"]
      assert Enum.find(spans, &(&1["text"] == "dries"))["marks"] == ["em"]
      assert Enum.find(spans, &(&1["marks"] == [link_key]))["text"] == "Huang Lian"
      assert Enum.map_join(spans, & &1["text"]) =~ "damp — see"

      assert [
               {"bullet", 1, "Stomach"},
               {"bullet", 2, "nausea"},
               {"bullet", 2, "reflux"},
               {"bullet", 1, "Heart"},
               {"number", 1, "First"},
               {"number", 1, "Second"}
             ] ==
               Enum.map([l1, l2a, l2b, l1b, o1, o2], fn block ->
                 {block["listItem"], block["level"],
                  block["children"] |> Enum.map_join(& &1["text"]) |> String.trim()}
               end)

      assert %{"style" => "blockquote", "children" => [%{"text" => "Bitter <cold>"}]} = blockquote
    end

    test "is what the rich_text block would hold for the same HTML" do
      html = "<p>A <strong>b</strong></p><ul><li>c</li></ul>"

      assert PortableFields.portable(html) ==
               html |> PortableText.from_html() |> PortableText.sanitize_body()
    end

    test "renders back to the same reading" do
      html = ~s(<p>One <em>two</em> <a href="https://x.test/">three</a></p><ul><li>four</li></ul>)

      assert html
             |> PortableFields.portable()
             |> PortableText.to_html()
             |> Floki.parse_fragment!()
             |> Floki.text() ==
               html |> Floki.parse_fragment!() |> Floki.text()
    end

    test "drops a link the sanitizer would not let through" do
      [%{"markDefs" => defs}] =
        PortableFields.portable(~s{<p><a href="javascript:alert(1)">x</a></p>})

      refute Enum.any?(defs, &String.starts_with?(&1["href"] || "", "javascript"))
    end

    test "reads markup-free text as the paragraphs and line breaks it was typed with" do
      assert [first, second] =
               PortableFields.portable("Bitter & cold\r\nenters the heart\n\n  Second  \n")

      assert first["style"] == "normal"
      assert first["children"] |> Enum.map_join(& &1["text"]) == "Bitter & cold\nenters the heart"
      assert second["children"] |> Enum.map_join(& &1["text"]) == "Second"
    end
  end

  describe "the fired :json artifact" do
    defp fire(actor, custom_fields) do
      page =
        CMS.create_page!(
          %{
            title: "Portable",
            slug: "portable-#{System.unique_integer([:positive])}",
            custom_fields: custom_fields
          },
          actor: actor
        )

      {:ok, artifacts} = KilnCMS.Firing.Engine.fire(page, mode: :preview)
      artifacts[:json]
    end

    test "carries custom_fields_portable beside the untouched custom_fields", %{actor: actor} do
      flagged = field(actor, %{field_type: :text, deliver_portable: true})
      other = field(actor, %{field_type: :text})
      html = "<p>One &mdash; <strong>two</strong></p>"

      json = fire(actor, %{flagged.name => html, other.name => html})

      assert json["custom_fields"][flagged.name] == html
      assert json["custom_fields"][other.name] == html
      assert Map.keys(json["custom_fields_portable"]) == [flagged.name]
      assert [%{"children" => spans}] = json["custom_fields_portable"][flagged.name]
      assert Enum.map(spans, &{&1["text"], &1["marks"]}) == [{"One — ", []}, {"two", ["strong"]}]
    end

    test "a type that flags nothing fires no custom_fields_portable key", %{actor: actor} do
      plain = field(actor, %{field_type: :text})

      refute Map.has_key?(fire(actor, %{plain.name => "<p>x</p>"}), "custom_fields_portable")
    end
  end
end
