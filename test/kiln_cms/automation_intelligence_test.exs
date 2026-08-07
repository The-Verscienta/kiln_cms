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

  # A relay that is up but greylisting — the failure `KilnCMS.Mail` turns into a
  # raise so Oban retries. `:temporary_failure` carries no permanent marker and
  # no `:network_failure`, so it takes the retry_transient path without the
  # relay-outage alert.
  defmodule TransientMailerStub do
    use Swoosh.Adapter

    @impl Swoosh.Adapter
    def deliver(_email, _config), do: {:error, {:temporary_failure, "4.7.1 greylisted"}}
  end

  # Returns values that survive `KilnCMS.Seo.Draft.normalize/1` unchanged, so
  # the escaping assertion is about `metadata_body/2` and not about the
  # sanitizer upstream of it.
  defmodule AmpersandGenerator do
    @behaviour KilnCMS.Seo.Generator
    @impl true
    def draft(_document, _opts \\ []) do
      {:ok,
       %KilnCMS.Seo.Draft{
         seo_title: "Tea & Coffee",
         seo_description: "Sun & Moon",
         seo_keywords: ["tea"]
       }}
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

  # ── #377 box 1: auto internal-linking as an automation reaction ───────────

  describe "suggest_links" do
    test "emails linkable paths for the document under review" do
      actor = admin()

      r =
        rule(%{
          trigger_event: :in_review,
          action: :suggest_links,
          config: %{"to" => "eds@example.com"}
        })

      # A published neighbour is what there is to link *to* — the suggester
      # mirrors the delivery boundary, so a draft would (correctly) be invisible.
      target = indexed_post(actor, "brewing chamomile slowly for calm", "Chamomile")
      CMS.publish_post!(target, %{}, actor: actor)

      subject = indexed_post(actor, "brewing chamomile slowly for calm", "Calm teas")

      assert :ok = run_rule(r, subject, "post.in_review")

      assert_email_sent(fn email ->
        assert email.subject =~ "Internal links to consider"
        assert email.html_body =~ "Chamomile"
        assert email.html_body =~ "nothing was inserted"
      end)
    end

    test "is silent when there is nothing worth linking to" do
      actor = admin()

      r =
        rule(%{
          trigger_event: :in_review,
          action: :suggest_links,
          config: %{"to" => "eds@example.com"}
        })

      lonely = indexed_post(actor, "a subject no other document touches at all", "Alone")

      assert :ok = run_rule(r, lonely, "post.in_review")
      refute_email_sent()
    end
  end

  # ── #377 box 2: metadata generation on a state transition ─────────────────

  describe "suggest_metadata" do
    # Long enough to clear `KilnCMS.Seo.min_words/0` (50), below which drafting
    # correctly refuses rather than hallucinating a description from a title.
    defp long_body do
      Enum.map_join(1..60, " ", &"word#{&1}")
    end

    defp with_seo(config) do
      previous = Application.get_env(:kiln_cms, KilnCMS.Seo, [])
      Application.put_env(:kiln_cms, KilnCMS.Seo, Keyword.merge(previous, config))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Seo, previous) end)
    end

    # A loopback base_url is what makes `Seo.egress?/0` false — an unresolvable
    # host reads as egress, which is the safe default and also the shipped
    # stub's, so the on-prem case has to be stated explicitly.
    defp with_local_generator do
      with_seo(
        generator: KilnCMS.StubSeoGenerator,
        model: "stub:stub",
        base_url: "http://127.0.0.1:11434"
      )
    end

    defp metadata_rule(config \\ %{"to" => "eds@example.com"}) do
      rule(%{trigger_event: :in_review, action: :suggest_metadata, config: config})
    end

    test "emails the proposal and writes nothing to the record" do
      with_local_generator()
      actor = admin()
      r = metadata_rule()
      post = indexed_post(actor, long_body(), "Chamomile")

      assert :ok = run_rule(r, post, "post.in_review")

      assert_email_sent(fn email ->
        assert email.subject =~ "Suggested SEO metadata"
        assert email.html_body =~ "SEO: Chamomile"
        assert email.html_body =~ "Nothing was written"
      end)

      # The whole point of the design: automation makes the computation
      # unattended, not the write. An unattended `seo_description` would put
      # model output over an untrusted body straight into a public `<meta>` tag.
      reloaded = CMS.get_post!(post.id, authorize?: false)
      assert reloaded.seo_title == post.seo_title
      assert reloaded.seo_description == post.seo_description
      assert reloaded.seo_keywords == post.seo_keywords
    end

    test "model output is escaped into the email body" do
      # Deliberately NOT markup: `Draft.normalize/1` already strips `<…>` before
      # a draft ever reaches this module, so a stub returning tags would prove
      # nothing about `metadata_body/2` — the assertion would pass with the
      # escaping deleted. An ampersand survives `clean/1` intact, so it is the
      # value that actually exercises the escape on the way out.
      with_seo(
        generator: AmpersandGenerator,
        model: "stub:stub",
        base_url: "http://127.0.0.1:11434"
      )

      actor = admin()
      post = indexed_post(actor, long_body(), "Teas")

      assert :ok = run_rule(metadata_rule(), post, "post.in_review")

      assert_email_sent(fn email ->
        # `refute` first: `assert_email_sent/1` asserts on the function's return
        # value, and a passing `refute` returns false.
        refute email.html_body =~ "Tea & Coffee"
        assert email.html_body =~ "Tea &amp; Coffee"
        assert email.html_body =~ "Sun &amp; Moon"
      end)
    end

    test "is inert when drafting is not configured" do
      # `generator: nil` is the default install. A rule created against a
      # deployment that never configured drafting must be quiet, not broken.
      with_seo(generator: nil, model: nil)
      actor = admin()
      r = metadata_rule()
      post = indexed_post(actor, long_body(), "Unconfigured")

      assert :ok = run_rule(r, post, "post.in_review")
      refute_email_sent()
    end

    test "refuses to ship content off-site unattended without an explicit opt-in" do
      # No base_url → unresolvable host → egress. The panel is one editor
      # spending one request; a rule is every matching document, forever, with
      # nobody watching.
      with_seo(generator: KilnCMS.StubSeoGenerator, model: "stub:stub", base_url: nil)
      actor = admin()
      post = indexed_post(actor, long_body(), "Offsite")

      assert :ok = run_rule(metadata_rule(), post, "post.in_review")
      refute_email_sent()

      # …and runs once the rule says so.
      opted_in = metadata_rule(%{"to" => "eds@example.com", "allow_egress" => true})
      assert :ok = run_rule(opted_in, post, "post.in_review")
      assert_email_sent(fn email -> assert email.subject =~ "Suggested SEO metadata" end)
    end

    test "a generator failure is a logged no-op, not an Oban retry" do
      # A suggestion is advisory. Retrying it five times per document spends
      # real tokens to tell an editor something they can ask for directly.
      with_seo(
        generator: KilnCMS.StubSeoGenerator.Failing,
        model: "stub:stub",
        base_url: "http://127.0.0.1:11434"
      )

      actor = admin()
      post = indexed_post(actor, long_body(), "Doomed")

      assert :ok = run_rule(metadata_rule(), post, "post.in_review")
      refute_email_sent()
    end

    test "a body too short to summarize is skipped rather than hallucinated" do
      with_local_generator()
      actor = admin()
      post = indexed_post(actor, "three words only", "Terse")

      assert :ok = run_rule(metadata_rule(), post, "post.in_review")
      refute_email_sent()
    end

    test "a string \"true\" does not permit egress, and says why" do
      # Every other config key is a string, so this is the natural mistake — and
      # failing closed silently looks like a rule that is enabled, green, and
      # emails nothing forever.
      with_seo(generator: KilnCMS.StubSeoGenerator, model: "stub:stub", base_url: nil)
      actor = admin()
      post = indexed_post(actor, long_body(), "Stringly")
      r = metadata_rule(%{"to" => "eds@example.com", "allow_egress" => "true"})

      log =
        ExUnit.CaptureLog.capture_log(fn -> assert :ok = run_rule(r, post, "post.in_review") end)

      refute_email_sent()
      assert log =~ "must be the JSON boolean true"
    end

    test "a transient delivery failure drops instead of retrying the generation" do
      # `Mail.deliver_for_worker/2` raises on a greylisted or unreachable relay
      # so Oban retries — and a retry re-enters `run/3` from the top, which
      # would generate the draft again. A bulk move to `in_review` against a
      # greylisting relay would bill five generations per document.
      with_local_generator()
      actor = admin()
      post = indexed_post(actor, long_body(), "Undeliverable")

      previous = Application.get_env(:kiln_cms, KilnCMS.Mailer)
      Application.put_env(:kiln_cms, KilnCMS.Mailer, adapter: TransientMailerStub)
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Mailer, previous) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = run_rule(metadata_rule(), post, "post.in_review")
        end)

      assert log =~ "dropping rather than retrying"
    end
  end
end
