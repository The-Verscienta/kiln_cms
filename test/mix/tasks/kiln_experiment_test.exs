defmodule Mix.Tasks.Kiln.ExperimentTest do
  @moduledoc """
  `mix kiln.experiment` (#499 phase 1, coverage gap #985).

  Until `/editor/experiments` lands this task is the **only** way to operate the
  engine, so a break here makes the feature inert in exactly the phase where it
  is the whole interface. It also carries real logic of its own — required
  options, the refused `content_view` goal, and the state-machine calls — none
  of which is exercised anywhere else.

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

    test "refuses --goal content_view and says where it went", ctx do
      doc = page(ctx.actor)
      form = ExperimentFixtures.goal_form!(ctx.org_id)

      # Phase 1 constrains `Experiment.goal` to `[:form_submission]`, so this
      # would fail anyway — but as a cast error naming an enum, which tells an
      # operator nothing. The task refuses it with the reason: attributing a
      # view on a LATER page needs a stable visitor key the built-in site does
      # not have (#984).
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
            "content_view"
          ])
        end

      assert Exception.message(error) =~ "phase 3"
      assert Exception.message(error) =~ "visitor key"
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

    test "show raises on an unknown name", _ctx do
      assert_raise Mix.Error, ~r/No experiment named/, fn -> run(["show", "nope-#{name()}"]) end
    end
  end

  test "an unrecognised subcommand prints usage", _ctx do
    assert_raise Mix.Error, ~r/Usage: mix kiln.experiment/, fn -> run(["frobnicate"]) end
  end
end
