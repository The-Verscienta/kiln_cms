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

  describe "low_count_threshold/0" do
    test "defaults to 5 when unconfigured" do
      Application.delete_env(:kiln_cms, :analytics_referrers)
      assert Analytics.low_count_threshold() == 5
    end

    test "reads a configured threshold" do
      Application.put_env(:kiln_cms, :analytics_referrers, low_count_threshold: 10)
      assert Analytics.low_count_threshold() == 10
    end
  end

  describe "suppress_low_count/1" do
    setup do
      Application.put_env(:kiln_cms, :analytics_referrers, low_count_threshold: 5)
      :ok
    end

    test "a true zero is never suppressed" do
      assert Analytics.suppress_low_count(0) == 0
    end

    test "a count below the threshold renders as \"< n\"" do
      assert Analytics.suppress_low_count(1) == "< 5"
      assert Analytics.suppress_low_count(4) == "< 5"
    end

    test "a count at or above the threshold is exact" do
      assert Analytics.suppress_low_count(5) == 5
      assert Analytics.suppress_low_count(42) == 42
    end

    test "follows a runtime-adjusted threshold" do
      Application.put_env(:kiln_cms, :analytics_referrers, low_count_threshold: 10)
      assert Analytics.suppress_low_count(7) == "< 10"
      assert Analytics.suppress_low_count(10) == 10
    end
  end
end
