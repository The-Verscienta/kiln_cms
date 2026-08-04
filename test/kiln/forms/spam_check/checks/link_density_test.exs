defmodule Kiln.Forms.SpamCheck.Checks.LinkDensityTest do
  use ExUnit.Case, async: true

  alias Kiln.Forms.SpamCheck.Checks.LinkDensity
  alias Kiln.Forms.SpamCheck.Context

  test "clean text is not flagged" do
    assert LinkDensity.check(Context.new(%{"message" => "Hi, I'd love a quote."})) == :ok
  end

  test "one or two links is not flagged" do
    ctx = Context.new(%{"message" => "See https://example.com for our portfolio."})
    assert LinkDensity.check(ctx) == :ok
  end

  test "three or more links is flagged" do
    ctx =
      Context.new(%{
        "message" => "Visit http://a.co and www.b.co and https://c.co/path?x=1 now!"
      })

    assert {:flag, :too_many_links, weight} = LinkDensity.check(ctx)
    assert weight > 0
  end
end
