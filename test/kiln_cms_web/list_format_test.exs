defmodule KilnCMSWeb.ListFormatTest do
  @moduledoc """
  Lists read naturally in every shipped locale (#2379): the catalog, not the
  code, decides the separator and the conjunction.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.ListFormat

  doctest KilnCMSWeb.ListFormat

  defp in_locale(locale, items) do
    Gettext.with_locale(KilnCMSWeb.Gettext, locale, fn -> ListFormat.to_sentence(items) end)
  end

  test "an empty list and a single item need no joining" do
    assert ListFormat.to_sentence([]) == ""
    assert ListFormat.to_sentence(["Trash"]) == "Trash"
  end

  test "English joins the last pair with \"and\"" do
    assert in_locale("en", ["Forms", "Trash"]) == "Forms and Trash"

    assert in_locale("en", ["Forms", "Webhooks", "API keys", "Trash"]) ==
             "Forms, Webhooks, API keys and Trash"
  end

  test "Spanish joins the last pair with \"y\"" do
    assert in_locale("es", ["Formularios", "Papelera"]) == "Formularios y Papelera"

    assert in_locale("es", ["Formularios", "Webhooks", "Papelera"]) ==
             "Formularios, Webhooks y Papelera"
  end

  test "French joins the last pair with \"et\"" do
    assert in_locale("fr", ["Formulaires", "Corbeille"]) == "Formulaires et Corbeille"

    assert in_locale("fr", ["Formulaires", "Webhooks", "Corbeille"]) ==
             "Formulaires, Webhooks et Corbeille"
  end
end
