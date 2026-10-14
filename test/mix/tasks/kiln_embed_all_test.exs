defmodule Mix.Tasks.Kiln.EmbedAllTest do
  @moduledoc """
  `mix kiln.embed_all --blocks`: after an embedding-space change (model,
  pooling, `document_prefix`) the block index must be re-embedded too, and the
  fire path cannot do it — it skips every block whose text is unchanged.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.{CMS, SearchIndex}
  alias KilnCMS.Search.BlockEmbeddingWorker

  # Two deterministic embedders standing in for "before" and "after" a model
  # swap: the same text lands at a different vector under each.
  defmodule OldModel do
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(text), do: {:ok, vector(:erlang.phash2(text))}
    def vector(seed), do: for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))
  end

  defmodule NewModel do
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(text), do: {:ok, vector(:erlang.phash2(text))}
    def vector(seed), do: for(i <- 1..384, do: :math.cos(seed * 1.0e-4 + i))
  end

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    put_search_env(semantic: true, embedder: OldModel)
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "embedall-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp page_with_blocks(actor, blocks) do
    CMS.create_page!(
      %{
        title: "Doc",
        slug: "embedall-#{System.unique_integer([:positive])}",
        blocks: KilnCMS.TypedFixtures.typed_blocks(blocks)
      },
      actor: actor
    )
  end

  defp block_vectors(page) do
    {:ok, rows} = SearchIndex.block_embeddings_for(:page, page.id, authorize?: false)
    rows |> Enum.sort_by(& &1.block_key) |> Enum.map(& &1.embedding)
  end

  defp close?(a, b), do: Enum.zip(a, b) |> Enum.all?(fn {x, y} -> abs(x - y) < 1.0e-4 end)

  defp run_task(args), do: capture_io(fn -> Mix.Tasks.Kiln.EmbedAll.run(args) end)

  test "--blocks re-embeds a published document's blocks in the new space" do
    actor = admin()
    page = page_with_blocks(actor, [%{type: :heading, content: "Otters", order: 0}])
    CMS.publish_page!(page, actor: actor)
    KilnCMS.DataCase.drain_oban()

    [before] = block_vectors(page)
    put_search_env(embedder: NewModel)

    # Without the flag the block index is left in the old space: nothing
    # re-embeds a block whose text did not change.
    refute run_task([]) =~ "block"
    KilnCMS.DataCase.drain_oban()
    assert [^before] = block_vectors(page)

    assert run_task(["--blocks"]) =~ ~r/forced block re-embedding for \d+ published document/
    KilnCMS.DataCase.drain_oban()

    [after_swap] = block_vectors(page)
    refute close?(before, after_swap)
    assert close?(after_swap, NewModel.vector(:erlang.phash2("Doc\n\nOtters")))
  end

  test "--blocks enqueues forced jobs for published documents only" do
    actor = admin()
    published = page_with_blocks(actor, [%{type: :heading, content: "Live", order: 0}])
    CMS.publish_page!(published, actor: actor)
    draft = page_with_blocks(actor, [%{type: :heading, content: "Draft", order: 0}])
    KilnCMS.DataCase.drain_oban()

    run_task(["--blocks"])

    ids =
      for job <- Oban.Testing.all_enqueued(repo: KilnCMS.Repo, worker: BlockEmbeddingWorker) do
        assert job.args["force"] == true
        job.args["id"]
      end

    assert published.id in ids
    refute draft.id in ids
  end

  test "an unknown flag is refused rather than ignored" do
    assert_raise OptionParser.ParseError, fn -> run_task(["--block"]) end
  end
end
