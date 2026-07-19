defmodule KilnCMS.Blocks.GeoBlocksTest do
  @moduledoc "The GEO block set (#357): faq / how_to / claim serializers."
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks
  alias KilnCMS.Blocks.{Claim, Faq, HowTo}

  describe "faq" do
    test "renders a FAQPage node with Question/Answer mainEntity" do
      block = %Faq{
        title: "FAQ",
        items: [
          %{"question" => "What is Kiln?", "answer" => "A CMS."},
          %{"question" => "", "answer" => "orphaned"}
        ]
      }

      assert %{"@type" => "FAQPage", "mainEntity" => [q]} = Blocks.render(block, :json_ld)
      assert q["@type"] == "Question"
      assert q["name"] == "What is Kiln?"
      assert q["acceptedAnswer"] == %{"@type" => "Answer", "text" => "A CMS."}
    end

    test "no answerable items → no node" do
      assert Blocks.render(%Faq{items: []}, :json_ld) == nil
      assert Blocks.render(%Faq{items: [%{"question" => "", "answer" => "x"}]}, :json_ld) == nil
    end

    test "web render escapes and wraps items in details/summary" do
      block = %Faq{title: "T", items: [%{"question" => "<b>Q</b>?", "answer" => "A & B"}]}
      html = block |> Blocks.render(:web) |> IO.iodata_to_binary()

      assert html =~ "<h2>T</h2>"
      assert html =~ "<summary>&lt;b&gt;Q&lt;/b&gt;?</summary>"
      assert html =~ "<p>A &amp; B</p>"
      refute html =~ "<b>Q</b>"
    end

    test "llm markdown chunks each question as a heading" do
      block = %Faq{title: "FAQ", items: [%{"question" => "Q?", "answer" => "A."}]}
      assert Blocks.to_markdown(block) == "## FAQ\n\n### Q?\n\nA."
    end

    test "search_text joins title, questions and answers" do
      block = %Faq{title: "FAQ", items: [%{"question" => "Q?", "answer" => "A."}]}
      assert Blocks.search_text(block) == "FAQ Q? A."
    end

    test "tolerates atom-keyed items" do
      block = %Faq{items: [%{question: "Q?", answer: "A."}]}
      assert %{"mainEntity" => [_]} = Blocks.render(block, :json_ld)
    end
  end

  describe "how_to" do
    test "renders a HowTo node with positioned HowToSteps" do
      block = %HowTo{
        name: "Brew tea",
        description: "Hot leaf juice.",
        steps: [
          %{"name" => "Boil", "text" => "Boil water."},
          %{"name" => "", "text" => "Steep."},
          %{"name" => "Skipped", "text" => ""}
        ]
      }

      assert %{"@type" => "HowTo", "name" => "Brew tea", "step" => [s1, s2]} =
               Blocks.render(block, :json_ld)

      assert s1 == %{
               "@type" => "HowToStep",
               "position" => 1,
               "text" => "Boil water.",
               "name" => "Boil"
             }

      assert s2 == %{"@type" => "HowToStep", "position" => 2, "text" => "Steep."}
    end

    test "no steps → no node" do
      assert Blocks.render(%HowTo{name: "Empty"}, :json_ld) == nil
    end

    test "web render is an ordered list" do
      block = %HowTo{name: "N", steps: [%{"name" => "S", "text" => "Do <it>."}]}
      html = block |> Blocks.render(:web) |> IO.iodata_to_binary()

      assert html =~ "<h2>N</h2>"
      assert html =~ "<ol><li><strong>S</strong> Do &lt;it&gt;.</li></ol>"
    end

    test "llm markdown numbers the steps" do
      block = %HowTo{
        name: "Brew",
        steps: [%{"name" => "Boil", "text" => "Boil water."}, %{"name" => "", "text" => "Steep."}]
      }

      assert Blocks.to_markdown(block) ==
               "## Brew\n\n1. **Boil** — Boil water.\n2. Steep."
    end
  end

  describe "claim" do
    test "renders a Claim node carrying its citation" do
      block = %Claim{
        text: "Water boils at 100 °C.",
        source_title: "NIST",
        source_url: "https://nist.gov/water"
      }

      assert %{"@type" => "Claim", "text" => "Water boils at 100 °C.", "citation" => citation} =
               Blocks.render(block, :json_ld)

      assert citation == %{
               "@type" => "CreativeWork",
               "name" => "NIST",
               "url" => "https://nist.gov/water"
             }
    end

    test "a rating upgrades the node to a ClaimReview" do
      block = %Claim{
        text: "The moon is cheese.",
        rating: "False",
        source_title: "NASA",
        source_url: "https://nasa.gov"
      }

      assert %{"@type" => "ClaimReview"} = node = Blocks.render(block, :json_ld)
      assert node["claimReviewed"] == "The moon is cheese."
      assert node["reviewRating"] == %{"@type" => "Rating", "alternateName" => "False"}
      assert %{"@type" => "Claim", "citation" => _} = node["itemReviewed"]
    end

    test "an uncited claim still fires a bare Claim node" do
      assert Blocks.render(%Claim{text: "Just so."}, :json_ld) ==
               %{"@type" => "Claim", "text" => "Just so."}

      assert Blocks.render(%Claim{text: ""}, :json_ld) == nil
    end

    test "unsafe source schemes are dropped everywhere" do
      block = %Claim{text: "X.", source_url: "javascript:alert(1)"}

      html = block |> Blocks.render(:web) |> IO.iodata_to_binary()
      refute html =~ "javascript:"

      assert Blocks.render(block, :json_ld) == %{"@type" => "Claim", "text" => "X."}
      assert Blocks.to_markdown(block) == "X."
    end

    test "web render carries the citation as a cite link" do
      block = %Claim{text: "X & Y.", source_title: "Src", source_url: "https://s.example"}
      html = block |> Blocks.render(:web) |> IO.iodata_to_binary()

      assert html =~ "<p class=\"kiln-claim\">X &amp; Y."
      assert html =~ ~s(<cite><a href="https://s.example" rel="noopener">Src</a></cite>)
    end

    test "llm markdown appends a Source line" do
      block = %Claim{text: "X.", source_title: "Src", source_url: "https://s.example"}
      assert Blocks.to_markdown(block) == "X.\n\nSource: [Src](https://s.example)"
    end
  end

  describe "legacy bridge round-trip" do
    test "faq and how_to survive typed → legacy → typed" do
      faq = %Faq{
        id: Ash.UUID.generate(),
        title: "T",
        items: [%{"question" => "Q?", "answer" => "A."}]
      }

      how_to = %HowTo{
        id: Ash.UUID.generate(),
        name: "N",
        description: "D",
        steps: [%{"name" => "S", "text" => "T."}]
      }

      claim = %Claim{
        id: Ash.UUID.generate(),
        text: "C.",
        source_title: "S",
        source_url: "https://s.example",
        rating: "True"
      }

      [faq2, how_to2, claim2] =
        [faq, how_to, claim]
        |> KilnCMS.CMS.TypedBlocks.to_legacy()
        |> KilnCMS.CMS.TypedBlocks.from_legacy()

      assert %Faq{title: "T", items: [%{"question" => "Q?", "answer" => "A."}]} = faq2

      assert %HowTo{name: "N", description: "D", steps: [%{"name" => "S", "text" => "T."}]} =
               how_to2

      assert %Claim{text: "C.", source_title: "S", rating: "True"} = claim2
    end
  end
end
