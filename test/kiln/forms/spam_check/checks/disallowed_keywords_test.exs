defmodule Kiln.Forms.SpamCheck.Checks.DisallowedKeywordsTest do
  use ExUnit.Case, async: true

  alias Kiln.Forms.SpamCheck.Checks.DisallowedKeywords
  alias Kiln.Forms.SpamCheck.Context

  test "no keywords configured is never flagged" do
    ctx = Context.new(%{"message" => "buy viagra now"}, keywords: [])
    assert DisallowedKeywords.check(ctx) == :ok
  end

  test "clean text against a configured list is not flagged" do
    ctx = Context.new(%{"message" => "I'd like a quote for a fence."}, keywords: ["viagra"])
    assert DisallowedKeywords.check(ctx) == :ok
  end

  test "a case-insensitive substring match is flagged" do
    ctx = Context.new(%{"message" => "Cheap ViAgRa here"}, keywords: ["viagra"])
    assert {:flag, :disallowed_keyword, weight} = DisallowedKeywords.check(ctx)
    assert weight > 0
  end

  test "matches anywhere across the submitted fields" do
    ctx =
      Context.new(%{"name" => "spammer", "message" => "click my link"},
        keywords: ["spammer"]
      )

    assert {:flag, :disallowed_keyword, _} = DisallowedKeywords.check(ctx)
  end
end
