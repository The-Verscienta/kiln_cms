defmodule KilnCMS.AnalyticsTest do
  @moduledoc "The runtime-readable referrer-attribution gate (#619)."
  use ExUnit.Case, async: false

  alias KilnCMS.Analytics

  setup do
    original = Application.get_env(:kiln_cms, :analytics_referrers, [])
    on_exit(fn -> Application.put_env(:kiln_cms, :analytics_referrers, original) end)
    :ok
  end

  test "off by default — the shipped compiled config, before any test mutates it" do
    assert Application.get_env(:kiln_cms, :analytics_referrers, [])[:enabled] != true
    refute Analytics.referrers_enabled?()
  end

  test "off when explicitly disabled" do
    Application.put_env(:kiln_cms, :analytics_referrers, enabled: false)
    refute Analytics.referrers_enabled?()
  end

  test "on when explicitly enabled" do
    Application.put_env(:kiln_cms, :analytics_referrers, enabled: true)
    assert Analytics.referrers_enabled?()
  end

  test "an absent config key reads as disabled, not as a crash" do
    Application.delete_env(:kiln_cms, :analytics_referrers)
    refute Analytics.referrers_enabled?()
  end
end
