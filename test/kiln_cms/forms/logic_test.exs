defmodule KilnCMS.Forms.LogicTest do
  @moduledoc """
  Conditional fields on public forms (#2262): the ordering layer
  (`KilnCMS.Forms.Logic`), run from
  `test/support/fixtures/form_visibility_cases.json`, the file the browser's
  `assets/js/form_logic.js` is held to as well, and the submission pipeline
  that enforces it: a hidden field is never required, and whatever was sent
  for it is dropped from the stored data, the spam checks, the mail and the
  webhook.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.Forms
  alias KilnCMS.Forms.Logic

  @cases "test/support/fixtures/form_visibility_cases.json"
         |> File.read!()
         |> Jason.decode!()

  @external_resource "test/support/fixtures/form_visibility_cases.json"

  defp fixture_fields(fields) do
    for %{"name" => name} = field <- fields,
        do: %{name: name, field_type: :string, condition: field["condition"]}
  end

  for %{"name" => name, "fields" => fields, "values" => values, "expected" => expected} <- @cases do
    test "fixture: #{name}" do
      fields = fixture_fields(unquote(Macro.escape(fields)))

      assert Logic.visibility(fields, unquote(Macro.escape(values))) ==
               unquote(Macro.escape(expected))
    end
  end

  test "the fixture names a case for each rule of the ordering layer" do
    names = Enum.map(@cases, & &1["name"])

    for needle <- [
          "chain",
          "later field",
          "itself",
          "missing field",
          "broken shape",
          "unknown action",
          "hide"
        ] do
      assert Enum.any?(names, &String.contains?(&1, needle)), needle
    end
  end

  describe "effective/2" do
    defp leaf(field, op \\ "eq", value \\ "x"),
      do: %{"field" => field, "op" => op, "value" => value}

    test "a hidden-type field takes no condition, so one stored on it does nothing" do
      field = %{name: "h", field_type: :hidden, condition: %{action: :show, rule: leaf("a")}}
      assert Logic.effective(field, MapSet.new(["a"])) == nil
    end

    test "a field of a type this release doesn't know is not a known field" do
      unknown = %{name: "u", field_type: %KilnCMS.Types.UnknownAtom{value: "zz"}}
      refute Logic.known?(unknown)

      assert Logic.known_fields([unknown, %{name: "a", field_type: :string}]) == [
               %{name: "a", field_type: :string}
             ]
    end
  end

  describe "order_violations/1" do
    test "names each field whose rule names a field that is not before it" do
      a = %{name: "a", condition: nil}
      b = %{name: "b", condition: %{action: :show, rule: %{"field" => "a", "op" => "not_empty"}}}
      assert Logic.order_violations([a, b]) == []
      assert Logic.order_violations([b, a]) == [{b, a}]
    end

    test "a rule naming a field the form doesn't have is not a violation" do
      b = %{
        name: "b",
        condition: %{action: :show, rule: %{"field" => "gone", "op" => "not_empty"}}
      }

      assert Logic.order_violations([b]) == []
    end
  end

  # --- the submission pipeline --------------------------------------------------

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "form-logic-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp form!(attrs \\ %{}, fields) do
    actor = admin()

    form =
      CMS.create_form!(
        Map.merge(%{name: "Contact", slug: "logic-#{System.unique_integer([:positive])}"}, attrs),
        actor: actor
      )

    for {field, position} <- Enum.with_index(fields) do
      CMS.create_form_field!(Map.merge(%{form_id: form.id, position: position}, field),
        actor: actor
      )
    end

    Forms.get_active(form.slug)
  end

  defp show_when(field, op, value \\ nil) do
    rule = %{"field" => field, "op" => op}
    rule = if is_nil(value), do: rule, else: Map.put(rule, "value", value)
    %{action: :show, rule: rule}
  end

  defp topic_form(attrs \\ %{}) do
    form!(attrs, [
      %{name: "topic", label: "Topic", field_type: :select, options: ["Sales", "Other"]},
      %{
        name: "details",
        label: "Details",
        field_type: :string,
        required: true,
        condition: show_when("topic", "eq", "Other")
      }
    ])
  end

  test "a required field its condition hides is accepted with no value" do
    assert {:ok, submission} = Forms.submit(topic_form(), %{"topic" => "Sales"})
    assert submission.data == %{"topic" => "Sales"}
  end

  test "a required field its condition shows is still required" do
    assert {:error, %{"details" => "is required"}} =
             Forms.submit(topic_form(), %{"topic" => "Other"})
  end

  test "a value crafted for a hidden field is dropped, and named as dropped" do
    assert {:ok, submission} =
             Forms.submit(topic_form(), %{"topic" => "Sales", "details" => "smuggled"})

    assert submission.data == %{"topic" => "Sales"}
    assert Forms.discarded_fields(submission) == ["details"]
  end

  test "a blank value for a hidden field is not named as dropped" do
    assert {:ok, submission} = Forms.submit(topic_form(), %{"topic" => "Sales", "details" => " "})
    assert Forms.discarded_fields(submission) == []
  end

  test "a value crafted for a hidden field never reaches the webhook" do
    CMS.create_webhook_endpoint!(
      %{url: "https://example.test/hook", events: ["form.submitted"]},
      actor: admin()
    )

    assert {:ok, _} = Forms.submit(topic_form(), %{"topic" => "Sales", "details" => "smuggled"})

    assert [delivery] = CMS.recent_webhook_deliveries!(authorize?: false)
    assert delivery.payload["data"] == %{"topic" => "Sales"}
  end

  test "a value crafted for a hidden field never reaches the spam checks" do
    CMS.save_form_spam_settings!(%{keywords: ["cryptobucks"]}, actor: admin())

    assert {:ok, submission} =
             Forms.submit(topic_form(), %{"topic" => "Sales", "details" => "cryptobucks"})

    refute submission.status == :spam

    assert {:ok, shown} =
             Forms.submit(topic_form(), %{"topic" => "Other", "details" => "cryptobucks"})

    assert shown.status == :spam
  end

  test "a chain: a field hidden by its condition hides the fields that depend on it" do
    form =
      form!([
        %{name: "a", label: "A", field_type: :select, options: ["yes", "no"]},
        %{name: "b", label: "B", field_type: :string, condition: show_when("a", "eq", "yes")},
        %{
          name: "c",
          label: "C",
          field_type: :string,
          required: true,
          condition: show_when("b", "not_empty")
        }
      ])

    # `b` was sent, but `a` hides it, so `c` sees it as empty and hides too.
    assert {:ok, submission} = Forms.submit(form, %{"a" => "no", "b" => "x"})
    assert submission.data == %{"a" => "no"}

    assert {:error, %{"c" => "is required"}} = Forms.submit(form, %{"a" => "yes", "b" => "x"})
  end

  test "the hide action hides the field while its rule holds" do
    form =
      form!([
        %{name: "member", label: "Member", field_type: :boolean},
        %{
          name: "postcode",
          label: "Postcode",
          field_type: :string,
          required: true,
          condition: %{action: :hide, rule: %{"field" => "member", "op" => "eq", "value" => true}}
        }
      ])

    assert {:ok, submission} = Forms.submit(form, %{"member" => "true", "postcode" => "x"})
    assert submission.data == %{"member" => true}

    assert {:error, %{"postcode" => "is required"}} = Forms.submit(form, %{"member" => "false"})
  end

  test "a value that fails to cast is still reported, and later rules read what was sent" do
    form =
      form!([
        %{name: "count", label: "Count", field_type: :integer},
        %{
          name: "bulk",
          label: "Bulk",
          field_type: :string,
          required: true,
          condition: show_when("count", "gt", 5)
        }
      ])

    assert {:error, errors} = Forms.submit(form, %{"count" => "7.5"})
    assert errors == %{"count" => "must be a whole number", "bulk" => "is required"}
  end

  test "a tripped honeypot names what a real submission would have dropped" do
    form = topic_form()
    assert Forms.hidden_answers(form, %{"topic" => "Sales", "details" => "x"}) == ["details"]
    assert Forms.hidden_answers(form, %{"topic" => "Other", "details" => "x"}) == []
  end

  describe "the autoresponder" do
    defp responder_form(fields) do
      form = form!(fields)

      CMS.update_form!(
        CMS.get_form!(form.id, authorize?: false),
        %{
          autoresponder_enabled: true,
          autoresponder_subject: "Thanks",
          autoresponder_body: "We got it"
        },
        authorize?: false
      )

      Forms.get_active(form.slug)
    end

    test "mails the first email field that is shown and has a value" do
      form =
        responder_form([
          %{name: "kind", label: "Kind", field_type: :select, options: ["work", "home"]},
          %{
            name: "work_email",
            label: "Work",
            field_type: :email,
            condition: show_when("kind", "eq", "work")
          },
          %{name: "home_email", label: "Home", field_type: :email}
        ])

      # The work email is hidden: its value is dropped, the home one is used.
      assert {:ok, submission} =
               Forms.submit(form, %{
                 "kind" => "home",
                 "work_email" => "boss@example.com",
                 "home_email" => "me@example.com"
               })

      assert {true, "me@example.com"} =
               KilnCMS.Forms.Autoresponder.eligible?(form, submission.data, form.fields)

      assert {:ok, submission} =
               Forms.submit(form, %{"kind" => "work", "work_email" => "boss@example.com"})

      assert {true, "boss@example.com"} =
               KilnCMS.Forms.Autoresponder.eligible?(form, submission.data, form.fields)
    end

    test "sends nothing when the only email field is hidden" do
      form =
        responder_form([
          %{name: "kind", label: "Kind", field_type: :select, options: ["work", "home"]},
          %{
            name: "email",
            label: "Email",
            field_type: :email,
            condition: show_when("kind", "eq", "work")
          }
        ])

      assert {:ok, submission} =
               Forms.submit(form, %{"kind" => "home", "email" => "x@example.com"})

      refute KilnCMS.Forms.Autoresponder.eligible?(form, submission.data, form.fields)
      refute_enqueued(worker: KilnCMS.Forms.AutoresponderWorker)
    end
  end
end
