defmodule KilnCMS.LLMTest do
  @moduledoc """
  The shared provider classifier (#60).

  `KilnCMS.Seo` and `KilnCMS.Assist` both delegate here, so a mistake in this
  module is a mistake in both — and the mistake it makes is always the same
  one: telling an operator their content stayed on the box when it didn't.
  These tests are written from that direction. Every case that isn't provably
  local must read as egress.

  Touches `:req_llm` app env, so `async: false`.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.LLM

  defp put_req_llm(key, value) do
    previous = Application.fetch_env(:req_llm, key)
    Application.put_env(:req_llm, key, value)

    on_exit(fn ->
      case previous do
        {:ok, was} -> Application.put_env(:req_llm, key, was)
        :error -> Application.delete_env(:req_llm, key)
      end
    end)
  end

  describe "provider/1" do
    test "splits the spec, and tolerates a model name containing colons" do
      assert LLM.provider("ollama:llama3.1") == "ollama"
      assert LLM.provider("ollama:gemma:27b") == "ollama"
      assert LLM.provider(nil) == nil
    end
  end

  describe "egress?/2" do
    test "an unconfigured feature sends nothing, so it cannot be egress" do
      refute LLM.egress?(nil)
    end

    test "the on-prem providers at their own defaults are local" do
      refute LLM.egress?("ollama:llama3.1")
      refute LLM.egress?("vllm:mistral-7b")
    end

    test "loopback and private addresses are local" do
      for host <- ~w(http://localhost:11434 http://127.0.0.1:8000 http://10.1.2.3
                     http://192.168.1.9 http://172.20.0.4 http://box.internal) do
        refute LLM.egress?("ollama:llama3.1", host), "expected #{host} to read as local"
      end
    end

    test "a hosted provider is egress" do
      assert LLM.egress?("anthropic:claude-sonnet-5")
      assert LLM.egress?("openai:gpt-4o-mini")
    end

    test "an on-prem provider pointed at a remote host is egress" do
      # The whole reason this is host-based: `base_url` is overridable, which
      # is the mechanism the docs recommend for on-prem, so classifying by the
      # provider's *name* said "no egress" while every page body left the box.
      assert LLM.egress?("ollama:llama3.1", "https://gpu.vendor.example/v1")

      assert LLM.endpoint_host("ollama:llama3.1", "https://gpu.vendor.example/v1") ==
               "gpu.vendor.example"
    end

    test "a scheme-less endpoint is classified by its host, not ignored" do
      # `URI.parse/1` leaves `:host` nil for these and puts everything in
      # `:path`, which fell through to the provider's local default.
      assert LLM.egress?("ollama:llama3.1", "gpu.example.com:11434")
      assert LLM.endpoint_host("ollama:llama3.1", "gpu.example.com:11434") == "gpu.example.com"
      refute LLM.egress?("ollama:llama3.1", "localhost:11434")
    end

    test "an unusable base_url falls back to the provider default rather than reading as local" do
      assert LLM.endpoint_host("ollama:llama3.1", "") == "localhost"
      assert LLM.endpoint_host("anthropic:claude-sonnet-5", "not a url") == nil
      assert LLM.egress?("anthropic:claude-sonnet-5", "not a url")
    end
  end

  describe "req_llm's own configuration" do
    test "the per-provider keyword shape is seen" do
      # This is the shape req_llm actually reads —
      # `Application.get_env(:req_llm, :ollama)[:base_url]`. Matching a flat
      # `:ollama_base_url` key instead made a real override invisible here and
      # reported a vendor endpoint as local.
      put_req_llm(:ollama, base_url: "https://gpu.vendor.example/v1")

      assert LLM.endpoint_host("ollama:llama3.1") == "gpu.vendor.example"
      assert LLM.egress?("ollama:llama3.1")
    end

    test "the flat key shape is also honoured" do
      put_req_llm(:ollama_base_url, "https://other.vendor.example")

      assert LLM.endpoint_host("ollama:llama3.1") == "other.vendor.example"
    end

    test "the feature's own override wins over req_llm's" do
      put_req_llm(:ollama, base_url: "https://gpu.vendor.example/v1")

      assert LLM.endpoint_host("ollama:llama3.1", "http://127.0.0.1:11434") == "127.0.0.1"
    end

    test "a provider entry that is not a keyword list is ignored, not fatal" do
      put_req_llm(:ollama, "https://not-a-keyword-list.example")

      assert LLM.endpoint_host("ollama:llama3.1") == "localhost"
    end
  end
end
