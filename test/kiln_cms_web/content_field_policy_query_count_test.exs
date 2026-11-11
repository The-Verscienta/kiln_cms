defmodule KilnCMSWeb.ContentFieldPolicyQueryCountTest do
  @moduledoc """
  What the `Content` field policy on the provenance fields (#2273, ADR 0012)
  costs a read, asserted rather than assumed.

  The policy's checks are `Checks.ReadableContentType` (a simple check, run once
  per read through `KilnCMS.Accounts.Scoping`'s tier lookup) and
  `Checks.DraftWriteOwnProvenance` (a filter check, compiled into the read's
  own SQL). Neither may issue a query per row, and with `Scoping`'s production
  memo on, neither may issue one at all: the tier lookup is the one the read
  policy already made.

  1. **Nothing per row.** A read of 20 rows costs what a read of 1 costs, for
     every actor shape the policy distinguishes and on every surface: the code
     interface, JSON:API (list and single), GraphQL, and a relationship load
     that pulls `Content` (a page's `children`). Measured with the test
     config's memo off, the strictest setting.
  2. **Nothing per read.** With the production memo on (each read starting
     cold, like a fresh request process), each read issues exactly the
     queries it issued before the field policy existed: one for the rows, the
     tier resolution (two `org_memberships` lookups), and on the API the key
     and its owner.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS
  alias KilnCMS.Test.QueryCounting

  @accept "application/vnd.api+json"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fp-cost-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint_key(owner, access) do
    key =
      Accounts.mint_api_key!(
        owner.id,
        "svc",
        DateTime.add(DateTime.utc_now(), 7, :day),
        %{access: access},
        actor: user(:admin)
      )

    {key.id, Ash.Resource.get_metadata(key, :plaintext_api_key)}
  end

  defp slug, do: "fp-cost-#{System.unique_integer([:positive])}"

  # Alternating published rows and drafts, all stamped with the `:draft_write`
  # key's provenance, so every branch of the field policy has rows to decide.
  defp seed_posts(n, author, key_id) do
    for i <- 1..n do
      Ash.Seed.seed!(CMS.Post, %{
        title: "Row #{i}",
        slug: slug(),
        state: if(rem(i, 2) == 0, do: :draft, else: :published),
        published_at: DateTime.utc_now(),
        author_id: author.id,
        created_via_key_id: key_id,
        created_via_key_name: "svc",
        on_behalf_of: "end-user"
      })
    end
  end

  defp seed_page(attrs) do
    Ash.Seed.seed!(
      CMS.Page,
      Map.merge(
        %{title: "Page", slug: slug(), state: :published, published_at: DateTime.utc_now()},
        attrs
      )
    )
  end

  defp seed_children(parent, n) do
    for i <- 1..n,
        do: seed_page(%{title: "Child #{i}", author_id: parent.author_id, parent_id: parent.id})
  end

  defp get_json(path, key) do
    build_conn()
    |> put_req_header("accept", @accept)
    |> put_req_header("authorization", "Bearer #{key}")
    |> get(path)
  end

  defp gql(query, key) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> post("/gql", Jason.encode!(%{query: query}))
  end

  # The Repo queries `fun` issues on this test's behalf, by source table —
  # Ecto's telemetry, so nothing a log-scraping proxy could miss. Starts from a
  # cold `Scoping` memo, the way a fresh request process does.
  defp queries(fun) do
    for {Scoping, _, _} = key <- Process.get_keys(), do: Process.delete(key)

    {_result, queries} = QueryCounting.queries(fun)
    QueryCounting.by_source(queries)
  end

  defp with_production_memo(fun) do
    previous = Application.get_env(:kiln_cms, Scoping)
    Application.put_env(:kiln_cms, Scoping, memo_ttl_ms: 5_000)

    try do
      fun.()
    after
      Application.put_env(:kiln_cms, Scoping, previous)
    end
  end

  setup do
    owner = user(:viewer)
    {dw_key_id, dw_key} = mint_key(owner, :draft_write)
    viewer = user(:viewer)
    editor = user(:editor)
    {_, editor_key} = mint_key(editor, :read)

    %{
      owner: owner,
      dw_key_id: dw_key_id,
      dw_key: dw_key,
      viewer: viewer,
      editor: editor,
      editor_key: editor_key
    }
  end

  # Every read the field policy sits on, keyed by name. Each must cost the same
  # with 1 row as with 20.
  defp reads(ctx, one_id, root_id) do
    gql_list =
      "{ publishedPosts(limit: 20) { count results { title createdViaKeyName onBehalfOf } } }"

    %{
      "list_posts anonymous" => fn -> CMS.list_posts!() end,
      "list_posts viewer" => fn -> CMS.list_posts!(actor: ctx.viewer) end,
      "list_posts editor" => fn -> CMS.list_posts!(actor: ctx.editor) end,
      "JSON:API list, editor key" => fn ->
        get_json("/api/json/posts?page[limit]=100", ctx.editor_key)
      end,
      "JSON:API list, draft_write key" => fn ->
        get_json("/api/json/posts?page[limit]=100", ctx.dw_key)
      end,
      "JSON:API single, draft_write key" => fn ->
        get_json("/api/json/posts/#{one_id}", ctx.dw_key)
      end,
      "GraphQL list, editor key" => fn -> gql(gql_list, ctx.editor_key) end,
      "page children, editor" => fn ->
        CMS.get_page!(root_id, actor: ctx.editor, load: [:children])
      end
    }
  end

  test "the field policy is actually decided on these reads", ctx do
    seed_posts(2, ctx.owner, ctx.dw_key_id)

    # An editor reads the provenance; a viewer and an anonymous caller get it
    # forbidden. Without this the counts below could pass on a read that
    # never reached the field policy.
    assert Enum.all?(CMS.list_posts!(actor: ctx.editor), &(&1.created_via_key_name == "svc"))

    for actor <- [ctx.viewer, nil] do
      assert [_ | _] = rows = CMS.list_posts!(actor: actor)
      assert Enum.all?(rows, &match?(%Ash.ForbiddenField{}, &1.created_via_key_name))
    end

    body = Jason.decode!(get_json("/api/json/posts?page[limit]=100", ctx.dw_key).resp_body)
    draft = Enum.find(body["data"], &(&1["attributes"]["title"] == "Row 2"))
    assert draft["attributes"]["created_via_key_id"] == ctx.dw_key_id
  end

  test "a Content read costs the same queries for 1 row as for 20", ctx do
    [one | _] = seed_posts(1, ctx.owner, ctx.dw_key_id)
    root = seed_page(%{author_id: ctx.owner.id})
    seed_children(root, 1)

    reads = reads(ctx, one.id, root.id)
    # Warm the per-VM caches (default org, key lookups) so neither run pays them.
    Enum.each(reads, fn {_, read} -> read.() end)
    small = Map.new(reads, fn {name, read} -> {name, queries(read)} end)

    seed_posts(19, ctx.owner, ctx.dw_key_id)
    seed_children(root, 19)
    large = Map.new(reads, fn {name, read} -> {name, queries(read)} end)

    for {name, counts} <- small do
      assert large[name] == counts,
             "#{name}: #{inspect(counts)} for 1 row, #{inspect(large[name])} for 20"
    end
  end

  test "with the production memo, the field policy adds no query to a read", ctx do
    [one | _] = seed_posts(20, ctx.owner, ctx.dw_key_id)
    root = seed_page(%{author_id: ctx.owner.id})
    seed_children(root, 20)

    reads = reads(ctx, one.id, root.id)
    Enum.each(reads, fn {_, read} -> read.() end)

    tier = %{"org_memberships" => 2}
    key = %{"api_keys" => 1, "users" => 1}

    expected = %{
      "list_posts anonymous" => %{"posts" => 1},
      "list_posts viewer" => Map.put(tier, "posts", 1),
      "list_posts editor" => Map.put(tier, "posts", 1),
      "JSON:API list, editor key" => tier |> Map.merge(key) |> Map.put("posts", 1),
      "JSON:API list, draft_write key" => tier |> Map.merge(key) |> Map.put("posts", 1),
      "JSON:API single, draft_write key" => tier |> Map.merge(key) |> Map.put("posts", 1),
      "GraphQL list, editor key" => tier |> Map.merge(key) |> Map.put("posts", 2),
      "page children, editor" => Map.put(tier, "pages", 2)
    }

    with_production_memo(fn ->
      for {name, read} <- reads do
        assert queries(read) == expected[name], name
      end
    end)
  end
end
