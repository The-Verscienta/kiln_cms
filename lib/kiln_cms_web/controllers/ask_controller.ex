defmodule KilnCMSWeb.AskController do
  @moduledoc """
  `GET /api/ask?q=…` — retrieval-augmented "ask your content" over **published**
  content (RAG, issue #339). Returns the relevant published passages as cited
  `sources`, and — when a generator is configured (`KilnCMS.Ask.Generator`) — a
  synthesized `answer` grounded in them.

  **Every** request sees published, world-readable content only — a bearer
  token does not widen it, unlike the other headless read surfaces. It used to,
  and that shipped drafts to the configured model for any editor or admin
  token (#916); `KilnCMS.Ask` explains why the floor lives in retrieval rather
  than in generation.

  Ships retrieval-only by default (`answer: null`, `generation: "disabled"`),
  so it works with no model configured; wiring an on-prem generator turns on
  generation without touching this controller.

  Always answers **200**, including when generation does not run — the cited
  sources are a useful result on their own, and a status code for a partial
  result would be worse. The reason therefore travels in the body:
  `generation` names it and `retry_after` gives the one case with a deadline
  (#853). See `t:KilnCMS.Ask.generation/0`.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Ask
  alias KilnCMSWeb.Params

  def ask(conn, params) do
    result =
      params
      |> Params.string("q", "")
      |> Ask.answer(
        # No `:actor`. Retrieval is anonymous for every caller — see #916 and
        # the `KilnCMS.Ask` moduledoc.
        #
        # Scope RAG retrieval to the request's org (#336).
        tenant: KilnCMSWeb.Tenant.current_org_id(conn),
        locale: Params.string(params, "locale"),
        limit: parse_limit(Params.string(params, "limit")),
        # What the generation budget keys on. This endpoint is public, so most
        # callers have no user, and without an identity the per-caller bucket
        # would be skipped outright — leaving only the pipeline's 120/min
        # per-IP limiter in front of an LLM call.
        caller_id: caller_id(conn)
      )

    conn
    # `no-store`, like `VisualEditingController`, and for the same reason: the
    # body is per-caller. `sources` already depended on the actor's visibility,
    # and #853 added throttle state that is not merely per-caller but decays —
    # a shared cache holding one client's `generation: "rate_limited"` would
    # hand a second client a deadline it was never subject to, and suppress
    # generated answers it was entitled to. A 200 with no directive is
    # heuristically cacheable, so the absence of a header is not neutral here.
    |> put_resp_header("cache-control", "private, no-store")
    |> json(result)
  end

  # Rate-limiting identity only — it decides how much someone may ask, never
  # what they may see. A signed-in caller gets their own bucket rather than
  # sharing one with everyone behind the same address; the address is the
  # fallback, spelled with `KilnCMSWeb.RateLimit.client_key/1` rather than
  # formatted here so this bucket and the pipeline's per-IP bucket name the
  # same client the same way.
  defp caller_id(conn) do
    case conn.assigns[:current_user] do
      %{id: id} -> "user:" <> to_string(id)
      _anonymous -> "ip:" <> KilnCMSWeb.RateLimit.client_key(conn.remote_ip)
    end
  end

  # Left unclamped on purpose: `Ask.answer/2` clamps it against its own ceiling,
  # so bounding it a second time here would be two numbers to keep in step. The
  # shape is `Params`' business; the range is the callee's.
  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _other -> nil
    end
  end

  defp parse_limit(_absent), do: nil
end
