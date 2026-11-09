defmodule KilnCMS.Challenge.RegistryTest do
  @moduledoc """
  Which human-verification provider an operator's id resolves to, and what
  the core does with one that misbehaves (#2249): a plugin's provider is used
  end to end, an id nobody installed or a provider that breaks the contract
  turns verification off, and a provider's answer is read conservatively —
  its claims enforced by the core, never trusted.

  `async: false`: `KilnCMS.ChallengeFixtures.enable!/1` writes application env
  and an OS variable, both node-wide, and the descriptor is memoised node-wide.
  """
  use KilnCMS.DataCase, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import KilnCMS.ChallengeFixtures
  import KilnCMS.RateLimitHelpers, only: [client_ip: 0]

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Challenge
  alias KilnCMS.Challenge.Gate
  alias KilnCMS.Challenge.Registry
  alias KilnCMS.Challenge.RegistryTest.Providers

  defp email, do: "registry-#{System.unique_integer([:positive])}@example.com"

  defp context(ip),
    do: Map.merge(%{security_request: %{ip: ip, user_agent: nil}}, Challenge.context(:browser))

  defp spend_account(address) do
    Enum.each(1..Challenge.threshold(:account), fn _ ->
      AccountThrottle.spend_free_attempt(address, Challenge.threshold(:account))
    end)
  end

  # Changes the configuration `enable!/1` set without resetting the memo.
  defp put_challenge_env(opts) do
    Application.put_env(
      :kiln_cms,
      Challenge,
      Keyword.merge(Application.get_env(:kiln_cms, Challenge, []), opts)
    )
  end

  defp clear_unusable_log,
    do: :ets.match_delete(ThrottleStore.Local, {{:challenge_unusable_logged, :_}, :_, :_})

  describe "the registered providers" do
    test "are the built-ins first, then plugins', then the test seam's" do
      enable!()

      assert [
               KilnCMS.Challenge.Providers.Turnstile,
               KilnCMS.Challenge.Providers.Recaptcha | rest
             ] = Registry.providers()

      assert KilnDepFixture.ChallengeProvider in rest
      assert KilnCMS.ChallengeFake in rest
      assert ["turnstile", "recaptcha" | _] = Registry.ids()
    end

    test "a built-in id always wins over a plugin's" do
      enable!(provider: "turnstile", providers: [Providers.Impostor])

      assert Registry.fetch("turnstile") == {:ok, KilnCMS.Challenge.Providers.Turnstile}
      assert Challenge.config().provider == KilnCMS.Challenge.Providers.Turnstile
    end

    test "every one of them conforms" do
      for module <- [
            KilnCMS.Challenge.Providers.Turnstile,
            KilnCMS.Challenge.Providers.Recaptcha,
            KilnDepFixture.ChallengeProvider,
            KilnCMS.ChallengeFake
          ] do
        assert Kiln.Challenge.Provider.conformance(module) == :ok, inspect(module)
      end
    end

    test "a module whose id/0 raises is no provider, and reading it crashes nothing" do
      enable!(providers: [Providers.RaisingId, KilnCMS.ChallengeFake])

      assert Registry.id_of(Providers.RaisingId) == nil
      refute "raising_id" in Registry.ids()
      assert Challenge.config().provider == KilnCMS.ChallengeFake
    end
  end

  describe "a plugin's provider (compiled as a dependency)" do
    setup do
      enable!(provider: "dep_fixture")
      test = self()

      Req.Test.stub(Challenge, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        fields = URI.decode_query(body)
        send(test, {:verify_request, conn.host, conn.request_path, fields})
        answer = if fields["response"] == "dep-pass", do: "pass", else: "no"
        Plug.Conn.send_resp(conn, 200, answer)
      end)

      :ok
    end

    test "is resolved, drawn and verified through the core's transport" do
      config = Challenge.config()
      assert config.provider == KilnDepFixture.ChallengeProvider

      assert %{
               provider: "dep_fixture",
               global: "depFixtureCaptcha",
               action_option: "action",
               response_field: nil
             } = Challenge.widget(config, :sign_in)

      assert Challenge.csp_sources(config).script_src == ["https://captcha.dep-fixture.test/v1/"]

      assert Challenge.verify(config, "dep-pass", :sign_in, hostname?: &(&1 == "localhost")) ==
               :ok

      assert_received {:verify_request, "captcha.dep-fixture.test", "/v1/verify",
                       %{"secret" => "test-secret", "response" => "dep-pass"}}

      assert Challenge.verify(config, "dep-fail", :sign_in) == {:error, :invalid}
    end
  end

  describe "a provider's own response field" do
    setup do
      enable!(providers: [Providers.WithField, KilnCMS.ChallengeFake])
      Registry.reset()
      on_exit(&Registry.reset/0)
      :ok
    end

    test "is known to the registry, and masked in error reports" do
      assert "with-field-response" in Registry.response_fields()
      assert "g-recaptcha-response" in Registry.response_fields()

      assert KilnCMSWeb.SentryScrubber.scrub_params(%Plug.Conn{
               params: %{"with-field-response" => "tok", "email" => "a@b.co"}
             }) == %{"with-field-response" => "*********", "email" => "a@b.co"}
    end

    test "is appended to a plain filter list, and the list is otherwise the operator's" do
      assert Registry.merge_filter_parameters(["password"], ["with-field-response"]) ==
               {:ok, ["password", "with-field-response"]}

      assert Registry.merge_filter_parameters(["password", "x"], ["x"]) == :unchanged
    end

    test "a list Phoenix compiled, or a keep list, is never rewritten" do
      compiled = Phoenix.Logger.compile_filter(["password", "g-recaptcha-response"])

      assert Registry.merge_filter_parameters(compiled, ["g-recaptcha-response"]) == :unchanged

      assert Registry.merge_filter_parameters(compiled, ["with-field-response"]) ==
               {:unfiltered, ["with-field-response"]}

      # A keep list filters everything it does not keep.
      assert Registry.merge_filter_parameters({:keep, ["id"]}, ["with-field-response"]) ==
               :unchanged

      assert Registry.merge_filter_parameters({:keep, ["with-field-response"]}, [
               "with-field-response"
             ]) == {:unfiltered, ["with-field-response"]}
    end
  end

  describe "an operator's id nothing answers to" do
    test "turns verification off, and says which ids exist — once a minute" do
      enable!(provider: "nobody_installed_this")

      log =
        capture_log(fn ->
          clear_unusable_log()
          assert Challenge.config().provider == nil
          assert Challenge.config().provider == nil
        end)

      assert log =~ ~s(CHALLENGE_PROVIDER="nobody_installed_this")
      assert log =~ "names no installed provider (installed: turnstile, recaptcha"
      assert log =~ "dep_fixture"
      assert length(String.split(log, "names no installed provider")) == 2

      refute Challenge.enabled?(Challenge.config())
      assert Challenge.csp_sources(Challenge.config()).script_src == []
    end

    test "is reported for the boot log, and a usable one is not" do
      enable!(provider: "nobody_installed_this")
      assert Challenge.provider_problem() =~ "names no installed provider"

      enable!(provider: "recaptcha")
      assert Challenge.provider_problem() == nil

      enable!(provider: nil)
      assert Challenge.provider_problem() == nil

      enable!(provider: "nobody_installed_this", disabled: true)
      assert Challenge.provider_problem() == nil
    end
  end

  describe "a provider that breaks the contract" do
    for {name, module, expected} <- [
          {"a raising widget/0", Providers.RaisingWidget, "widget/0 raised"},
          {"a raising csp_sources/0", Providers.RaisingCsp, "csp_sources/0 raised"},
          {"a wildcard CSP source", Providers.WildcardCsp, "must be https://host"},
          {"a script outside its own sources", Providers.Uncovered, "is not covered"}
        ] do
      test "is off, and named at boot: #{name}" do
        module = unquote(module)
        enable!(provider: module.id(), providers: [module])

        log =
          capture_log(fn ->
            clear_unusable_log()
            assert Challenge.config().provider == nil
          end)

        assert log =~ "does not meet the provider contract"
        assert log =~ unquote(expected)
        assert Challenge.provider_problem() =~ unquote(expected)
        assert Challenge.csp_sources(Challenge.config()).script_src == []
      end
    end

    test "a raising verify/2 is the provider crashing: unavailable, never a pass" do
      enable!(provider: "raising_verify", providers: [Providers.RaisingVerify])

      assert Challenge.verify(Challenge.config(), "anything", :sign_in) ==
               {:error, {:unavailable, :crashed}}
    end
  end

  describe "a provider's answer" do
    setup do
      enable!(provider: "loose", providers: [Providers.Loose])
      %{config: Challenge.config()}
    end

    defp ours(host), do: host == "localhost"

    test "can never be :missing or :malformed — only the core says that", %{config: config} do
      assert Challenge.verify(config, "say-missing", :sign_in) == {:error, :invalid}
      assert Challenge.verify(config, "say-malformed", :sign_in) == {:error, :invalid}
      assert Challenge.verify(config, "say-weird", :sign_in) == {:error, :invalid}
    end

    test "an unavailable reason it invents is a crash", %{config: config} do
      assert Challenge.verify(config, "say-unavailable-weird", :sign_in) ==
               {:error, {:unavailable, :crashed}}

      assert Challenge.verify(config, "say-nonsense", :sign_in) ==
               {:error, {:unavailable, :crashed}}
    end

    test "a pass naming no hostname is refused when hostnames are checked", %{config: config} do
      assert Challenge.verify(config, "pass-no-claims", :sign_in, hostname?: &ours/1) ==
               {:error, :hostname_mismatch}

      assert Challenge.verify(config, "pass-no-claims", :sign_in) == :ok
    end

    test "a pass on another host is refused, and the host is reported", %{config: config} do
      assert Challenge.verify_reporting(config, "pass-evil", :form, hostname?: &ours/1) ==
               {{:error, :hostname_mismatch}, "evil.example.net"}
    end

    test "a bare :ok is a pass with no claims: refused while hostnames are checked",
         %{config: config} do
      assert Challenge.verify(config, "pass-no-claims", :form, hostname?: &ours/1) ==
               {:error, :hostname_mismatch}
    end

    test "claims may use string keys", %{config: config} do
      assert Challenge.verify(config, "pass-string-keys", :register, hostname?: &ours/1) == :ok

      assert Challenge.verify(config, "pass-string-keys", :sign_in, hostname?: &ours/1) ==
               {:error, :action_mismatch}
    end

    test "a hostname check that raises or exits is unavailable, not a crashed request",
         %{config: config} do
      exits = fn _host -> exit(:db_down) end
      raises = fn _host -> raise "db down" end

      assert Challenge.verify(config, "pass-local", :form, hostname?: exits) ==
               {:error, {:unavailable, :crashed}}

      assert Challenge.verify(config, "pass-local", :form, hostname?: raises) ==
               {:error, {:unavailable, :crashed}}
    end

    test "a pass for another action is refused; one naming none passes", %{config: config} do
      assert Challenge.verify(config, "pass-register", :sign_in, hostname?: &ours/1) ==
               {:error, :action_mismatch}

      assert Challenge.verify(config, "pass-register", :register, hostname?: &ours/1) == :ok
      assert Challenge.verify(config, "pass-local", :sign_in, hostname?: &ours/1) == :ok
    end

    test "a sign-in during an outage is refused when it says :missing, not admitted" do
      address = email()
      spend_account(address)

      assert Challenge.verify(Challenge.config(), "down", :sign_in) ==
               {:error, {:unavailable, :transport}}

      assert Challenge.outage?()

      # A real missing token during an outage gets the bounded fail-open...
      assert Gate.sign_in(context(client_ip()), address, nil) == :ok
      # ...but a provider calling a token it saw "missing" never does.
      assert Gate.sign_in(context(client_ip()), address, "say-missing") == {:refuse, :failed}
    end

    test "a form submission it calls :missing is refused, not held" do
      assert Gate.form(%{challenge: :always}, "say-missing") == {:refuse, :failed}
      assert Gate.form(%{challenge: :always}, "say-malformed") == {:refuse, :failed}
      assert Gate.form(%{challenge: :always}, nil) == {:accept, :missing}
    end
  end

  describe "a refusal outside the contract's shape" do
    setup do
      enable!(provider: "loose", providers: [Providers.Loose], registration: :always)
      :ok
    end

    for token <- ["say-string", "say-tuple"] do
      test "#{token} is :invalid everywhere: refused, never held, no outage" do
        token = unquote(token)
        assert Challenge.verify(Challenge.config(), token, :sign_in) == {:error, :invalid}

        address = email()
        spend_account(address)
        assert Gate.sign_in(context(client_ip()), address, token) == {:refuse, :failed}
        assert Gate.registration(context(client_ip()), token) == {:refuse, :failed}
        assert Gate.form(%{challenge: :always}, token) == {:refuse, :failed}

        refute Challenge.outage?()
      end
    end
  end

  describe "the resolved provider" do
    test "is checked once per id and configuration, not per request" do
      Application.put_env(:kiln_cms, Providers.Counting, notify: self())
      on_exit(fn -> Application.delete_env(:kiln_cms, Providers.Counting) end)

      enable!(provider: "counting", providers: [Providers.Counting])

      for _ <- 1..5, do: Challenge.widget(Challenge.config(), :sign_in)

      assert_received :widget_called
      refute_received :widget_called

      # Another site key is not another provider...
      put_challenge_env(site_key: "other")
      Challenge.config()
      refute_received :widget_called

      # ...but another `providers:` list (the test seam) resolves again.
      put_challenge_env(providers: [Providers.Counting, KilnCMS.ChallengeFake])
      Challenge.config()
      assert_received :widget_called
    end
  end

  describe "CHALLENGE_PROVIDER's spelling" do
    test "is trimmed and downcased, then held to the id format" do
      assert Challenge.parse_provider_id("Turnstile") == {:ok, "turnstile"}
      assert Challenge.parse_provider_id(" turnstile ") == {:ok, "turnstile"}
      assert Challenge.parse_provider_id("RECAPTCHA\n") == {:ok, "recaptcha"}
      assert Challenge.parse_provider_id("my_captcha2") == {:ok, "my_captcha2"}
      assert Challenge.parse_provider_id("") == :unset
      assert Challenge.parse_provider_id("   ") == :unset
      assert Challenge.parse_provider_id(nil) == :unset
      assert Challenge.parse_provider_id("my-captcha") == :invalid
      assert Challenge.parse_provider_id("2captcha") == :invalid
      assert Challenge.parse_provider_id(String.duplicate("a", 33)) == :invalid
    end
  end
end

defmodule KilnCMS.Challenge.RegistryTest.Providers do
  @moduledoc false
  # Providers that each break one thing. Defined beside the test, since only
  # the `providers:` test seam ever registers them.

  defmodule Base do
    @moduledoc false
    defmacro __using__(opts) do
      id = Keyword.fetch!(opts, :id)

      quote do
        use Kiln.Challenge.Provider

        @impl true
        def id, do: unquote(id)

        @impl true
        def widget, do: %{script_url: "https://captcha.test/api.js", global: "testCaptcha"}

        @impl true
        def csp_sources,
          do: %{script_src: ["https://captcha.test"], frame_src: [], connect_src: []}

        @impl true
        def verify(_token, _opts), do: {:error, :invalid}

        defoverridable id: 0, widget: 0, csp_sources: 0, verify: 2
      end
    end
  end

  defmodule Impostor do
    @moduledoc false
    use Base, id: "turnstile"
  end

  defmodule RaisingId do
    @moduledoc false
    use Base, id: "raising_id"
    def id, do: raise("no id")
  end

  defmodule RaisingWidget do
    @moduledoc false
    use Base, id: "raising_widget"
    def widget, do: raise("no widget")
  end

  defmodule RaisingCsp do
    @moduledoc false
    use Base, id: "raising_csp"
    def csp_sources, do: raise("no sources")
  end

  defmodule WildcardCsp do
    @moduledoc false
    use Base, id: "wildcard_csp"
    def csp_sources, do: %{script_src: ["https://*.captcha.test"], frame_src: [], connect_src: []}
  end

  defmodule Uncovered do
    @moduledoc false
    use Base, id: "uncovered"
    def widget, do: %{script_url: "https://elsewhere.test/api.js", global: "testCaptcha"}
  end

  defmodule RaisingVerify do
    @moduledoc false
    use Base, id: "raising_verify"
    def verify(_token, _opts), do: raise("verify blew up")
  end

  defmodule Loose do
    @moduledoc false
    use Base, id: "loose"

    def verify("say-missing", _opts), do: {:error, :missing}
    def verify("say-malformed", _opts), do: {:error, :malformed}
    def verify("say-weird", _opts), do: {:error, :weird}
    def verify("say-string", _opts), do: {:error, "invalid-input-response"}
    def verify("say-tuple", _opts), do: {:error, {:invalid, ["x"]}}

    def verify("pass-string-keys", _opts),
      do: {:ok, %{"hostname" => "localhost", "action" => "register"}}

    def verify("say-unavailable-weird", _opts), do: {:error, {:unavailable, :weird}}
    def verify("say-nonsense", _opts), do: :yes
    def verify("down", _opts), do: {:error, {:unavailable, :transport}}
    def verify("pass-no-claims", _opts), do: :ok
    def verify("pass-evil", _opts), do: {:ok, %{hostname: "evil.example.net"}}
    def verify("pass-register", _opts), do: {:ok, %{hostname: "localhost", action: "register"}}
    def verify("pass-local", _opts), do: {:ok, %{hostname: "localhost"}}
    def verify(_token, _opts), do: {:error, :invalid}
  end

  defmodule WithField do
    @moduledoc false
    use Base, id: "with_field"

    def widget,
      do: %{
        script_url: "https://captcha.test/api.js",
        global: "testCaptcha",
        response_field: "with-field-response"
      }
  end

  defmodule Counting do
    @moduledoc false
    use Base, id: "counting"

    def widget do
      case Application.get_env(:kiln_cms, __MODULE__, [])[:notify] do
        pid when is_pid(pid) -> send(pid, :widget_called)
        _none -> :ok
      end

      %{script_url: "https://captcha.test/api.js", global: "testCaptcha"}
    end
  end
end
