defmodule KilnCMS.CMS.FormFieldConditionTest do
  @moduledoc """
  The write-side rules of a form field's `condition` (#2262,
  `KilnCMS.CMS.Validations.FormFieldCondition`): what a rule may name, and
  what a field other fields' rules name can no longer have done to it.
  Rename carries those rules along (`Changes.RewriteConditionReferences`).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Forms
  alias KilnCMS.Forms.FieldOrder

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "condition-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role()
    })
  end

  defp role, do: :admin

  setup do
    actor = admin()

    form =
      CMS.create_form!(
        %{name: "F", slug: "cond-#{System.unique_integer([:positive])}", active: true},
        actor: actor
      )

    %{actor: actor, form: form}
  end

  defp field!(ctx, name, position, attrs \\ %{}) do
    CMS.create_form_field!(
      Map.merge(
        %{
          form_id: ctx.form.id,
          name: name,
          label: String.capitalize(name),
          field_type: :string,
          position: position
        },
        attrs
      ),
      actor: ctx.actor
    )
  end

  defp leaf(field, op \\ "eq", value \\ "x") do
    rule = %{"field" => field, "op" => op}
    if op in ["empty", "not_empty"], do: rule, else: Map.put(rule, "value", value)
  end

  defp show(rule), do: %{action: :show, rule: rule}

  defp set_condition(ctx, field, condition),
    do: CMS.update_form_field(field, %{condition: condition}, actor: ctx.actor)

  defp message(error) do
    error |> Ash.Error.to_error_class() |> Exception.message()
  end

  defp reload(field),
    do: CMS.form_fields_for!(field.form_id, authorize?: false) |> Enum.find(&(&1.id == field.id))

  describe "the field's own condition" do
    test "a valid condition on an earlier field is stored normalized", ctx do
      field!(ctx, "topic", 0, %{field_type: :select, options: ["a", "b"]})
      details = field!(ctx, "details", 1)

      assert {:ok, saved} =
               set_condition(ctx, details, %{
                 action: :hide,
                 rule: %{field: "topic", op: :eq, value: "a"}
               })

      assert saved.condition.action == :hide
      assert saved.condition.rule == %{"field" => "topic", "op" => "eq", "value" => "a"}
      assert reload(details).condition.rule == %{"field" => "topic", "op" => "eq", "value" => "a"}
    end

    test "a rule with a broken shape is refused", ctx do
      field!(ctx, "a", 0)
      b = field!(ctx, "b", 1)
      assert {:error, error} = set_condition(ctx, b, show(%{"field" => "a", "op" => "nope"}))
      assert message(error) =~ "is not a valid condition"
    end

    test "an over-long value is refused", ctx do
      field!(ctx, "a", 0)
      b = field!(ctx, "b", 1)
      long = String.duplicate("x", KilnCMS.Limits.line() + 1)
      assert {:error, error} = set_condition(ctx, b, show(leaf("a", "eq", long)))
      assert message(error) =~ "at most"
    end

    test "a rule naming the field itself is refused", ctx do
      a = field!(ctx, "a", 0)
      assert {:error, error} = set_condition(ctx, a, show(leaf("a")))
      assert message(error) =~ "itself"
    end

    test "a rule naming a field of another form is refused", ctx do
      other =
        CMS.create_form!(%{name: "G", slug: "other-#{System.unique_integer([:positive])}"},
          actor: ctx.actor
        )

      CMS.create_form_field!(
        %{form_id: other.id, name: "elsewhere", label: "E", field_type: :string},
        actor: ctx.actor
      )

      b = field!(ctx, "b", 1)
      assert {:error, error} = set_condition(ctx, b, show(leaf("elsewhere")))
      assert message(error) =~ "not a field on this form"
    end

    # Rules name only strictly earlier fields, which is what rules out a cycle.
    test "a rule naming a later field is refused", ctx do
      a = field!(ctx, "a", 0)
      field!(ctx, "b", 1)
      assert {:error, error} = set_condition(ctx, a, show(leaf("b")))
      assert message(error) =~ "comes after this field"
    end

    test "giving a field a rule on one whose rule names it is refused as a later reference",
         ctx do
      a = field!(ctx, "a", 0)
      b = field!(ctx, "b", 1)
      assert {:ok, _} = set_condition(ctx, b, show(leaf("a")))
      assert {:error, error} = set_condition(ctx, a, show(leaf("b")))
      assert message(error) =~ "comes after this field"
    end

    test "a hidden-type field takes no condition", ctx do
      field!(ctx, "a", 0)
      h = field!(ctx, "h", 1, %{field_type: :hidden})
      assert {:error, error} = set_condition(ctx, h, show(leaf("a")))
      assert message(error) =~ "a hidden field can't have a condition"
    end

    test "a hidden-type field may be named by a rule", ctx do
      field!(ctx, "utm", 0, %{field_type: :hidden})
      b = field!(ctx, "b", 1)
      assert {:ok, _} = set_condition(ctx, b, show(leaf("utm", "contains", "spring")))
    end

    test "an operator that doesn't fit the named field's type is refused", ctx do
      field!(ctx, "name", 0)
      field!(ctx, "stars", 1, %{field_type: :rating})
      c = field!(ctx, "c", 2)
      assert {:error, error} = set_condition(ctx, c, show(leaf("name", "gt", 3)))
      assert message(error) =~ "can't test"
      assert {:error, error} = set_condition(ctx, c, show(leaf("stars", "contains", "3")))
      assert message(error) =~ "can't test"
      assert {:ok, _} = set_condition(ctx, c, show(leaf("stars", "gt", 3)))
    end

    test "a field created with a condition on an earlier field is checked as well", ctx do
      field!(ctx, "a", 0)

      assert {:error, error} =
               CMS.create_form_field(
                 %{
                   form_id: ctx.form.id,
                   name: "z",
                   label: "Z",
                   field_type: :string,
                   position: 0,
                   condition: show(leaf("missing"))
                 },
                 actor: ctx.actor
               )

      assert message(error) =~ "not a field on this form"
    end

    test "only an admin may set a condition", ctx do
      field!(ctx, "a", 0)
      b = field!(ctx, "b", 1)

      editor =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "editor-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        })

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_form_field(b, %{condition: show(leaf("a"))}, actor: editor)
    end
  end

  describe "the fields other fields' rules name" do
    setup ctx do
      a = field!(ctx, "a", 0, %{field_type: :select, options: ["x", "y"]})
      b = field!(ctx, "b", 1)
      {:ok, b} = set_condition(ctx, b, show(leaf("a", "eq", "x")))
      %{a: a, b: b}
    end

    test "deleting one is refused, naming the dependents", ctx do
      assert {:error, error} = CMS.destroy_form_field(ctx.a, actor: ctx.actor)
      assert message(error) =~ "is used in the conditions of “B”"
      assert reload(ctx.a)
    end

    test "deleting one is allowed once the condition is removed", ctx do
      assert {:ok, _} = set_condition(ctx, ctx.b, nil)
      assert :ok = CMS.destroy_form_field(ctx.a, actor: ctx.actor)
    end

    test "retyping one so a dependent's operator no longer fits is refused", ctx do
      {:ok, _} = set_condition(ctx, ctx.b, show(leaf("a", "contains", "x")))

      assert {:error, error} =
               CMS.update_form_field(ctx.a, %{field_type: :rating, options: []}, actor: ctx.actor)

      assert message(error) =~ "test this field in a way this type can't answer"
    end

    test "retyping one keeps working while the dependents' operators still fit", ctx do
      assert {:ok, _} = CMS.update_form_field(ctx.a, %{field_type: :string}, actor: ctx.actor)
    end

    test "moving one to another form is refused", ctx do
      other =
        CMS.create_form!(%{name: "G", slug: "move-#{System.unique_integer([:positive])}"},
          actor: ctx.actor
        )

      assert {:error, error} =
               CMS.update_form_field(ctx.a, %{form_id: other.id}, actor: ctx.actor)

      assert message(error) =~ "is used in the conditions of"
    end

    test "moving a field that has a condition to another form is refused", ctx do
      other =
        CMS.create_form!(%{name: "G", slug: "move-#{System.unique_integer([:positive])}"},
          actor: ctx.actor
        )

      assert {:error, error} =
               CMS.update_form_field(ctx.b, %{form_id: other.id}, actor: ctx.actor)

      assert message(error) =~ "has a condition"
    end

    test "moving a field to another form while giving it a condition is refused", ctx do
      other =
        CMS.create_form!(%{name: "G", slug: "move-#{System.unique_integer([:positive])}"},
          actor: ctx.actor
        )

      CMS.create_form_field!(
        %{form_id: other.id, name: "there", label: "There", field_type: :string, position: 0},
        actor: ctx.actor
      )

      loner = field!(ctx, "loner", 9)

      assert {:error, error} =
               CMS.update_form_field(
                 loner,
                 %{form_id: other.id, position: 5, condition: show(leaf("there"))},
                 actor: ctx.actor
               )

      assert message(error) =~ "has a condition"
      assert reload(loner).form_id == ctx.form.id
    end

    test "a rename leaves the rule of a field this release doesn't know alone", ctx do
      KilnCMS.NewerReleaseRows.form_field_type!(ctx.b.id)

      assert {:ok, renamed} = CMS.update_form_field(ctx.a, %{name: "choice"}, actor: ctx.actor)
      assert renamed.__metadata__.condition_rewrites == []
      assert reload(ctx.b).condition.rule == leaf("a", "eq", "x")
    end

    test "a position change that puts a dependent first is refused", ctx do
      assert {:error, error} = CMS.update_form_field(ctx.a, %{position: 5}, actor: ctx.actor)
      assert message(error) =~ "“B” is shown based on “A”, which would come after it"
      assert {:error, _} = CMS.update_form_field(ctx.b, %{position: -1}, actor: ctx.actor)
    end

    test "renaming one rewrites the dependents' rules in the same write", ctx do
      assert {:ok, renamed} = CMS.update_form_field(ctx.a, %{name: "choice"}, actor: ctx.actor)
      assert renamed.__metadata__.condition_rewrites == ["B"]
      assert reload(ctx.b).condition.rule == %{"field" => "choice", "op" => "eq", "value" => "x"}
    end

    test "a rename that would put the renamed field after a dependent is refused", ctx do
      # Two fields at one position (an older release's data) are ordered by
      # name: `m` before `z`, so `z` may name `m`. Renamed `zz`, it wouldn't.
      m = field!(ctx, "m", 7)
      z = field!(ctx, "z", 7)
      {:ok, _} = set_condition(ctx, z, show(leaf("m", "not_empty")))

      assert {:error, error} = CMS.update_form_field(m, %{name: "zz"}, actor: ctx.actor)
      assert message(error) =~ "“Z” is shown based on “M”, which would come after it"
      assert reload(m).name == "m"
      assert reload(z).condition.rule == leaf("m", "not_empty")
    end

    test "a label edit on a field whose own rule dangles still saves", ctx do
      # An older release let the rule outlive the field it named.
      KilnCMS.Repo.query!(
        "UPDATE form_fields SET condition = $1 WHERE id = $2",
        [%{"action" => "show", "rule" => leaf("gone")}, Ecto.UUID.dump!(ctx.b.id)]
      )

      b = reload(ctx.b)
      assert {:ok, _} = CMS.update_form_field(b, %{label: "Renamed label"}, actor: ctx.actor)
      assert {:ok, _} = CMS.update_form_field(b, %{name: "b2"}, actor: ctx.actor)
    end
  end

  describe "reorder (FieldOrder)" do
    setup ctx do
      a = field!(ctx, "a", 0)
      b = field!(ctx, "b", 1)
      c = field!(ctx, "c", 2)
      {:ok, c} = set_condition(ctx, c, show(leaf("a", "not_empty")))
      %{a: a, b: b, c: c}
    end

    test "an order putting a dependent before the field it names is refused whole", ctx do
      fields = CMS.form_fields_for!(ctx.form.id, authorize?: false)

      assert {:error, {:conditions, dependent, target}} =
               FieldOrder.reorder(fields, [ctx.c.id, ctx.b.id, ctx.a.id], actor: ctx.actor)

      assert {dependent.name, target.name} == {"c", "a"}

      assert Enum.map(CMS.form_fields_for!(ctx.form.id, authorize?: false), & &1.name) ==
               ~w(a b c)
    end

    test "an order keeping every rule's fields before it is saved", ctx do
      fields = CMS.form_fields_for!(ctx.form.id, authorize?: false)
      assert :ok = FieldOrder.reorder(fields, [ctx.b.id, ctx.a.id, ctx.c.id], actor: ctx.actor)

      assert Enum.map(CMS.form_fields_for!(ctx.form.id, authorize?: false), & &1.name) ==
               ~w(b a c)
    end

    test "a rule already out of order doesn't block an unrelated reorder", ctx do
      # Written by an older release: `a` names `c`, which comes after it.
      KilnCMS.Repo.query!(
        "UPDATE form_fields SET condition = $1 WHERE id = $2",
        [%{"action" => "show", "rule" => leaf("c")}, Ecto.UUID.dump!(ctx.a.id)]
      )

      fields = CMS.form_fields_for!(ctx.form.id, authorize?: false)
      assert :ok = FieldOrder.reorder(fields, [ctx.a.id, ctx.c.id, ctx.b.id], actor: ctx.actor)
    end
  end

  describe "a rule an older release left dangling" do
    setup ctx do
      field!(ctx, "kind", 0, %{field_type: :select, options: ["a", "b"]})
      details = field!(ctx, "details", 1, %{required: true})

      KilnCMS.Repo.query!(
        "UPDATE form_fields SET condition = $1 WHERE id = $2",
        [%{"action" => "show", "rule" => leaf("removed_field")}, Ecto.UUID.dump!(details.id)]
      )

      %{details: details}
    end

    test "leaves its field shown and its own required in force", ctx do
      form = Forms.get_active(ctx.form.slug)
      refute Forms.conditional?(form)
      assert {:error, %{"details" => "is required"}} = Forms.submit(form, %{"kind" => "a"})
    end
  end
end
