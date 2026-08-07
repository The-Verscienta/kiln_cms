defmodule KilnCMS.Ask.PromptTest do
  @moduledoc "The messages sent to an ask-your-content model (#339)."
  use ExUnit.Case, async: true

  alias KilnCMS.Ask.Prompt

  defp sources do
    [
      %{
        type: "page",
        title: "Firing schedules",
        url: "/firing",
        excerpt: "Cone 6 takes 9 hours."
      },
      %{type: "post", title: "Glaze safety", url: "/blog/glaze", excerpt: "Barium is toxic."}
    ]
  end

  test "numbers the excerpts and asks for those numbers back as citations" do
    {system, user} = Prompt.build("How long is a cone 6 firing?", sources())

    assert user =~ "[1] Firing schedules"
    assert user =~ "Cone 6 takes 9 hours."
    assert user =~ "[2] Glaze safety"
    assert system =~ "square brackets"
  end

  test "the question and the excerpts are distinguishable, and the excerpts fenced" do
    {_system, user} = Prompt.build("How long is a cone 6 firing?", sources())

    assert user =~ "Question: How long is a cone 6 firing?"
    # Opening and closing marker around the passages.
    assert user |> String.split("-----") |> length() == 3
  end

  test "the system prompt forbids outside knowledge and allows 'I don't know'" do
    {system, _user} = Prompt.build("anything", sources())

    assert system =~ "only the numbered excerpts"
    assert system =~ "general knowledge"
    assert system =~ "do not answer the question, say so"
  end

  test "the language is the CONTENT locale, not the caller's" do
    {system, _user} = Prompt.build("q", sources(), locale: "fr")
    assert system =~ KilnCMS.I18n.language_name("fr")

    {default, _user} = Prompt.build("q", sources())
    assert default =~ KilnCMS.I18n.language_name(KilnCMS.I18n.default_locale())
  end

  test "an unknown locale option falls back rather than crashing the ask" do
    # `KilnCMS.Ask` validates the locale before it gets here, so this only ever
    # fires on a direct call — but a prompt builder that raises would take down
    # a request that was supposed to degrade to retrieval-only.
    {system, _user} = Prompt.build("q", sources(), locale: nil)
    assert system =~ KilnCMS.I18n.language_name(KilnCMS.I18n.default_locale())
  end

  test "an empty retrieval says so explicitly rather than sending bare fences" do
    # The failure this guards: an empty region reads as a truncated prompt, and
    # a model with nothing to ground on answers from general knowledge — the
    # one thing RAG must not do.
    {_system, user} = Prompt.build("q", [])

    assert user =~ "no matching content was found"
  end

  test "a source with no excerpt still contributes its title, and no blank line" do
    {_system, user} =
      Prompt.build("q", [%{type: "page", title: "Kilns", url: "/k", excerpt: nil}])

    assert user =~ "[1] Kilns"
    refute user =~ "[1] Kilns\n\n"
  end

  test "string-keyed sources work too" do
    # `KilnCMS.Ask` builds atom-keyed maps, but a bespoke caller assembling
    # sources from decoded JSON would hand over string keys, and silently
    # dropping every title is worse than either working or failing loudly.
    {_system, user} = Prompt.build("q", [%{"title" => "Kilns", "excerpt" => "Hot."}])

    assert user =~ "[1] Kilns"
    assert user =~ "Hot."
  end
end
