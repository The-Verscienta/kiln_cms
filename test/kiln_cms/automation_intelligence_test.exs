defmodule KilnCMS.AutomationIntelligenceTest do
  @moduledoc "Embedding-driven automation reactions + event dedupe (#377)."
  # async: false — toggles the global KilnCMS.Search app env (stub embedder).
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import Swoosh.TestAssertions

  alias KilnCMS.Automation
  alias KilnCMS.Automation.Rule
  alias KilnCMS.Automation.RuleWorker
  alias KilnCMS.CMS
  alias KilnCMS.Search.BlockIndexer

  defmodule StubEmbedder do
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(text) do
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      Keyword.merge(original, semantic: true, embedder: StubEmbedder)
    )

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ai-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp rule(attrs) do
    Ash.Seed.seed!(
      Rule,
      Map.merge(
        %{name: "AI #{System.unique_integer([:positive])}", enabled: true, config: %{}},
        attrs
      )
    )
  end

  defp indexed_post(actor, text, title) do
    post =
      CMS.create_post!(
        %{
          title: title,
          slug: "ai-#{System.unique_integer([:positive])}",
          blocks: [%{type: :rich_text, content: "<p>#{text}</p>", order: 0}]
        },
        actor: actor
      )

    {:ok, _} = BlockIndexer.reindex(post)
    post
  end

  defp run_rule(rule, post, event) do
    RuleWorker.perform(%Oban.Job{
      args: %{
        "rule_id" => rule.id,
        "event" => event,
        "payload" => %{"id" => post.id, "title" => post.title, "slug" => post.slug},
        "org_id" => rule.org_id
      }
    })
  end

  test "flag_duplicates emails editors when near-identical content exists — and only then" do
    actor = admin()

    r =
      rule(%{
        trigger_event: :published,
        action: :flag_duplicates,
        config: %{"to" => "eds@example.com"}
      })

    anchor = indexed_post(actor, "the exact same passage", "Same")
    _dup = indexed_post(actor, "the exact same passage", "Same")

    assert :ok = run_rule(r, anchor, "post.published")

    assert_email_sent(fn email ->
      assert email.subject =~ "possible duplicates"
      assert email.html_body =~ "Same"
    end)

    lonely = indexed_post(actor, "a passage no other document shares", "Lonely")
    assert :ok = run_rule(r, lonely, "post.published")
    refute_email_sent()
  end

  test "suggest_tags emails ranked suggestions and skips when there are none" do
    actor = admin()
    uniq = System.unique_integer([:positive])
    CMS.create_tag!(%{name: "herbal tea", slug: "tag-#{uniq}"}, actor: actor)

    r =
      rule(%{
        trigger_event: :published,
        action: :suggest_tags,
        config: %{"to" => "eds@example.com"}
      })

    post = indexed_post(actor, "brewing herbal tea slowly", "Teas")

    assert :ok = run_rule(r, post, "post.published")

    assert_email_sent(fn email ->
      assert email.subject =~ "Tag suggestions"
      assert email.html_body =~ "herbal tea"
    end)
  end

  test "a missing `to` is a logged no-op, not a crash" do
    actor = admin()
    r = rule(%{trigger_event: :published, action: :flag_duplicates, config: %{}})
    anchor = indexed_post(actor, "same body here", "Same")
    _dup = indexed_post(actor, "same body here", "Same")

    assert :ok = run_rule(r, anchor, "post.published")
  end

  test "duplicate editorial events collapse to one job per {rule, event, document}" do
    r = rule(%{trigger_event: :published, action: :broadcast})
    payload = %{"id" => Ash.UUID.generate(), "title" => "T", "slug" => "s"}

    Automation.dispatch("post.published", payload)
    Automation.dispatch("post.published", payload)

    jobs =
      all_enqueued(worker: RuleWorker)
      |> Enum.filter(&(&1.args["rule_id"] == r.id))

    assert length(jobs) == 1

    # A DIFFERENT document within the window still enqueues.
    Automation.dispatch("post.published", %{payload | "id" => Ash.UUID.generate()})

    jobs =
      all_enqueued(worker: RuleWorker)
      |> Enum.filter(&(&1.args["rule_id"] == r.id))

    assert length(jobs) == 2
  end
end
