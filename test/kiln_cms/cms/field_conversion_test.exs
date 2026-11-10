defmodule KilnCMS.CMS.FieldConversionTest do
  @moduledoc """
  `mix kiln.fields.convert` (`KilnCMS.CMS.FieldConversion`): JSON-in-text
  values moved into a `:group` field — each input shape, prose and bad
  sub-field values reported with their paths, `--map`, all-or-nothing unless
  `--skip-invalid`, idempotence, and a dry run that writes nothing.
  """
  use KilnCMS.DataCase, async: true

  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureIO

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldConversion
  alias KilnCMS.CMS.WorkingCopy

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "convert-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "convert-#{System.unique_integer([:positive])}"

  defp field!(admin, attrs),
    do: CMS.create_field_definition!(Map.put_new(attrs, :content_type, :post), actor: admin)

  defp post!(%{admin: admin, source: source}, value) do
    CMS.create_post!(%{title: "Herb", slug: slug(), custom_fields: %{source => value}},
      actor: admin
    )
  end

  defp reload(post), do: CMS.get_post!(post.id, authorize?: false)

  defp convert(ctx, opts \\ []) do
    {:ok, report} =
      FieldConversion.run(KilnCMS.Accounts.default_org_id(), "post", ctx.source, ctx.group, opts)

    report
  end

  setup do
    admin = user(:admin)
    n = System.unique_integer([:positive])

    source =
      field!(admin, %{name: "dosages_json_#{n}", label: "Dosages (old)", field_type: :text})

    group =
      field!(admin, %{name: "dosages_#{n}", label: "Dosages", field_type: :group, multiple: true})

    sub = &field!(admin, Map.merge(%{group_of_id: group.id, content_type: nil}, &1))
    sub.(%{name: "amount", label: "Amount", field_type: :float})

    sub.(%{
      name: "unit",
      label: "Unit",
      field_type: :select,
      options: ["g", "ml"],
      required: true,
      position: 1
    })

    %{admin: admin, source: source.name, group: group.name}
  end

  describe "parse/1" do
    test "accepts an array, one object, and either encoded twice" do
      assert FieldConversion.parse(~s([{"a":1},{"a":2}])) == {:ok, [%{"a" => 1}, %{"a" => 2}]}
      assert FieldConversion.parse(~s({"a":1})) == {:ok, [%{"a" => 1}]}
      assert FieldConversion.parse(Jason.encode!(~s([{"a":1}]))) == {:ok, [%{"a" => 1}]}

      assert FieldConversion.parse(Jason.encode!(Jason.encode!(~s({"a":1})))) ==
               {:ok, [%{"a" => 1}]}

      assert FieldConversion.parse([%{"a" => 1}]) == {:ok, [%{"a" => 1}]}
    end

    test "blank, null and empty containers are empty" do
      for value <- [nil, "", "  ", "null", "[]", "{}", ~s(""), [], %{}],
          do: assert(FieldConversion.parse(value) == :empty, inspect(value))
    end

    test "prose and bare scalars are refused, saying what they are" do
      assert {:error, "is not JSON: \"Take 2 g twice daily\""} =
               FieldConversion.parse("Take 2 g twice daily")

      assert {:error, "is JSON 42, not an object or a list of objects"} =
               FieldConversion.parse("42")

      assert {:error, "is not JSON: " <> _} = FieldConversion.parse(Jason.encode!("prose"))
    end
  end

  describe "a run" do
    setup ctx do
      posts = %{
        array: post!(ctx, ~s([{"amount": 2, "unit": "g"}, {"amount": "5", "unit": "ml"}])),
        object: post!(ctx, ~s({"amount": 1.5, "unit": "g"})),
        twice: post!(ctx, Jason.encode!(~s([{"amount": 3, "unit": "ml"}]))),
        empty: post!(ctx, ""),
        prose: post!(ctx, "Take 2 g twice daily with food"),
        bad: post!(ctx, ~s([{"amount": 1, "unit": "g"}, {"amount": 2, "unit": "tsp"}]))
      }

      %{posts: posts}
    end

    test "a dry run reports every record and writes nothing", %{posts: posts} = ctx do
      report = convert(ctx)

      assert %{dry_run?: true, scanned: 6, convertible: 3, written: 0, empty: 1, kept: 0} = report

      assert [
               %{id: prose_id, kind: :unparseable, messages: ["is not JSON: " <> _]},
               %{id: bad_id, kind: :invalid, messages: [bad]}
             ] = Enum.sort_by(report.problems, &(&1.kind != :unparseable))

      assert prose_id == posts.prose.id
      assert bad_id == posts.bad.id
      assert bad =~ "Unit (#{ctx.group}[1].unit) is not one of the allowed options"

      for {_name, post} <- posts, do: assert(reload(post).custom_fields[ctx.group] == nil)
    end

    test "--apply writes nothing while any record is invalid", %{posts: posts} = ctx do
      report = convert(ctx, dry_run?: false)

      assert report.blocked?
      assert report.written == 0
      for {_name, post} <- posts, do: assert(reload(post).custom_fields[ctx.group] == nil)
      assert FieldConversion.describe(report) =~ "nothing written"
    end

    test "--skip-invalid writes the valid records; the rest keep their string",
         %{posts: posts} = ctx do
      before = reload(posts.array)
      report = convert(ctx, dry_run?: false, skip_invalid?: true)

      assert %{written: 3, convertible: 3, empty: 1, blocked?: false} = report
      assert length(report.problems) == 2

      array = reload(posts.array)

      assert array.custom_fields[ctx.group] == [
               %{"amount" => 2.0, "unit" => "g"},
               %{"amount" => 5.0, "unit" => "ml"}
             ]

      # The source is untouched, and this is a backfill, not an edit.
      assert array.custom_fields[ctx.source] == before.custom_fields[ctx.source]
      assert array.updated_at == before.updated_at
      assert array.lock_version == before.lock_version

      assert reload(posts.object).custom_fields[ctx.group] == [%{"amount" => 1.5, "unit" => "g"}]
      assert reload(posts.twice).custom_fields[ctx.group] == [%{"amount" => 3.0, "unit" => "ml"}]
      assert reload(posts.prose).custom_fields[ctx.group] == nil
      assert reload(posts.bad).custom_fields[ctx.group] == nil
      assert reload(posts.prose).custom_fields[ctx.source] =~ "twice daily"

      # Re-running skips what is converted; --overwrite rewrites it.
      again = convert(ctx, dry_run?: false, skip_invalid?: true)
      assert %{kept: 3, written: 0} = again

      assert %{written: 3, kept: 0} =
               convert(ctx, dry_run?: false, skip_invalid?: true, overwrite?: true)
    end
  end

  test "--map renames keys before coercion", ctx do
    post = post!(ctx, ~s([{"dose": 2, "units": "g"}]))

    assert %{problems: [%{messages: messages}]} = convert(ctx)

    assert Enum.find(messages, &(&1 =~ ".dose)")) =~
             "Dosages (#{ctx.group}[0].dose) is not a sub-field"

    report =
      convert(ctx, dry_run?: false, renames: %{"dose" => "amount", "units" => "unit"})

    assert report.written == 1
    assert reload(post).custom_fields[ctx.group] == [%{"amount" => 2.0, "unit" => "g"}]
  end

  test "a group holding one row refuses a list of several rather than keep the first", ctx do
    single =
      field!(ctx.admin, %{
        name: "dose_#{System.unique_integer([:positive])}",
        label: "Dose",
        field_type: :group
      })

    field!(ctx.admin, %{
      group_of_id: single.id,
      content_type: nil,
      name: "unit",
      label: "Unit",
      field_type: :string
    })

    post!(ctx, ~s([{"unit": "g"}, {"unit": "ml"}]))
    one = post!(ctx, ~s([{"unit": "g"}]))

    {:ok, report} =
      FieldConversion.run(KilnCMS.Accounts.default_org_id(), "post", ctx.source, single.name,
        dry_run?: false,
        skip_invalid?: true
      )

    assert [%{kind: :unparseable, messages: [message]}] = report.problems
    assert message =~ "holds 2 rows, but Dose"
    assert reload(one).custom_fields[single.name] == %{"unit" => "g"}
  end

  test "the fields must fit before any record is read", ctx do
    org = KilnCMS.Accounts.default_org_id()

    assert {:error, "No content type " <> _} =
             FieldConversion.run(org, "nope", ctx.source, ctx.group)

    assert {:error, "No field \"nope\"" <> _} =
             FieldConversion.run(org, "post", "nope", ctx.group)

    assert {:error, "No field \"nope\"" <> rest} =
             FieldConversion.run(org, "post", ctx.source, "nope")

    assert rest =~ "create the group and its sub-fields first"

    assert {:error, message} = FieldConversion.run(org, "post", ctx.group, ctx.source)
    assert message =~ "already a group"

    assert {:error, message} =
             FieldConversion.run(org, "post", ctx.source, ctx.group, renames: %{"a" => "nope"})

    assert message =~ "not a sub-field"
  end

  describe "a published record" do
    setup ctx do
      post = post!(ctx, ~s([{"amount": 2, "unit": "g"}]))
      CMS.publish_post!(post, %{}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()
      %{post: reload(post)}
    end

    test "re-fires, sends no webhook, and keeps lock_version", %{post: post} = ctx do
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: ctx.admin)

      assert %{written: 1} = convert(ctx, dry_run?: false)

      assert_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => post.id})
      refute_enqueued(worker: KilnCMS.Webhooks.DeliveryWorker)

      converted = reload(post)
      assert converted.lock_version == post.lock_version
      assert converted.custom_fields[ctx.group] == [%{"amount" => 2.0, "unit" => "g"}]

      # Where an editor's save of the same record would have sent one.
      CMS.update_post!(converted, %{title: "Edited"}, actor: ctx.admin)
      assert_enqueued(worker: KilnCMS.Webhooks.DeliveryWorker)
    end

    test "a pending working copy gets its own held value converted", %{post: post} = ctx do
      held = %{"custom_fields" => %{ctx.source => ~s([{"amount": 9, "unit": "ml"}])}}

      {:ok, saved} =
        CMS.save_post_working_copy(post, %{fields: held}, actor: ctx.admin, tenant: post.org_id)

      assert WorkingCopy.pending?(saved)

      assert %{written: 1} = convert(ctx, dry_run?: false)

      converted = reload(post)
      assert converted.custom_fields[ctx.group] == [%{"amount" => 2.0, "unit" => "g"}]
      assert WorkingCopy.reconcile(converted).conflicts == []

      {:ok, published} = CMS.publish_post_changes(converted, %{}, actor: ctx.admin)
      assert published.custom_fields[ctx.group] == [%{"amount" => 9.0, "unit" => "ml"}]
    end

    test "an unparseable held value is reported as the working copy's", %{post: post} = ctx do
      held = %{"custom_fields" => %{ctx.source => "Nine ml, as needed"}}

      {:ok, _saved} =
        CMS.save_post_working_copy(post, %{fields: held}, actor: ctx.admin, tenant: post.org_id)

      assert %{problems: [%{kind: :unparseable, messages: ["(working copy) is not JSON" <> _]}]} =
               convert(ctx)
    end

    test "the action's system grant is :field_conversion's alone", %{post: post} = ctx do
      write = fn actor ->
        post
        |> Ash.Changeset.for_update(:convert_custom_field, %{},
          actor: actor,
          context: %{convert_custom_field: %{name: ctx.group, live: [%{"unit" => "g"}]}}
        )
        |> Ash.update()
      end

      assert {:error, %Ash.Error.Forbidden{}} = write.(nil)
      assert {:error, %Ash.Error.Forbidden{}} = write.(KilnCMS.SystemActor.new(:media))
      assert {:ok, _post} = write.(KilnCMS.SystemActor.new(:field_conversion))
    end
  end

  # A contract step must reach the trash too (#2533): the source field is
  # dropped a release later, and a record restored after that would come back
  # holding only the string.
  describe "a trashed record" do
    setup ctx do
      post = post!(ctx, ~s([{"amount": 2, "unit": "g"}]))
      CMS.publish_post!(post, %{}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()
      :ok = CMS.destroy_post!(reload(post), actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()
      %{post: trashed(post)}
    end

    defp trashed(post) do
      CMS.list_trashed_posts!(authorize?: false, tenant: post.org_id)
      |> Enum.find(&(&1.id == post.id))
    end

    defp convert_changeset(record, ctx, rows) do
      Ash.Changeset.for_update(record, :convert_custom_field, %{},
        actor: KilnCMS.SystemActor.resolve(:field_conversion),
        tenant: record.org_id,
        context: %{convert_custom_field: %{name: ctx.group, live: rows}}
      )
    end

    test "is converted without a fire, and a restore brings the group back",
         %{post: post} = ctx do
      dry = convert(ctx)
      assert %{convertible: 1, published: 0, trashed: 1} = dry
      assert FieldConversion.describe(dry) =~ "would convert 1 (0 published, 1 trashed)"

      assert %{written: 1, published: 0, trashed: 1, problems: []} =
               convert(ctx, dry_run?: false)

      # Its artifacts were purged when it was trashed; a fire would put them back.
      refute_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => post.id})

      converted = trashed(post)
      assert converted.custom_fields[ctx.group] == [%{"amount" => 2.0, "unit" => "g"}]
      assert converted.lock_version == post.lock_version
      assert converted.updated_at == post.updated_at

      restored = CMS.restore_post!(converted, actor: ctx.admin)
      assert reload(restored).custom_fields[ctx.group] == [%{"amount" => 2.0, "unit" => "g"}]

      # A second run finds it converted.
      assert %{kept: 1, written: 0} = convert(ctx, dry_run?: false)
    end

    test "that does not fit is reported as trashed and does not block --apply", ctx do
      prose = post!(ctx, "Two grams, as needed")
      :ok = CMS.destroy_post!(prose, actor: ctx.admin)
      live = post!(ctx, ~s({"amount": 1, "unit": "ml"}))

      report = convert(ctx, dry_run?: false)

      refute report.blocked?
      assert %{written: 2, trashed: 1} = report
      assert [%{id: id, kind: :unparseable, trashed?: true}] = report.problems
      assert id == prose.id
      assert FieldConversion.blocking(report) == []
      assert reload(live).custom_fields[ctx.group] == [%{"amount" => 1.0, "unit" => "ml"}]
      assert trashed(prose).custom_fields[ctx.source] == "Two grams, as needed"

      described = FieldConversion.describe(report)
      assert described =~ "#{prose.id} (#{prose.slug}) (trashed) — unparseable:"
      assert described =~ "1 trashed record(s) keep their string"
    end

    test "a live record that does not fit still blocks, and the count is the live ones'", ctx do
      trashed_prose = post!(ctx, "Two grams")
      :ok = CMS.destroy_post!(trashed_prose, actor: ctx.admin)
      _live_prose = post!(ctx, "Three grams")

      report = convert(ctx, dry_run?: false)

      assert report.blocked?
      assert report.written == 0
      assert length(report.problems) == 2
      assert [%{trashed?: false}] = FieldConversion.blocking(report)
      assert FieldConversion.describe(report) =~ "nothing written: 1 invalid"
      assert trashed(trashed_prose).custom_fields[ctx.group] == nil
    end

    # The race the fire gate is for: a trash and a restore bump no
    # `lock_version`, so the struct read in the trashed pass still writes
    # after a restore. The write must fire then: the restore's own fire may
    # have delivered the shape from before the conversion.
    test "restored between the read and the write is fired", %{post: post} = ctx do
      changeset = convert_changeset(post, ctx, [%{"amount" => 4, "unit" => "g"}])
      assert changeset.data.archived_at

      CMS.restore_post!(post, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()
      refute_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => post.id})

      assert {:ok, %{archived_at: nil}} = Ash.update(changeset)

      assert_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => post.id})
      assert reload(post).custom_fields[ctx.group] == [%{"amount" => 4.0, "unit" => "g"}]
    end

    test "a live struct whose row is trashed before the write is written and not fired", ctx do
      post = post!(ctx, ~s([{"amount": 2, "unit": "g"}]))
      live = CMS.publish_post!(post, %{}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()
      live = reload(live)

      changeset = convert_changeset(live, ctx, [%{"amount" => 6, "unit" => "ml"}])
      :ok = CMS.destroy_post!(live, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()

      assert {:ok, %{archived_at: %DateTime{}}} = Ash.update(changeset)

      refute_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => live.id})
      assert trashed(live).custom_fields[ctx.group] == [%{"amount" => 6.0, "unit" => "ml"}]
    end

    test "an ordinary update of it is still refused", %{post: post} = ctx do
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{} | _]}} =
               CMS.update_post(post, %{title: "After the trash"}, actor: ctx.admin)
    end

    test "of a dynamic type is converted too", ctx do
      type =
        CMS.create_type_definition!(
          %{name: "remedy#{System.unique_integer([:positive])}", label: "Remedy"},
          actor: ctx.admin
        )

      field =
        &CMS.create_field_definition!(Map.put(&1, :type_definition_id, type.id),
          actor: ctx.admin
        )

      field.(%{name: "uses_json", label: "Uses (old)", field_type: :text})
      field.(%{name: "uses", label: "Uses", field_type: :string, multiple: true})

      entry =
        CMS.create_entry!(
          %{
            type_definition_id: type.id,
            title: "Remedy",
            slug: slug(),
            custom_fields: %{"uses_json" => ~s(["sleep", "calm"])}
          },
          actor: ctx.admin
        )

      :ok = CMS.destroy_entry!(entry, actor: ctx.admin)

      assert {:ok, %{written: 1, trashed: 1}} =
               FieldConversion.run(entry.org_id, type.name, "uses_json", "uses",
                 dry_run?: false,
                 batch: 1
               )

      [converted] =
        CMS.list_trashed_entries!(authorize?: false, tenant: entry.org_id)
        |> Enum.filter(&(&1.id == entry.id))

      assert converted.custom_fields["uses"] == ["sleep", "calm"]
    end
  end

  describe "the release entry point" do
    defp release(ctx, opts, serving? \\ true) do
      test = self()

      out =
        capture_io(fn ->
          send(
            test,
            {:result,
             KilnCMS.Release.run_conversion("post", ctx.source, ctx.group, opts, serving?)}
          )
        end)

      assert_received {:result, result}
      {result, out}
    end

    test "takes the task's flags as options and prints its report", ctx do
      post = post!(ctx, ~s([{"dose": 2, "unit": "g"}]))

      {{:ok, dry}, out} = release(ctx, map: %{"dose" => "amount"})
      assert dry.convertible == 1
      assert out =~ "would convert 1"
      assert reload(post).custom_fields[ctx.group] == nil

      {{:ok, applied}, _out} = release(ctx, map: %{"dose" => "amount"}, apply: true)
      assert applied.written == 1
      assert reload(post).custom_fields[ctx.group] == [%{"amount" => 2.0, "unit" => "g"}]
    end

    test "refuses outside a running node, and an unknown org", ctx do
      assert {{:error, message}, out} = release(ctx, [], false)
      assert out =~ message
      assert {{:error, "No organization with slug nope"}, _out} = release(ctx, org: "nope")
    end
  end

  describe "into a select holding several terms" do
    setup ctx do
      terms =
        field!(ctx.admin, %{
          name: "properties_#{System.unique_integer([:positive])}",
          label: "Properties",
          field_type: :select,
          multiple: true,
          options: ["tonic", "adaptogen"]
        })

      %{ctx | group: terms.name} |> Map.put(:terms, terms)
    end

    test "reports each distinct term with its count, and the ones not yet options", ctx do
      post!(ctx, ~s(["tonic","nervine"]))
      post!(ctx, Jason.encode!(~s(["nervine","adaptogen"])))

      report = convert(ctx)

      assert report.terms == %{"tonic" => 1, "nervine" => 2, "adaptogen" => 1}
      assert report.new_terms == ["nervine"]
      assert [_, _] = report.problems
      assert FieldConversion.describe(report) =~ "3 distinct term(s), 1 not in the options:"
      assert FieldConversion.describe(report) =~ "nervine (2)"
    end

    test "writes the terms once they fit — here by opening the vocabulary", ctx do
      post = post!(ctx, ~s(["tonic","nervine"]))
      CMS.update_field_definition!(ctx.terms, %{allow_custom: true}, actor: ctx.admin)

      assert %{written: 1, new_terms: ["nervine"]} = convert(ctx, dry_run?: false)
      assert reload(post).custom_fields[ctx.group] == ["tonic", "nervine"]

      assert %{kept: 1, written: 0} = convert(ctx, dry_run?: false)
    end

    test "counts the published records a run would write", ctx do
      published = post!(ctx, ~s(["tonic"]))
      CMS.publish_post!(published, %{}, actor: ctx.admin)
      post!(ctx, ~s(["adaptogen"]))

      assert %{convertible: 2, published: 1} = convert(ctx)
    end

    test "refuses a select holding one choice, and --map", ctx do
      org = KilnCMS.Accounts.default_org_id()

      single =
        field!(ctx.admin, %{
          name: "grade_#{System.unique_integer([:positive])}",
          label: "Grade",
          field_type: :select,
          options: ["a"]
        })

      assert {:error, message} = FieldConversion.run(org, "post", ctx.source, single.name)
      assert message =~ "make it hold several terms first"

      assert {:error, message} =
               FieldConversion.run(org, "post", ctx.source, ctx.group, renames: %{"a" => "b"})

      assert message =~ "holds items, which have none"
    end
  end

  describe "into a list of phrases (multiple :string)" do
    setup ctx do
      list =
        field!(ctx.admin, %{
          name: "symptoms_#{System.unique_integer([:positive])}",
          label: "Symptoms",
          field_type: :string,
          multiple: true
        })

      Map.put(%{ctx | group: list.name}, :list, list)
    end

    test "writes a JSON array of strings as the items", ctx do
      post = post!(ctx, ~s(["fatigue","night sweats"]))

      assert %{written: 1, terms: terms} = convert(ctx, dry_run?: false)
      assert terms == %{}
      assert reload(post).custom_fields[ctx.group] == ["fatigue", "night sweats"]
    end

    test "--lines reads text that is not JSON as one item per line; without it, refused", ctx do
      post = post!(ctx, "Acupuncture\nCupping\n\n  Herbal consults  ")

      assert %{problems: [%{kind: :unparseable}]} = convert(ctx)

      assert %{written: 1} = convert(ctx, dry_run?: false, lines?: true)

      assert reload(post).custom_fields[ctx.group] == [
               "Acupuncture",
               "Cupping",
               "Herbal consults"
             ]
    end

    test "--lines keeps a character whose UTF-8 holds 0x85 whole", ctx do
      post = post!(ctx, "Acupuncture\n內科 consults")

      assert %{written: 1} = convert(ctx, dry_run?: false, lines?: true)
      assert reload(post).custom_fields[ctx.group] == ["Acupuncture", "內科 consults"]
    end

    test "refuses a string that holds one line", ctx do
      single =
        field!(ctx.admin, %{
          name: "one_#{System.unique_integer([:positive])}",
          label: "One",
          field_type: :string
        })

      assert {:error, message} =
               FieldConversion.run(
                 KilnCMS.Accounts.default_org_id(),
                 "post",
                 ctx.source,
                 single.name
               )

      assert message =~ "make it a list first"
    end
  end

  describe "into a typed list (#2289)" do
    setup ctx do
      dates =
        field!(ctx.admin, %{
          name: "event_dates_#{System.unique_integer([:positive])}",
          label: "Event dates",
          field_type: :date,
          multiple: true
        })

      Map.put(%{ctx | group: dates.name}, :dates, dates)
    end

    test "writes a JSON array of dates as the items, in order, without repeats", ctx do
      post = post!(ctx, ~s(["2026-03-08","2026-03-01","2026-03-08"]))

      assert %{written: 1, terms: terms} = convert(ctx, dry_run?: false)
      assert terms == %{}
      assert reload(post).custom_fields[ctx.group] == ["2026-03-08", "2026-03-01"]
    end

    test "an item that is not a date is reported by its position; nothing is written", ctx do
      post = post!(ctx, ~s(["2026-03-01","not a date"]))

      assert %{blocked?: true, written: 0, problems: [%{kind: :invalid, messages: messages}]} =
               convert(ctx, dry_run?: false)

      assert Enum.any?(messages, &(&1 =~ "item 2"))
      assert reload(post).custom_fields[ctx.group] in [nil, []]
    end

    test "an integer list keeps the numbers JSON-native, repeats included", ctx do
      scores =
        field!(ctx.admin, %{
          name: "scores_#{System.unique_integer([:positive])}",
          label: "Scores",
          field_type: :integer,
          multiple: true
        })

      ctx = %{ctx | group: scores.name}
      post = post!(ctx, ~s([3, "5", 3]))

      assert %{written: 1} = convert(ctx, dry_run?: false)
      assert reload(post).custom_fields[ctx.group] == [3, 5, 3]
    end

    test "--lines reads one link per line into a url list", ctx do
      links =
        field!(ctx.admin, %{
          name: "links_#{System.unique_integer([:positive])}",
          label: "Links",
          field_type: :url,
          multiple: true
        })

      ctx = %{ctx | group: links.name}
      post = post!(ctx, "https://a.example\n\n  https://b.example  ")

      assert %{problems: [%{kind: :unparseable}]} = convert(ctx)
      assert %{written: 1} = convert(ctx, dry_run?: false, lines?: true)

      assert reload(post).custom_fields[ctx.group] == [
               "https://a.example",
               "https://b.example"
             ]
    end

    test "refuses a single typed field, and --map", ctx do
      org = KilnCMS.Accounts.default_org_id()

      single =
        field!(ctx.admin, %{
          name: "count_#{System.unique_integer([:positive])}",
          label: "Count",
          field_type: :integer
        })

      assert {:error, message} = FieldConversion.run(org, "post", ctx.source, single.name)
      assert message == "#{single.name} is a single integer field — make it a list first"

      assert {:error, message} =
               FieldConversion.run(org, "post", ctx.source, ctx.group, renames: %{"a" => "b"})

      assert message =~ "holds items, which have none"
    end

    test "a type that cannot be a list is still not a target", ctx do
      flag =
        field!(ctx.admin, %{
          name: "flag_#{System.unique_integer([:positive])}",
          label: "Flag",
          field_type: :boolean
        })

      assert {:error, message} =
               FieldConversion.run(
                 KilnCMS.Accounts.default_org_id(),
                 "post",
                 ctx.source,
                 flag.name
               )

      assert message =~ "is a boolean field, not a group, a multiple select or a list"
    end
  end
end
