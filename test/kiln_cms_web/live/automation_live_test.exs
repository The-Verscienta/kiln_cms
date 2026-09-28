defmodule KilnCMSWeb.AutomationLiveTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Automation
  alias KilnCMS.Automation.Rule
  alias KilnCMS.Automation.Validations.ActionConfig
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.AutomationLive.ConfigFields
  alias KilnCMSWeb.AutomationLive.Wording

  @password "password123456"

  defp authed_user(role) do
    email = "auto-live-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp type_label(type) do
    {label, _type} = Enum.find(ContentTypes.options(nil), &(elem(&1, 1) == type))
    label
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  describe "authorization" do
    test "anonymous users are redirected to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/automation")
    end

    test "editors are redirected away", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))

      assert {:error,
              {:redirect,
               %{to: "/", flash: %{"error" => "You need admin access to view that page."}}}} =
               live(conn, ~p"/editor/automation")
    end
  end

  describe "managing rules" do
    setup %{conn: conn} do
      %{conn: log_in(conn, authed_user(:admin))}
    end

    test "an admin can create a rule", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      # Picking the action first renders its settings inputs — the form only
      # ever shows the fields the selected reaction accepts.
      view |> form("#new-rule-form", rule: %{action: "broadcast"}) |> render_change()

      view
      |> form("#new-rule-form",
        rule: %{
          name: "Notify on publish",
          trigger_event: "published",
          content_type: "post",
          action: "broadcast",
          # Trimmed: "editorial " is a channel no listener is on.
          config: %{topic: " editorial "}
        }
      )
      |> render_submit()

      rule =
        Enum.find(Automation.list_rules!(authorize?: false), &(&1.name == "Notify on publish"))

      # The rules list says what the rule does in words, not `post.published`.
      assert has_element?(view, "#rule-#{rule.id}", "Notify on publish")

      assert has_element?(
               view,
               "#rule-#{rule.id}",
               "When #{type_label("post")} content is published, broadcast on “editorial”."
             )

      assert rule.trigger_event == :published
      assert rule.action == :broadcast
      assert rule.config == %{"topic" => "editorial"}
    end

    test "an admin can scope a rule to task events (#501)", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/editor/automation")

      # The content-type picker offers "Tasks" so a task.assigned/task.overdue
      # rule can be scoped correctly, rather than left at "Any content type"
      # (which would also match every content-publish event) or pointed at an
      # actual content type (which `Rule.matching`'s exact string match would
      # then never fire for). Asserted on the option itself: the console
      # sidebar's own "Tasks" link would satisfy a substring match on the page.
      assert html =~ ~s(<option value="task">Tasks</option>)

      view |> form("#new-rule-form", rule: %{action: "broadcast"}) |> render_change()

      view
      |> form("#new-rule-form",
        rule: %{
          name: "Notify on task assignment",
          trigger_event: "assigned",
          content_type: "task",
          action: "broadcast",
          config: %{topic: "tasks"}
        }
      )
      |> render_submit()

      rule =
        Enum.find(
          Automation.list_rules!(authorize?: false),
          &(&1.name == "Notify on task assignment")
        )

      assert has_element?(
               view,
               "#rule-#{rule.id}",
               "When a task is assigned, broadcast on “tasks”."
             )

      assert rule.trigger_event == :assigned
      assert rule.content_type == "task"
    end

    test "every reaction is a card that says what it does", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      for action <- Rule.action_kinds() do
        %{label: label} = Wording.action(action)

        assert has_element?(
                 view,
                 ~s(#new-rule-form label[for="rule_action_#{action}"]),
                 label
               )
      end

      # The untouched form has the first reaction chosen, as the select did.
      first = List.first(Rule.action_kinds())
      assert has_element?(view, ~s(input#rule_action_#{first}[checked]))
    end

    test "the sentence the rule reads as follows the form as it changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      assert has_element?(
               view,
               "#rule_summary",
               "When any content is published, send an email."
             )

      view
      |> form("#new-rule-form",
        rule: %{content_type: "post", trigger_event: "updated", action: "invalidate_cache"}
      )
      |> render_change()

      assert has_element?(
               view,
               "#rule_summary",
               "When #{type_label("post")} content is updated, clear the cache."
             )

      # It is also the name field's placeholder: what a blank name becomes.
      assert has_element?(
               view,
               ~s(#rule_name[placeholder="When #{type_label("post")} content is updated, clear the cache."])
             )
    end

    test "a rule saved without a name is named by its sentence", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      view
      |> form("#new-rule-form",
        rule: %{
          name: "",
          trigger_event: "published",
          action: "send_email",
          config: %{to: "ed@example.com"}
        }
      )
      |> render_submit()

      assert [rule] = Automation.list_rules!(authorize?: false)
      assert rule.name == "When any content is published, email ed@example.com."

      # The list shows the sentence once, as the name, not twice.
      assert view
             |> element("#rule-#{rule.id}")
             |> render()
             |> String.split("ed@example.com")
             |> length() == 2
    end

    test "the settings are generated from the enforcing table", %{conn: conn} do
      # One input per key `ActionConfig.shapes/0` accepts, required where
      # `required_keys/2` says so — a hand-kept list beside the form is the
      # doc-drifts-from-enforcement failure #944 is about.
      {:ok, view, html} = live(conn, ~p"/editor/automation")

      # The first action kind is what the untouched select displays.
      assert has_element?(view, ~s(input[type="email"][name="rule[config][to]"][required]))
      assert has_element?(view, ~s(input[name="rule[config][subject]"]))
      assert has_element?(view, ~s(textarea[name="rule[config][body]"]))
      assert html =~ "Send to"
      refute has_element?(view, ~s(textarea[name="rule[config]"]))

      view |> form("#new-rule-form", rule: %{action: "reindex"}) |> render_change()
      assert render(view) =~ "Nothing to set up"
      refute has_element?(view, ~s([name^="rule[config]"]))

      view |> form("#new-rule-form", rule: %{action: "social_post"}) |> render_change()
      assert has_element?(view, ~s(select[name="rule[config][provider]"][required]))

      assert has_element?(
               view,
               ~s(select[name="rule[config][provider]"] option[value="mastodon"])
             )
    end

    test "deliver_as shows only the fields where the finding is going (#946)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      view |> form("#new-rule-form", rule: %{action: "suggest_metadata"}) |> render_change()

      # No deliver_as yet reads as email — the default the save applies.
      assert has_element?(
               view,
               ~s(input[name="rule[config][deliver_as]"][value="email"][checked])
             )

      assert has_element?(view, ~s(input[name="rule[config][to]"][required]))
      assert has_element?(view, ~s(input[type="checkbox"][name="rule[config][allow_egress]"]))
      refute has_element?(view, ~s([name="rule[config][assignee]"]))

      view
      |> form("#new-rule-form",
        rule: %{action: "suggest_metadata", config: %{deliver_as: "task"}}
      )
      |> render_change()

      assert has_element?(view, ~s(select[name="rule[config][assignee]"][required]))
      assert has_element?(view, ~s(input[type="number"][name="rule[config][due_in_days]"]))
      refute has_element?(view, ~s([name="rule[config][to]"]))

      view
      |> form("#new-rule-form",
        rule: %{action: "suggest_metadata", config: %{deliver_as: "comment"}}
      )
      |> render_change()

      refute has_element?(view, ~s([name="rule[config][to]"]))
      refute has_element?(view, ~s([name="rule[config][assignee]"]))
    end

    test "inputs are saved as the typed config the reaction reads", %{conn: conn} do
      admin = authed_user(:admin)
      conn = log_in(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      view |> form("#new-rule-form", rule: %{action: "suggest_metadata"}) |> render_change()

      view
      |> form("#new-rule-form",
        rule: %{action: "suggest_metadata", config: %{deliver_as: "task"}}
      )
      |> render_change()

      view
      |> form("#new-rule-form",
        rule: %{
          name: "Draft metadata",
          trigger_event: "in_review",
          action: "suggest_metadata",
          config: %{
            deliver_as: "task",
            assignee: admin.id,
            due_in_days: "5",
            allow_egress: "true"
          }
        }
      )
      |> render_submit()

      rule = Enum.find(Automation.list_rules!(authorize?: false), &(&1.name == "Draft metadata"))

      # The toggle is the JSON boolean and the day count an integer — the
      # `"allow_egress": "true"` string the JSON box invited can't be produced.
      assert rule.config == %{
               "deliver_as" => "task",
               "assignee" => admin.id,
               "due_in_days" => 5,
               "allow_egress" => true
             }
    end

    test "blank optional fields mean the default, and are left out", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      view
      |> form("#new-rule-form",
        rule: %{
          name: "Email on publish",
          trigger_event: "published",
          action: "send_email",
          config: %{to: " team@example.com ", subject: "", body: "   "}
        }
      )
      |> render_submit()

      rule =
        Enum.find(Automation.list_rules!(authorize?: false), &(&1.name == "Email on publish"))

      assert rule.config == %{"to" => "team@example.com"}
    end

    test "switching the action drops the previous action's settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      view
      |> form("#new-rule-form", rule: %{action: "send_email", config: %{to: "a@example.com"}})
      |> render_change()

      # The change that switches the select still posts the email fields —
      # they're what was on screen — and they must not reach the broadcast
      # rule as an unknown key.
      html =
        view
        |> form("#new-rule-form",
          rule: %{
            name: "Broadcast",
            trigger_event: "published",
            action: "reindex",
            config: %{to: "a@example.com"}
          }
        )
        |> render_submit()

      refute html =~ "has no `to`"
      rule = Enum.find(Automation.list_rules!(authorize?: false), &(&1.name == "Broadcast"))
      assert rule.action == :reindex
      assert rule.config == %{}
    end

    test "config that can never work is refused, beside the field (#944)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      # A browser stops this at the `required` attribute; LiveViewTest doesn't,
      # which is what lets this check the server-side refusal behind it.
      view
      |> form("#new-rule-form",
        rule: %{
          name: "Never sends",
          trigger_event: "published",
          content_type: "",
          action: "send_email",
          config: %{subject: "Live: {{title}}"}
        }
      )
      |> render_submit()

      # Beside the field its label already names, so the message says only
      # what is wrong — not the config-map wording the API gets.
      assert has_element?(view, "#rule_config_to-error", "This is required.")
      assert Automation.list_rules!(authorize?: false) == []
    end

    test "settings errors wait for the first save attempt", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      view |> form("#new-rule-form", rule: %{action: "suggest_tags"}) |> render_change()

      view
      |> form("#new-rule-form", rule: %{action: "suggest_tags", config: %{deliver_as: "task"}})
      |> render_change()

      # "Task" was just picked; "Assign to" is empty because nobody has had a
      # chance to fill it, not because anyone got it wrong.
      refute has_element?(view, "#rule_config_assignee-error")

      view
      |> form("#new-rule-form",
        rule: %{
          name: "Tags",
          action: "suggest_tags",
          config: %{deliver_as: "task", due_in_days: "0"}
        }
      )
      |> render_submit()

      assert has_element?(view, "#rule_config_assignee-error", "This is required.")
    end

    test "a wrongly-typed value is explained in words beside its field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      view |> form("#new-rule-form", rule: %{action: "create_task"}) |> render_change()

      view
      |> form("#new-rule-form",
        rule: %{name: "Stale", action: "create_task", config: %{due_in_days: "400"}}
      )
      |> render_submit()

      assert has_element?(
               view,
               "#rule_config_due_in_days-error",
               "Must be a whole number of days between 1 and 365, got 400."
             )
    end

    test "editing leaves a legacy string \"true\" allow_egress switched off", %{conn: conn} do
      # Seeded past the validation, the way a rule predating #944 exists. The
      # worker treats the string as off; the edit form must not show it as on
      # and turn it into the boolean on a save that only renames the rule.
      rule =
        Ash.Seed.seed!(Rule, %{
          org_id: Accounts.default_org_id(),
          name: "Legacy egress",
          trigger_event: :in_review,
          action: :suggest_metadata,
          config: %{"to" => "team@example.com", "allow_egress" => "true"},
          enabled: true
        })

      {:ok, view, _html} = live(conn, ~p"/editor/automation")
      view |> element("#rule-#{rule.id} button", "Edit") |> render_click()

      refute has_element?(
               view,
               ~s(#edit-rule-#{rule.id} input[type="checkbox"][name="rule[config][allow_egress]"][checked])
             )

      view |> form("#edit-rule-#{rule.id}", rule: %{name: "Renamed"}) |> render_submit()

      assert {:ok, %{name: "Renamed", config: config}} =
               Automation.get_rule(rule.id, authorize?: false)

      refute config["allow_egress"] == true
    end

    test "editing keeps a stored value its picker no longer offers", %{conn: conn} do
      # A deleted segment: the rule is refused at send time today. Blanking
      # the key on an unrelated save would make it mail every subscriber.
      stale = Ash.UUID.generate()

      {:ok, rule} =
        Automation.create_rule(
          %{
            name: "Segment newsletter",
            trigger_event: :published,
            action: :newsletter,
            config: %{"segment_id" => stale}
          },
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/editor/automation")
      view |> element("#rule-#{rule.id} button", "Edit") |> render_click()

      assert has_element?(
               view,
               ~s(#edit-rule-#{rule.id} select[name="rule[config][segment_id]"] option[value="#{stale}"][selected])
             )

      view
      |> form("#edit-rule-#{rule.id}", rule: %{name: "Renamed newsletter"})
      |> render_submit()

      assert {:ok, %{name: "Renamed newsletter", config: %{"segment_id" => ^stale}}} =
               Automation.get_rule(rule.id, authorize?: false)
    end

    test "editing a rule shows its stored settings in the inputs", %{conn: conn} do
      {:ok, rule} =
        Automation.create_rule(
          %{
            name: "Edit me",
            trigger_event: :published,
            action: :send_email,
            config: %{"to" => "ops@example.com", "subject" => "Live: {{title}}"}
          },
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/editor/automation")
      view |> element("#rule-#{rule.id} button", "Edit") |> render_click()

      assert has_element?(
               view,
               ~s(#edit-rule-#{rule.id} input[name="rule[config][to]"][value="ops@example.com"])
             )

      view
      |> form("#edit-rule-#{rule.id}",
        rule: %{config: %{to: "ops@example.com", subject: "Now live: {{title}}"}}
      )
      |> render_submit()

      assert {:ok, %{config: %{"subject" => "Now live: {{title}}"}}} =
               Automation.get_rule(rule.id, authorize?: false)
    end

    test "an admin can toggle and delete a rule", %{conn: conn} do
      {:ok, rule} =
        Automation.create_rule(
          %{name: "Toggle me", trigger_event: :updated, action: :invalidate_cache},
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/editor/automation")

      view |> element("#rule-#{rule.id} button", "Disable") |> render_click()
      assert {:ok, %{enabled: false}} = Automation.get_rule(rule.id, authorize?: false)

      view |> element("#rule-#{rule.id} button[aria-label='Delete rule']") |> render_click()
      assert Automation.list_rules!(authorize?: false) == []
    end
  end

  describe "Wording" do
    test "words every trigger and reaction Rule has" do
      # A new one would otherwise reach the builder as a raw atom.
      for trigger <- Rule.triggers() do
        assert Wording.trigger_phrase(trigger), "trigger #{trigger} has no wording"
      end

      for action <- Rule.action_kinds() do
        assert Wording.action(action), "reaction #{action} has no card wording"
      end
    end

    test "every trigger is offered, once" do
      offered = for {_group, options} <- Wording.trigger_options(), {_label, t} <- options, do: t
      assert Enum.sort(offered) == Enum.sort(Rule.triggers())
    end

    test "every reaction is on exactly one card" do
      carded = for {_group, cards} <- Wording.action_groups(), {a, _card} <- cards, do: a
      assert Enum.sort(carded) == Enum.sort(Rule.action_kinds())
    end
  end

  describe "ConfigFields.meta/1" do
    test "labels every key any reaction accepts" do
      # A key added to `ActionConfig` without a label would render as its raw
      # name to the non-developer this form exists for.
      for {action, shape} <- ActionConfig.shapes(),
          {key, _type} <- shape.required ++ shape.optional do
        assert ConfigFields.meta(key), "#{action}'s `#{key}` has no label in ConfigFields.meta/1"
      end
    end

    test "words every deliver_as value ActionConfig accepts" do
      # The fallback humanizes the value and has no hint.
      for value <- ActionConfig.deliver_as_values() do
        assert {_label, hint} = ConfigFields.deliver_as_label(value)
        assert hint, "deliver_as #{inspect(value)} has no wording in ConfigFields"
      end
    end
  end
end
