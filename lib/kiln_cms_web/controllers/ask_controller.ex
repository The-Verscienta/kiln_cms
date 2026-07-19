defmodule KilnCMSWeb.AskController do
  @moduledoc """
  `GET /api/ask?q=…` — retrieval-augmented "ask your content" over **published**
  content (RAG, issue #339). Returns the relevant published passages as cited
  `sources`, and — when a generator is configured (`KilnCMS.Ask.Generator`) — a
  synthesized `answer` grounded in them.

  Anonymous requests see published, world-readable content only (the read
  policies); a bearer token widens visibility like every other headless surface.
  Ships retrieval-only by default (`answer: null`), so it works with no model
  configured; wiring an on-prem generator turns on generation without touching
  this controller.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Ask

  def ask(conn, params) do
    result =
      params["q"]
      |> to_string()
      |> Ask.answer(
        actor: conn.assigns[:current_user],
        authorize?: true,
        # Scope RAG retrieval to the request's org (#336).
        tenant: KilnCMSWeb.Tenant.current_org_id(conn),
        locale: params["locale"],
        limit: parse_limit(params["limit"])
      )

    json(conn, result)
  end

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_limit(_), do: nil
end
