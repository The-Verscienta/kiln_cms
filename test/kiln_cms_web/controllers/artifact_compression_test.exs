defmodule KilnCMSWeb.ArtifactCompressionTest do
  @moduledoc """
  Fired artifacts and public HTML pages are gzipped by Kiln itself.

  Bandit compresses a response only when it carries no *strong* `ETag` (a
  strong validator promises byte-identical bodies, and the compressed body is
  not), so this goes through a real Bandit listener rather than
  `Phoenix.ConnTest`, which never reaches Bandit's compression.

  Not async: the listener's request processes read through the shared sandbox.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.TypedFixtures

  alias KilnCMS.CMS

  setup do
    server =
      start_supervised!(
        {Bandit,
         plug: KilnCMSWeb.Endpoint, scheme: :http, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{base: "http://127.0.0.1:#{port}"}
  end

  defp published_page do
    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "gz-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    slug = "gz-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        %{
          title: "Compressed",
          slug: slug,
          blocks:
            typed_blocks([
              %{type: :heading, content: "Welcome", data: %{"level" => 1}, order: 0},
              %{type: :paragraph, content: String.duplicate("Kiln fires. ", 200), order: 1}
            ])
        },
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    KilnCMS.DataCase.drain_oban()
    slug
  end

  defp fetch(url, headers) do
    Req.get!(url, headers: headers, raw: true, retry: false, redirect: false)
  end

  test "a fired artifact is gzipped and still revalidates to a 304", %{base: base} do
    url = "#{base}/api/content/page/#{published_page()}"

    served = fetch(url, [{"accept-encoding", "gzip"}])

    assert served.status == 200
    assert Req.Response.get_header(served, "content-encoding") == ["gzip"]
    assert %{"title" => "Compressed"} = served.body |> :zlib.gunzip() |> Jason.decode!()

    assert [etag] = Req.Response.get_header(served, "etag")
    assert etag =~ ~r/^W\/".+"$/

    # The tag as sent, the opaque part alone (the strong form a client cached
    # before tags turned weak), one of a list, and `*` all revalidate.
    opaque = String.replace_prefix(etag, "W/", "")

    for presented <- [etag, opaque, ~s("nope", #{etag}), "*"] do
      revalidated = fetch(url, [{"accept-encoding", "gzip"}, {"if-none-match", presented}])
      assert revalidated.status == 304, "expected 304 for If-None-Match: #{presented}"
      assert revalidated.body == ""
    end

    assert fetch(url, [{"if-none-match", ~s("nope")}]).status == 200
  end

  # #2766: the delivered page used to carry a strong ETag, so Bandit sent it
  # uncompressed, and its exact-match comparison missed every weak, listed or
  # `*` validator a CDN or browser sent back.
  test "a public HTML page is gzipped, weakly tagged and revalidates to a 304", %{base: base} do
    url = "#{base}/#{published_page()}"

    served = fetch(url, [{"accept-encoding", "gzip"}])

    assert served.status == 200
    assert Req.Response.get_header(served, "content-encoding") == ["gzip"]
    assert served.body |> :zlib.gunzip() =~ "Kiln fires."

    assert [etag] = Req.Response.get_header(served, "etag")
    assert etag =~ ~r/^W\/".+"$/

    opaque = String.replace_prefix(etag, "W/", "")

    for presented <- [etag, opaque, ~s("nope", #{etag}), "*"] do
      revalidated = fetch(url, [{"accept-encoding", "gzip"}, {"if-none-match", presented}])
      assert revalidated.status == 304, "expected 304 for If-None-Match: #{presented}"
      assert revalidated.body == ""
    end

    assert fetch(url, [{"if-none-match", ~s("nope")}]).status == 200
    assert fetch(url, [{"if-none-match", ~s(W/"nope")}]).status == 200
  end
end
