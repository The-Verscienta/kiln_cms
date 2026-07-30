defmodule KilnCMSWeb.Plugs.RawBodyReader do
  @moduledoc """
  `Plug.Parsers` body reader that stashes the **exact raw request bytes** in
  `conn.private[:raw_body]` — but only for the inbound payment-webhook path.

  A provider's webhook signature is an HMAC over the raw bytes, and re-encoding the
  parsed JSON does not reproduce them (key order, whitespace and unicode escaping
  all differ), so the signature is unverifiable without this.

  ## Scoped by path on purpose

  Buffering unconditionally would hold a second copy of every request body — up to
  the endpoint's 8 MB `length` — for the whole request, doubling peak memory on
  media uploads for the benefit of one route.

  The webhook path also gets a much tighter cap than the endpoint default: it is an
  unauthenticated route, and events are a few KB, so there is no reason to let a
  caller make us buffer megabytes before we have verified anything. Over the cap,
  the `{:more, ...}` return is passed through unchanged so `Plug.Parsers` raises
  its own `RequestTooLargeError` — a partial body is never stashed, which would
  otherwise surface as a confusing signature failure rather than a size error.
  """
  @webhook_path "/billing/webhooks/"
  @max_bytes 1_000_000

  @doc "The path prefix whose bodies are preserved."
  def webhook_path, do: @webhook_path

  @doc "The byte cap applied to preserved bodies."
  def max_bytes, do: @max_bytes

  @doc """
  Read the body, preserving it for the webhook path only.

  Passed to `Plug.Parsers` as `body_reader: {__MODULE__, :read_body, []}`.
  """
  def read_body(conn, opts) do
    if webhook?(conn) do
      read_and_stash(conn, Keyword.put(opts, :length, @max_bytes))
    else
      Plug.Conn.read_body(conn, opts)
    end
  end

  # `KilnCMSWeb.Plugs.SetLocale` strips a `/<locale>/…` prefix, but it runs AFTER
  # `Plug.Parsers`, so a locale-prefixed hit still carries its prefix here — hence
  # a contains check rather than an exact match.
  defp webhook?(conn), do: String.contains?(conn.request_path, @webhook_path)

  defp read_and_stash(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, Plug.Conn.put_private(conn, :raw_body, body)}

      other ->
        other
    end
  end
end
