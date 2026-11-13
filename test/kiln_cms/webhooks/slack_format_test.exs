defmodule KilnCMS.Webhooks.SlackFormatTest do
  @moduledoc """
  The Slack-format body (#2245): what a security alert, a summary, a notice
  and a ping say, and that nothing typed into a site name or carried by a
  request can format, mention or link in the channel.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Webhooks.SlackFormat

  @console "https://console.test/editor/security-log"

  # A security alert's payload as the ledger hands it back: string keys.
  defp alert(overrides \\ %{}) do
    Map.merge(
      %{
        "phase" => "alert",
        "channel" => "site",
        "site_id" => "4a1c3b52-0000-0000-0000-00000000site",
        "site_name" => "Example",
        "console_url" => @console,
        "kind" => "lockout",
        "occurred_at" => "2026-11-10T14:03:27.123456Z",
        "window" => %{
          "started_at" => "2026-11-10T14:00:00Z",
          "ends_at" => "2026-11-10T14:15:00Z"
        },
        "count" => 1,
        "event" => %{
          "id" => "9e1d0000-0000-0000-0000-0000000event",
          "type" => "lockout",
          "actor_id" => "77aa0000-0000-0000-0000-0000000actor",
          "ip" => "203.0.113.0/24",
          "metadata" => %{"user_agent" => "curl/8.0"}
        }
      },
      overrides
    )
  end

  defp section(body), do: body |> Map.fetch!(:blocks) |> hd() |> get_in([:text, :text])

  defp context(body),
    do:
      body
      |> Map.fetch!(:blocks)
      |> List.last()
      |> Map.fetch!(:elements)
      |> hd()
      |> Map.fetch!(:text)

  describe "an alert" do
    test "says what happened, where and when, with a link to the security log" do
      body = SlackFormat.render("security.lockout", alert())

      assert body.text ==
               "Security alert on `Example`: An account was locked out (from `203.0.113.0/24`)" <>
                 " · Open the security log: #{@console}"

      assert section(body) ==
               "*An account was locked out (from `203.0.113.0/24`)* on `Example`\n" <>
                 "2026-11-10 14:03 UTC"

      assert context(body) == "<#{@console}|Open the security log> · `security.lockout`"
    end

    test "never unfurls, and carries nothing the headline does not say" do
      body = SlackFormat.render("security.lockout", alert())
      encoded = Jason.encode!(body)

      assert body.unfurl_links == false
      assert body.unfurl_media == false

      for leaked <- ["0000site", "0000event", "0000actor", "curl/8.0", "delivery_id"] do
        refute encoded =~ leaked
      end
    end

    test "with atom keys, as the alert delivery builds it, says the same" do
      atom_keyed = %{
        phase: "alert",
        site_name: "Example",
        console_url: @console,
        kind: "lockout",
        occurred_at: "2026-11-10T14:03:27Z",
        event: %{ip: "203.0.113.0/24", type: "lockout"}
      }

      assert SlackFormat.render("security.lockout", atom_keyed).text ==
               SlackFormat.render("security.lockout", alert()).text
    end

    test "is English whatever the process locale" do
      Gettext.put_locale(KilnCMSWeb.Gettext, "es")
      on_exit(fn -> Gettext.put_locale(KilnCMSWeb.Gettext, "en") end)

      assert SlackFormat.render("security.lockout", alert()).text =~ "An account was locked out"
    end

    test "without an address, the headline is the kind alone" do
      body =
        SlackFormat.render("security.new_admin", alert(%{"kind" => "new_admin", "event" => nil}))

      assert section(body) =~ "*A new administrator* on `Example`"
    end
  end

  describe "names and addresses cannot format, mention or link" do
    test "a site name is one code span, escaped, on one line" do
      name = "Evil `tick` <!channel> & *bold* _it_\n@here <https://evil.test|click>"
      body = SlackFormat.render("security.lockout", alert(%{"site_name" => name}))

      expected =
        "`Evil 'tick' &lt;!channel&gt; &amp; *bold* _it_ @here &lt;https://evil.test|click&gt;`"

      assert section(body) =~ "on #{expected}"
      assert body.text =~ "Security alert on #{expected}:"

      for part <- [section(body), body.text],
          raw <- ["<!channel>", "<https://evil.test", "\n@here", "`tick`"] do
        refute part =~ raw
      end

      # The headline's line holds two code spans: the address and the name.
      [headline_line | _] = String.split(section(body), "\n")
      assert headline_line |> String.graphemes() |> Enum.count(&(&1 == "`")) == 4
    end

    test "an address is a code span, escaped" do
      body =
        SlackFormat.render(
          "security.lockout",
          alert(%{"event" => %{"ip" => "203.0.113.0/24 <!here>`x`", "type" => "lockout"}})
        )

      assert section(body) =~ "(from `203.0.113.0/24 &lt;!here&gt;'x'`)"
      refute body.text =~ "<!here>"
    end

    test "a block rule is a code span, escaped, like the address" do
      body =
        SlackFormat.render(
          "security.blocked_ip",
          alert(%{
            "kind" => "blocked_ip",
            "event" => %{
              "ip" => nil,
              "type" => "ip_block_refused",
              "metadata" => %{"rule" => "203.0.113.0/24 <!here>", "surface" => "http"}
            }
          })
        )

      assert section(body) =~
               "*A blocked address was refused (rule `203.0.113.0/24 &lt;!here&gt;`)* on `Example`"

      refute body.text =~ "<!here>"
    end

    test "the console URL is escaped for the link syntax" do
      body =
        SlackFormat.render(
          "security.lockout",
          alert(%{"console_url" => "https://c.test/log?a=1&b=<2>|x"})
        )

      assert context(body) =~ "<https://c.test/log?a=1&amp;b=&lt;2&gt;%7Cx|Open the security log>"
    end

    test "an empty site name is still a closed code span" do
      body = SlackFormat.render("security.lockout", alert(%{"site_name" => " \n "}))
      assert section(body) =~ "on `-`"
    end
  end

  describe "a summary and a notice" do
    test "a summary counts the window and says when it ran" do
      body =
        SlackFormat.render(
          "security.lockout",
          alert(%{"phase" => "summary", "count" => 7, "event" => nil})
        )

      assert section(body) ==
               "*An account was locked out: 7 in this alert window* on `Example`\n" <>
                 "From 2026-11-10 14:00 UTC to 2026-11-10 14:15 UTC"

      assert body.text =~
               "Security alert on `Example`: An account was locked out: 7 in this alert window"
    end

    test "a notice names the change and links to the alert settings" do
      body =
        SlackFormat.render("security.alerts_silenced", %{
          "phase" => "notice",
          "site_name" => "Example",
          "console_url" => "https://console.test/editor/security-alerts",
          "change" => "kind_disabled",
          "kinds" => ["lockout", "new_admin"],
          "endpoint_id" => "e0000000-0000-0000-0000-0000endpoint",
          "actor_id" => "a0000000-0000-0000-0000-000000actor"
        })

      assert section(body) ==
               "*Some security alerts were turned off* on `Example`\n" <>
                 "Turned off: An account was locked out, A new administrator"

      assert context(body) =~
               "<https://console.test/editor/security-alerts|Open the security alerts settings>"

      refute Jason.encode!(body) =~ "0000endpoint"
      refute Jason.encode!(body) =~ "000000actor"
    end
  end

  describe "anything else" do
    test "a ping names the site and no URL" do
      body =
        SlackFormat.render("ping", %{
          "message" => "KilnCMS webhook test",
          "site_name" => "Example <!channel>",
          "endpoint_url" => "https://hooks.slack.com/services/T0/B0/s3cr3tT0ken",
          "sent_at" => "2026-11-10T14:03:27Z"
        })

      assert body == %{
               text: "KilnCMS webhook test for `Example &lt;!channel&gt;`",
               unfurl_links: false,
               unfurl_media: false
             }
    end

    test "a content event says nothing from its payload" do
      body =
        SlackFormat.render("page.published", %{"title" => "Embargoed results", "body" => "x"})

      assert body.text =~ "`page.published`"
      refute Jason.encode!(body) =~ "Embargoed"
    end

    test "a security event of a phase this release does not know is a neutral line" do
      body = SlackFormat.render("security.lockout", alert(%{"phase" => "digest"}))

      assert body.text =~ "`security.lockout`"
      refute Jason.encode!(body) =~ "Example"
    end
  end
end
