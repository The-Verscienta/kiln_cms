defmodule KilnCMS.Webhooks.SlackFormat do
  @moduledoc """
  The body a Slack-format webhook endpoint is sent (#2245): an
  incoming-webhook message instead of Kiln's signed JSON envelope.
  `KilnCMS.Webhooks.DeliveryWorker` renders it at send time from the ledger
  row's event and payload, and signs the body it actually sends.

  "Slack-compatible" also covers Mattermost, Rocket.Chat and Discord's
  `/slack` endpoints, which read `text` and may ignore `blocks`. So `text`
  says everything on its own, the link to the console included, and `blocks`
  is what Slack shows in the channel.

  ## What it says

    * a security alert, summary or notice: its headline
      (`KilnCMS.Security.AlertText.headline/1`, in English, like the email),
      the site, when, and a link to the security log (or, for a notice, the
      alert settings);
    * a `"ping"`: "KilnCMS webhook test for `Site`". Never the endpoint's
      URL, which for an incoming webhook is the credential;
    * anything else (a subscription from before the format rules, or a
      redelivery of an older row): one neutral line naming the event, and
      nothing from its payload.

  Only what the payload already says goes out: the address as the site's
  settings allow (`KilnCMS.Security.Alerts.display_ip/2`), no delivery id, no
  actor or endpoint id.

  ## Escaping

  Every value that comes from a person (the site name) or from a request (the
  address) is put in a code span, with backticks inside it replaced and runs
  of whitespace and newlines collapsed, so it cannot close the span, start a
  new line, or be read as formatting. Slack's control characters (`&`, `<`,
  `>`) are escaped in the whole line once it is composed, so `<!channel>` or
  a `<url|link>` typed into a site name arrives as text. The console link is
  the one piece of `<url|text>` syntax, and its URL is escaped for it.

  `unfurl_links` and `unfurl_media` are off: the message carries a link to
  the console, and nothing from it should be fetched and previewed.
  """

  alias KilnCMS.Security.AlertText

  @doc """
  The JSON-encodable body for `event` with `data` (the ledger row's payload,
  string keys, or atom keys straight from the caller).
  """
  @spec render(String.t(), map()) :: map()
  def render("ping", data) do
    message("KilnCMS webhook test for #{code(get(data, "site_name"))}")
  end

  def render("security." <> _ = event, data) when is_map(data) do
    case get(data, "phase") do
      phase when phase in ["alert", "summary", "notice"] -> security(event, phase, data)
      _unknown -> neutral(event)
    end
  end

  def render(event, _data), do: neutral(event)

  defp security(event, phase, data) do
    english(fn ->
      headline = data |> AlertText.details() |> code_ip() |> AlertText.headline()
      site = code(get(data, "site_name"))
      link = link(get(data, "console_url"), link_text(phase))

      lines =
        [
          "*#{escape(headline)}* on #{escape(site)}",
          detail(phase, data)
        ]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n")

      context = Enum.reject([link, escape(code(event))], &is_nil/1) |> Enum.join(" · ")

      text =
        escape("Security alert on #{site}: #{headline}") <>
          fallback_link(get(data, "console_url"), link_text(phase))

      %{
        text: text,
        blocks: [
          %{type: "section", text: %{type: "mrkdwn", text: lines}},
          %{type: "context", elements: [%{type: "mrkdwn", text: context}]}
        ],
        unfurl_links: false,
        unfurl_media: false
      }
    end)
  end

  defp neutral(event) do
    message("KilnCMS sent #{code(event)}, which a Slack endpoint has no message for.")
  end

  defp message(line) do
    %{text: escape(line), unfurl_links: false, unfurl_media: false}
  end

  # The address goes into the headline as a code span (the critic's rule from
  # 2026-11-08: names and addresses in code spans).
  defp code_ip(%{"ip" => ip} = details) when is_binary(ip), do: %{details | "ip" => code(ip)}
  defp code_ip(details), do: details

  defp detail("alert", data), do: escape(at(get(data, "occurred_at")))

  defp detail("summary", data) do
    window = get(data, "window") || %{}

    case {at(get(window, "started_at")), at(get(window, "ends_at"))} do
      {"", _} -> nil
      {_, ""} -> nil
      {from, to} -> escape("From #{from} to #{to}")
    end
  end

  defp detail("notice", data) do
    case data |> get("kinds") |> List.wrap() |> Enum.map_join(", ", &AlertText.kind_label/1) do
      "" -> nil
      kinds -> escape("Turned off: #{kinds}")
    end
  end

  defp link_text("notice"), do: "Open the security alerts settings"
  defp link_text(_phase), do: "Open the security log"

  defp link(url, text) when is_binary(url) and url != "",
    do: "<#{link_url(url)}|#{escape(text)}>"

  defp link(_url, _text), do: nil

  # `text` is read by clients that ignore `blocks` and may not know Slack's
  # `<url|text>` (#2245, C8): the bare URL, which they link themselves.
  defp fallback_link(url, text) when is_binary(url) and url != "",
    do: escape(" · #{text}: ") <> link_url(url)

  defp fallback_link(_url, _text), do: ""

  # `2026-11-10T14:03:27Z` → `2026-11-10 14:03 UTC`; "" when it does not parse.
  defp at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
      _ -> ""
    end
  end

  defp at(_iso), do: ""

  @doc false
  # A value as a code span: backticks replaced (one would close the span),
  # whitespace and newlines collapsed. Escaped later, with the rest of the line.
  @spec code(term()) :: String.t()
  def code(value) do
    inner =
      value
      |> to_string()
      |> String.replace("`", "'")
      |> String.split()
      |> Enum.join(" ")
      |> String.slice(0, 200)

    "`" <> if(inner == "", do: "-", else: inner) <> "`"
  end

  @doc false
  # Slack's three control characters (`&` first, so the others are not
  # escaped twice).
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # A URL inside `<url|text>`: escaped, and a `|` (which would end the URL)
  # percent-encoded.
  defp link_url(url), do: url |> escape() |> String.replace("|", "%7C")

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_existing_atom(key))
    end
  end

  defp get(_value, _key), do: nil

  defp english(fun), do: Gettext.with_locale(KilnCMSWeb.Gettext, "en", fun)
end
