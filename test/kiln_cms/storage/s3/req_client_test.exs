defmodule KilnCMS.Storage.S3.ReqClientTest do
  @moduledoc """
  #222: every S3 HTTP call carries bounded connect/receive timeouts so a stalled
  request can't hang a variant worker, upload, or media load.
  """
  # async: false — one test mutates the global Storage.S3 config.
  use ExUnit.Case, async: false

  alias KilnCMS.Storage.S3.ReqClient

  test "S3 Req calls carry bounded connect and receive timeouts by default" do
    opts = ReqClient.build_options(:get, "https://s3.example/key", "", [], [])

    assert opts[:receive_timeout] == 30_000
    assert opts[:connect_options][:timeout] == 5_000
  end

  test "the timeouts are configurable" do
    original = Application.get_env(:kiln_cms, KilnCMS.Storage.S3, [])

    try do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Storage.S3,
        Keyword.merge(original, connect_timeout_ms: 1_000, receive_timeout_ms: 7_000)
      )

      opts = ReqClient.build_options(:put, "https://s3.example/key", "body", [], [])

      assert opts[:receive_timeout] == 7_000
      assert opts[:connect_options][:timeout] == 1_000
    after
      Application.put_env(:kiln_cms, KilnCMS.Storage.S3, original)
    end
  end
end
