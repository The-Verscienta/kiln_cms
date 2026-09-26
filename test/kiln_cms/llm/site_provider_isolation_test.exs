defmodule KilnCMS.LLM.SiteProviderIsolationTest do
  @moduledoc """
  A site's AI requests carry nothing of the operator's (#1557), and a site
  whose own provider is set but unusable is refused rather than sent to the
  operator's.

  `req_llm` fills in anything a request does not pass from the operator's
  configuration: the key from `config :req_llm, :<provider>_api_key` and then
  `<PROVIDER>_API_KEY`, the endpoint from `config :req_llm, :<provider>`. In
  the test env none of those are set, so without **planting** them a request
  that forgot to pass the site's own would still look fine here — and in
  production would send the site's content to the operator's endpoint, or the
  operator's key to the site's provider. So every one is planted, and the
  request that actually leaves (`Req.Test`, through `req_llm`'s own client and
  through `KilnCMS.SafeFetch`) is inspected.

  `async: false`: it rewrites global app and OS environment.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Assist.Request
  alias KilnCMS.CMS
  alias KilnCMS.LLM.Client
  alias KilnCMS.LLM.Route
  alias KilnCMS.LLM.SiteProvider

  @moduletag :capture_log

  @site_key "sk-site-0001"
  @operator_keys ["sk-operator-app-anthropic", "sk-operator-env-anthropic"] ++
                   ["sk-operator-app-openai", "sk-operator-env-openai"]

  @passage "The kiln reaches cone ten overnight. Cooling takes a further two days " <>
             "before the door can be opened safely."

  # Tattletale operator generators: the fail-direction tests assert these are
  # never called.
  defmodule OperatorSeo do
    @behaviour KilnCMS.Seo.Generator
    def draft(_document, _opts) do
      send(self(), :operator_generator_called)
      {:ok, %KilnCMS.Seo.Draft{seo_title: "operator"}}
    end
  end

  defmodule OperatorAssist do
    @behaviour KilnCMS.Assist.Generator
    def generate(_request, _opts) do
      send(self(), :operator_generator_called)
      {:ok, "operator"}
    end
  end

  defmodule OperatorAsk do
    @behaviour KilnCMS.Ask.Generator
    def generate(_question, _sources) do
      send(self(), :operator_generator_called)
      {:ok, "operator"}
    end
  end

  setup do
    put_env(:req_llm, :anthropic_api_key, "sk-operator-app-anthropic")
    put_env(:req_llm, :openai_api_key, "sk-operator-app-openai")
    put_env(:req_llm, :anthropic, base_url: "https://operator-proxy.example")
    put_env(:req_llm, :openai, base_url: "https://operator-proxy.example/v1")
    put_env(:req_llm, :warn_unverified_models, false)
    put_system_env("ANTHROPIC_API_KEY", "sk-operator-env-anthropic")
    put_system_env("OPENAI_API_KEY", "sk-operator-env-openai")

    # The operator's own AI config is on for every feature, with its own
    # endpoint — the layer a broken site row must not fall through to.
    put_env(:kiln_cms, KilnCMS.Seo,
      generator: OperatorSeo,
      model: "anthropic:operator-model",
      base_url: "https://operator-seo.example"
    )

    put_env(:kiln_cms, KilnCMS.Assist,
      generator: OperatorAssist,
      model: "anthropic:operator-model",
      base_url: "https://operator-assist.example"
    )

    put_env(:kiln_cms, KilnCMS.Ask, generator: OperatorAsk, model: "anthropic:operator-model")

    put_env(:kiln_cms, KilnCMS.LLM.SiteProvider,
      req_http_options: [plug: {Req.Test, __MODULE__}],
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:llm_request, conn.host, conn.request_path, conn.req_headers, body})
      Req.Test.json(conn, response_for(conn.host))
    end)

    %{org: KilnCMS.OrgFixtures.org("ai-isolation")}
  end

  describe "no operator credential rides along" do
    test "a hosted provider gets the site's key at the provider's own host", %{org: org} do
      save!(org, %{provider: :anthropic, api_key: @site_key, assist_model: "claude-site"})

      assert {:ok, suggestion} = KilnCMS.Assist.run(assist_request(), org_id: org.id)
      assert suggestion.model == "anthropic:claude-site"

      assert_received {:llm_request, host, _path, headers, body}
      assert host == "api.anthropic.com"
      assert header(headers, "x-api-key") == @site_key
      assert Jason.decode!(body)["model"] == "claude-site"
      refute_operator_credentials(headers, body)
      refute_received :operator_generator_called
    end

    test "an OpenAI provider gets the site's key as its bearer token", %{org: org} do
      save!(org, %{provider: :openai, api_key: @site_key, seo_model: "gpt-4o-mini"})

      # Only the request is asserted: whether the stub's reply parses as a
      # draft is `req_llm`'s business, not this test's.
      _result = KilnCMS.Seo.draft(seo_document(), org_id: org.id)

      assert_received {:llm_request, "api.openai.com", _path, headers, body}
      assert header(headers, "authorization") == "Bearer " <> @site_key
      refute_operator_credentials(headers, body)
      refute_received :operator_generator_called
    end

    test "an OpenAI-compatible endpoint is reached through SafeFetch with the site's key",
         %{org: org} do
      save!(org, %{
        provider: :openai_compatible,
        base_url: "https://llm.site.example/v1",
        api_key: @site_key,
        assist_model: "site-model"
      })

      assert {:ok, suggestion} = KilnCMS.Assist.run(assist_request(), org_id: org.id)
      assert Enum.join(suggestion.paragraphs) =~ "site answer"

      assert_received {:llm_request, "llm.site.example", "/v1/chat/completions", headers, body}
      assert header(headers, "authorization") == "Bearer " <> @site_key
      assert Jason.decode!(body)["model"] == "site-model"
      refute_operator_credentials(headers, body)
    end

    test "a keyless OpenAI-compatible endpoint sends no key at all", %{org: org} do
      save!(org, %{
        provider: :openai_compatible,
        base_url: "https://llm.site.example/v1",
        ask_model: "site-model"
      })

      result = KilnCMS.Ask.answer("How long does the kiln cool?", tenant: org.id)
      assert result.answer =~ "site answer"

      assert_received {:llm_request, "llm.site.example", _path, headers, body}
      assert header(headers, "authorization") == nil
      refute_operator_credentials(headers, body)
      refute_received :operator_generator_called
    end

    test "the options a site request is sent with override anything a caller passed" do
      route = %Route{
        source: :site,
        provider: :anthropic,
        model: "anthropic:m",
        base_url: "https://api.anthropic.com",
        api_key: @site_key
      }

      opts =
        Client.request_opts(route,
          temperature: 0.1,
          api_key: "sk-operator-app-anthropic",
          base_url: "https://operator-seo.example",
          access_token: "operator-oauth",
          auth_mode: :oauth,
          provider_options: [access_token: "operator-oauth"]
        )

      assert opts[:api_key] == @site_key
      assert opts[:base_url] == "https://api.anthropic.com"
      assert opts[:temperature] == 0.1
      refute Keyword.has_key?(opts, :access_token)
      refute Keyword.has_key?(opts, :auth_mode)
      refute Keyword.has_key?(opts, :provider_options)
    end

    test "a site route with no key sends an empty one, which req_llm refuses to fill in" do
      route = %Route{source: :site, provider: :anthropic, model: "anthropic:m", base_url: "x"}
      assert Client.request_opts(route, [])[:api_key] == ""
    end

    test "the operator's own request options keep the operator's endpoint", _ctx do
      # The other half: this change must not move the operator's path.
      assert KilnCMS.Assist.request_opts()[:base_url] == "https://operator-assist.example"

      refute Keyword.has_key?(
               KilnCMS.Assist.request_opts(%Route{source: :site, model: "m"}),
               :base_url
             )
    end
  end

  describe "an unusable site provider is refused, never sent to the operator's" do
    setup %{org: org} do
      row = save!(org, %{provider: :anthropic, api_key: @site_key})

      # What a SECRET_KEY_BASE rotation leaves behind.
      {1, _} =
        KilnCMS.Repo.update_all(
          Ecto.Query.from(r in "site_ai_providers", where: r.id == type(^row.id, :binary_id)),
          set: [api_key_encrypted: :crypto.strong_rand_bytes(48)]
        )

      :ok
    end

    test "SEO drafting", %{org: org} do
      assert {:error, {:site_provider, :credentials_unreadable}} =
               KilnCMS.Seo.draft(seo_document(), org_id: org.id)

      refute_received :operator_generator_called
      refute_received {:llm_request, _host, _path, _headers, _body}
    end

    test "block assist", %{org: org} do
      assert {:error, {:site_provider, :credentials_unreadable}} =
               KilnCMS.Assist.run(assist_request(), org_id: org.id)

      refute_received :operator_generator_called
    end

    test "/api/ask answers degrade to retrieval-only", %{org: org} do
      result = KilnCMS.Ask.answer("How long does the kiln cool?", tenant: org.id)

      assert result.answer == nil
      assert result.generation == :failed
      refute_received :operator_generator_called
    end

    test "the editor is told, and still offered the control", %{org: org} do
      assert %{enabled?: true, source: :site, error: :credentials_unreadable} =
               KilnCMS.Seo.summary(org.id)
    end
  end

  describe "a feature the site left blank" do
    test "is off, even though the operator has it on", %{org: org} do
      save!(org, %{provider: :anthropic, api_key: @site_key, assist_model: nil})

      assert {:error, :disabled} = KilnCMS.Assist.run(assist_request(), org_id: org.id)
      assert %{enabled?: false} = KilnCMS.Assist.summary(org.id)
      refute_received :operator_generator_called
    end
  end

  describe "a site with no provider of its own" do
    test "keeps the operator's configuration, as before", %{org: org} do
      assert {:ok, _suggestion} = KilnCMS.Assist.run(assist_request(), org_id: org.id)
      assert_received :operator_generator_called

      assert %{source: :operator, provider: "anthropic", endpoint_host: "operator-seo.example"} =
               KilnCMS.Seo.summary(org.id)
    end

    test "and so does one whose provider is switched off", %{org: org} do
      save!(org, %{provider: :anthropic, api_key: @site_key, enabled: false})

      assert SiteProvider.resolve(org.id, :assist) == :operator
      assert {:ok, _suggestion} = KilnCMS.Assist.run(assist_request(), org_id: org.id)
      assert_received :operator_generator_called
    end
  end

  defp save!(org, attrs) do
    %{seo_model: "gpt-4o-mini", assist_model: "claude-site", ask_model: "site-model"}
    |> Map.merge(attrs)
    |> CMS.save_site_ai_provider!(tenant: org, authorize?: false)
  end

  defp assist_request do
    Request.new(%{action: :rewrite, text: @passage, title: "Firing schedule", locale: "en"})
  end

  defp seo_document do
    KilnCMS.Seo.Document.new(%{
      title: "Kiln firing",
      body_text: String.duplicate("The kiln firing process takes patience and care. ", 20),
      locale: "en"
    })
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
  end

  defp refute_operator_credentials(headers, body) do
    for {_name, value} <- headers, key <- @operator_keys do
      refute value =~ key, "an operator credential was sent in a header"
    end

    for key <- @operator_keys ++ ["operator-proxy", "operator-seo", "operator-assist"] do
      refute body =~ key
    end
  end

  # Enough of each API's response for its client to parse.
  defp response_for("api.anthropic.com") do
    %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-site",
      "content" => [%{"type" => "text", "text" => "A site answer from the kiln."}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }
  end

  defp response_for(_openai_shaped) do
    content =
      Jason.encode!(%{
        "seo_title" => "Kiln firing, a site answer",
        "seo_description" => "A site answer about firing a kiln.",
        "seo_keywords" => ["kiln"]
      })

    %{
      "id" => "chatcmpl-1",
      "object" => "chat.completion",
      "created" => 1,
      "model" => "site-model",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => "A site answer. " <> content},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
    }
  end

  defp put_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp put_system_env(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end
end
