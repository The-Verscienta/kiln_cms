defmodule KilnCMS.Slug.LintTest do
  use ExUnit.Case, async: true

  alias KilnCMS.Slug.Lint

  test "a clean short slug with a matching keyphrase raises nothing" do
    assert Lint.lint(%{
             slug: "ceramic-kiln-care",
             title: "Ceramic Kiln Care for Beginners",
             seo_keywords: "ceramic kiln care"
           }) == []
  end

  test "long slugs are flagged by segment count and by raw length" do
    assert :slug_long in Lint.lint(%{slug: "one-two-three-four-five-six-seven"})
    assert :slug_long in Lint.lint(%{slug: String.duplicate("a", 76)})
    refute :slug_long in Lint.lint(%{slug: "one-two-three-four-five-six"})
  end

  test "a keyphrase missing from the slug is flagged, stop words ignored" do
    findings = Lint.lint(%{slug: "something-else", title: "T", seo_keywords: "ceramic kiln"})
    assert :keyphrase_not_in_slug in findings

    # "Guide to the Kiln" ~ "guide-kiln": stop words never cause a mismatch.
    assert :keyphrase_not_in_slug not in Lint.lint(%{
             slug: "guide-kiln",
             title: "Guide to the Kiln",
             seo_keywords: "Guide to the Kiln"
           })
  end

  test "a keyphrase absent from title and SEO title is flagged; either field satisfies it" do
    fields = %{slug: "ceramic-kiln", title: "Something Else", seo_keywords: "ceramic kiln"}
    assert :keyphrase_not_in_title in Lint.lint(fields)

    satisfied = Map.put(fields, :seo_title, "The Best Ceramic Kiln")
    assert :keyphrase_not_in_title not in Lint.lint(satisfied)
  end

  test "no keyphrase means no keyphrase checks; blank slug means no slug checks" do
    assert Lint.lint(%{slug: "whatever-here", title: "T"}) == []
    assert Lint.lint(%{slug: "", title: "T", seo_keywords: "kiln"}) == [:keyphrase_not_in_title]
  end
end
