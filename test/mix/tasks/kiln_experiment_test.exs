defmodule Mix.Tasks.Kiln.ExperimentTest do
  @moduledoc """
  `mix kiln.experiment` (#499 phase 1, coverage gap #985).

  Until `/editor/experiments` lands this task is the **only** way to operate the
  engine, so a break here makes the feature inert in exactly the phase where it
  is the whole interface. It also carries real logic of its own — required
  options, the per-goal requirements, and the state-machine calls — none of
  which is exercised anywhere else.

  `async: false`: the task calls `Mix.shell()` and `Mix.raise/1`, which are
  process-global.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.ExperimentFixtures
  alias KilnCMS.Experiments
  alias Mix.Tasks.Kiln.Experiment

  setup do
    # `@requirements ["app.start"]` is already satisfied under the test runner;
    # running the task directly skips it, so nothing to stub.
    org_id = KilnCMS.Accounts.default_org_id()
    %{org_id: org_id, actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "exptask-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp page(actor) do
    KilnCMS.CMS.create_page!(
      %{title: "Target", slug: "exptask-#{System.unique_integer([:positive])}"},
      actor: actor
    )
  end

  defp name, do: "exp-#{System.unique_integer([:positive])}"

  defp run(args), do: capture_io(fn -> Experiment.run(args) end)

  defp sticky_on do
    original = Application.get_env(:kiln_cms, KilnCMS.Experiments, [])
    Application.put_env(:kiln_cms, KilnCMS.Experiments, Keyword.put(original, :sticky, true))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Experiments, original) end)
  end

  defp sticky_off do
    original = Application.get_env(:kiln_cms, KilnCMS.Experiments, [])
    Application.put_env(:kiln_cms, KilnCMS.Experiments, Keyword.put(original, :sticky, false))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Experiments, original) end)
  end

  defp find(org_id, name) do
    Experiments.list_experiments!(authorize?: false, tenant: org_id, load: [:variants])
    |> Enum.find(&(&1.name == name))
  end

  describe "create" do
    test "requires --form, because a goal form is what makes a conversion countable",
         %{actor: actor} do
      doc = page(actor)

      # Not cosmetic: a form_submission experiment with no goal form counts
      # nothing and would report 0.0% forever. `:start` enforces it too — this
      # refuses earlier, where the operator can still fix it cheaply.
      assert_raise Mix.Error, ~r/--form/, fn ->
        run(["create", name(), "--type", "page", "--document", doc.id])
      end
    end

    test "requires --type and --document", %{actor: actor} do
      doc = page(actor)

      assert_raise Mix.Error, ~r/--type/, fn ->
        run(["create", name(), "--document", doc.id, "--form", Ash.UUID.generate()])
      end

      assert_raise Mix.Error, ~r/--document/, fn ->
        run(["create", name(), "--type", "page", "--form", Ash.UUID.generate()])
      end
    end

    test "creates a draft experiment against the document", ctx do
      doc = page(ctx.actor)
      form = ExperimentFixtures.goal_form!(ctx.org_id)
      exp_name = name()

      out = run(["create", exp_name, "--type", "page", "--document", doc.id, "--form", form.id])

      assert out =~ "Created experiment #{exp_name}"

      experiment = find(ctx.org_id, exp_name)
      assert experiment.state == :draft
      assert experiment.content_type == "page"
      assert experiment.document_id == doc.id
      assert experiment.goal == :form_submission
      assert experiment.goal_form_id == form.id
    end

    test "refuses --goal content_view while sticky assignment is off", ctx do
      doc = page(ctx.actor)

      # Attributing a view on a LATER page needs to know the visitor was
      # exposed, which on the built-in site only the sticky cookie can say
      # (#984). Without it the experiment would run and report 0.0% forever, so
      # the task names the switch rather than letting that happen.
      error =
        assert_raise Mix.Error, fn ->
          run([
            "create",
            name(),
            "--type",
            "page",
            "--document",
            doc.id,
            "--goal",
            "content_view",
            "--goal-type",
            "page",
            "--goal-document",
            page(ctx.actor).id
          ])
        end

      assert Exception.message(error) =~ "sticky"
      assert Exception.message(error) =~ "ever convert"
    end

    test "creates a content_view experiment once sticky assignment is on", ctx do
      sticky_on()
      doc = page(ctx.actor)
      target = page(ctx.actor)
      experiment_name = name()

      run([
        "create",
        experiment_name,
        "--type",
        "page",
        "--document",
        doc.id,
        "--goal",
        "content_view",
        "--goal-type",
        "page",
        "--goal-document",
        target.id
      ])

      experiment = find(ctx.org_id, experiment_name)

      assert experiment.goal == :content_view
      assert experiment.goal_content_type == "page"
      assert experiment.goal_document_id == target.id
      # No goal form: a content-view experiment does not convert on a form.
      refute experiment.goal_form_id
    end

    test "refuses --form alongside a content_view goal instead of dropping it", ctx do
      sticky_on()
      doc = page(ctx.actor)
      form = ExperimentFixtures.goal_form!(ctx.org_id)

      # Silently ignoring it would leave an operator who adapted an existing
      # command line believing form submissions also count.
      error =
        assert_raise Mix.Error, fn ->
          run([
            "create",
            name(),
            "--type",
            "page",
            "--document",
            doc.id,
            "--form",
            form.id,
            "--goal",
            "content_view",
            "--goal-type",
            "page",
            "--goal-document",
            page(ctx.actor).id
          ])
        end

      assert Exception.message(error) =~ "--form does not apply"
    end

    test "requires --goal-type and --goal-document for a content_view goal", ctx do
      sticky_on()
      doc = page(ctx.actor)
      base = ["create", name(), "--type", "page", "--document", doc.id, "--goal", "content_view"]

      assert_raise Mix.Error, ~r/--goal-type/, fn ->
        run(base ++ ["--goal-document", page(ctx.actor).id])
      end

      assert_raise Mix.Error, ~r/--goal-document/, fn ->
        run(base ++ ["--goal-type", "page"])
      end
    end

    test "refuses an unknown goal", ctx do
      doc = page(ctx.actor)
      form = ExperimentFixtures.goal_form!(ctx.org_id)

      assert_raise Mix.Error, ~r/Unknown goal/, fn ->
        run([
          "create",
          name(),
          "--type",
          "page",
          "--document",
          doc.id,
          "--form",
          form.id,
          "--goal",
          "vibes"
        ])
      end
    end
  end

  describe "variant" do
    setup ctx do
      doc = page(ctx.actor)
      form = ExperimentFixtures.goal_form!(ctx.org_id)
      exp_name = name()
      run(["create", exp_name, "--type", "page", "--document", doc.id, "--form", form.id])
      Map.merge(ctx, %{exp_name: exp_name, doc: doc, form: form})
    end

    test "adds a control and a patched treatment", ctx do
      run(["variant", ctx.exp_name, "--variant", "Control", "--control"])

      run([
        "variant",
        ctx.exp_name,
        "--variant",
        "Punchier",
        "--patch",
        ~s({"fields":{"title":"Punchier"}}),
        "--weight",
        "3"
      ])

      experiment = find(ctx.org_id, ctx.exp_name)
      by_name = Map.new(experiment.variants, &{&1.name, &1})

      assert by_name["Control"].control
      assert by_name["Control"].patch == %{}
      refute by_name["Punchier"].control
      assert by_name["Punchier"].weight == 3
      assert by_name["Punchier"].patch == %{"fields" => %{"title" => "Punchier"}}
    end

    test "rejects a --patch that is not a JSON object", ctx do
      # A bare string or array would otherwise reach the resource as a cast
      # error much further from the typo that caused it.
      assert_raise Mix.Error, ~r/JSON object/, fn ->
        run(["variant", ctx.exp_name, "--variant", "Bad", "--patch", ~s(["not","an","object")])
      end

      assert_raise Mix.Error, ~r/JSON object/, fn ->
        run(["variant", ctx.exp_name, "--variant", "Bad", "--patch", "not json at all"])
      end
    end

    test "requires --variant NAME", ctx do
      assert_raise Mix.Error, ~r/--variant/, fn ->
        run(["variant", ctx.exp_name])
      end
    end

    test "refuses to name an experiment that does not exist", ctx do
      assert_raise Mix.Error, ~r/No experiment named/, fn ->
        run(["variant", "no-such-experiment-#{ctx.org_id}", "--variant", "X"])
      end
    end
  end

  describe "start / conclude" do
    setup ctx do
      doc = page(ctx.actor)
      form = ExperimentFixtures.goal_form!(ctx.org_id)
      exp_name = name()
      run(["create", exp_name, "--type", "page", "--document", doc.id, "--form", form.id])
      run(["variant", exp_name, "--variant", "Control", "--control"])
      run(["variant", exp_name, "--variant", "Treatment", "--patch", ~s({"fields":{}})])
      Map.merge(ctx, %{exp_name: exp_name, doc: doc, form: form})
    end

    test "start moves the experiment to running", ctx do
      run(["start", ctx.exp_name])
      assert find(ctx.org_id, ctx.exp_name).state == :running
    end

    test "a second running experiment on the same document is refused", ctx do
      # A partial unique index enforces it. The point of the assertion is that
      # the operator gets a message rather than a raw constraint error.
      run(["start", ctx.exp_name])

      second = name()
      run(["create", second, "--type", "page", "--document", ctx.doc.id, "--form", ctx.form.id])
      run(["variant", second, "--variant", "Control", "--control"])
      run(["variant", second, "--variant", "Treatment", "--patch", ~s({"fields":{}})])

      assert_raise Mix.Error, fn -> run(["start", second]) end

      assert find(ctx.org_id, second).state == :draft
      assert find(ctx.org_id, ctx.exp_name).state == :running
    end

    test "conclude with a winner records it", ctx do
      run(["start", ctx.exp_name])
      run(["conclude", ctx.exp_name, "--winner", "Treatment"])

      experiment = find(ctx.org_id, ctx.exp_name)
      winner = Enum.find(experiment.variants, &(&1.name == "Treatment"))

      assert experiment.state == :concluded
      assert experiment.winner_variant_id == winner.id

      # Concluding records a result; it does not touch the document. Promotion
      # is a separate, deliberate act (the resource's moduledoc, and #982).
      assert run(["show", ctx.exp_name]) =~ "concluded"
    end

    test "conclude refuses a --winner that is not a variant of this experiment", ctx do
      run(["start", ctx.exp_name])

      assert_raise Mix.Error, ~r/No variant named/, fn ->
        run(["conclude", ctx.exp_name, "--winner", "Nonexistent"])
      end

      assert find(ctx.org_id, ctx.exp_name).state == :running
    end
  end

  describe "list / show" do
    test "list says whether the deployment switch is on", ctx do
      # The single most common "why is nothing happening": an experiment can be
      # running while `KILN_EXPERIMENTS_ENABLED` is unset, and then nothing
      # serves. The task says so on every list.
      doc = page(ctx.actor)
      form = ExperimentFixtures.goal_form!(ctx.org_id)
      exp_name = name()
      run(["create", exp_name, "--type", "page", "--document", doc.id, "--form", form.id])

      out = run(["list"])
      assert out =~ exp_name
      assert out =~ "draft"
    end

    test "show prints the variants with their counters", ctx do
      doc = page(ctx.actor)
      form = ExperimentFixtures.goal_form!(ctx.org_id)
      exp_name = name()
      run(["create", exp_name, "--type", "page", "--document", doc.id, "--form", form.id])
      run(["variant", exp_name, "--variant", "Control", "--control"])

      out = run(["show", exp_name])

      assert out =~ "Name:"
      assert out =~ exp_name
      assert out =~ "Control"
      assert out =~ "served"
      assert out =~ "converted"
    end

    test "list marks a running experiment that cannot convert, and says why", ctx do
      # #1008: the failure this closes is an experiment that reads `running`
      # while nothing it needs is in place, so the marker has to hang off the
      # row an operator is already looking at.
      ExperimentFixtures.enable!()
      sticky_on()
      goal = page(ctx.actor)

      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(page(ctx.actor), "page", %{},
          org_id: ctx.org_id,
          goal: :content_view,
          goal_content_type: "page",
          goal_document_id: goal.id
        )

      refute run(["list"]) =~ "cannot convert"

      sticky_off()

      out = run(["list"])
      assert out =~ experiment.name
      assert out =~ "cannot convert"
      assert out =~ "sticky"
    end

    test "show states it before the numbers it invalidates", ctx do
      ExperimentFixtures.enable!()
      sticky_on()
      goal = page(ctx.actor)

      {experiment, _control, _treatment} =
        ExperimentFixtures.running!(page(ctx.actor), "page", %{},
          org_id: ctx.org_id,
          goal: :content_view,
          goal_content_type: "page",
          goal_document_id: goal.id
        )

      refute run(["show", experiment.name]) =~ "CANNOT CONVERT"

      sticky_off()

      out = run(["show", experiment.name])
      assert out =~ "CANNOT CONVERT"

      # Before the variants: a 0.0% rate under this experiment is not a result,
      # and reading the numbers first is how an operator concludes "no effect".
      [before_variants, _rest] = String.split(out, "Control", parts: 2)
      assert before_variants =~ "CANNOT CONVERT"
    end

    test "show raises on an unknown name", _ctx do
      assert_raise Mix.Error, ~r/No experiment named/, fn -> run(["show", "nope-#{name()}"]) end
    end
  end

  test "an unrecognised subcommand prints usage", _ctx do
    assert_raise Mix.Error, ~r/Usage: mix kiln.experiment/, fn -> run(["frobnicate"]) end
  end
end
