defmodule KilnCMS.Challenge.FormGateTest do
  @moduledoc """
  What a public form submission's human-verification answer does (#2249):
  `KilnCMS.Challenge.Gate.form/3`, and the clamp that decides whether a form
  asks at all (`KilnCMS.Challenge.form_required?/2`).

  `async: false`: `KilnCMS.ChallengeFixtures.enable!/1` writes application env
  and an OS variable, both node-wide.
  """
  use KilnCMS.DataCase, async: false

  # The wrong-host case logs; the assertions are on the verdicts.
  @moduletag :capture_log

  import ExUnit.CaptureLog
  import KilnCMS.ChallengeFixtures

  alias KilnCMS.Challenge
  alias KilnCMS.Challenge.Gate

  @always %{challenge: :always}
  @off %{challenge: :off}

  describe "when the form asks for a check" do
    setup do
      enable!()
      :ok
    end

    test "a passing token is accepted as :passed, verified for the form action" do
      assert Gate.form(@always, "pass", remote_ip: "203.0.113.9") == {:accept, :passed}
      assert_received {:challenge_verify, "pass", opts}
      assert opts[:action] == "form"
    end

    test "no token is held as :missing, and the provider is never asked" do
      assert Gate.form(@always, nil) == {:accept, :missing}
      assert Gate.form(@always, "") == {:accept, :missing}
      refute_received {:challenge_verify, _, _}
    end

    test "no token is still held during an outage — never admitted on the provider's say-so" do
      # An outage noticed by a sign-in check.
      assert {:error, {:unavailable, _}} = Challenge.verify(Challenge.config(), "down", :sign_in)
      assert Challenge.outage?()

      assert Gate.form(@always, nil) == {:accept, :missing}
    end

    test "a form check the provider could not answer never opens sign-in's outage window" do
      Challenge.clear_outage()
      refute Challenge.outage?()

      for _ <- 1..5, do: assert(Gate.form(@always, "down") == {:accept, :unavailable})
      assert Gate.form(@always, "crash") == {:accept, :unavailable}

      refute Challenge.outage?()
    end

    test "a token the provider could not check is held as :unavailable" do
      assert Gate.form(@always, "down") == {:accept, :unavailable}
    end

    test "a refused token is refused, whatever the reason" do
      for token <- ["fail", "expired", String.duplicate("x", 3000), "bad\ntoken", %{"a" => 1}] do
        assert Gate.form(@always, token) == {:refuse, :failed}, inspect(token)
      end
    end

    test "a provider that crashes could not answer: held, not admitted" do
      assert Gate.form(@always, "crash") == {:accept, :unavailable}
    end

    test "a token solved on a host this deployment does not serve is held as :wrong_host" do
      # Logged at most once a minute per node: start with that allowance unspent.
      KilnCMS.Accounts.ThrottleStore.Local.set(
        :challenge_form_wrong_host_logged,
        :timer.minutes(1),
        0
      )

      log =
        capture_log(fn ->
          assert Gate.form(@always, "host:shop.example.net") == {:accept, :wrong_host}
        end)

      assert log =~ ~s("shop.example.net")
      assert log =~ "CHALLENGE_HOSTNAMES"
    end

    test "another site's host on this deployment is accepted" do
      org = KilnCMS.OrgFixtures.org("formgate")

      assert Gate.form(@always, "host:#{org.slug}.localhost") == {:accept, :passed}
      assert Gate.form(@always, "host:localhost") == {:accept, :passed}
    end

    test "a host the operator listed in CHALLENGE_HOSTNAMES is accepted" do
      enable!(hostnames: ["Shop.Example.net"])
      assert Gate.form(@always, "host:shop.example.net") == {:accept, :passed}
    end

    test "the request's own host plays no part: an unlisted host is held whatever was dialled" do
      assert Gate.form(@always, "host:evil.example.net") == {:accept, :wrong_host}
    end

    test "a form left :off needs nothing and never asks the provider" do
      assert Gate.form(@off, "fail") == :not_required
      refute_received {:challenge_verify, _, _}
    end
  end

  describe "the operator's ceiling clamps every form to :off" do
    test "with no provider configured" do
      assert Gate.form(@always, "fail") == :not_required
      refute Challenge.form_required?(Challenge.config(), @always)
    end

    test "with forms turned off (CHALLENGE_FORMS=false)" do
      enable!(forms: false)

      assert Gate.form(@always, "fail") == :not_required
      refute Challenge.forms_available?(Challenge.config())
      refute_received {:challenge_verify, _, _}
    end

    test "with the kill switch on" do
      enable!(disabled: true)

      assert Gate.form(@always, "fail") == :not_required
      refute Challenge.form_required?(Challenge.config(), @always)
    end

    test "forms stay available with sign-in and registration both off" do
      enable!(sign_in: :off, registration: :off)

      assert Challenge.form_required?(Challenge.config(), @always)
      refute Challenge.enabled?(Challenge.config())
      assert Gate.form(@always, "pass") == {:accept, :passed}
    end
  end

  describe "configuration" do
    test "the form widget and the fingerprint follow the provider and site key" do
      enable!()
      config = Challenge.config()

      assert %{action: "form", site_key: "test-site-key", provider: "fake"} =
               Challenge.widget(config, :form)

      assert "fake:test-site-key:" <> digest = Challenge.forms_fingerprint(config)
      assert byte_size(digest) == 12
      assert Challenge.csp_sources(config, :forms).script_src == ["https://challenge.test"]

      enable!(forms: false)
      config = Challenge.config()
      assert Challenge.widget(config, :form) == nil
      assert Challenge.forms_fingerprint(config) == ""
      assert Challenge.csp_sources(config, :forms).script_src == []
    end
  end
end
