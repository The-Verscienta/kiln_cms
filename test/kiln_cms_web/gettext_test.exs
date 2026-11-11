defmodule KilnCMSWeb.GettextTest do
  # The locale chain a missing message walks (#2637). The end-to-end check, a
  # `fr-CA` page in French, is in `KilnCMSWeb.ChromeLocaleTest`.
  use ExUnit.Case, async: true

  doctest KilnCMSWeb.Gettext

  alias KilnCMSWeb.Gettext, as: Backend

  test "a regional tag walks to its language, then stops" do
    assert Backend.parent_locale("pt-BR") == "pt_BR"
    assert Backend.parent_locale("pt_BR") == "pt"
    assert Backend.parent_locale("zh-Hant-TW") == "zh_Hant_TW"
    assert Backend.parent_locale("zh_Hant_TW") == "zh_Hant"
    assert Backend.parent_locale("en") == nil
    assert Backend.parent_locale(nil) == nil
  end

  test "each tag reaches its own language's catalog" do
    Gettext.with_locale(Backend, "fr", fn ->
      assert Gettext.gettext(Backend, "Blog") == "Blogue"
    end)

    Gettext.with_locale(Backend, "es-MX", fn ->
      assert Gettext.gettext(Backend, "Search") == "Buscar"
    end)
  end
end
