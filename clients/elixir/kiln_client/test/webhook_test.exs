defmodule KilnClient.WebhookTest do
  use ExUnit.Case, async: true

  alias KilnClient.Webhook

  # The same vector the server's `KilnCMS.WebhooksTest` and the JS client
  # assert, so the implementations cannot drift apart unnoticed.
  @secret "whsec-test"
  @body ~s({"event":"page.published","delivery_id":"d-1","data":{}})
  @v1 "e09a0895dc1b7f726710de36079d36941c634959f61a2c547ff00e848c3df80a"
  @header "t=1800000000,v1=#{@v1}"
  @now 1_800_000_000

  test "accepts the server's signature inside the window" do
    assert Webhook.verify(@secret, @body, @header, now: @now) == :ok
    assert Webhook.verify(@secret, @body, @header, now: @now + 300) == :ok
    assert Webhook.verify(@secret, [@body], @header, now: @now - 300) == :ok
  end

  test "refuses a stale or future timestamp" do
    assert Webhook.verify(@secret, @body, @header, now: @now + 301) == {:error, :expired}
    assert Webhook.verify(@secret, @body, @header, now: @now - 301) == {:error, :expired}
    assert Webhook.verify(@secret, @body, @header, now: @now + 900, tolerance: 900) == :ok
  end

  test "refuses a changed body, a wrong secret, and a re-stamped capture" do
    assert Webhook.verify(@secret, @body <> " ", @header, now: @now) == {:error, :mismatch}
    assert Webhook.verify("other", @body, @header, now: @now) == {:error, :mismatch}

    assert Webhook.verify(@secret, @body, "t=1800000100,v1=#{@v1}", now: @now) ==
             {:error, :mismatch}
  end

  test "accepts any matching v1 among several" do
    header = "t=1800000000,v1=#{String.duplicate("0", 64)},v1=#{@v1}"
    assert Webhook.verify(@secret, @body, header, now: @now) == :ok
  end

  test "calls a header that does not parse malformed" do
    for header <- [nil, "", "v1=abc", "t=soon,v1=abc", "t=1,t=2,v1=a", "t=1"] do
      assert Webhook.verify(@secret, @body, header, now: @now) == {:error, :malformed}
    end
  end
end
