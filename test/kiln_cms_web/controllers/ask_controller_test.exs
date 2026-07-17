defmodule KilnCMSWeb.AskControllerTest do
  @moduledoc "The /api/ask RAG endpoint (issue #339)."
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ask-ctrl-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "askc-#{System.unique_integer([:positive])}"

  test "GET /api/ask returns cited published sources, excluding drafts", %{conn: conn} do
    actor = admin()
    term = "zorptastic#{System.unique_integer([:positive])}"

    post = CMS.create_post!(%{title: "The #{term} handbook", slug: slug()}, actor: actor)
    CMS.publish_post!(post, %{}, actor: actor)
    CMS.create_post!(%{title: "Draft #{term}", slug: slug()}, actor: actor)

    body = conn |> get(~p"/api/ask?q=#{term}") |> json_response(200)

    assert body["question"] == term
    # Retrieval-only by default (no generator configured).
    assert body["generated"] == false
    assert body["answer"] == nil

    titles = Enum.map(body["sources"], & &1["title"])
    assert Enum.any?(titles, &String.contains?(&1, "handbook"))
    refute Enum.any?(titles, &String.contains?(&1, "Draft"))
  end

  test "an empty query returns an empty result without error", %{conn: conn} do
    body = conn |> get(~p"/api/ask?q=") |> json_response(200)
    assert body["sources"] == []
    assert body["answer"] == nil
  end
end
