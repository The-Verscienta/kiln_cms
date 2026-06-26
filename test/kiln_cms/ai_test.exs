defmodule KilnCMS.AITest do
  @moduledoc """
  The AI assistant facade is provider-pluggable and ships an offline Echo
  provider so generation works without an API key (issue #60).
  """
  use ExUnit.Case, async: false

  alias KilnCMS.AI

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.AI)
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.AI, original) end)
    :ok
  end

  describe "Echo provider (default)" do
    test "generate echoes a trimmed prompt" do
      assert {:ok, text} = AI.generate("  hello\n\n  world  ")
      assert text == "hello world"
    end

    test "summarize returns non-empty text" do
      assert {:ok, text} = AI.summarize("KilnCMS is a headless CMS built on Ash.")
      assert is_binary(text) and text != ""
    end

    test "seo_description is capped at 160 characters" do
      long = String.duplicate("content ", 100)
      assert {:ok, text} = AI.seo_description(long)
      assert String.length(text) <= 160
    end

    test "seo_title is capped at 60 characters" do
      long = String.duplicate("title ", 100)
      assert {:ok, text} = AI.seo_title(long)
      assert String.length(text) <= 60
    end
  end

  describe "configuration" do
    test "adapter and enabled? reflect config" do
      assert AI.adapter() == KilnCMS.AI.Echo
      assert AI.enabled?() == true

      Application.put_env(:kiln_cms, KilnCMS.AI, adapter: KilnCMS.AI.Anthropic, enabled: false)
      assert AI.adapter() == KilnCMS.AI.Anthropic
      refute AI.enabled?()
    end
  end

  describe "Anthropic provider" do
    test "returns a missing-key error when no API key is configured" do
      Application.put_env(:kiln_cms, KilnCMS.AI.Anthropic, [])
      assert {:error, :missing_api_key} = KilnCMS.AI.Anthropic.complete("hi")
    end
  end
end
