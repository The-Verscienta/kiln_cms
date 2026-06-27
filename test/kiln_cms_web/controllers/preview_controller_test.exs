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
    test "sign/verify round-trips a page reference" do
      page = draft_page()
      assert {:ok, %{type: :page, id: id}} = page |> PreviewToken.sign() |> PreviewToken.verify()
      assert id == page.id
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
      # A validly-signed token pointing at an id with no record.
      token = PreviewToken.sign(%Page{id: Ecto.UUID.generate()})

      conn = conn |> json_conn() |> get(~p"/preview/#{token}")
      assert json_response(conn, 404)
    end
  end
end
