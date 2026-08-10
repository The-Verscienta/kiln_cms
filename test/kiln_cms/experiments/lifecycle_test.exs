defmodule KilnCMS.Experiments.LifecycleTest do
  @moduledoc """
  The experiment lifecycle, its guards, and conversion counting (#499).

  The `:start` guards carry the weight here: every one of them protects against
  something that is **not recoverable once visitors are in the experiment**. A
  test with one arm, or no control, or overlapping another test on the same
  document, produces numbers that cannot be interpreted afterwards — and nobody
  finds out until they try to read the result.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.ExperimentFixtures
  alias KilnCMS.Experiments

  setup do
    org_id = KilnCMS.Accounts.default_org_id()
    %{org_id: org_id, actor: admin(), document_id: Ash.UUID.generate()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "lc-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp experiment!(ctx, attrs \\ %{}) do
    Experiments.create_experiment!(
      Map.merge(
        %{
          name: "exp-#{System.unique_integer([:positive])}",
          content_type: "page",
          document_id: ctx.document_id,
          # `:start` requires one, so every fixture here carries one; the tests
          # that care about the goal override it.
          goal_form_id: ExperimentFixtures.goal_form!(ctx.org_id).id
        },
        attrs
      ),
      authorize?: false,
      tenant: ctx.org_id
    )
  end

  # A form-submission experiment with no goal form converts nothing, so `:start`
  # refuses it rather than letting someone read 0.0% forever.
  defp assert_start_refused(experiment, ctx, message) do
    assert {:error, error} =
             Experiments.start_experiment(experiment, authorize?: false, tenant: ctx.org_id)

    assert Exception.message(error) =~ message
  end

  describe "starting" do
    test "a well-formed experiment starts", ctx do
      experiment = experiment!(ctx)
      ExperimentFixtures.variant!(experiment, "Control", %{}, ctx.org_id, control: true)
      ExperimentFixtures.variant!(experiment, "B", %{}, ctx.org_id, [])

      assert {:ok, started} =
               Experiments.start_experiment(experiment, authorize?: false, tenant: ctx.org_id)

      assert started.state == :running
      assert started.started_at
    end

    # One arm is not a test.
    test "refuses fewer than two variants", ctx do
      experiment = experiment!(ctx)
      ExperimentFixtures.variant!(experiment, "Only", %{}, ctx.org_id, control: true)

      assert {:error, error} =
               Experiments.start_experiment(experiment, authorize?: false, tenant: ctx.org_id)

      assert Exception.message(error) =~ "at least two variants"
    end

    # Nothing about a goal-less experiment looks broken from outside: traffic
    # splits, the page loses its shared cache, impressions pile up on every arm,
    # and the conversion column reads 0.0% forever.
    test "refuses a form-submission goal with no goal form", ctx do
      experiment = experiment!(ctx, %{goal_form_id: nil})
      ExperimentFixtures.variant!(experiment, "Control", %{}, ctx.org_id, control: true)
      ExperimentFixtures.variant!(experiment, "B", %{}, ctx.org_id, [])

      assert_start_refused(experiment, ctx, "needs a goal form")
    end

    # An experiment that serves no arm at all still shows as running.
    test "refuses weights that sum to zero", ctx do
      experiment = experiment!(ctx)

      ExperimentFixtures.variant!(experiment, "Control", %{}, ctx.org_id,
        control: true,
        weight: 0
      )

      ExperimentFixtures.variant!(experiment, "B", %{}, ctx.org_id, weight: 0)

      assert_start_refused(experiment, ctx, "weights sum to zero")
    end

    # Without a baseline, "the control won" is not something the data can say.
    test "refuses no control", ctx do
      experiment = experiment!(ctx)
      ExperimentFixtures.variant!(experiment, "A", %{}, ctx.org_id, [])
      ExperimentFixtures.variant!(experiment, "B", %{}, ctx.org_id, [])

      assert {:error, error} =
               Experiments.start_experiment(experiment, authorize?: false, tenant: ctx.org_id)

      assert Exception.message(error) =~ "exactly one control"
    end

    test "refuses two controls", ctx do
      experiment = experiment!(ctx)
      ExperimentFixtures.variant!(experiment, "A", %{}, ctx.org_id, control: true)
      ExperimentFixtures.variant!(experiment, "B", %{}, ctx.org_id, control: true)

      assert {:error, error} =
               Experiments.start_experiment(experiment, authorize?: false, tenant: ctx.org_id)

      assert Exception.message(error) =~ "exactly one control"
    end

    # Two overlapping patches make BOTH results uninterpretable — you cannot
    # tell which change moved the number.
    test "refuses a second experiment on the same document", ctx do
      first = experiment!(ctx)
      ExperimentFixtures.variant!(first, "Control", %{}, ctx.org_id, control: true)
      ExperimentFixtures.variant!(first, "B", %{}, ctx.org_id, [])
      {:ok, _running} = Experiments.start_experiment(first, authorize?: false, tenant: ctx.org_id)

      second = experiment!(ctx)
      ExperimentFixtures.variant!(second, "Control", %{}, ctx.org_id, control: true)
      ExperimentFixtures.variant!(second, "B", %{}, ctx.org_id, [])

      assert {:error, error} =
               Experiments.start_experiment(second, authorize?: false, tenant: ctx.org_id)

      assert Exception.message(error) =~ "already running on this document"
    end

    test "allows a new experiment once the previous one concluded", ctx do
      first = experiment!(ctx)
      ExperimentFixtures.variant!(first, "Control", %{}, ctx.org_id, control: true)
      ExperimentFixtures.variant!(first, "B", %{}, ctx.org_id, [])
      {:ok, running} = Experiments.start_experiment(first, authorize?: false, tenant: ctx.org_id)

      {:ok, _done} =
        Experiments.conclude_experiment(running, nil, authorize?: false, tenant: ctx.org_id)

      second = experiment!(ctx)
      ExperimentFixtures.variant!(second, "Control", %{}, ctx.org_id, control: true)
      ExperimentFixtures.variant!(second, "B", %{}, ctx.org_id, [])

      assert {:ok, _started} =
               Experiments.start_experiment(second, authorize?: false, tenant: ctx.org_id)
    end
  end

  describe "editing" do
    # Changing the split or a patch mid-flight silently invalidates every result
    # gathered so far, and nothing afterwards says so.
    test "a running experiment cannot be edited", ctx do
      experiment = experiment!(ctx)
      ExperimentFixtures.variant!(experiment, "Control", %{}, ctx.org_id, control: true)
      ExperimentFixtures.variant!(experiment, "B", %{}, ctx.org_id, [])

      {:ok, running} =
        Experiments.start_experiment(experiment, authorize?: false, tenant: ctx.org_id)

      assert {:error, error} =
               Ash.update(running, %{name: "renamed"}, authorize?: false, tenant: ctx.org_id)

      assert Exception.message(error) =~ "only a draft"
    end
  end

  describe "concluding" do
    setup ctx do
      experiment = experiment!(ctx)
      control = ExperimentFixtures.variant!(experiment, "Control", %{}, ctx.org_id, control: true)
      treatment = ExperimentFixtures.variant!(experiment, "B", %{}, ctx.org_id, [])

      {:ok, running} =
        Experiments.start_experiment(experiment, authorize?: false, tenant: ctx.org_id)

      %{experiment: running, control: control, treatment: treatment}
    end

    test "records the winner", ctx do
      assert {:ok, concluded} =
               Experiments.conclude_experiment(ctx.experiment, ctx.treatment.id,
                 authorize?: false,
                 tenant: ctx.org_id
               )

      assert concluded.state == :concluded
      assert concluded.winner_variant_id == ctx.treatment.id
      assert concluded.concluded_at
    end

    # A test whose answer was "no difference" is a legitimate outcome, and the
    # common one.
    test "may conclude with no winner", ctx do
      assert {:ok, concluded} =
               Experiments.conclude_experiment(ctx.experiment, nil,
                 authorize?: false,
                 tenant: ctx.org_id
               )

      assert concluded.state == :concluded
      refute concluded.winner_variant_id
    end

    test "emits experiment.concluded through the shared event funnel", ctx do
      endpoint =
        CMS.create_webhook_endpoint!(
          %{
            url: "https://receiver.test/hook",
            events: ["experiment.concluded"],
            active: true
          },
          authorize?: false,
          tenant: ctx.org_id
        )

      {:ok, _concluded} =
        Experiments.conclude_experiment(ctx.experiment, ctx.treatment.id,
          authorize?: false,
          tenant: ctx.org_id
        )

      deliveries = Ash.read!(CMS.WebhookDelivery, authorize?: false, tenant: ctx.org_id)

      assert [delivery] = Enum.filter(deliveries, &(&1.endpoint_id == endpoint.id))
      assert delivery.event == "experiment.concluded"
      # The automation dispatcher dedupes on `id`, so the payload must carry one.
      assert delivery.payload["id"] == ctx.experiment.id
      assert delivery.payload["winner_variant_id"] == ctx.treatment.id
    end
  end

  describe "counters" do
    setup ctx do
      experiment = experiment!(ctx)
      variant = ExperimentFixtures.variant!(experiment, "Control", %{}, ctx.org_id, control: true)
      %{variant: variant}
    end

    test "impressions and conversions accumulate on one row per day", ctx do
      for _ <- 1..3 do
        Experiments.record_impression!(ctx.variant.id, authorize?: false, tenant: ctx.org_id)
      end

      Experiments.record_conversion!(ctx.variant.id, authorize?: false, tenant: ctx.org_id)

      assert [day] =
               Ash.read!(KilnCMS.Experiments.VariantDay, authorize?: false, tenant: ctx.org_id)

      assert day.impressions == 3
      assert day.conversions == 1
      assert day.day == Date.utc_today()
    end
  end

  # The variant id arrives on a public, CSRF-free form POST, so it is
  # attacker-controlled and every one of these would otherwise be accepted.
  describe "conversion attribution refuses an id it did not serve" do
    setup ctx do
      # The deployment switch gates conversion counting too, not just serving.
      ExperimentFixtures.enable!()
      form = ExperimentFixtures.goal_form!(ctx.org_id)
      experiment = experiment!(ctx, %{goal_form_id: form.id})
      control = ExperimentFixtures.variant!(experiment, "Control", %{}, ctx.org_id, control: true)
      ExperimentFixtures.variant!(experiment, "B", %{}, ctx.org_id, [])

      {:ok, running} =
        Experiments.start_experiment(experiment, authorize?: false, tenant: ctx.org_id)

      KilnCMS.Cache.bust_experiments(ctx.org_id)

      %{experiment: running, control: control, form: form}
    end

    defp convert(variant_id, ctx), do: convert(variant_id, ctx, ctx.form.id)

    defp convert(variant_id, ctx, form_id),
      do: KilnCMS.Experiments.Delivery.record_conversion(variant_id, ctx.org_id, form_id: form_id)

    defp variant_days(org_id),
      do: Ash.read!(KilnCMS.Experiments.VariantDay, authorize?: false, tenant: org_id)

    test "counts a variant of a running experiment on its goal form", ctx do
      convert(ctx.control.id, ctx)

      assert [day] = variant_days(ctx.org_id)
      assert day.variant_id == ctx.control.id
      assert day.conversions == 1
    end

    # There is no foreign key on `variant_id`, so without the check every
    # distinct uuid an attacker posts would mint a row.
    test "ignores an unknown variant id", ctx do
      convert(Ash.UUID.generate(), ctx)

      assert [] = variant_days(ctx.org_id)
    end

    # Otherwise every form on the site converts every arm: read a treatment id
    # off any page's hidden field, post it with an unrelated newsletter form,
    # and pick the winner.
    test "ignores a submission of a form that is not the goal", ctx do
      other = ExperimentFixtures.goal_form!(ctx.org_id)

      convert(ctx.control.id, ctx, other.id)

      assert [] = variant_days(ctx.org_id)
    end

    test "ignores a variant that belongs to another site", ctx do
      other =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "other",
          slug: "other-#{System.unique_integer([:positive])}",
          status: :active
        })

      KilnCMS.Experiments.Delivery.record_conversion(ctx.control.id, other.id,
        form_id: ctx.form.id
      )

      assert [] = variant_days(other.id)
    end

    # A concluded experiment stops serving, so it must stop counting too —
    # otherwise a stale page left open in a tab keeps moving the result after
    # someone read it and decided.
    test "ignores a variant whose experiment has concluded", ctx do
      {:ok, _done} =
        Experiments.conclude_experiment(ctx.experiment, nil,
          authorize?: false,
          tenant: ctx.org_id
        )

      convert(ctx.control.id, ctx)

      assert [] = variant_days(ctx.org_id)
    end

    test "ignores a blank or missing field", ctx do
      convert(nil, ctx)
      convert("", ctx)

      assert [] = variant_days(ctx.org_id)
    end

    # The switch is documented as "whether this deployment serves experiments at
    # all", and a public form POST carrying a stale variant id is the other way
    # in — so it has to gate counting as well as serving.
    test "counts nothing when the deployment switch is off", ctx do
      original = Application.get_env(:kiln_cms, KilnCMS.Experiments, [])
      Application.put_env(:kiln_cms, KilnCMS.Experiments, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Experiments, original) end)

      convert(ctx.control.id, ctx)

      assert [] = variant_days(ctx.org_id)
    end
  end

  describe "the patch allowlist" do
    setup ctx, do: %{experiment: experiment!(ctx)}

    test "accepts a patchable field", ctx do
      assert {:ok, _variant} =
               Experiments.create_variant(
                 %{
                   experiment_id: ctx.experiment.id,
                   name: "B",
                   patch: %{"fields" => %{"title" => "New"}}
                 },
                 authorize?: false,
                 tenant: ctx.org_id
               )
    end

    # A patch that could set `slug` would move the page under the visitor; one
    # that could set `state` would publish from a copy-editing form.
    for field <- ~w(slug state audience seo_title) do
      test "refuses #{field}", ctx do
        assert {:error, error} =
                 Experiments.create_variant(
                   %{
                     experiment_id: ctx.experiment.id,
                     name: "B-#{unquote(field)}",
                     patch: %{"fields" => %{unquote(field) => "x"}}
                   },
                   authorize?: false,
                   tenant: ctx.org_id
                 )

        assert Exception.message(error) =~ "may not be varied"
      end
    end

    test "refuses an unknown top-level key", ctx do
      assert {:error, error} =
               Experiments.create_variant(
                 %{experiment_id: ctx.experiment.id, name: "B", patch: %{"whatever" => %{}}},
                 authorize?: false,
                 tenant: ctx.org_id
               )

      assert Exception.message(error) =~ "unknown patch key"
    end

    test "refuses a block key that is not a block id", ctx do
      assert {:error, error} =
               Experiments.create_variant(
                 %{
                   experiment_id: ctx.experiment.id,
                   name: "B",
                   patch: %{"blocks" => %{"first" => %{"text" => "x"}}}
                 },
                 authorize?: false,
                 tenant: ctx.org_id
               )

      assert Exception.message(error) =~ "must be block ids"
    end
  end

  describe "running read order (#1118)" do
    test "returns experiments in inserted_at ascending order", ctx do
      # Two documents so both can be :running at once (partial unique index).
      earlier =
        experiment!(ctx, %{
          name: "earlier-#{System.unique_integer([:positive])}",
          document_id: Ash.UUID.generate()
        })

      ExperimentFixtures.variant!(earlier, "Control", %{}, ctx.org_id, control: true)
      ExperimentFixtures.variant!(earlier, "B", %{}, ctx.org_id, [])
      {:ok, earlier} =
        Experiments.start_experiment(earlier, authorize?: false, tenant: ctx.org_id)

      # Force a later inserted_at on the second row so the assertion is not
      # relying on wall-clock coincidence under a fast suite.
      later =
        experiment!(ctx, %{
          name: "later-#{System.unique_integer([:positive])}",
          document_id: Ash.UUID.generate()
        })

      ExperimentFixtures.variant!(later, "Control", %{}, ctx.org_id, control: true)
      ExperimentFixtures.variant!(later, "B", %{}, ctx.org_id, [])
      {:ok, later} = Experiments.start_experiment(later, authorize?: false, tenant: ctx.org_id)

      # Bump the second row's inserted_at past the first; create timestamps can
      # land in the same microsecond on a warm CI runner.
      later
      |> Ecto.Changeset.change(inserted_at: DateTime.add(earlier.inserted_at, 1, :second))
      |> KilnCMS.Repo.update!()

      Experiments.bust(ctx.org_id)

      ids = ctx.org_id |> Experiments.running() |> Enum.map(& &1.id)
      earlier_idx = Enum.find_index(ids, &(&1 == earlier.id))
      later_idx = Enum.find_index(ids, &(&1 == later.id))

      assert earlier_idx < later_idx
    end
  end
end
