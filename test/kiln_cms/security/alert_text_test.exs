defmodule KilnCMS.Security.AlertTextTest do
  @moduledoc """
  `KilnCMS.Security.AlertText.setting_label/1` (#3495): a kind named as its
  setting's checkbox says it, for the notices that name the kinds turned off.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Security.Alerts
  alias KilnCMS.Security.AlertText

  @settable Alerts.site_kinds() ++ Alerts.platform_optional_kinds()

  test "every kind a setting turns off has its own label, not the alert's" do
    for kind <- @settable do
      label = AlertText.setting_label(kind)

      assert label != AlertText.kind_label(kind), "#{kind} has no setting label"
      assert label == AlertText.setting_label(Atom.to_string(kind))
    end

    assert AlertText.setting_label(:lockout) == "Account locked out"
    assert AlertText.setting_label("api_key_rate_limited") == "API keys over a rate limit"
  end

  test "a kind with no setting, or none this release knows, says the alert's label" do
    assert AlertText.setting_label("new_api_key") == AlertText.kind_label("new_api_key")
    assert AlertText.setting_label("zz_unknown_kind") == "Security alert"
    assert AlertText.setting_label(nil) == "Security alert"
  end

  test "is said in the current locale" do
    Gettext.with_locale(KilnCMSWeb.Gettext, "es", fn ->
      assert AlertText.setting_label(:lockout) == "Cuenta bloqueada"
    end)
  end
end
