defmodule KilnCMS.Challenge.RecaptchaTest do
  @moduledoc """
  Google reCAPTCHA v2's verification (#2249), through `KilnCMS.Challenge.verify/4`
  so the transport, the deadline, the token precheck and the core's claim
  checks are the real ones. The network is a `Req.Test` stub (`config/test.exs`).

  `async: false`: `KilnCMS.ChallengeFixtures.enable!/1` writes node-wide config.
  """
  # DataCase: `hostname_allowed?/1` looks the host up among the sites.
  use KilnCMS.DataCase, async: false

  @moduletag :capture_log

  import KilnCMS.ChallengeFixtures

  alias KilnCMS.Challenge
  alias KilnCMS.Challenge.Providers.Recaptcha

  setup do
    enable!(provider: "recaptcha", providers: [])
    %{config: Challenge.config()}
  end

  # Answers siteverify with `answer` (a map, JSON-encoded) and reports the
  # request to the test.
  defp answer(answer, status \\ 200) do
    test = self()

    Req.Test.stub(Challenge, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:siteverify, conn.host, conn.request_path, URI.decode_query(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, if(is_map(answer), do: Jason.encode!(answer), else: answer))
    end)
  end

  defp ours(host), do: host in ["localhost", "kiln.test"]

  defp verify(config, token \\ "a-token", action \\ :sign_in),
    do: Challenge.verify(config, token, action, hostname?: &ours/1)

  test "is the configured provider, and conforms", %{config: config} do
    assert config.provider == Recaptcha
    assert Kiln.Challenge.Provider.conformance(Recaptcha) == :ok
  end

  test "a genuine v2 token for this host passes, verified at recaptcha.net", %{config: config} do
    answer(%{
      "success" => true,
      "hostname" => "localhost",
      "challenge_ts" => "2026-11-09T00:00:00Z"
    })

    assert verify(config) == :ok
    assert_received {:siteverify, "www.recaptcha.net", "/recaptcha/api/siteverify", fields}
    assert fields == %{"secret" => "test-secret", "response" => "a-token"}
  end

  test "v2 carries no action, so a pass is good for any of Kiln's checks", %{config: config} do
    answer(%{"success" => true, "hostname" => "localhost"})

    for action <- [:sign_in, :register, :form] do
      assert verify(config, "a-token", action) == :ok
    end
  end

  test "an answer carrying a score (a v3 or Enterprise key) is refused, whatever it is",
       %{config: config} do
    for score <- [0.1, 0.9, 1.0] do
      answer(%{"success" => true, "hostname" => "localhost", "score" => score})
      assert verify(config) == {:error, :invalid}, "score #{score}"
    end
  end

  test "a token solved on someone else's page is refused", %{config: config} do
    answer(%{"success" => true, "hostname" => "phish.example.net"})
    assert verify(config) == {:error, :hostname_mismatch}
  end

  test "an answer naming no hostname (an Android key) is refused", %{config: config} do
    answer(%{"success" => true, "apk_package_name" => "com.example"})
    assert verify(config) == {:error, :hostname_mismatch}
  end

  test "Google's test keys answer testkey.google.com, accepted once listed" do
    answer(%{"success" => true, "hostname" => "testkey.google.com"})

    refute Challenge.hostname_allowed?("testkey.google.com")

    enable!(provider: "recaptcha", providers: [], hostnames: ["testkey.google.com"])

    assert Challenge.verify(Challenge.config(), "t", :sign_in,
             hostname?: &Challenge.hostname_allowed?/1
           ) == :ok
  end

  test "error codes map as Turnstile's do", %{config: config} do
    answer(%{"success" => false, "error-codes" => ["timeout-or-duplicate"]})
    assert verify(config) == {:error, :expired}

    answer(%{"success" => false, "error-codes" => ["invalid-input-response"]})
    assert verify(config) == {:error, :invalid}

    answer(%{"success" => false, "error-codes" => ["invalid-input-secret"]})
    assert verify(config) == {:error, {:unavailable, :not_configured}}
  end

  test "a 5xx is unavailable, a 4xx a refusal, garbage unavailable", %{config: config} do
    answer(%{}, 503)
    assert verify(config) == {:error, {:unavailable, :http_status}}

    answer(%{}, 400)
    assert verify(config) == {:error, :invalid}

    answer("<html>")
    assert verify(config) == {:error, {:unavailable, :malformed_response}}
  end

  test "the widget waits for the onload callback and asks people to click" do
    assert %{
             script_url: "https://www.recaptcha.net/recaptcha/api.js?render=explicit",
             global: "grecaptcha",
             onload_param: "onload",
             response_field: "g-recaptcha-response",
             interactive: true
           } = Recaptcha.widget()

    refute Map.has_key?(Recaptcha.widget(), :action_option)
  end

  test "the page policy never names www.google.com" do
    sources = Recaptcha.csp_sources()

    assert sources == %{
             script_src: [
               "https://www.recaptcha.net/recaptcha/",
               "https://www.gstatic.com/recaptcha/"
             ],
             frame_src: ["https://www.recaptcha.net/recaptcha/"],
             connect_src: []
           }

    refute sources |> Map.values() |> List.flatten() |> Enum.any?(&(&1 =~ "google.com"))
  end

  test "the widget data the browser is told carries no action option", %{config: config} do
    widget = Challenge.widget(config, :form)

    assert widget.action == "form"
    assert widget.action_option == nil
    assert widget.onload_param == "onload"
    assert widget.render_options == %{}
  end
end
