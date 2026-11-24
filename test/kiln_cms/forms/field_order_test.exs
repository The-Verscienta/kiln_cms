defmodule KilnCMS.Forms.FieldOrderTest do
  @moduledoc """
  `KilnCMS.Forms.FieldOrder` (#2717): a form's field order is saved all or
  nothing. A refused write rolls back every position before it and names the
  field, where the builder used to discard the results and leave half an
  order saved.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FormField
  alias KilnCMS.Forms.FieldOrder

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fo-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp form!(admin) do
    CMS.create_form!(%{name: "T", slug: "fo-#{System.unique_integer([:positive])}"},
      actor: admin
    )
  end

  defp field!(form, admin, name, position) do
    CMS.create_form_field!(
      %{form_id: form.id, name: name, label: name, field_type: :string, position: position},
      actor: admin
    )
  end

  # A row from before `FormFieldConfig` refused it: a dropdown without
  # options. Every update of it — a position-only one too — is refused.
  defp legacy_select!(form, position) do
    Ash.Seed.seed!(FormField, %{
      form_id: form.id,
      name: "topic",
      label: "Topic",
      field_type: :select,
      options: [],
      position: position
    })
  end

  # Ash's warning for an `after_transaction` hook run inside a transaction the
  # action didn't open. Only the form resources': `capture_log/1` also hears
  # other async tests.
  defp nested_hook_warning,
    do: ~r/`after_transaction` hooks on `KilnCMS\.CMS\.Form(Field)?\.\w+` are being executed/

  defp fields(form), do: CMS.form_fields_for!(form.id, authorize?: false)

  defp positions(form), do: form |> fields() |> Map.new(&{&1.name, &1.position})

  defp ids(form, names) do
    by_name = form |> fields() |> Map.new(&{&1.name, &1.id})
    Enum.map(names, &Map.fetch!(by_name, &1))
  end

  test "saves every moved field's position" do
    admin = user(:admin)
    form = form!(admin)
    for {name, i} <- Enum.with_index(~w(a b c)), do: field!(form, admin, name, i)

    log =
      capture_log(fn ->
        assert :ok = FieldOrder.reorder(fields(form), ids(form, ~w(c a b)), actor: admin)
      end)

    assert positions(form) == %{"c" => 0, "a" => 1, "b" => 2}
    refute log =~ nested_hook_warning()
  end

  test "a refused write rolls back the whole order and names the field" do
    admin = user(:admin)
    form = form!(admin)
    field!(form, admin, "a", 0)
    legacy_select!(form, 1)
    field!(form, admin, "c", 2)

    log =
      capture_log(fn ->
        # `c` and `a` are written before `topic` is refused.
        assert {:error, {:field, %FormField{name: "topic"}, %Ash.Error.Invalid{}}} =
                 FieldOrder.reorder(fields(form), ids(form, ~w(c a topic)), actor: admin)
      end)

    assert positions(form) == %{"a" => 0, "topic" => 1, "c" => 2}
    refute log =~ nested_hook_warning()
  end

  test "unknown ids are ignored and fields already in place are not written" do
    admin = user(:admin)
    form = form!(admin)
    field!(form, admin, "a", 0)
    field!(form, admin, "b", 1)
    # Stays at index 2, so it is never written and its refusal can't block
    # the reorder.
    legacy_select!(form, 2)
    order = ids(form, ~w(b a topic)) ++ [Ecto.UUID.generate()]

    assert :ok = FieldOrder.reorder(fields(form), order, actor: admin)
    assert positions(form) == %{"b" => 0, "a" => 1, "topic" => 2}
  end

  test "an editor is refused and nothing moves" do
    admin = user(:admin)
    form = form!(admin)
    for {name, i} <- Enum.with_index(~w(a b)), do: field!(form, admin, name, i)

    assert {:error, {:field, %FormField{}, %Ash.Error.Forbidden{}}} =
             FieldOrder.reorder(fields(form), ids(form, ~w(b a)), actor: user(:editor))

    assert positions(form) == %{"a" => 0, "b" => 1}
  end

  test "nothing to move is not a write" do
    admin = user(:admin)
    form = form!(admin)
    field!(form, admin, "a", 0)

    assert :ok = FieldOrder.reorder(fields(form), ids(form, ~w(a)), actor: user(:editor))
  end
end
