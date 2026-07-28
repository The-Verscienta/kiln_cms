defmodule KilnCMS.Seo.AnalyzerTest do
  use ExUnit.Case, async: true

  alias KilnCMS.Seo.Analyzer

  # Readable prose — short sentences, common words — long enough to clear the
  # thin-content and density floors, with the keyphrase in the first paragraph.
  # Deliberately *good* writing, so the only findings on it are real ones.
  defp long_body do
    paragraphs =
      for i <- 1..10 do
        # The keyphrase appears in the opening paragraphs only, keeping density
        # inside the 0.5–2.5% band the way real prose does.
        opener =
          if i <= 3,
            do: "The kiln firing step #{i} is simple. ",
            else: "Step #{i} is just as simple. "

        %{
          "_type" => "block",
          "style" => "normal",
          "children" => [
            %{
              "text" =>
                opener <>
                  "Load the shelves with care. Leave a gap at each side. " <>
                  "Set the ramp rate low for the first hour. " <>
                  "Watch the cones as the heat climbs. " <>
                  "Let the work cool in the closed kiln."
            }
          ]
        }
      end

    [
      %{"_type" => "heading", "text" => "Understanding kiln firing", "level" => 2},
      %{"_type" => "rich_text", "body" => paragraphs}
    ]
  end

  defp fields(overrides) do
    Map.merge(
      %{
        title: "Understanding kiln firing",
        slug: "kiln-firing",
        seo_title: "Understanding kiln firing schedules for beginners",
        seo_description:
          "A practical guide to kiln firing schedules, covering ramp rates, soak times and cone packs for the studio potter.",
        seo_keywords: "kiln firing, glaze",
        seo_image: "/uploads/kiln.jpg",
        featured_image_id: nil,
        locale: "en"
      },
      overrides
    )
  end

  defp codes(report), do: Enum.map(report.findings, & &1.code)

  defp analyze(overrides \\ %{}, blocks \\ nil),
    do: Analyzer.analyze_blocks(fields(overrides), blocks || long_body())

  describe "a well-formed document" do
    test "produces no findings at all and grades :good" do
      report = analyze()

      assert report.findings == []
      assert report.grade == :good
      assert report.passed > 0
      assert report.passed == report.total
    end

    test "advisory infos alone do not downgrade the grade below :good" do
      # No OG image is an :info. It should show in the list but keep the badge
      # green — only warnings and errors move the traffic light.
      report = analyze(%{seo_image: ""})

      assert :og_image_missing in codes(report)
      assert Enum.all?(report.findings, &(&1.severity == :info))
      assert report.grade == :good
    end

    test "a single warning drops the grade to :ok, three make it :poor" do
      assert analyze(%{seo_description: ""}).grade == :ok

      # Slug.Lint's keyphrase-in-title check reads `title` *and* `seo_title`, so
      # both must lose the keyphrase for that warning to fire.
      poor =
        analyze(%{
          seo_description: "",
          title: "Pottery",
          seo_title: "Pottery basics for the complete beginner",
          slug: "unrelated-slug-entirely"
        })

      assert Enum.count(poor.findings, &(&1.severity == :warning)) >= 3
      assert poor.grade == :poor
    end
  end

  describe "empty documents" do
    test "an untouched draft reports no failures — every check is :n_a" do
      report =
        Analyzer.analyze_blocks(
          %{
            title: "",
            slug: "",
            seo_title: "",
            seo_description: "",
            seo_keywords: "",
            locale: "en"
          },
          []
        )

      # The description and OG image are the only things judgeable with no
      # input at all; nothing else may fire.
      refute :thin_content in codes(report)
      refute :no_headings in codes(report)
      refute :keyphrase_missing in codes(report) and :images_missing_alt in codes(report)
      refute :images_missing_alt in codes(report)
    end

    test "a blank title and blank seo_title is :n_a, not a failure" do
      report = analyze(%{title: "", seo_title: ""})
      refute :seo_title_missing in codes(report)
    end
  end

  describe "seo_title length boundaries" do
    test "exactly #{30} characters passes" do
      report = analyze(%{seo_title: String.duplicate("a", 30)})
      refute :seo_title_short in codes(report)
      refute :seo_title_long in codes(report)
    end

    test "29 characters is short" do
      report = analyze(%{seo_title: String.duplicate("a", 29)})
      assert :seo_title_short in codes(report)
    end

    test "exactly 60 characters passes" do
      report = analyze(%{seo_title: String.duplicate("a", 60)})
      refute :seo_title_long in codes(report)
    end

    test "61 characters is long, and carries the measured length" do
      report = analyze(%{seo_title: String.duplicate("a", 61)})
      finding = Enum.find(report.findings, &(&1.code == :seo_title_long))

      assert finding.severity == :warning
      assert finding.field == :seo_title
      assert finding.args == %{length: 61, min: 30, max: 60}
    end

    test "an seo_title identical to the title is flagged as duplicate" do
      title = "Understanding kiln firing schedules for beginners"
      report = analyze(%{title: title, seo_title: title})
      assert :seo_title_duplicates_title in codes(report)
    end
  end

  describe "seo_description length boundaries" do
    test "a missing description is a warning" do
      report = analyze(%{seo_description: ""})
      finding = Enum.find(report.findings, &(&1.code == :seo_description_missing))
      assert finding.severity == :warning
    end

    test "exactly 70 characters passes" do
      report = analyze(%{seo_description: String.duplicate("a", 70)})
      refute :seo_description_short in codes(report)
    end

    test "69 characters is short" do
      report = analyze(%{seo_description: String.duplicate("a", 69)})
      assert :seo_description_short in codes(report)
    end

    test "exactly 160 characters passes" do
      report = analyze(%{seo_description: String.duplicate("a", 160)})
      refute :seo_description_long in codes(report)
    end

    test "161 characters is long" do
      report = analyze(%{seo_description: String.duplicate("a", 161)})
      assert :seo_description_long in codes(report)
    end
  end

  describe "keyphrase checks (wrapping Slug.Lint)" do
    test "Slug.Lint findings surface with field: :slug" do
      report = analyze(%{slug: "something-entirely-different"})
      finding = Enum.find(report.findings, &(&1.code == :keyphrase_not_in_slug))

      assert finding
      assert finding.field == :slug
    end

    test "a keyphrase absent from the title is reported" do
      report = analyze(%{title: "Pottery basics", seo_title: "Pottery basics for beginners"})
      assert :keyphrase_not_in_title in codes(report)
    end

    test "an over-long slug is reported" do
      report = analyze(%{slug: "a-very-long-slug-with-far-too-many-hyphenated-segments-in-it"})
      assert :slug_long in codes(report)
    end

    test "no keyphrase set means keyphrase checks are :n_a, and only an info fires" do
      report = analyze(%{seo_keywords: ""})

      assert :keyphrase_missing in codes(report)
      assert Enum.find(report.findings, &(&1.code == :keyphrase_missing)).severity == :info
      refute :keyphrase_not_in_slug in codes(report)
      refute :keyphrase_not_in_title in codes(report)
      refute :keyphrase_not_in_description in codes(report)
    end

    test "a keyphrase missing from the description is reported" do
      report =
        analyze(%{
          seo_description:
            "A practical guide to studio pottery, covering ramp rates, soak times and cone packs for the beginner."
        })

      assert :keyphrase_not_in_description in codes(report)
    end

    test "a keyphrase absent from the body's first paragraph is reported" do
      blocks = [
        %{
          "_type" => "rich_text",
          "body" => [
            %{
              "_type" => "block",
              "style" => "normal",
              "children" => [%{"text" => String.duplicate("unrelated prose here ", 40)}]
            }
          ]
        }
      ]

      report = analyze(%{}, blocks)
      assert :keyphrase_not_in_first_paragraph in codes(report)
    end
  end

  describe "keyphrase density" do
    test "a body repeating the keyphrase relentlessly is flagged as too dense" do
      blocks = [
        %{
          "_type" => "rich_text",
          "body" => [
            %{
              "_type" => "block",
              "style" => "normal",
              "children" => [%{"text" => String.duplicate("kiln firing ", 60)}]
            }
          ]
        }
      ]

      report = analyze(%{}, blocks)
      finding = Enum.find(report.findings, &(&1.code == :keyphrase_density_high))

      assert finding
      assert finding.args.density > 2.5
    end

    test "density is :n_a below the 50-word floor" do
      blocks = [
        %{
          "_type" => "rich_text",
          "body" => [
            %{"_type" => "block", "style" => "normal", "children" => [%{"text" => "Short."}]}
          ]
        }
      ]

      report = analyze(%{}, blocks)
      refute :keyphrase_density_low in codes(report)
      refute :keyphrase_density_high in codes(report)
    end
  end

  describe "structure" do
    test "content under 300 words is thin, and reports its count" do
      blocks = [
        %{
          "_type" => "rich_text",
          "body" => [
            %{
              "_type" => "block",
              "style" => "normal",
              "children" => [%{"text" => String.duplicate("word ", 50)}]
            }
          ]
        }
      ]

      report = analyze(%{}, blocks)
      finding = Enum.find(report.findings, &(&1.code == :thin_content))

      assert finding.args.min == 300
      assert finding.args.count == 50
    end

    test "a skipped heading level is reported with the jump" do
      blocks =
        long_body() ++
          [%{"_type" => "heading", "text" => "Way too deep", "level" => 5}]

      report = analyze(%{}, blocks)
      finding = Enum.find(report.findings, &(&1.code == :heading_levels_skipped))

      assert finding.args == %{from: 2, to: 5}
    end

    test "long content with no headings at all is reported" do
      blocks = [
        %{
          "_type" => "rich_text",
          "body" => [
            %{
              "_type" => "block",
              "style" => "normal",
              "children" => [%{"text" => String.duplicate("kiln firing prose ", 150)}]
            }
          ]
        }
      ]

      report = analyze(%{}, blocks)
      assert :no_headings in codes(report)
    end
  end

  describe "images" do
    test "an image with no alt text is an error carrying its block index" do
      blocks = long_body() ++ [%{"_type" => "image", "url" => "/a.jpg", "alt" => ""}]
      report = analyze(%{}, blocks)
      finding = Enum.find(report.findings, &(&1.code == :images_missing_alt))

      assert finding.severity == :error
      assert finding.field == :images
      assert finding.args.count == 1
      assert finding.args.indexes == [2]
      assert report.grade == :poor
    end

    test "an image with alt text passes" do
      blocks = long_body() ++ [%{"_type" => "image", "url" => "/a.jpg", "alt" => "A loaded kiln"}]
      report = analyze(%{}, blocks)
      refute :images_missing_alt in codes(report)
    end

    test "a missing social image is an info" do
      report = analyze(%{seo_image: ""})
      assert Enum.find(report.findings, &(&1.code == :og_image_missing)).severity == :info
    end

    test "a featured image does NOT satisfy the social image" do
      # Delivery emits og:image from seo_image alone (ContentController's
      # render_content_body/6 has no featured-image fallback), so reporting
      # this as satisfied would promise a preview that never ships.
      report = analyze(%{seo_image: "", featured_image_id: Ecto.UUID.generate()})
      assert :og_image_missing in codes(report)
    end

    test "an explicit social image satisfies it" do
      refute :og_image_missing in codes(analyze(%{seo_image: "/uploads/card.jpg"}))
    end
  end

  describe "readability is English-only" do
    test "a non-English locale emits no reading-grade finding" do
      dense = [
        %{
          "_type" => "rich_text",
          "body" => [
            %{
              "_type" => "block",
              "style" => "normal",
              "children" => [
                %{"text" => String.duplicate("Die Erkenntnistheorie unterscheidet ", 60)}
              ]
            }
          ]
        }
      ]

      report = analyze(%{locale: "de"}, dense)
      refute :hard_to_read in codes(report)
    end

    test "impenetrable English prose is flagged" do
      dense = [
        %{
          "_type" => "rich_text",
          "body" => [
            %{
              "_type" => "block",
              "style" => "normal",
              "children" => [
                %{
                  "text" =>
                    String.duplicate(
                      "Notwithstanding the aforementioned epistemological considerations regarding institutional methodologies, the administration subsequently promulgated comprehensive regulatory frameworks incorporating multitudinous interdisciplinary perspectives ",
                      6
                    )
                }
              ]
            }
          ]
        }
      ]

      report = analyze(%{locale: "en"}, dense)
      finding = Enum.find(report.findings, &(&1.code == :hard_to_read))

      assert finding
      assert finding.args.score < 50.0
    end
  end
end
