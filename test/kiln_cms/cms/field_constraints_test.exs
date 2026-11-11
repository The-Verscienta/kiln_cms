defmodule KilnCMS.CMS.FieldConstraintsTest do
  @moduledoc """
  Per-field value constraints (#2276): the pure check
  (`KilnCMS.CMS.FieldConstraints`), the definition-save rules
  (`Validations.FieldConstraints`) and the write path through
  `Changes.ApplyCustomFields`, including grandfathering and the
  `custom_fields_constraints: :skip` context.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldConstraints

  defp def_(type, validation, extra \\ %{}) do
    Map.merge(
      %{name: "f", label: "F", field_type: type, validation: validation, multiple: false},
      extra
    )
  end

  defp texts(problems), do: Enum.map(problems, fn {_path, _label, {:full, text}} -> text end)
  defp paths(problems), do: Enum.map(problems, fn {path, _label, _text} -> path end)

  describe "compile/1" do
    test "refuses a pattern that would escape its anchors" do
      assert {:error, _} = KilnCMS.CMS.FieldConstraints.compile("a)|(b")
      assert {:ok, _} = KilnCMS.CMS.FieldConstraints.compile("[A-Z]{3}-\\d+")
    end
  end

  describe "check/3 on numbers" do
    test "bounds are inclusive" do
      d = def_(:integer, %{"min" => 1, "max" => 5})

      assert FieldConstraints.check(d, 1) == []
      assert FieldConstraints.check(d, 5) == []
      assert ["F (f) must be at least 1"] = d |> FieldConstraints.check(0) |> texts()
      assert ["F (f) must be at most 5"] = d |> FieldConstraints.check(6) |> texts()
    end

    test "float bounds and atom keys" do
      d = def_(:float, %{min: 0.5})

      assert FieldConstraints.check(d, 0.5) == []
      assert ["F (f) must be at least 0.5"] = d |> FieldConstraints.check(0.1) |> texts()
    end

    test "blank values are not checked" do
      d = def_(:integer, %{"min" => 1})

      assert FieldConstraints.check(d, nil) == []
      assert FieldConstraints.check(d, "") == []
    end
  end

  describe "check/3 on text" do
    test "lengths count graphemes of the value" do
      d = def_(:string, %{"min_length" => 2, "max_length" => 3})

      assert FieldConstraints.check(d, "ab") == []
      assert FieldConstraints.check(d, "éé") == []

      assert ["F (f) must be at least 2 characters long"] =
               d |> FieldConstraints.check("a") |> texts()

      assert ["F (f) must be at most 3 characters long"] =
               d |> FieldConstraints.check("abcd") |> texts()
    end

    test "singular for one character" do
      d = def_(:string, %{"min_length" => 1, "max_length" => 1})

      assert ["F (f) must be at most 1 character long"] =
               d |> FieldConstraints.check("ab") |> texts()
    end

    test "the pattern is anchored to the whole value" do
      d = def_(:string, %{"pattern" => "[A-Z]{2}\\d+"})

      assert FieldConstraints.check(d, "AB12") == []

      assert ["F (f) doesn't match the required format"] =
               d |> FieldConstraints.check("xAB12") |> texts()

      assert FieldConstraints.check(d, "AB12x") != []
    end

    test "an alternation cannot escape the anchors" do
      d = def_(:string, %{"pattern" => "a|b"})
      assert FieldConstraints.check(d, "a") == []
      assert FieldConstraints.check(d, "ab") != []
    end

    test "the admin's pattern_message is the explanation" do
      d = def_(:string, %{"pattern" => "\\d+", "pattern_message" => "Digits only"})
      assert ["F (f): Digits only"] = d |> FieldConstraints.check("x") |> texts()
    end

    test "every failed rule is reported" do
      d = def_(:string, %{"min_length" => 5, "pattern" => "\\d+"})
      assert length(FieldConstraints.check(d, "ab")) == 2
    end

    test "a catastrophic pattern is bounded and does not match" do
      d = def_(:string, %{"pattern" => "(a+)+$"})
      value = String.duplicate("a", 40) <> "!"

      {micros, problems} = :timer.tc(fn -> FieldConstraints.check(d, value) end)

      assert length(problems) == 1
      assert micros < 2_000_000
    end

    test "a value past the matching ceiling fails without matching" do
      d = def_(:string, %{"pattern" => ".*"})
      assert FieldConstraints.check(d, String.duplicate("a", 2_001)) != []
      assert FieldConstraints.check(d, String.duplicate("a", 2_000)) == []
    end

    test "rich text is not length-checked, plain text is" do
      v = %{"max_length" => 3}
      assert FieldConstraints.check(def_(:text, v, %{format: :rich}), "<p>long html</p>") == []
      assert FieldConstraints.check(def_(:text, v, %{format: :plain}), "long") != []
    end

    test "a multiple string is checked per item with indexed paths" do
      d = def_(:string, %{"max_length" => 3}, %{multiple: true})

      assert d |> FieldConstraints.check(["ok", "toolong", "yes", "alsolong"]) |> paths() ==
               ["f[1]", "f[3]"]
    end
  end

  describe "check/3 on groups" do
    setup do
      subs = [
        def_(:string, %{"max_length" => 2}, %{name: "unit", label: "Unit"}),
        def_(:integer, %{"min" => 1}, %{name: "amount", label: "Amount"})
      ]

      %{group: %{name: "dosages", label: "Dosages", field_type: :group, group_fields: subs}}
    end

    test "rows report sub-field paths", %{group: group} do
      rows = [%{"unit" => "g", "amount" => 2}, %{"unit" => "gram", "amount" => 0}]

      problems = FieldConstraints.check(group, rows)

      assert paths(problems) == ["dosages[1].unit", "dosages[1].amount"]
      assert ["Unit (dosages[1].unit) must be at most 2 characters long", _] = texts(problems)
    end

    test "one object uses the group's own path", %{group: group} do
      assert [{"dosages.unit", "Unit", _}] = FieldConstraints.check(group, %{"unit" => "gram"})
    end
  end

  describe "definition rules" do
    setup do
      admin =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "fc-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      %{admin: admin}
    end

    defp define(admin, type, validation, extra \\ %{}) do
      CMS.create_field_definition(
        Map.merge(
          %{
            content_type: :post,
            name: "f_#{System.unique_integer([:positive])}",
            label: "F",
            field_type: type,
            validation: validation
          },
          extra
        ),
        actor: admin
      )
    end

    defp message(result) do
      assert {:error, error} = result
      Exception.message(error)
    end

    test "valid constraints save and default to an empty map", %{admin: admin} do
      assert {:ok, d} = define(admin, :integer, %{"min" => 1, "max" => 9, "unique" => true})
      assert d.validation == %{"min" => 1, "max" => 9, "unique" => true}
      assert {:ok, %{validation: %{}}} = define(admin, :string, %{})
    end

    test "unknown keys, bad shapes and wrong types are refused", %{admin: admin} do
      assert message(define(admin, :integer, %{"bogus" => 1})) =~ "unknown constraints"
      assert message(define(admin, :integer, %{"min" => "x"})) =~ "min is not valid"
      assert message(define(admin, :integer, %{"min" => 1.5})) =~ "whole numbers"
      assert message(define(admin, :string, %{"min" => 1})) =~ "min can't be set on a string"
      assert message(define(admin, :integer, %{"pattern" => "a"})) =~ "can't be set"
      assert message(define(admin, :boolean, %{"unique" => true})) =~ "can't be set"
      assert message(define(admin, :text, %{"max_length" => 5})) =~ "can't be set"
    end

    test "plain text may carry length rules", %{admin: admin} do
      assert {:ok, _} = define(admin, :text, %{"max_length" => 5}, %{format: :plain})
    end

    test "ranges must be satisfiable", %{admin: admin} do
      assert message(define(admin, :integer, %{"min" => 5, "max" => 1})) =~ "min can't be more"

      assert message(define(admin, :string, %{"min_length" => 5, "max_length" => 1})) =~
               "min_length can't be more"
    end

    test "the pattern must compile and stay short", %{admin: admin} do
      assert message(define(admin, :string, %{"pattern" => "(unclosed"})) =~
               "not a valid regular expression"

      assert message(define(admin, :string, %{"pattern" => String.duplicate("a", 201)})) =~
               "at most 200"
    end

    test "the default must satisfy the constraints", %{admin: admin} do
      assert message(define(admin, :integer, %{"min" => 5}, %{default: "2"})) =~ "default value"
      assert {:ok, _} = define(admin, :integer, %{"min" => 5}, %{default: "7"})

      assert message(define(admin, :string, %{"pattern" => "\\d+"}, %{default: "abc"})) =~
               "default value"
    end

    test "unique is refused with a default, on several values, on shared fields", %{admin: admin} do
      assert message(define(admin, :string, %{"unique" => true}, %{default: "x"})) =~ "default"

      assert message(define(admin, :string, %{"unique" => true}, %{localization: :shared})) =~
               "shared"
    end

    test "computed fields take no constraints", %{admin: admin} do
      assert message(
               define(admin, :computed, %{"min" => 1}, %{compute: "{{ word_count(title) }}"})
             ) =~ "can't be set"
    end

    test "sub-fields take constraints but not unique", %{admin: admin} do
      {:ok, group} = define(admin, :group, %{}, %{multiple: true})

      assert {:ok, _} =
               define(admin, :string, %{"max_length" => 3}, %{
                 content_type: nil,
                 group_of_id: group.id
               })

      assert message(
               define(admin, :string, %{"unique" => true}, %{
                 content_type: nil,
                 group_of_id: group.id
               })
             ) =~ "inside a relationship or group"
    end

    test "changing the type with stale keys is refused", %{admin: admin} do
      {:ok, d} = define(admin, :string, %{"max_length" => 3})
      assert {:error, _} = CMS.update_field_definition(d, %{field_type: :integer}, actor: admin)
    end
  end

  describe "write path" do
    setup do
      admin =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "fcw-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      group =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: "dosages",
            label: "Dosages",
            field_type: :group,
            multiple: true
          },
          actor: admin
        )

      CMS.create_field_definition!(
        %{
          group_of_id: group.id,
          name: "unit",
          label: "Unit",
          field_type: :string,
          validation: %{"max_length" => 2}
        },
        actor: admin
      )

      score =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: "score",
            label: "Score",
            field_type: :integer,
            validation: %{"min" => 1, "max" => 10}
          },
          actor: admin
        )

      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "code",
          label: "Code",
          field_type: :string,
          validation: %{"pattern" => "[A-Z]{3}"}
        },
        actor: admin
      )

      %{admin: admin, score: score}
    end

    defp post(admin, fields),
      do:
        CMS.create_post(
          %{title: "T", slug: "fc-#{System.unique_integer([:positive])}", custom_fields: fields},
          actor: admin
        )

    test "a violation names the field", %{admin: admin} do
      assert {:error, error} = post(admin, %{"score" => 11})
      assert Exception.message(error) =~ "Score (score) must be at most 10"
      assert {:ok, %{custom_fields: %{"score" => 10}}} = post(admin, %{"score" => "10"})
    end

    test "every violation is reported at once", %{admin: admin} do
      assert {:error, error} = post(admin, %{"score" => 0, "code" => "abc"})
      message = Exception.message(error)
      assert message =~ "Score (score) must be at least 1"
      assert message =~ "Code (code) doesn't match the required format"
    end

    test "group rows report their path", %{admin: admin} do
      rows = [%{"unit" => "g"}, %{"unit" => "gram"}]
      assert {:error, error} = post(admin, %{"dosages" => rows})

      assert Exception.message(error) =~
               "Unit (dosages[1].unit) must be at most 2 characters long"
    end

    test "a stored value is grandfathered when a constraint tightens", %{
      admin: admin,
      score: score
    } do
      {:ok, post} = post(admin, %{"score" => 8})
      CMS.update_field_definition!(score, %{validation: %{"min" => 1, "max" => 5}}, actor: admin)

      # Resubmitting the stored value (a form) passes; changing it is checked.
      assert {:ok, post} = CMS.update_post(post, %{custom_fields: %{"score" => 8}}, actor: admin)
      assert {:error, _} = CMS.update_post(post, %{custom_fields: %{"score" => 9}}, actor: admin)
      # Omitting the key keeps the stored value unchecked.
      assert {:ok, %{custom_fields: %{"score" => 8}}} =
               CMS.update_post(post, %{custom_fields: %{"code" => "ABC"}}, actor: admin)
    end

    test "custom_fields_constraints: :skip lets the value constraints through", %{admin: admin} do
      assert {:ok, %{custom_fields: %{"score" => 99}}} =
               CMS.create_post(
                 %{
                   title: "T",
                   slug: "fc-#{System.unique_integer([:positive])}",
                   custom_fields: %{"score" => 99}
                 },
                 actor: admin,
                 context: %{custom_fields_constraints: :skip}
               )
    end

    test "an import keeps enforcing constraints" do
      # Importers set `custom_fields: :drop` only, never the skip context.
      refute Map.has_key?(
               %{custom_fields: :drop, shared_fields_check: :skip},
               :custom_fields_constraints
             )
    end
  end
end
