defmodule KilnCMS.Security.Posture.Checks.HumanVerificationTest do
  @moduledoc """
  `core.human_verification` (#2252), read through `KilnCMS.Challenge.config/0`.

  `async: false`: the configuration is application env (and the fixture's
  secret an OS variable), both node-wide.
  """
  use ExUnit.Case, async: false

  import KilnCMS.PostureFixtures, only: [context: 1]

  alias KilnCMS.ChallengeFixtures
  alias KilnCMS.Security.Posture.Checks.HumanVerification

  @moduletag :capture_log

  defp run, do: HumanVerification.run(context(nil))

  defp merge!(opts) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Challenge,
      Keyword.merge(Application.get_env(:kiln_cms, KilnCMS.Challenge, []), opts)
    )

    KilnCMS.Challenge.reset_cache()
  end

  test "a usable provider passes" do
    ChallengeFixtures.enable!()
    assert %{status: :pass, facts: %{provider: "fake", sign_in: "adaptive"}} = run()
  end

  test "the kill switch warns" do
    ChallengeFixtures.enable!()
    merge!(disabled: true)

    assert %{status: :warn, facts: %{kill_switch: true}} = run()
  end

  test "a named provider nobody installed warns" do
    ChallengeFixtures.enable!()
    merge!(provider: "nobody")

    result = run()
    assert result.status == :warn
    assert result.summary =~ "can't be used"
  end

  test "a usable provider switched off for both sign-in and registration warns" do
    ChallengeFixtures.enable!(sign_in: :off, registration: :off)

    result = run()
    assert result.status == :warn
    assert result.summary =~ "switched off for both"
    assert result.facts == %{provider: "fake", sign_in: "off", registration: "off"}
  end

  test "no provider warns" do
    assert %{status: :warn, facts: %{provider: nil, kill_switch: false}} = run()
  end
end
