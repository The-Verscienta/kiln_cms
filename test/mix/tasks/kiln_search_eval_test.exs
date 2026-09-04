defmodule Mix.Tasks.Kiln.Search.EvalTest do
  @moduledoc """
  The task around `KilnCMS.Search.Eval`: argument handling, the golden-set
  file, the two output modes, the job-summary append, and the exit contract —
  zero whatever the numbers, non-zero only under a `--fail-below` that is not
  met. The ranking itself is covered by `KilnCMS.Search.EvalIntegrationTest`;
  here the corpus is one published page.
  """
  # `Mix.shell/1` and `$GITHUB_STEP_SUMMARY` are process-global, so the
  # `run/1` cases cannot share the VM with another test that swaps them.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias Mix.Tasks.Kiln.Search.Eval, as: Task

  @scratch Path.join(System.tmp_dir!(), "kiln_search_eval_test")

  setup do
    Mix.shell(Mix.Shell.Process)
    File.mkdir_p!(@scratch)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      File.rm_rf!(@scratch)
    end)

    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "eval-task-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    org =
      Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
        name: "eval-task",
        slug: "eval-task-#{System.unique_integer([:positive])}",
        status: :active
      })

    word = "kilnobsidian#{System.unique_integer([:positive])}"

    CMS.create_page!(%{title: "#{word} guide", slug: "g-#{word}", blocks: []},
      actor: actor,
      tenant: org
    )
    |> then(&CMS.publish_page!(&1, %{}, actor: actor, tenant: org))

    KilnCMS.DataCase.drain_oban()

    %{org: org, word: word, slug: "g-#{word}"}
  end

  defp golden(rows) do
    path = Path.join(@scratch, "golden-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(rows))
    path
  end

  defp output do
    receive do
      {:mix_shell, :info, [text]} -> text
    after
      0 -> flunk("the task printed nothing")
    end
  end

  test "prints the table and the per-query ranks, and exits 0 on misses", ctx do
    path =
      golden([
        %{query: ctx.word, expected: [ctx.slug], class: "single_entity"},
        %{query: "nothing #{ctx.word}", expected: ["absent-slug"], class: "paraphrase"},
        %{query: "asdfghjkl zzqqxx", expected: [], class: "junk"}
      ])

    assert :ok = Task.run([path, "--org", ctx.org.slug, "--k", "1,5"])

    text = output()
    assert text =~ "Search eval — 3 queries, source: global (in-process), k = 1,5"
    assert text =~ ~r/^single_entity\s+1\s+1\.000\s+1\.000\s+1\.000$/m
    assert text =~ ~r/^paraphrase\s+1\s+0\.000\s+0\.000\s+0\.000$/m
    assert text =~ ~r/^overall\s+3\s+0\.667\s+0\.667\s+0\.667$/m
    assert text =~ ~r/^    #{ctx.slug}\s+#1  keyword/m
    assert text =~ ~r/^    absent-slug\s+missing$/m
    assert text =~ ~s([junk] "asdfghjkl zzqqxx"  PASS)
  end

  test "--json prints the report as JSON", ctx do
    path = golden([%{query: ctx.word, expected: [ctx.slug], class: "single_entity"}])

    assert :ok = Task.run([path, "--org", ctx.org.slug, "--json"])

    json = Jason.decode!(output())
    assert json["source"] == "global (in-process)"
    assert json["ks"] == [1, 3, 5, 10]
    assert json["summary"]["overall"]["recall"]["1"] == 1.0
    assert [%{"expected" => [%{"slug" => slug, "rank" => 1}]}] = json["queries"]
    assert slug == ctx.slug
  end

  test "--ask judges the ask path's source order", ctx do
    path = golden([%{query: ctx.word, expected: [ctx.slug], class: "single_entity"}])

    assert :ok = Task.run([path, "--org", ctx.org.slug, "--ask"])
    text = output()
    assert text =~ "source: ask (in-process)"
    assert text =~ ~r/^    #{ctx.slug}\s+#1  keyword/m
  end

  test "--fail-below fails the task only when a threshold is not met", ctx do
    path =
      golden([
        %{query: ctx.word, expected: [ctx.slug], class: "single_entity"},
        %{query: "nothing #{ctx.word}", expected: ["absent-slug"], class: "paraphrase"}
      ])

    # Met: single_entity is at 1.0, overall at 0.5.
    assert :ok =
             Task.run([
               path,
               "--org",
               ctx.org.slug,
               "--fail-below",
               "single_entity=1.0",
               "--fail-below",
               "overall=0.5@1"
             ])

    _ = output()

    # Not met: the report is still printed first, then the task raises.
    error =
      assert_raise Mix.Error, fn ->
        Task.run([path, "--org", ctx.org.slug, "--fail-below", "paraphrase=0.5@3"])
      end

    assert error.message =~ "search eval below threshold"
    assert error.message =~ "paraphrase recall@3 = 0.000 < 0.500"
    assert output() =~ "Per query:"
  end

  test "appends the markdown summary to the GitHub job summary when set", ctx do
    path = golden([%{query: ctx.word, expected: [ctx.slug], class: "single_entity"}])
    summary = Path.join(@scratch, "summary.md")
    File.write!(summary, "# before\n")
    System.put_env("GITHUB_STEP_SUMMARY", summary)
    on_exit(fn -> System.delete_env("GITHUB_STEP_SUMMARY") end)

    assert :ok = Task.run([path, "--org", ctx.org.slug])
    _ = output()

    md = File.read!(summary)
    assert md =~ "# before\n### Search ranking eval (global (in-process), 1 queries)"
    assert md =~ "| `single_entity` | 1 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 |"
  end

  test "bad input is a Mix error that names the problem", ctx do
    assert_raise Mix.Error, ~r/usage: mix kiln.search.eval/, fn -> Task.run([]) end

    assert_raise Mix.Error, ~r/is not a file/, fn ->
      Task.run([Path.join(@scratch, "missing.json")])
    end

    bad = Path.join(@scratch, "bad.json")
    File.write!(bad, ~s([{"query": "x", "expected": ["y"], "class": "nope"}]))
    assert_raise Mix.Error, ~r/row 0: "class" must be one of/, fn -> Task.run([bad]) end

    path = golden([%{query: ctx.word, expected: [ctx.slug], class: "single_entity"}])

    assert_raise Mix.Error, ~r/--k expects positive integers/, fn ->
      Task.run([path, "--k", "1,x"])
    end

    assert_raise Mix.Error, ~r/unknown class "herbs"/, fn ->
      Task.run([path, "--fail-below", "herbs=0.9"])
    end

    assert_raise Mix.Error, ~r/--url must be an http\(s\) base URL/, fn ->
      Task.run([path, "--url", "example.com"])
    end

    assert_raise Mix.Error, ~r/no organization with slug/, fn ->
      Task.run([path, "--org", "no-such-org-#{System.unique_integer([:positive])}"])
    end
  end
end
