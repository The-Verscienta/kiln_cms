defmodule KilnCMS.Challenge.TurnstileTest do
  @moduledoc """
  Cloudflare Turnstile's verification (#2249), through `KilnCMS.Challenge.verify/4`
  so the transport, the deadline and the token precheck are the real ones. The
  network is a `Req.Test` stub (`config/test.exs`).

  `async: false`: `KilnCMS.ChallengeFixtures.enable!/1` writes node-wide config.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import KilnCMS.ChallengeFixtures

  alias KilnCMS.Challenge
  alias KilnCMS.Challenge.Providers.Turnstile

  setup do
    enable!(provider: "turnstile", providers: [])
    %{config: Challenge.config()}
  end

  # Answers siteverify with `answer` (a map, JSON-encoded) and reports the
  # request's decoded form fields to the test.
  defp answer(answer, status \\ 200) do
    test = self()

    Req.Test.stub(Challenge, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:siteverify, conn.request_path, URI.decode_query(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, if(is_map(answer), do: Jason.encode!(answer), else: answer))
    end)
  end

  defp ours(host), do: host in ["localhost", "kiln.test"]

  defp verify(config, token \\ "a-token", opts \\ [hostname?: &ours/1]),
    do: Challenge.verify(config, token, :sign_in, opts)

  test "a genuine token for this host and action passes", %{config: config} do
    answer(%{"success" => true, "hostname" => "localhost", "action" => "sign_in"})

    assert verify(config) == :ok
    assert_received {:siteverify, "/turnstile/v0/siteverify", fields}
    assert fields == %{"secret" => "test-secret", "response" => "a-token"}
  end

  test "the client address goes out only when the operator turned it on", %{config: config} do
    answer(%{"success" => true, "hostname" => "localhost", "action" => "sign_in"})

    assert Challenge.verify(config, "t", :sign_in, remote_ip: "203.0.113.9") == :ok
    assert_received {:siteverify, _, fields}
    refute Map.has_key?(fields, "remoteip")

    enable!(provider: "turnstile", providers: [], send_remote_ip: true)
    assert Challenge.verify(Challenge.config(), "t", :sign_in, remote_ip: "203.0.113.9") == :ok
    assert_received {:siteverify, _, %{"remoteip" => "203.0.113.9"}}
  end

  test "a token solved on a host this deployment does not serve is refused", %{config: config} do
    answer(%{"success" => true, "hostname" => "phish.example.net", "action" => "sign_in"})
    assert verify(config) == {:error, :hostname_mismatch}
  end

  test "an answer that names no hostname is refused when one is checked", %{config: config} do
    answer(%{"success" => true, "action" => "sign_in"})
    assert verify(config) == {:error, :hostname_mismatch}
  end

  test "a token drawn for another action is refused", %{config: config} do
    answer(%{"success" => true, "hostname" => "localhost", "action" => "register"})
    assert verify(config) == {:error, :action_mismatch}
  end

  test "a spent or stale token is :expired", %{config: config} do
    answer(%{"success" => false, "error-codes" => ["timeout-or-duplicate"]})
    assert verify(config) == {:error, :expired}
  end

  test "a forged token is :invalid", %{config: config} do
    answer(%{"success" => false, "error-codes" => ["invalid-input-response"]})
    assert verify(config) == {:error, :invalid}

    answer(%{"success" => false, "error-codes" => ["something-new"]})
    assert verify(config) == {:error, :invalid}
  end

  test "a wrong secret is the operator's problem: unavailable, not a refusal", %{config: config} do
    answer(%{"success" => false, "error-codes" => ["invalid-input-secret"]})
    assert verify(config) == {:error, {:unavailable, :not_configured}}
  end

  test "a 5xx, a provider error or a non-JSON body is unavailable", %{config: config} do
    answer(%{"error" => "boom"}, 502)
    assert verify(config) == {:error, {:unavailable, :http_status}}

    answer(%{"success" => false, "error-codes" => ["internal-error"]})
    assert verify(config) == {:error, {:unavailable, :http_status}}

    answer("<html>not json</html>")
    assert verify(config) == {:error, {:unavailable, :malformed_response}}
  end

  test "a 429 is unavailable, but any other 4xx is a refusal", %{config: config} do
    answer(%{"error" => "slow down"}, 429)
    assert verify(config) == {:error, {:unavailable, :http_status}}

    for status <- [400, 401, 403, 404] do
      answer(%{"error" => "no"}, status)
      assert verify(config) == {:error, :invalid}, "status #{status}"
    end
  end

  test "a transport failure is unavailable", %{config: config} do
    Req.Test.stub(Challenge, &Req.Test.transport_error(&1, :econnrefused))
    assert verify(config) == {:error, {:unavailable, :transport}}
  end

  test "the deadline bounds the whole call", %{config: config} do
    enable!(provider: "turnstile", providers: [], deadline: 50)

    Req.Test.stub(Challenge, fn conn ->
      Process.sleep(500)
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    assert verify(Challenge.config()) == {:error, {:unavailable, :timeout}}
    _ = config
  end

  test "an oversized, missing or garbled token never leaves the node", %{config: config} do
    answer(%{"success" => true, "hostname" => "localhost", "action" => "sign_in"})

    assert verify(config, String.duplicate("x", 2049)) == {:error, :malformed}
    assert verify(config, "a\u0000b") == {:error, :malformed}
    assert verify(config, nil) == {:error, :missing}
    assert verify(config, "") == {:error, :missing}

    refute_received {:siteverify, _, _}
  end

  test "names its one origin for the policy" do
    assert Turnstile.csp_sources() == %{
             script_src: ["https://challenges.cloudflare.com"],
             frame_src: ["https://challenges.cloudflare.com"],
             connect_src: []
           }

    assert Turnstile.widget().script_url =~ "render=explicit"
    assert Kiln.Challenge.Provider.conformance(Turnstile) == :ok
  end

  test "its widget keeps today's browser behaviour" do
    assert %{
             global: "turnstile",
             render_options: %{"response-field" => false},
             action_option: "action",
             response_field: "cf-turnstile-response"
           } = Turnstile.widget()

    assert {:ok, %{widget: %{interactive: false, onload_param: nil, api: :explicit_render}}} =
             Kiln.Challenge.Provider.describe(Turnstile)
  end
end
