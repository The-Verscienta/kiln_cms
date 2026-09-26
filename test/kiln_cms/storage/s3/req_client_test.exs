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

  describe "a site's own store (#1559)" do
    test "connects to the pinned address, with SNI and verification on the name, no redirects" do
      opts =
        ReqClient.build_options(:get, "https://s3.site.example/bucket/key", "", [],
          site_storage: true,
          pinned_address: {93, 184, 216, 34}
        )

      assert opts[:url] == "https://93.184.216.34/bucket/key"
      assert opts[:redirect] == false

      transport = opts[:connect_options][:transport_opts]
      assert transport[:verify] == :verify_peer
      assert transport[:server_name_indication] == ~c"s3.site.example"
      assert opts[:connect_options][:timeout] == 5_000
    end

    test "unpinned (dev, or DNS off in tests) keeps the URL and still refuses redirects" do
      opts =
        ReqClient.build_options(:get, "https://s3.site.example/k", "", [],
          site_storage: true,
          pinned_address: nil
        )

      assert opts[:url] == "https://s3.site.example/k"
      assert opts[:redirect] == false
    end

    test "the operator's requests are untouched" do
      opts = ReqClient.build_options(:get, "https://s3.example/key", "", [], [])

      assert opts[:url] == "https://s3.example/key"
      refute Keyword.has_key?(opts, :redirect)
    end
  end
end
