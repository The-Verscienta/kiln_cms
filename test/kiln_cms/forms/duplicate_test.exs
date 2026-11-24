defmodule KilnCMS.Forms.DuplicateTest do
  @moduledoc """
  `KilnCMS.Forms.Duplicate` (#2717): a form's copy — settings, fields, renamed
  autoresponder tokens and the autoresponder switch — commits in one
  transaction. A field that can't be copied leaves nothing behind, and a
  template the copy can't switch on is an outcome, not a failure.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FormField
  alias KilnCMS.Forms.Duplicate

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fd-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp form!(admin, attrs \\ %{}) do
    CMS.create_form!(
      Map.merge(%{name: "Contact", slug: "fd-#{System.unique_integer([:positive])}"}, attrs),
      actor: admin
    )
  end

  defp field!(form, admin, name, position) do
    CMS.create_form_field!(
      %{form_id: form.id, name: name, label: name, field_type: :string, position: position},
      actor: admin
    )
  end

  # Rows from before a rule refused them, written underneath the actions.
  defp legacy_field!(form, attrs) do
    Ash.Seed.seed!(
      FormField,
      Map.merge(%{form_id: form.id, label: "Legacy", field_type: :string}, attrs)
    )
  end

  # Ash's warning for an `after_transaction` hook run inside a transaction the
  # action didn't open. Only the form resources': `capture_log/1` also hears
  # other async tests.
  defp nested_hook_warning,
    do: ~r/`after_transaction` hooks on `KilnCMS\.CMS\.Form(Field)?\.\w+` are being executed/

  defp copies(form),
    do: CMS.list_forms!(authorize?: false, query: [filter: [slug: "#{form.slug}-copy"]])

  defp field_names(form),
    do: form.id |> CMS.form_fields_for!(authorize?: false) |> Enum.map(& &1.name)

  # Every org's rows: no read action lists fields across forms.
  defp field_count, do: KilnCMS.Repo.aggregate("form_fields", :count)

  test "copies settings and fields into an inactive form" do
    admin = user(:admin)

    form =
      form!(admin, %{
        active: true,
        success_message: "Merci!",
        embed_origins: ["https://acme.test"]
      })

    field!(form, admin, "email", 0)
    field!(form, admin, "message", 1)

    log =
      capture_log(fn ->
        assert {:ok, %{copy: copy, renames: [], autoresponder: :off_by_default}} =
                 Duplicate.run(form, actor: admin)

        send(self(), {:copy, copy})
      end)

    assert_received {:copy, copy}
    assert copy.slug == "#{form.slug}-copy"
    assert copy.name == "Contact (copy)"
    refute copy.active
    assert copy.success_message == "Merci!"
    assert copy.embed_origins == ["https://acme.test"]
    assert field_names(copy) == ["email", "message"]
    refute log =~ nested_hook_warning()
  end

  test "a field that fails halfway leaves no copy and no field behind" do
    admin = user(:admin)
    form = form!(admin)
    field!(form, admin, "email", 0)
    # A dropdown without options: the create action refuses it now.
    legacy_field!(form, %{name: "topic", field_type: :select, options: [], position: 1})
    field!(form, admin, "name", 2)
    before = field_count()

    capture_log(fn ->
      assert {:error, {:field, "topic", %Ash.Error.Invalid{}}} =
               Duplicate.run(form, actor: admin)
    end)

    assert copies(form) == []
    # `email` was created before `topic` was refused: rolled back with the copy.
    assert field_count() == before
  end

  test "a field named like the honeypot is renamed, and the copy's tokens follow" do
    admin = user(:admin)
    form = form!(admin)
    field!(form, admin, "email", 0)
    legacy_field!(form, %{name: "website", position: 1})

    form =
      CMS.update_form!(
        form,
        %{
          autoresponder_enabled: true,
          autoresponder_subject: "Hi [field:website]",
          autoresponder_body: "Sent to [field:email]."
        },
        actor: admin
      )

    assert {:ok, %{copy: copy, renames: [{"website", "website_2"}], autoresponder: :copied}} =
             Duplicate.run(form, actor: admin)

    assert copy.autoresponder_enabled
    assert copy.autoresponder_subject == "Hi [field:website_2]"
    assert field_names(copy) == ["email", "website_2"]
  end

  test "a template naming a field the copy lacks leaves its autoresponder off, and the rest commits" do
    admin = user(:admin)
    form = form!(admin)
    field!(form, admin, "email", 0)
    gone = field!(form, admin, "gone", 1)

    form =
      CMS.update_form!(
        form,
        %{
          autoresponder_enabled: true,
          autoresponder_subject: "About [field:gone]",
          autoresponder_body: "Sent to [field:email]."
        },
        actor: admin
      )

    # The field the template names is deleted underneath the actions: the
    # destroy action refuses that while the template still uses it (#2343),
    # but a stale token from before that rule is still out there.
    Ash.Seed.update!(gone, %{form_id: form!(admin).id})

    log =
      capture_log(fn ->
        assert {:ok, %{autoresponder: {:off, ["field:gone"]}}} =
                 Duplicate.run(form, actor: admin)
      end)

    refute log =~ nested_hook_warning()

    [copy] = copies(form)
    refute copy.autoresponder_enabled
    assert copy.autoresponder_subject == "About [field:gone]"
    assert field_names(copy) == ["email"]
  end

  test "a blank template leaves the copy's autoresponder off, with no tokens to name" do
    admin = user(:admin)
    form = form!(admin)
    field!(form, admin, "email", 0)

    # Switched on with a blank body underneath the actions, which refuse that.
    form =
      Ash.Seed.update!(form, %{
        autoresponder_enabled: true,
        autoresponder_subject: "Thanks",
        autoresponder_body: nil
      })

    assert {:ok, %{copy: copy, autoresponder: {:off, []}}} = Duplicate.run(form, actor: admin)
    refute copy.autoresponder_enabled
    assert field_names(copy) == ["email"]
  end

  test "an editor is refused and no copy is made" do
    admin = user(:admin)
    form = form!(admin)
    field!(form, admin, "email", 0)
    before = field_count()

    assert {:error, %Ash.Error.Forbidden{}} = Duplicate.run(form, actor: user(:editor))
    assert copies(form) == []
    assert field_count() == before
  end
end
