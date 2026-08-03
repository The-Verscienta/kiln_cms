defmodule KilnCMS.OEmbedTest do
  @moduledoc """
  The oEmbed resolver (#489). Most of what matters here is what it *refuses*.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.OEmbed
  alias KilnCMS.OEmbed.Provider

  @youtube "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

  setup do
    previous = Application.get_env(:kiln_cms, KilnCMS.OEmbed, [])
    Application.put_env(:kiln_cms, KilnCMS.OEmbed, Keyword.put(previous, :enabled, true))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.OEmbed, previous) end)
    :ok
  end

  defp stub(payload, status \\ 200) do
    Req.Test.stub(KilnCMS.OEmbed, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(payload))
    end)
  end

  describe "the provider registry" do
    test "claims the URLs it should and nothing adjacent" do
      assert %{name: "YouTube"} = Provider.for_url(@youtube)
      assert %{name: "YouTube"} = Provider.for_url("https://youtu.be/dQw4w9WgXcQ")
      assert %{name: "Vimeo"} = Provider.for_url("https://vimeo.com/123456")

      # A pattern that isn't anchored at both ends matches a lookalike host.
      # This is the assertion that catches it.
      refute Provider.for_url("https://evil-youtube.com.attacker.example/watch?v=x")
      refute Provider.for_url("https://youtube.com.attacker.example/watch?v=x")
      refute Provider.for_url("https://attacker.example/https://youtube.com/watch?v=x")
    end

    test "matching ignores scheme case and a leading www" do
      assert Provider.for_url("https://YouTube.com/watch?v=x")
      assert Provider.for_url("http://www.youtube.com/watch?v=x")
    end

    test "a non-http scheme claims nothing" do
      refute Provider.for_url("javascript:alert(1)")
      refute Provider.for_url("file:///etc/passwd")
      refute Provider.for_url("not a url")
      refute Provider.for_url(nil)
    end

    test "the providers: config narrows the shipped list and cannot widen it" do
      previous = Application.get_env(:kiln_cms, KilnCMS.OEmbed, [])

      Application.put_env(
        :kiln_cms,
        KilnCMS.OEmbed,
        Keyword.merge(previous, providers: ["Vimeo", "Nonexistent"])
      )

      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.OEmbed, previous) end)

      assert Enum.map(Provider.enabled(), & &1.name) == ["Vimeo"]
      refute Provider.for_url(@youtube)
    end
  end

  describe "resolve/1" do
    test "returns the card fields from a provider response" do
      stub(%{
        "title" => "  A video  ",
        "author_name" => "Someone",
        "provider_name" => "YouTube",
        "thumbnail_url" => "https://i.ytimg.com/vi/x/hq.jpg",
        # Everything below is deliberately dropped.
        "html" => "<script>alert(1)</script>",
        "width" => 480
      })

      assert {:ok, card} = OEmbed.resolve(@youtube)

      assert card == %{
               title: "A video",
               author_name: "Someone",
               provider_name: "YouTube",
               thumbnail_url: "https://i.ytimg.com/vi/x/hq.jpg"
             }
    end

    test "never carries the provider's html through" do
      stub(%{"title" => "T", "html" => "<iframe src=\"https://evil.example\"></iframe>"})

      assert {:ok, card} = OEmbed.resolve(@youtube)

      # Rendering provider markup means trusting a third party with script
      # execution on the delivery origin. The card is built from scalars only.
      refute Map.has_key?(card, :html)
      refute card |> Map.values() |> Enum.any?(&(is_binary(&1) and &1 =~ "iframe"))
    end

    test "drops a thumbnail that is not on the provider's CDN" do
      stub(%{"title" => "T", "thumbnail_url" => "https://attacker.example/track.gif"})

      assert {:ok, card} = OEmbed.resolve(@youtube)

      # img-src is a security boundary; "whatever the provider returned" is not.
      refute Map.has_key?(card, :thumbnail_url)
      assert card.title == "T"
    end

    test "drops a plain-http thumbnail even on an allowed host" do
      stub(%{"title" => "T", "thumbnail_url" => "http://i.ytimg.com/vi/x/hq.jpg"})

      assert {:ok, card} = OEmbed.resolve(@youtube)
      refute Map.has_key?(card, :thumbnail_url)
    end

    test "falls back to our provider name when the response omits one" do
      stub(%{"title" => "T"})

      assert {:ok, %{provider_name: "YouTube"}} = OEmbed.resolve(@youtube)
    end

    test "caps a runaway title rather than storing it whole" do
      stub(%{"title" => String.duplicate("a", 5_000)})

      assert {:ok, %{title: title}} = OEmbed.resolve(@youtube)
      assert String.length(title) == 300
    end

    test "a non-200, a non-JSON body and a blank title are all just errors" do
      stub(%{"title" => "T"}, 404)
      assert {:error, reason} = OEmbed.resolve(@youtube)
      assert reason =~ "404"

      Req.Test.stub(KilnCMS.OEmbed, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>nope") end)
      assert {:error, _} = OEmbed.resolve(@youtube)
    end

    test "a URL no provider claims is refused without a request" do
      # No stub is installed: if this made a request it would raise rather than
      # quietly return, which is the point — an unknown URL must not become
      # outbound traffic to a host the content chose.
      assert {:error, :no_provider} = OEmbed.resolve("https://attacker.example/thing")
    end

    test "resolves nothing at all when the feature is off" do
      previous = Application.get_env(:kiln_cms, KilnCMS.OEmbed, [])
      Application.put_env(:kiln_cms, KilnCMS.OEmbed, Keyword.put(previous, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.OEmbed, previous) end)

      assert {:error, :disabled} = OEmbed.resolve(@youtube)
      refute OEmbed.resolvable?(@youtube)
      # And the CSP does not widen for a feature nobody switched on.
      assert Provider.thumbnail_hosts() == []
    end
  end

  describe "thumbnail_hosts/0" do
    test "covers every host the resolver would accept, and no others" do
      hosts = Provider.thumbnail_hosts()

      assert "https://i.ytimg.com" in hosts
      assert Enum.all?(hosts, &String.starts_with?(&1, "https://"))
      # Endpoints are not thumbnail hosts; letting one in would widen img-src
      # for a host that never serves images.
      refute "https://www.youtube.com/oembed" in hosts
    end
  end
end
