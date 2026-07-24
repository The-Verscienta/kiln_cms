defmodule KilnCMSWeb.FormBuilderLiveTest do
  @moduledoc """
  The visual form builder (`/editor/forms/:id`, admin-only): palette → canvas
  → options panel, drag reorder persisting `position`, duplicate, settings
  tabs, and the entries viewer.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "fb-#{System.unique_integer([:positive])}@example.com"

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

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # Creates a form (and optionally fields) FIRST, then mounts the builder —
  # the LiveView only sees fields that exist at mount (or that it creates).
  defp builder(conn, admin, form_attrs \\ %{}, fields \\ []) do
    slug = "fb-#{System.unique_integer([:positive])}"
    attrs = Map.merge(%{name: "Contact", slug: slug}, form_attrs)
    form = CMS.create_form!(attrs, actor: admin)

    created =
      for field_attrs <- fields do
        CMS.create_form_field!(Map.put(field_attrs, :form_id, form.id), actor: admin)
      end

    {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/forms/#{form.id}")
    {form, created, lv, html}
  end

  test "editors are redirected away", %{conn: conn} do
    admin = authed_user(:admin)
    form = CMS.create_form!(%{name: "Contact", slug: "fb-tier"}, actor: admin)

    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in(authed_user(:editor)) |> live(~p"/editor/forms/#{form.id}")
  end

  test "an unknown form id bounces back to the index", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/editor/forms"}}} =
             conn
             |> log_in(authed_user(:admin))
             |> live(~p"/editor/forms/#{Ash.UUID.generate()}")
  end

  test "clicking a palette type adds a field and selects it", %{conn: conn} do
    {form, [], lv, html} = builder(conn, authed_user(:admin))
    assert html =~ "No fields yet"

    html =
      lv
      |> element(~s(button[phx-click="add_field"][phx-value-type="email"]))
      |> render_click()

    assert [field] = CMS.form_fields_for!(form.id, authorize?: false)
    assert field.field_type == :email
    assert field.name == "email"
    # The new field is selected — its settings form is on screen.
    assert html =~ "field-settings-#{field.id}"

    # Adding a second field of the same type uniquifies the machine name.
    lv
    |> element(~s(button[phx-click="add_field"][phx-value-type="email"]))
    |> render_click()

    names = form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.map(& &1.name)
    assert Enum.sort(names) == ["email", "email_2"]
  end

  test "a dropdown field arrives with starter options", %{conn: conn} do
    {form, [], lv, _html} = builder(conn, authed_user(:admin))

    lv
    |> element(~s(button[phx-click="add_field"][phx-value-type="select"]))
    |> render_click()

    assert [field] = CMS.form_fields_for!(form.id, authorize?: false)
    assert field.field_type == :select
    assert length(field.options) == 2
  end

  test "the options panel edits the selected field live", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [field], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "email", label: "Email", field_type: :email}
      ])

    lv
    |> element(~s(button[phx-click="select_field"][phx-value-id="#{field.id}"]))
    |> render_click()

    html =
      lv
      |> form("#field-settings-#{field.id}", %{
        field: %{
          label: "Work email",
          name: "email",
          field_type: "email",
          width: "half",
          required: "true",
          placeholder: "you@company.com",
          default_value: "",
          help_text: "We reply within a day."
        }
      })
      |> render_change()

    updated = CMS.form_fields_for!(form.id, authorize?: false) |> hd()
    assert updated.label == "Work email"
    assert updated.width == :half
    assert updated.required
    assert updated.placeholder == "you@company.com"
    assert updated.help_text == "We reply within a day."

    # The canvas re-renders the public markup with the changes.
    assert html =~ "Work email"
    assert html =~ "you@company.com"
    assert html =~ "sm:col-span-3"
  end

  test "switching a field to dropdown seeds options so it stays valid", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [field], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "topic", label: "Topic", field_type: :string}
      ])

    lv
    |> element(~s(button[phx-click="select_field"][phx-value-id="#{field.id}"]))
    |> render_click()

    lv
    |> form("#field-settings-#{field.id}", %{
      field: %{label: "Topic", name: "topic", field_type: "select"}
    })
    |> render_change()

    updated = CMS.form_fields_for!(form.id, authorize?: false) |> hd()
    assert updated.field_type == :select
    assert updated.options != []
  end

  test "drag reorder persists positions", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [a, b, c], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "one", label: "one", position: 0},
        %{name: "two", label: "two", position: 1},
        %{name: "three", label: "three", position: 2}
      ])

    render_hook(lv, "reorder", %{"order" => [c.id, a.id, b.id]})

    names = form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.map(& &1.name)
    assert names == ["three", "one", "two"]
  end

  test "duplicating a field slots the copy right after the original", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [a, _b], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "email", label: "email", position: 0},
        %{name: "message", label: "message", position: 1}
      ])

    lv
    |> element(~s(button[phx-click="duplicate_field"][phx-value-id="#{a.id}"]))
    |> render_click()

    names = form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.map(& &1.name)
    assert names == ["email", "email_2", "message"]
  end

  test "deleting a field removes it from the canvas", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [field], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "email", label: "Email", field_type: :email}
      ])

    lv
    |> element(~s(button[phx-click="delete_field"][phx-value-id="#{field.id}"]))
    |> render_click()

    assert CMS.form_fields_for!(form.id, authorize?: false) == []
  end

  test "the general tab saves form settings, including the submit label", %{conn: conn} do
    {form, [], lv, _html} = builder(conn, authed_user(:admin))

    lv |> element(~s(nav button[phx-value-tab="general"])) |> render_click()

    html =
      lv
      |> form("section form[phx-submit=save_form]", %{
        form: %{
          name: "Contact us",
          slug: form.slug,
          description: "Say hi.",
          submit_label: "Send it",
          progress_indicator: "bar",
          active: "true"
        }
      })
      |> render_submit()

    assert html =~ "Saved."
    updated = CMS.get_form!(form.id, authorize?: false)
    assert updated.name == "Contact us"
    assert updated.submit_label == "Send it"
    assert updated.description == "Say hi."
    assert updated.progress_indicator == :bar
  end

  test "adding a page break shows the split marker on the canvas", %{conn: conn} do
    {form, [], lv, _html} = builder(conn, authed_user(:admin))

    html =
      lv
      |> element(~s(button[phx-click="add_field"][phx-value-type="page_break"]))
      |> render_click()

    assert [field] = CMS.form_fields_for!(form.id, authorize?: false)
    assert field.field_type == :page_break
    assert html =~ "Page break"
    assert html =~ "hero-scissors"
  end

  test "the confirmations tab manages type, redirect and conditional messages", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [_plan], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "plan", label: "Plan", field_type: :radio, options: ["basic", "pro"]}
      ])

    lv |> element(~s(nav button[phx-value-tab="confirmations"])) |> render_click()

    # Set the redirect URL first, then flip the type (auto-save on change).
    lv
    |> form("section form[phx-change=save_form_settings]", %{
      form: %{confirmation_type: "message", redirect_url: "/thanks", success_message: "Merci!"}
    })
    |> render_change()

    lv
    |> form("section form[phx-change=save_form_settings]", %{
      form: %{confirmation_type: "redirect", redirect_url: "/thanks", success_message: "Merci!"}
    })
    |> render_change()

    updated = CMS.get_form!(form.id, authorize?: false)
    assert updated.confirmation_type == :redirect
    assert updated.redirect_url == "/thanks"

    # Add a conditional message and fill in its rule.
    lv |> element(~s(button[phx-click="conf_add_variant"])) |> render_click()

    lv
    |> form("section form[phx-change=save_form_settings]", %{
      form: %{
        confirmation_type: "redirect",
        redirect_url: "/thanks",
        success_message: "Merci!",
        variants: %{
          "0" => %{
            message: "We'll call you.",
            logic: "all",
            rules: %{"0" => %{field: "plan", operator: "eq", value: "pro"}}
          }
        }
      }
    })
    |> render_change()

    updated = CMS.get_form!(form.id, authorize?: false)

    assert updated.confirmation_variants == [
             %{
               "message" => "We'll call you.",
               "conditions" => %{
                 "logic" => "all",
                 "rules" => [%{"field" => "plan", "operator" => "eq", "value" => "pro"}]
               }
             }
           ]
  end

  test "the notifications tab manages recipients, rules and the autoresponder", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [_guests], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "guests", label: "Guests", field_type: :integer}
      ])

    lv |> element(~s(nav button[phx-value-tab="notifications"])) |> render_click()

    # Enable conditional notification — a blank rule row is seeded.
    lv
    |> form("section form[phx-change=save_form_settings]", %{
      form: %{notify_email: "a@x.co, b@x.co", notify_logic_enabled: "true"}
    })
    |> render_change()

    seeded = CMS.get_form!(form.id, authorize?: false)
    assert seeded.notify_email == "a@x.co, b@x.co"
    assert seeded.notify_conditions["rules"] != []

    # Enable the autoresponder and fill its templates.
    lv
    |> form("section form[phx-change=save_form_settings]", %{
      form: %{
        notify_email: "a@x.co, b@x.co",
        notify_logic_enabled: "true",
        notify_conditions: %{
          logic: "any",
          rules: %{"0" => %{field: "guests", operator: "gt", value: "5"}}
        },
        autoresponder_enabled: "true"
      }
    })
    |> render_change()

    lv
    |> form("section form[phx-change=save_form_settings]", %{
      form: %{
        notify_email: "a@x.co, b@x.co",
        notify_logic_enabled: "true",
        notify_conditions: %{
          logic: "any",
          rules: %{"0" => %{field: "guests", operator: "gt", value: "5"}}
        },
        autoresponder_enabled: "true",
        autoresponder_subject: "Thanks {{guests}}",
        autoresponder_body: "See you soon."
      }
    })
    |> render_change()

    updated = CMS.get_form!(form.id, authorize?: false)
    assert updated.autoresponder_enabled
    assert updated.autoresponder_subject == "Thanks {{guests}}"

    assert updated.notify_conditions == %{
             "logic" => "any",
             "rules" => [%{"field" => "guests", "operator" => "gt", "value" => "5"}]
           }
  end

  test "the entries tab links the CSV export", %{conn: conn} do
    {form, [], lv, _html} = builder(conn, authed_user(:admin))

    html = lv |> element(~s(nav button[phx-value-tab="entries"])) |> render_click()
    assert html =~ "/editor/forms/#{form.id}/export.csv"
    assert html =~ "Export CSV"
  end

  test "the embed tab shows a copyable snippet", %{conn: conn} do
    {form, [], lv, _html} = builder(conn, authed_user(:admin))

    html = lv |> element(~s(nav button[phx-value-tab="embed"])) |> render_click()

    assert html =~ "/embed.js"
    assert html =~ "data-kiln-form=&quot;#{form.slug}&quot;"
    assert lv |> render_hook("copied", %{}) =~ "Embed code copied to clipboard."
  end

  test "the entries tab lists and deletes submissions", %{conn: conn} do
    admin = authed_user(:admin)
    {form, [], lv, _html} = builder(conn, admin)

    submission =
      CMS.create_form_submission!(
        %{form_id: form.id, data: %{"email" => "visitor@example.com"}},
        authorize?: false
      )

    html = lv |> element(~s(nav button[phx-value-tab="entries"])) |> render_click()
    assert html =~ "visitor@example.com"

    lv
    |> element(~s(button[phx-click="delete_submission"][phx-value-id="#{submission.id}"]))
    |> render_click()

    assert CMS.recent_form_submissions!(form.id, authorize?: false) == []
  end

  test "adding a radio field seeds starter options too", %{conn: conn} do
    {form, [], lv, _html} = builder(conn, authed_user(:admin))

    lv
    |> element(~s(button[phx-click="add_field"][phx-value-type="radio"]))
    |> render_click()

    assert [field] = CMS.form_fields_for!(form.id, authorize?: false)
    assert field.field_type == :radio
    assert length(field.options) == 2
  end

  test "a hidden field shows as a chip on the canvas", %{conn: conn} do
    {_form, [field], _lv, html} =
      builder(conn, authed_user(:admin), %{}, [
        %{name: "source", label: "Source", field_type: :hidden, default_value: "landing-a"}
      ])

    assert html =~ "Hidden field"
    assert html =~ field.name
  end

  test "the validation section stores typed rules", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [field], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "code", label: "Code", field_type: :string}
      ])

    lv
    |> element(~s(button[phx-click="select_field"][phx-value-id="#{field.id}"]))
    |> render_click()

    lv
    |> form("#field-settings-#{field.id}", %{
      field: %{
        label: "Code",
        name: "code",
        field_type: "string",
        validation: %{
          min_length: "3",
          max_length: "",
          pattern: "[A-Z]+",
          message: "letters only"
        }
      }
    })
    |> render_change()

    updated = form.id |> CMS.form_fields_for!(authorize?: false) |> hd()

    assert updated.validation == %{
             "min_length" => 3,
             "pattern" => "[A-Z]+",
             "message" => "letters only"
           }
  end

  test "enabling conditional logic seeds a blank rule; rule edits persist", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [_plan, note], lv, _html} =
      builder(conn, admin, %{}, [
        %{name: "plan", label: "Plan", field_type: :radio, options: ["basic", "pro"]},
        %{name: "note", label: "Note", field_type: :string, position: 1}
      ])

    lv
    |> element(~s(button[phx-click="select_field"][phx-value-id="#{note.id}"]))
    |> render_click()

    # Toggling the checkbox fires the settings form's phx-change with no rule
    # rows yet — the builder seeds one blank rule.
    lv
    |> form("#field-settings-#{note.id}", %{
      field: %{label: "Note", name: "note", field_type: "string", logic_enabled: "true"}
    })
    |> render_change()

    seeded = form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.find(&(&1.name == "note"))

    assert seeded.conditions == %{
             "logic" => "all",
             "rules" => [%{"field" => "", "operator" => "eq", "value" => ""}]
           }

    # Now the rule row renders — fill it in.
    lv
    |> form("#field-settings-#{note.id}", %{
      field: %{
        label: "Note",
        name: "note",
        field_type: "string",
        logic_enabled: "true",
        conditions: %{
          logic: "any",
          rules: %{"0" => %{field: "plan", operator: "eq", value: "pro"}}
        }
      }
    })
    |> render_change()

    updated =
      form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.find(&(&1.name == "note"))

    assert updated.conditions == %{
             "logic" => "any",
             "rules" => [%{"field" => "plan", "operator" => "eq", "value" => "pro"}]
           }

    # Add + remove rule rows via the panel buttons.
    lv |> element(~s(button[phx-click="logic_add_rule"])) |> render_click()

    two_rules =
      form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.find(&(&1.name == "note"))

    assert length(two_rules.conditions["rules"]) == 2

    lv
    |> element(~s(button[phx-click="logic_remove_rule"][phx-value-index="1"]))
    |> render_click()

    one_rule =
      form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.find(&(&1.name == "note"))

    assert length(one_rule.conditions["rules"]) == 1

    # Disabling clears the map.
    lv
    |> form("#field-settings-#{note.id}", %{
      field: %{label: "Note", name: "note", field_type: "string", logic_enabled: "false"}
    })
    |> render_change()

    cleared =
      form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.find(&(&1.name == "note"))

    assert cleared.conditions == %{}
  end

  test "the embed page carries conditions data and the conditions script", %{conn: conn} do
    admin = authed_user(:admin)
    form = CMS.create_form!(%{name: "Logic", slug: "fb-logic"}, actor: admin)

    CMS.create_form_field!(
      %{form_id: form.id, name: "plan", label: "Plan", field_type: :radio, options: ["a", "b"]},
      actor: admin
    )

    CMS.create_form_field!(
      %{
        form_id: form.id,
        name: "note",
        label: "Note",
        field_type: :string,
        position: 1,
        conditions: %{
          "logic" => "all",
          "rules" => [%{"field" => "plan", "operator" => "eq", "value" => "b"}]
        }
      },
      actor: admin
    )

    html = conn |> get("/forms/#{form.slug}/embed") |> html_response(200)

    assert html =~ "data-kiln-conditions="
    assert html =~ "form-conditions.js"
    assert html =~ ~s(data-kiln-field="note")
  end

  test "page breaks split the embed into pages with a steps indicator", %{conn: conn} do
    admin = authed_user(:admin)
    form = CMS.create_form!(%{name: "Paged", slug: "fb-paged"}, actor: admin)

    fields = [
      %{name: "email", label: "Email", field_type: :email, required: true},
      %{name: "step_2", label: "Next page", field_type: :page_break},
      %{name: "message", label: "Message", field_type: :text},
      %{name: "step_3", label: "Next page", field_type: :page_break},
      %{name: "rating", label: "Rating", field_type: :rating}
    ]

    for {attrs, position} <- Enum.with_index(fields) do
      CMS.create_form_field!(
        Map.merge(%{form_id: form.id, position: position}, attrs),
        actor: admin
      )
    end

    html = conn |> get("/forms/#{form.slug}/embed") |> html_response(200)

    # Three page containers, a steps indicator, translated nav labels for the
    # pager script, and the script itself.
    assert html =~ ~s(data-kiln-page="0")
    assert html =~ ~s(data-kiln-page="2")
    refute html =~ ~s(data-kiln-page="3")
    assert html =~ "data-kiln-steps"
    assert html =~ ~s(data-prev-label="Previous")
    assert html =~ ~s(data-next-label="Next")
    assert html =~ "form-pages.js"
  end

  test "a single-page form renders no steps indicator", %{conn: conn} do
    admin = authed_user(:admin)
    form = CMS.create_form!(%{name: "Flat", slug: "fb-flat"}, actor: admin)

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email},
      actor: admin
    )

    html = conn |> get("/forms/#{form.slug}/embed") |> html_response(200)

    assert html =~ ~s(data-kiln-page="0")
    refute html =~ ~s(data-kiln-page="1")
    refute html =~ "data-kiln-steps"
    refute html =~ "data-kiln-progress"
  end

  test "empty pages from stray breaks are dropped" do
    fields = [
      %{field_type: :page_break},
      %{field_type: :string},
      %{field_type: :page_break},
      %{field_type: :page_break},
      %{field_type: :text}
    ]

    pages = KilnCMSWeb.BlockComponents.split_form_pages(fields)
    assert length(pages) == 2
    assert [[%{field_type: :string}], [%{field_type: :text}]] = pages

    assert KilnCMSWeb.BlockComponents.split_form_pages([]) == [[]]
  end

  test "renaming a field cascades into rules that reference it", %{conn: conn} do
    admin = authed_user(:admin)

    {form, [plan, _dependent], lv, _html} =
      builder(
        conn,
        admin,
        %{
          notify_conditions: %{
            "logic" => "all",
            "rules" => [%{"field" => "plan", "operator" => "eq", "value" => "pro"}]
          }
        },
        [
          %{
            name: "plan",
            label: "Plan",
            field_type: :radio,
            options: ["basic", "pro"],
            position: 0
          },
          %{
            name: "company",
            label: "Company",
            field_type: :string,
            position: 1,
            conditions: %{
              "logic" => "all",
              "rules" => [%{"field" => "plan", "operator" => "eq", "value" => "pro"}]
            }
          }
        ]
      )

    lv
    |> element(~s(button[phx-click="select_field"][phx-value-id="#{plan.id}"]))
    |> render_click()

    lv
    |> form("#field-settings-#{plan.id}", %{
      field: %{label: "Plan", name: "plan_tier", field_type: "radio"}
    })
    |> render_change()

    # The dependent field's rule and the form's notify_conditions both follow.
    dependent =
      form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.find(&(&1.name == "company"))

    assert dependent.conditions["rules"] == [
             %{"field" => "plan_tier", "operator" => "eq", "value" => "pro"}
           ]

    updated_form = CMS.get_form!(form.id, authorize?: false)

    assert updated_form.notify_conditions["rules"] == [
             %{"field" => "plan_tier", "operator" => "eq", "value" => "pro"}
           ]
  end

  test "the public form renders the phase-2 field types", %{conn: conn} do
    admin = authed_user(:admin)
    form = CMS.create_form!(%{name: "Everything", slug: "fb-phase2"}, actor: admin)

    fields = [
      %{name: "intro", label: "About you", field_type: :heading},
      %{name: "sep", label: "Divider", field_type: :divider},
      %{name: "phone", label: "Phone", field_type: :phone},
      %{name: "site", label: "Site", field_type: :url},
      %{name: "amount", label: "Amount", field_type: :number},
      %{name: "plan", label: "Plan", field_type: :radio, options: ["basic", "pro"]},
      %{name: "colors", label: "Colors", field_type: :checkboxes, options: ["red", "blue"]},
      %{name: "stars", label: "Stars", field_type: :rating},
      %{name: "gdpr", label: "I agree", field_type: :consent, required: true},
      %{name: "source", label: "Source", field_type: :hidden, default_value: "landing-a"},
      %{
        name: "code",
        label: "Code",
        field_type: :string,
        validation: %{"min_length" => 3, "max_length" => 8, "pattern" => "[A-Z]+"}
      }
    ]

    for {attrs, position} <- Enum.with_index(fields) do
      CMS.create_form_field!(
        Map.merge(%{form_id: form.id, position: position}, attrs),
        actor: admin
      )
    end

    html = conn |> get("/forms/#{form.slug}/embed") |> html_response(200)

    assert html =~ "<h3"
    assert html =~ "About you"
    assert html =~ "<hr"
    assert html =~ ~s(type="tel")
    assert html =~ ~s(type="url")
    assert html =~ ~s(step="any")
    assert html =~ ~s(type="radio" name="plan" value="basic")
    assert html =~ ~s(name="colors[]")
    assert html =~ ~s(name="stars" value="5")
    assert html =~ ~s(type="hidden" name="source" value="landing-a")
    assert html =~ ~s(minlength="3")
    assert html =~ ~s(maxlength="8")
    assert html =~ ~s(pattern="[A-Z]+")
  end

  test "the public form renders placeholder, default, width and submit label", %{conn: conn} do
    admin = authed_user(:admin)

    form =
      CMS.create_form!(
        %{name: "Contact", slug: "fb-public", submit_label: "Send it"},
        actor: admin
      )

    CMS.create_form_field!(
      %{
        form_id: form.id,
        name: "email",
        label: "Email",
        field_type: :email,
        placeholder: "you@company.com",
        default_value: "hi@example.com",
        width: :half
      },
      actor: admin
    )

    html =
      conn
      |> get("/forms/#{form.slug}/embed")
      |> html_response(200)

    assert html =~ ~s(placeholder="you@company.com")
    assert html =~ ~s(value="hi@example.com")
    assert html =~ "sm:col-span-3"
    assert html =~ "Send it"
  end
end
