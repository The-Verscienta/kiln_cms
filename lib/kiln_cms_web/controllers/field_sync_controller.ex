defmodule KilnCMSWeb.FieldSyncController do
  @moduledoc """
  The site's custom-field definitions as a download (#2288) —
  `GET /editor/fields/export.json`, the document `mix kiln.fields.import`
  reads (`KilnCMS.CMS.FieldSync`, docs/field-sync.md).

  Admin only, like defining a field: `FieldSync.export/1` re-checks that the
  actor can create a definition. A definition document holds no content, but
  it is the site's schema.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.FieldSync

  # The body is an application/json attachment, never rendered as a document.
  # sobelow_skip ["XSS.SendResp"]
  def export(conn, _params) do
    actor = conn.assigns[:current_user]
    org = KilnCMSWeb.Tenant.current_org(conn)

    with :admin <- KilnCMSWeb.LiveUserAuth.effective_tier(conn),
         {:ok, doc} <- FieldSync.export(actor: actor, tenant: org) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-disposition", ~s(attachment; filename="field-definitions.json"))
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, Jason.encode!(doc, pretty: true))
    else
      _not_admin -> conn |> put_status(:forbidden) |> json(%{error: "admin_required"})
    end
  end
end
