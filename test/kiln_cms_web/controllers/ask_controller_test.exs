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
    assert body["generation"] == "no_question"
  end

  test "the JSON names why generation did not run, and stays 200 (#853)", %{conn: conn} do
    actor = admin()
    term = "zorptastic#{System.unique_integer([:positive])}"

    post = CMS.create_post!(%{title: "The #{term} handbook", slug: slug()}, actor: actor)
    CMS.publish_post!(post, %{}, actor: actor)

    body = conn |> get(~p"/api/ask?q=#{term}") |> json_response(200)

    # The suite runs with no generator configured, so this is the default
    # install's answer: permanent, and distinguishable from a throttle.
    assert body["generation"] == "disabled"
    assert body["retry_after"] == nil

    # Still a degraded 200 with usable sources, not a refusal — the whole reason
    # the reason has to travel in the body rather than as a status code.
    assert body["generated"] == false
    assert body["sources"] != []
  end

  test "the response keeps the fields existing clients already read (#853)", %{conn: conn} do
    actor = admin()
    term = "zorptastic#{System.unique_integer([:positive])}"

    post = CMS.create_post!(%{title: "The #{term} handbook", slug: slug()}, actor: actor)
    CMS.publish_post!(post, %{}, actor: actor)

    body = conn |> get(~p"/api/ask?q=#{term}") |> json_response(200)

    # #853 is additive by construction: the four pre-existing fields stay, and
    # the two new ones are ALWAYS present so a typed client can rely on them —
    # asserting only the old four would pass with the feature deleted.
    assert Map.has_key?(body, "question")
    assert Map.has_key?(body, "answer")
    assert Map.has_key?(body, "generated")
    assert Map.has_key?(body, "sources")
    assert Map.has_key?(body, "generation")
    assert Map.has_key?(body, "retry_after")
    assert is_boolean(body["generated"])

    # And the two say the same thing about success, in the two directions a
    # client might read it.
    assert body["generated"] == is_nil(body["generation"])
  end

  test "the response is not cacheable — it is per-caller (#853)", %{conn: conn} do
    actor = admin()
    term = "zorptastic#{System.unique_integer([:positive])}"

    post = CMS.create_post!(%{title: "The #{term} handbook", slug: slug()}, actor: actor)
    CMS.publish_post!(post, %{}, actor: actor)

    conn = get(conn, ~p"/api/ask?q=#{term}")

    # `sources` already varied by the caller's visibility; #853 added throttle
    # state that also decays. A 200 with no directive is heuristically
    # cacheable, so a shared cache could hand one caller another's deadline.
    assert ["private, no-store"] = get_resp_header(conn, "cache-control")
  end
end
