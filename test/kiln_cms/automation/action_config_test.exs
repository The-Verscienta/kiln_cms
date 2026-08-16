defmodule KilnCMS.Automation.ActionConfigTest do
  @moduledoc """
  A rule whose `config` can't work must say so where it was typed, not in a
  server log nobody is reading (#944).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Automation
  alias KilnCMS.Automation.Rule
  alias KilnCMS.Automation.Validations.ActionConfig

  defp create(attrs) do
    Automation.create_rule(
      Map.merge(%{name: "Rule #{System.unique_integer([:positive])}"}, attrs),
      authorize?: false
    )
  end

  defp messages({:error, error}) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.map_join(" ", & &1.message)
  end

  describe "the shape table covers the resource" do
    test "every action kind has an entry" do
      # Otherwise a new reaction silently opts out of validation, which is the
      # state this exists to end.
      for action <- Rule.action_kinds() do
        assert ActionConfig.shape(action), "#{action} has no config shape"
      end
    end

    test "and it describes nothing the resource doesn't have" do
      assert ActionConfig.shapes() |> Map.keys() |> Enum.sort() ==
               Enum.sort(Rule.action_kinds())
    end
  end

  describe "required keys" do
    test "send_email without a `to` is refused at save, not at 3am in a log" do
      result = create(%{trigger_event: :published, action: :send_email, config: %{}})

      assert {:error, _} = result
      assert messages(result) =~ "missing `to`"
    end

    test "each intelligence reaction needs somewhere to deliver" do
      for action <- [:flag_duplicates, :suggest_tags, :suggest_links, :suggest_metadata] do
        result = create(%{trigger_event: :in_review, action: action, config: %{}})

        assert {:error, _} = result, "#{action} accepted a config with no `to`"
        assert messages(result) =~ "missing `to`"
      end
    end

    test "social_post needs a provider" do
      result = create(%{trigger_event: :published, action: :social_post, config: %{}})

      assert {:error, _} = result
      assert messages(result) =~ "missing `provider`"
    end

    test "a blank string is missing, not present" do
      result =
        create(%{trigger_event: :published, action: :send_email, config: %{"to" => "   "}})

      assert {:error, _} = result
      assert messages(result) =~ "missing `to`"
    end

    test "the reactions that read no config save with none" do
      for action <- [:invalidate_cache, :reindex, :broadcast, :newsletter] do
        assert {:ok, _} = create(%{trigger_event: :published, action: action, config: %{}})
      end
    end
  end

  describe "types" do
    test "allow_egress must be the JSON boolean, and the string is named as the mistake" do
      # The natural error: every other key in that textarea is a string, and
      # the runtime gate fails closed on it, so the rule looks configured and
      # emails nothing forever.
      result =
        create(%{
          trigger_event: :in_review,
          action: :suggest_metadata,
          config: %{"to" => "team@example.com", "allow_egress" => "true"}
        })

      assert {:error, _} = result
      assert messages(result) =~ "allow_egress"
      assert messages(result) =~ "not a string"
    end

    test "the JSON boolean itself is accepted" do
      assert {:ok, _} =
               create(%{
                 trigger_event: :in_review,
                 action: :suggest_metadata,
                 config: %{"to" => "team@example.com", "allow_egress" => true}
               })
    end

    test "a `to` that isn't an address is refused" do
      result =
        create(%{
          trigger_event: :published,
          action: :send_email,
          config: %{"to" => "team at example.com"}
        })

      assert {:error, _} = result
      assert messages(result) =~ "must be an email address"
    end

    test "an unknown social provider is refused, and the message lists the real ones" do
      result =
        create(%{
          trigger_event: :published,
          action: :social_post,
          config: %{"provider" => "myspace"}
        })

      assert {:error, _} = result
      assert messages(result) =~ "must be one of"
      assert messages(result) =~ "mastodon"
    end
  end

  describe "unknown keys" do
    test "a misspelled key is refused rather than ignored" do
      # An ignored key is a typo that survives the form: this rule would look
      # configured and never send.
      result =
        create(%{
          trigger_event: :published,
          action: :send_email,
          config: %{"to" => "team@example.com", "recipient" => "team@example.com"}
        })

      assert {:error, _} = result
      assert messages(result) =~ "no `recipient`"
      assert messages(result) =~ "It accepts: to, subject, body"
    end

    test "a key that belongs to a DIFFERENT action is refused too" do
      result =
        create(%{
          trigger_event: :published,
          action: :send_email,
          config: %{"to" => "team@example.com", "allow_egress" => true}
        })

      assert {:error, _} = result
      assert messages(result) =~ "no `allow_egress`"
    end
  end

  describe "changing the action on an existing rule" do
    test "re-validates the config it already had" do
      # `:broadcast` accepts a topic; `:send_email` does not, and needs a `to`
      # the old config has no reason to carry.
      {:ok, rule} =
        create(%{
          trigger_event: :published,
          action: :broadcast,
          config: %{"topic" => "editorial"}
        })

      result = Automation.update_rule(rule, %{action: :send_email}, authorize?: false)

      assert {:error, _} = result
      # Missing-required is reported before unknown-key: it is the reason the
      # rule can't work, and `topic` is only stale.
      assert messages(result) =~ "missing `to`"
    end

    test "and reports a leftover key once the required one is supplied" do
      {:ok, rule} =
        create(%{
          trigger_event: :published,
          action: :broadcast,
          config: %{"topic" => "editorial"}
        })

      result =
        Automation.update_rule(
          rule,
          %{action: :send_email, config: %{"topic" => "editorial", "to" => "team@example.com"}},
          authorize?: false
        )

      assert {:error, _} = result
      assert messages(result) =~ "no `topic`"
    end

    test "and accepts the config that suits the new action" do
      {:ok, rule} =
        create(%{
          trigger_event: :published,
          action: :broadcast,
          config: %{"topic" => "editorial"}
        })

      assert {:ok, %{action: :send_email}} =
               Automation.update_rule(
                 rule,
                 %{action: :send_email, config: %{"to" => "team@example.com"}},
                 authorize?: false
               )
    end
  end

  describe "rules that predate the validation" do
    test "still exist and still read — this is a check on the form, not on the table" do
      # Ash.Seed writes the row directly, which is what an existing rule (or an
      # AshAdmin edit) looks like. The contrast is the point: the same attrs
      # through the action are refused, so the executor's own runtime guards
      # are still the thing standing between a legacy config and a crash.
      attrs = %{
        name: "Legacy #{System.unique_integer([:positive])}",
        trigger_event: :published,
        action: :send_email,
        config: %{},
        enabled: true
      }

      rule = Ash.Seed.seed!(Rule, attrs)

      assert {:error, _} = create(Map.delete(attrs, :name))
      assert {:ok, %{config: %{}}} = Automation.get_rule(rule.id, authorize?: false)
    end
  end

  describe "deliver_as (#946)" do
    test "an absent deliver_as still needs `to`, exactly as before" do
      result = create(%{trigger_event: :in_review, action: :flag_duplicates, config: %{}})

      assert {:error, _} = result
      assert messages(result) =~ "missing `to`"
    end

    test "deliver_as: email needs `to`, same as no deliver_as at all" do
      assert {:ok, _} =
               create(%{
                 trigger_event: :in_review,
                 action: :flag_duplicates,
                 config: %{"deliver_as" => "email", "to" => "eds@example.com"}
               })

      result =
        create(%{
          trigger_event: :in_review,
          action: :flag_duplicates,
          config: %{"deliver_as" => "email"}
        })

      assert {:error, _} = result
      assert messages(result) =~ "missing `to`"
    end

    test "deliver_as: comment needs nothing further" do
      for action <- [:flag_duplicates, :suggest_tags, :suggest_links, :suggest_metadata] do
        assert {:ok, _} =
                 create(%{
                   trigger_event: :in_review,
                   action: action,
                   config: %{"deliver_as" => "comment"}
                 })
      end
    end

    test "deliver_as: task needs an assignee, and due_in_days is optional" do
      result =
        create(%{
          trigger_event: :in_review,
          action: :suggest_tags,
          config: %{"deliver_as" => "task"}
        })

      assert {:error, _} = result
      assert messages(result) =~ "missing `assignee`"

      assert {:ok, _} =
               create(%{
                 trigger_event: :in_review,
                 action: :suggest_tags,
                 config: %{"deliver_as" => "task", "assignee" => Ash.UUID.generate()}
               })

      assert {:ok, _} =
               create(%{
                 trigger_event: :in_review,
                 action: :suggest_tags,
                 config: %{
                   "deliver_as" => "task",
                   "assignee" => Ash.UUID.generate(),
                   "due_in_days" => 5
                 }
               })
    end

    test "assignee must be a uuid" do
      result =
        create(%{
          trigger_event: :in_review,
          action: :suggest_tags,
          config: %{"deliver_as" => "task", "assignee" => "not-a-uuid"}
        })

      assert {:error, _} = result
      assert messages(result) =~ "must be a uuid"
    end

    test "due_in_days must be a positive whole number" do
      result =
        create(%{
          trigger_event: :in_review,
          action: :suggest_tags,
          config: %{
            "deliver_as" => "task",
            "assignee" => Ash.UUID.generate(),
            "due_in_days" => -1
          }
        })

      assert {:error, _} = result
      assert messages(result) =~ "must be a positive whole number"
    end

    test "an unrecognized deliver_as value is refused" do
      result =
        create(%{
          trigger_event: :in_review,
          action: :suggest_tags,
          config: %{"deliver_as" => "carrier_pigeon", "to" => "eds@example.com"}
        })

      assert {:error, _} = result
      assert messages(result) =~ "must be one of email, comment, task"
    end

    test "suggest_metadata still accepts allow_egress alongside deliver_as" do
      assert {:ok, _} =
               create(%{
                 trigger_event: :in_review,
                 action: :suggest_metadata,
                 config: %{"deliver_as" => "comment", "allow_egress" => true}
               })
    end
  end

  describe "shapes that are not just required keys" do
    test "an optional key of the wrong type is refused" do
      result =
        create(%{
          trigger_event: :published,
          action: :broadcast,
          config: %{"topic" => 42}
        })

      assert {:error, _} = result
      assert messages(result) =~ "must be a non-empty string"
    end

    test "newsletter's optional keys are accepted when well-typed" do
      assert {:ok, _} =
               create(%{
                 trigger_event: :published,
                 action: :newsletter,
                 config: %{"segment_id" => Ash.UUID.generate(), "subject" => "New: {{title}}"}
               })
    end

    test "social_post takes an optional template alongside its provider" do
      assert {:ok, _} =
               create(%{
                 trigger_event: :published,
                 action: :social_post,
                 config: %{"provider" => "mastodon", "template" => "New: {{title}} {{url}}"}
               })
    end
  end
end
