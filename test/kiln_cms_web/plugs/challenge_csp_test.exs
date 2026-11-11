defmodule KilnCMSWeb.Plugs.ChallengeCspTest do
  @moduledoc """
  The auth pages' Content-Security-Policy admits the human-verification
  provider's origin only while a challenge can be shown there (#2249), and is
  byte-for-byte unchanged otherwise.

  `async: false`: `KilnCMS.ChallengeFixtures.enable!/1` writes node-wide config.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.ChallengeFixtures

  alias KilnCMS.Challenge
  alias KilnCMSWeb.Plugs.ChallengeCsp

  @origin "https://challenge.test"

  defp policy(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()

  defp directive(policy, name) do
    policy
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&String.starts_with?(&1, name <> " "))
  end

  # The nonce is fresh per response; everything else must match.
  defp scrub(policy), do: String.replace(policy, ~r/'nonce-[^']+'/, "'nonce-*'")

  describe "the auth pages" do
    test "admit the provider in script-src and frame-src, and nothing else changes", %{conn: conn} do
      off = conn |> get(~p"/sign-in") |> policy() |> scrub()

      enable!()
      on = build_conn() |> get(~p"/sign-in") |> policy() |> scrub()

      assert directive(on, "script-src") == directive(off, "script-src") <> " " <> @origin
      assert directive(on, "frame-src") == directive(off, "frame-src") <> " " <> @origin
      assert directive(on, "connect-src") == directive(off, "connect-src")

      # Exactly those two additions, and every other directive as it was.
      assert on ==
               off
               |> String.replace(directive(off, "script-src"), directive(on, "script-src"))
               |> String.replace(directive(off, "frame-src"), directive(on, "frame-src"))
    end

    test "are unchanged with no provider, the kill switch, or both modes off", %{conn: conn} do
      baseline = conn |> get(~p"/sign-in") |> policy() |> scrub()

      for opts <- [[provider: nil], [disabled: true], [sign_in: :off, registration: :off]] do
        enable!(opts)
        assert build_conn() |> get(~p"/sign-in") |> policy() |> scrub() == baseline
      end
    end

    test "are widened when only registration can ask" do
      enable!(sign_in: :off, registration: :always)
      assert build_conn() |> get(~p"/register") |> policy() |> directive("script-src") =~ @origin
    end
  end

  describe "the provider decides the sources (#2249)" do
    test "reCAPTCHA adds recaptcha.net and gstatic, and never www.google.com", %{conn: conn} do
      off = conn |> get(~p"/sign-in") |> policy() |> scrub()

      enable!(provider: "recaptcha")
      on = build_conn() |> get(~p"/sign-in") |> policy() |> scrub()

      assert directive(on, "script-src") ==
               directive(off, "script-src") <>
                 " https://www.recaptcha.net/recaptcha/ https://www.gstatic.com/recaptcha/"

      assert directive(on, "frame-src") ==
               directive(off, "frame-src") <> " https://www.recaptcha.net/recaptcha/"

      assert directive(on, "connect-src") == directive(off, "connect-src")
      refute on =~ "www.google.com"
    end

    test "a plugin's provider adds its own sources", %{conn: conn} do
      off = conn |> get(~p"/sign-in") |> policy() |> scrub()

      enable!(provider: "dep_fixture")
      on = build_conn() |> get(~p"/sign-in") |> policy() |> scrub()

      assert directive(on, "script-src") ==
               directive(off, "script-src") <> " https://captcha.dep-fixture.test/v1/"

      assert directive(on, "frame-src") ==
               directive(off, "frame-src") <> " https://captcha.dep-fixture.test"
    end

    @tag :capture_log
    test "an id no provider answers to leaves the policy byte for byte", %{conn: conn} do
      baseline = conn |> get(~p"/sign-in") |> policy() |> scrub()

      enable!(provider: "nobody_installed_this")
      assert build_conn() |> get(~p"/sign-in") |> policy() |> scrub() == baseline
    end
  end

  test "no other page is widened" do
    enable!()

    for path <- [~p"/", ~p"/editor"] do
      conn = get(build_conn(), path)

      case policy(conn) do
        nil -> :ok
        header -> refute header =~ @origin, "#{path} admitted the challenge origin"
      end
    end
  end

  describe "widen_policy/2" do
    @policy "script-src 'self' 'nonce-abc'; default-src 'self'; connect-src 'self'; frame-src 'self'"

    test "adds each list to its own directive" do
      assert ChallengeCsp.widen_policy(@policy, %{
               script_src: ["https://a.test"],
               frame_src: ["https://b.test"],
               connect_src: ["https://c.test"]
             }) ==
               "script-src 'self' 'nonce-abc' https://a.test; default-src 'self'; " <>
                 "connect-src 'self' https://c.test; frame-src 'self' https://b.test"
    end

    test "leaves a policy with nothing to add byte-for-byte alone" do
      odd = "script-src 'self';  default-src 'self' ;"

      assert ChallengeCsp.widen_policy(odd, %{script_src: [], frame_src: [], connect_src: []}) ==
               odd
    end

    test "never adds a directive the policy does not name" do
      assert ChallengeCsp.widen_policy("default-src 'self'", %{
               script_src: ["https://a.test"],
               frame_src: [],
               connect_src: []
             }) == "default-src 'self'"
    end
  end

  describe "widen_for_forms/2 (#2249)" do
    @page "script-src 'self' 'nonce-abc'; default-src 'self'; frame-src 'self' https://www.youtube.com"

    defp page_conn,
      do: put_resp_header(build_conn(), "content-security-policy", @page)

    test "adds the provider while a form can ask" do
      enable!()
      conn = ChallengeCsp.widen_for_forms(page_conn(), Challenge.config())

      assert policy(conn) ==
               "script-src 'self' 'nonce-abc' #{@origin}; default-src 'self'; " <>
                 "frame-src 'self' https://www.youtube.com #{@origin}"
    end

    test "is idempotent" do
      enable!()
      config = Challenge.config()
      once = ChallengeCsp.widen_for_forms(page_conn(), config)

      assert policy(ChallengeCsp.widen_for_forms(once, config)) == policy(once)
    end

    test "leaves the policy byte for byte while no form can ask" do
      for opts <- [[provider: nil], [disabled: true], [forms: false]] do
        enable!(opts)
        assert policy(ChallengeCsp.widen_for_forms(page_conn(), Challenge.config())) == @page
      end
    end

    test "leaves a conn with no policy alone" do
      enable!()
      assert policy(ChallengeCsp.widen_for_forms(build_conn(), Challenge.config())) == nil
    end
  end

  test "forms being available does not widen the auth pages", %{conn: conn} do
    baseline = conn |> get(~p"/sign-in") |> policy() |> scrub()

    enable!(sign_in: :off, registration: :off, forms: true)
    assert Challenge.forms_available?(Challenge.config())
    assert build_conn() |> get(~p"/sign-in") |> policy() |> scrub() == baseline
  end

  test "the plug leaves a conn untouched when nothing is configured" do
    conn =
      build_conn()
      |> put_resp_header("content-security-policy", "script-src 'self';x")
      |> ChallengeCsp.call([])

    assert policy(conn) == "script-src 'self';x"
    refute Challenge.enabled?(Challenge.config())
  end
end
