defmodule KilnCMSWeb.PreviewControllerTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS.{Page, PreviewToken}

  defp draft_page(attrs \\ %{}) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{
          title: "Secret draft",
          slug: "prev-#{System.unique_integer([:positive])}",
          state: :draft
        },
        attrs
      )
    )
  end

  defp json_conn(conn), do: put_req_header(conn, "accept", "application/json")

  describe "PreviewToken" do
    test "sign/verify round-trips a page reference, tenant included" do
      page = draft_page()

      assert {:ok, %{type: :page, id: id, org_id: org_id}} =
               page |> PreviewToken.sign() |> PreviewToken.verify()

      assert id == page.id
      assert org_id == page.org_id
    end

    test "verify refuses a token that carries no tenant (#1309)" do
      # A pre-#1309 payload: validly signed, but the read it would authorize
      # has no tenant to scope it. Nothing may read tenant-less on its behalf.
      page = draft_page()

      legacy =
        Phoenix.Token.sign(KilnCMSWeb.Endpoint, "content preview", %{type: :page, id: page.id})

      assert {:error, :invalid} = PreviewToken.verify(legacy)
    end

    test "verify rejects a garbage token" do
      assert {:error, _} = PreviewToken.verify("not-a-real-token")
    end
  end

  describe "GET /preview/:token" do
    test "returns the unpublished content for a valid token", %{conn: conn} do
      page = draft_page(%{title: "Hush hush"})
      token = PreviewToken.sign(page)

      conn = conn |> json_conn() |> get(~p"/preview/#{token}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == page.id
      assert data["title"] == "Hush hush"
      assert data["state"] == "draft"
      # Internal fields are not leaked.
      refute Map.has_key?(data, "search_text")
    end

    test "404s on a tampered/invalid token", %{conn: conn} do
      conn = conn |> json_conn() |> get(~p"/preview/garbage")

      assert %{"errors" => [%{"code" => "invalid_preview", "detail" => detail}]} =
               json_response(conn, 404)

      assert detail =~ "Invalid or expired"
    end

    test "404s when the referenced content doesn't exist", %{conn: conn} do
      # A validly-signed token for THIS site pointing at an id with no record —
      # the org must be real, or `verify/1` refuses it before the read.
      token = PreviewToken.sign(%Page{id: Ecto.UUID.generate(), org_id: draft_page().org_id})

      conn = conn |> json_conn() |> get(~p"/preview/#{token}")
      assert %{"errors" => [%{"code" => "invalid_preview"}]} = json_response(conn, 404)
    end

    test "404s when the token was minted for another site (#1309)", %{conn: conn} do
      # Same record, but the token claims a different org than the one serving
      # the request: refused rather than served under this site's name.
      page = draft_page()
      token = PreviewToken.sign(%{page | org_id: Ecto.UUID.generate()})

      conn = conn |> json_conn() |> get(~p"/preview/#{token}")
      assert %{"errors" => [%{"code" => "invalid_preview"}]} = json_response(conn, 404)
    end
  end
end
