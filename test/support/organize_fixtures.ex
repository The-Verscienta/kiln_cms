defmodule KilnCMS.OrganizeFixtures do
  @moduledoc """
  Shared scaffolding for the derived-organization suites (#1596): a private
  org per test (so a tightened `KilnCMS.LLM.Budget` window in one test is never
  starved by another's spend — the org bucket key is the record's `org_id`),
  users, posts with one block per passage, and the `KilnCMS.Search` env that
  turns the stub embedder on.

  Callers are `async: false`: the search env is global app config.
  """
  alias KilnCMS.CMS
  alias KilnCMS.Search.BlockIndexer

  @doc "Turns semantic search on with `KilnCMS.StubEmbedder`, restoring on exit."
  def semantic_on!(overrides \\ []) do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      original |> Keyword.merge(KilnCMS.StubEmbedder.search_env()) |> Keyword.merge(overrides)
    )
  end

  @doc "Merges `overrides` into the live `KilnCMS.Search` env."
  def put_search_env(overrides) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      :kiln_cms |> Application.get_env(KilnCMS.Search, []) |> Keyword.merge(overrides)
    )
  end

  @doc "A fresh organization (real row, so tenant isolation is real)."
  def org! do
    {org, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        KilnCMS.Accounts.create_organization!(
          %{name: "Organize org", slug: "organize-#{uniq()}"},
          authorize?: false
        )
      end)

    org
  end

  @doc "A user of `role`, with optional extra attributes (`readable_types:` …)."
  def user!(role \\ :admin, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "organize-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  @doc """
  A post in `org` with one rich-text block per passage. Options: `:title`,
  `:publish?` (default true — and indexed, so it has stored vectors),
  `:tag_ids`, `:category_id`.
  """
  def post!(org, actor, passages, opts \\ []) do
    blocks =
      passages
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {text, i} -> %{type: :rich_text, content: "<p>#{text}</p>", order: i} end)
      |> KilnCMS.TypedFixtures.typed_blocks()

    attrs =
      %{title: Keyword.get(opts, :title, "Doc #{uniq()}"), slug: "org-#{uniq()}", blocks: blocks}
      |> put_opt(:tag_ids, opts[:tag_ids])
      |> put_opt(:category_id, opts[:category_id])

    post = CMS.create_post!(attrs, actor: actor, tenant: org)

    if Keyword.get(opts, :publish?, true) do
      post = CMS.publish_post!(post, %{}, actor: actor, tenant: org)
      {:ok, _} = BlockIndexer.reindex(post)
      post
    else
      post
    end
  end

  @doc "A tag in `org`."
  def tag!(org, actor, name \\ nil) do
    name = name || "tag #{uniq()}"
    CMS.create_tag!(%{name: name, slug: slugify(name)}, actor: actor, tenant: org)
  end

  @doc "A category in `org`."
  def category!(org, actor, name \\ nil) do
    name = name || "cat #{uniq()}"
    CMS.create_category!(%{name: name, slug: slugify(name)}, actor: actor, tenant: org)
  end

  defp slugify(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  @doc "The live count in a `KilnCMS.LLM.Budget` bucket for this window."
  def spent(kind, id, window_ms),
    do: KilnCMS.LLM.Budget.get("search_embedding:#{kind}:#{id}", window_ms)

  def uniq, do: System.unique_integer([:positive])

  defp put_opt(map, _key, nil), do: map
  defp put_opt(map, key, value), do: Map.put(map, key, value)
end
