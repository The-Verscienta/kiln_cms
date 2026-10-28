defmodule KilnCMS.CMS.PlainFieldsTest do
  @moduledoc """
  `deliver_plain` on a `:text` field definition: the flag itself (what keeps
  it, what clears it), the projection `KilnCMS.CMS.PlainFields` delivers, and
  the fired `:json` artifact that carries it.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.PlainFields

  doctest PlainFields

  setup do
    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "plain-#{System.unique_integer([:positive])}@example.com",
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
      refute field(actor, %{field_type: :text}).deliver_plain
    end

    test "a :text field keeps it", %{actor: actor} do
      assert field(actor, %{field_type: :text, deliver_plain: true}).deliver_plain
    end

    test "any other type drops it", %{actor: actor} do
      for type <- [:string, :integer, :url, :select] do
        attrs = %{field_type: type, deliver_plain: true}
        attrs = if type == :select, do: Map.put(attrs, :options, ["a"]), else: attrs
        refute field(actor, attrs).deliver_plain, "#{type} kept deliver_plain"
      end
    end

    test "retyping a flagged field away from :text drops it", %{actor: actor} do
      definition = field(actor, %{field_type: :text, deliver_plain: true})

      updated = CMS.update_field_definition!(definition, %{field_type: :string}, actor: actor)

      refute updated.deliver_plain
    end
  end

  describe "plain_breaks" do
    test "is off by default, and kept beside deliver_plain", %{actor: actor} do
      refute field(actor, %{field_type: :text, deliver_plain: true}).plain_breaks

      assert field(actor, %{field_type: :text, deliver_plain: true, plain_breaks: true}).plain_breaks
    end

    test "means nothing without deliver_plain, so it drops", %{actor: actor} do
      refute field(actor, %{field_type: :text, plain_breaks: true}).plain_breaks
    end

    test "drops with deliver_plain on a retype or an untick", %{actor: actor} do
      on = %{field_type: :text, deliver_plain: true, plain_breaks: true}

      retyped =
        actor
        |> field(on)
        |> CMS.update_field_definition!(%{field_type: :string}, actor: actor)

      refute retyped.plain_breaks

      unticked =
        actor
        |> field(on)
        |> CMS.update_field_definition!(%{deliver_plain: false}, actor: actor)

      refute unticked.plain_breaks
    end
  end

  describe "KilnCMS.PlainText.from_html_paragraphs/1" do
    alias KilnCMS.PlainText

    test "a paragraph per block element, a line per <br> and list item" do
      html = """
      <h2>Actions</h2>
      <p>Clears <strong>heat</strong>,
         drains damp.</p>
      <ul>
        <li>Bitter</li>
        <li>Cold</li>
      </ul>
      <blockquote><p>First line<br/>second line</p></blockquote>
      """

      assert PlainText.from_html_paragraphs(html) ==
               "Actions\n\nClears heat, drains damp.\n\nBitter\nCold\n\nFirst line\nsecond line"
    end

    test "inline elements never split a word, and entities decode" do
      assert PlainText.from_html_paragraphs("<p>C<sub>24</sub>H<sub>30</sub> &mdash; AT&amp;T&nbsp;x</p>") ==
               "C24H30 — AT&T x"
    end

    test "comments go, and empty blocks leave no runs of blank lines" do
      assert PlainText.from_html_paragraphs("<div><p>a</p><!-- x --><p></p><div></div><p>b</p></div>") ==
               "a\n\nb"
    end

    test "markup-free text keeps its own newlines" do
      assert PlainText.from_html_paragraphs("  one  \r\n two\n\n\n\nthree  ") ==
               "one\ntwo\n\nthree"
    end

    test "a < in prose is not taken for markup" do
      assert PlainText.from_html_paragraphs("x < y\nand b > a") == "x < y\nand b > a"
    end

    test "nil and blank read as empty" do
      assert PlainText.from_html_paragraphs(nil) == ""
      assert PlainText.from_html_paragraphs("<p> </p>") == ""
    end

    test "reads the same words as from_html/1, only the whitespace differs" do
      html = "<p>One <em>two</em></p><ul><li>three</li></ul><p>four<br>five</p>"

      assert html |> PlainText.from_html_paragraphs() |> String.replace(~r/\s+/, " ") ==
               PlainText.from_html(html)
    end
  end

  describe "project/2" do
    defp definition(name, attrs \\ %{}),
      do: Map.merge(%{name: name, field_type: :text, deliver_plain: true}, attrs)

    test "strips each flagged field and leaves the others out" do
      definitions = [
        definition("body"),
        definition("notes", %{deliver_plain: false}),
        definition("title", %{field_type: :string})
      ]

      values = %{
        "body" => "<p>Huang Qi &amp; <em>Astragalus</em></p><p>Second</p>",
        "notes" => "<b>kept out</b>",
        "title" => "x"
      }

      assert PlainFields.project(values, definitions) == %{
               "body" => "Huang Qi & Astragalus Second"
             }
    end

    test "a flagged field holding no string is nil" do
      definitions = [definition("a"), definition("b"), definition("c")]

      assert PlainFields.project(%{"a" => nil, "b" => 3}, definitions) ==
               %{"a" => nil, "b" => nil, "c" => nil}
    end

    test "a link field is never projected" do
      assert PlainFields.project(%{"a" => "x"}, [
               definition("a", %{link_of_id: Ash.UUID.generate()})
             ]) ==
               nil
    end

    test "no flagged field is nil, so the caller leaves the key out" do
      assert PlainFields.project(%{"a" => "<p>x</p>"}, [definition("a", %{deliver_plain: false})]) ==
               nil
    end
  end

  describe "the fired :json artifact" do
    defp fire(actor, custom_fields) do
      page =
        CMS.create_page!(
          %{
            title: "Plain",
            slug: "plain-#{System.unique_integer([:positive])}",
            custom_fields: custom_fields
          },
          actor: actor
        )

      {:ok, artifacts} = KilnCMS.Firing.Engine.fire(page, mode: :preview)
      artifacts[:json]
    end

    test "carries custom_fields_plain beside the untouched custom_fields", %{actor: actor} do
      flagged = field(actor, %{field_type: :text, deliver_plain: true})
      other = field(actor, %{field_type: :text})
      html = "<p>One &mdash; <strong>two</strong></p>"

      json = fire(actor, %{flagged.name => html, other.name => html})

      assert json["custom_fields"][flagged.name] == html
      assert json["custom_fields"][other.name] == html
      assert json["custom_fields_plain"] == %{flagged.name => "One — two"}
    end

    test "a field that keeps its breaks fires them, the others stay on one line",
         %{actor: actor} do
      kept = field(actor, %{field_type: :text, deliver_plain: true, plain_breaks: true})
      flat = field(actor, %{field_type: :text, deliver_plain: true})
      html = "<p>One</p><p>Two<br>three</p>"

      json = fire(actor, %{kept.name => html, flat.name => html})

      assert json["custom_fields_plain"] == %{
               kept.name => "One\n\nTwo\nthree",
               flat.name => "One Two three"
             }

      assert json["custom_fields"][kept.name] == html
    end

    test "a type that flags nothing fires no custom_fields_plain key", %{actor: actor} do
      plain = field(actor, %{field_type: :text})

      refute Map.has_key?(fire(actor, %{plain.name => "<p>x</p>"}), "custom_fields_plain")
    end
  end
end
