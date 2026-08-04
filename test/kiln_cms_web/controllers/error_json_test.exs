defmodule KilnCMSWeb.ErrorJSONTest do
  @moduledoc """
  #750: renders the same envelope every headless surface does, not the
  Phoenix-generator default object shape.
  """
  use KilnCMSWeb.ConnCase, async: true

  test "renders 404" do
    assert KilnCMSWeb.ErrorJSON.render("404.json", %{}) ==
             %{errors: [%{status: "404", code: "not_found", detail: "Not Found"}]}
  end

  test "renders 500" do
    assert KilnCMSWeb.ErrorJSON.render("500.json", %{}) ==
             %{
               errors: [
                 %{status: "500", code: "internal_server_error", detail: "Internal Server Error"}
               ]
             }
  end

  test "422 answers unprocessable_entity, not Plug's reason_atom(422)" do
    # Plug.Conn.Status.reason_atom(422) answers :unprocessable_content (RFC
    # 9110's spelling), but every 422 this codebase writes by hand uses
    # "unprocessable_entity" — left to derive automatically, a raised 422
    # would silently answer a different code than every other one.
    assert %{errors: [%{code: "unprocessable_entity"}]} =
             KilnCMSWeb.ErrorJSON.render("422.json", %{})
  end

  test "an unrecognized template falls back to 500, same as Phoenix's own status_message_from_template/1" do
    assert KilnCMSWeb.ErrorJSON.render("whatever.json", %{}) ==
             %{
               errors: [
                 %{status: "500", code: "internal_server_error", detail: "Internal Server Error"}
               ]
             }
  end

  test "an unrouted path answers the envelope, not the object shape", %{conn: conn} do
    # A GET to almost anything under "/" matches the site's own HTML catch-all
    # (`get "/*path", ContentController, :fallback`), so a genuinely unrouted
    # request needs a method that catch-all doesn't accept.
    conn = conn |> put_req_header("accept", "application/json") |> post("/api/no-such-route", %{})

    assert %{"errors" => [%{"status" => "404", "code" => "not_found", "detail" => "Not Found"}]} =
             json_response(conn, 404)
  end
end
