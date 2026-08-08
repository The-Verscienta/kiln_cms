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

  require Ash.Query

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
          document_id: ctx.document_id
        },
        attrs
      ),
      authorize?: false,
      tenant: ctx.org_id
    )
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
      experiment = experiment!(ctx)
      control = ExperimentFixtures.variant!(experiment, "Control", %{}, ctx.org_id, control: true)
      ExperimentFixtures.variant!(experiment, "B", %{}, ctx.org_id, [])

      {:ok, running} =
        Experiments.start_experiment(experiment, authorize?: false, tenant: ctx.org_id)

      KilnCMS.Cache.bust_experiments(ctx.org_id)

      %{experiment: running, control: control}
    end

    defp variant_days(org_id),
      do: Ash.read!(KilnCMS.Experiments.VariantDay, authorize?: false, tenant: org_id)

    test "counts a variant of a running experiment", ctx do
      KilnCMS.Experiments.Delivery.record_conversion(ctx.control.id, ctx.org_id)

      assert [day] = variant_days(ctx.org_id)
      assert day.variant_id == ctx.control.id
      assert day.conversions == 1
    end

    # There is no foreign key on `variant_id`, so without the check every
    # distinct uuid an attacker posts would mint a row.
    test "ignores an unknown variant id", ctx do
      KilnCMS.Experiments.Delivery.record_conversion(Ash.UUID.generate(), ctx.org_id)

      assert [] = variant_days(ctx.org_id)
    end

    test "ignores a variant that belongs to another site", ctx do
      other =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "other",
          slug: "other-#{System.unique_integer([:positive])}",
          status: :active
        })

      KilnCMS.Experiments.Delivery.record_conversion(ctx.control.id, other.id)

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

      KilnCMS.Experiments.Delivery.record_conversion(ctx.control.id, ctx.org_id)

      assert [] = variant_days(ctx.org_id)
    end

    test "ignores a blank or missing field", ctx do
      KilnCMS.Experiments.Delivery.record_conversion(nil, ctx.org_id)
      KilnCMS.Experiments.Delivery.record_conversion("", ctx.org_id)

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
end
