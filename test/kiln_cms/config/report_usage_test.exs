defmodule KilnCMS.Config.ReportUsageTest do
  @moduledoc """
  Pins that the seven post-boot configuration warnings #1126 moved onto
  `KilnCMS.Config.Report.warn/3` stay there.

  A source-grep rather than exercising each check: five of the six
  `KilnCMS.Application` checks need boot-time conditions (`:prod` compile
  env, a second organization, an unsigned provenance chain, egress flags on
  three separate AI features) that are awkward and slow to assemble just to
  prove which function a private helper calls — and `KilnCMS.Config.Report`
  itself is already exercised directly (`KilnCMS.Config.ReportTest`). What
  actually needs pinning is that nobody quietly reverts one of these seven
  call sites to a bare `Logger.warning`, which would compile clean, pass
  every other test, and simply stop reaching Sentry — exactly the silent
  regression #1126 exists to prevent. Same technique
  `KilnCMS.Config.EnvTest` uses for "no bare IO.warn survives in
  runtime.exs".
  """
  use ExUnit.Case, async: true

  @application_ex Path.join([__DIR__, "..", "..", "..", "lib", "kiln_cms", "application.ex"])
  @branding_ex Path.join([__DIR__, "..", "..", "..", "lib", "kiln_cms", "branding.ex"])
  @env_ex Path.join([__DIR__, "..", "..", "..", "lib", "kiln_cms", "config", "env.ex"])

  defp warn_if_functions(source) do
    ~r/defp (warn_if_\w+) do(.*?)\n  end/s
    |> Regex.scan(source)
    |> Map.new(fn [_whole, name, body] -> {name, body} end)
  end

  test "every warn_if_* boot check in KilnCMS.Application reports via Config.Report" do
    source = File.read!(@application_ex)
    functions = warn_if_functions(source)

    expected = ~w(
      warn_if_no_mailer_in_prod
      warn_if_multi_tenant_without_strict_host
      warn_if_chain_unsigned
      warn_if_seo_drafting_egresses
      warn_if_assist_egresses
      warn_if_ask_egresses
    )

    assert Enum.sort(Map.keys(functions)) == Enum.sort(expected),
           "KilnCMS.Application's warn_if_* checks changed — update this test's " <>
             "expected list (and make sure the new one reports via Config.Report too)."

    for {name, body} <- functions do
      refute body =~ "Logger.warning",
             "#{name} calls Logger.warning directly — it reached Sentry only via " <>
               "KilnCMS.Config.Report.warn/3 before #1126, and a bare Logger.warning " <>
               "silently stops reaching it (Sentry.LoggerHandler drops plain :warning logs)."

      assert body =~ "KilnCMS.Config.Report.warn(",
             "#{name} should report via KilnCMS.Config.Report.warn/3 (#1126)."
    end
  end

  test "the branding AA-contrast warning reports via Config.Report" do
    source = File.read!(@branding_ex)

    # The css_variables/1 :error branch specifically — branding.ex has other
    # Logger.warning calls (a DB read failure, a config-grammar check already
    # covered by #1089/Env at boot) that are a different concern and out of
    # this issue's scope; isolate the one clause this issue is about, bounded
    # on both ends so the match can't run past it into an unrelated clause.
    [_before, rest] = String.split(source, ":error ->\n        # No fill/ink pair", parts: 2)
    [error_clause, _after] = String.split(rest, "\n    end\n  end", parts: 2)

    refute error_clause =~ "Logger.warning"
    assert error_clause =~ "KilnCMS.Config.Report.warn("
  end

  test "Env.replay_collected/0 reports via Config.Report too, not its own Sentry call" do
    source = File.read!(@env_ex)
    [_before, after_def] = String.split(source, "def replay_collected do", parts: 2)
    [replay_body, _rest] = String.split(after_def, "\n  end", parts: 2)

    assert replay_body =~ "Report.warn("

    refute replay_body =~ "Sentry.capture_message",
           "replay_collected/0 should delegate to Config.Report.warn/3 rather than " <>
             "calling Sentry directly, so Env and every other config warning share " <>
             "one path (#1126)."
  end
end
