defmodule KilnCMS.CMS.FormFieldAutoresponderTest do
  @moduledoc """
  A form field and the autoresponder template that names it (#2343): a rename
  rewrites `[field:<old>]` to `[field:<new>]` in the form's subject and body,
  and a delete (or a move to another form) is refused while an enabled
  template still names the field — rather than leaving every confirmation from
  then on rendering the token as `""`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ffar-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # A form with `names` as fields (the first is the :email one), then the
  # autoresponder attrs — after the fields, since the template may only name
  # fields that exist at that save.
  defp form!(actor, names, autoresponder) do
    form =
      CMS.create_form!(%{name: "Contact", slug: "ffar-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    fields =
      for {name, position} <- Enum.with_index(names) do
        type = if position == 0, do: :email, else: :string

        CMS.create_form_field!(
          %{form_id: form.id, name: name, label: name, field_type: type, position: position},
          actor: actor
        )
      end

    {CMS.update_form!(form, autoresponder, actor: actor), fields}
  end

  defp enabled(subject, body),
    do: %{autoresponder_enabled: true, autoresponder_subject: subject, autoresponder_body: body}

  defp disabled(subject, body), do: %{enabled(subject, body) | autoresponder_enabled: false}

  defp reload(form, actor), do: CMS.get_form!(form.id, actor: actor)

  defp field_names(form, actor),
    do: form.id |> CMS.form_fields_for!(actor: actor) |> Enum.map(& &1.name)

  defp error_message(%Ash.Error.Invalid{errors: errors}),
    do: Enum.map_join(errors, "; ", &Exception.message/1)

  describe "a rename" do
    test "rewrites the enabled template's subject and body, and nothing else" do
      admin = user(:admin)

      {form, [email, _email2]} =
        form!(
          admin,
          ["email", "email2"],
          enabled(
            "Thanks, [field:email]!",
            "<p>[field:email] and [field:email] (not [field:email2]), from [form-name].</p>"
          )
        )

      assert {:ok, renamed} = CMS.update_form_field(email, %{name: "address"}, actor: admin)
      assert renamed.name == "address"

      form = reload(form, admin)
      assert form.autoresponder_subject == "Thanks, [field:address]!"

      assert form.autoresponder_body ==
               "<p>[field:address] and [field:address] (not [field:email2]), from [form-name].</p>"
    end

    test "keeps a disabled template in step too" do
      admin = user(:admin)
      {form, [email]} = form!(admin, ["email"], disabled("Hi [field:email]", "[field:email]"))

      CMS.update_form_field!(email, %{name: "address"}, actor: admin)

      form = reload(form, admin)
      assert form.autoresponder_enabled == false
      assert form.autoresponder_subject == "Hi [field:address]"
      assert form.autoresponder_body == "[field:address]"
    end

    test "writes nothing to a form whose template does not name the field" do
      admin = user(:admin)
      {form, [email]} = form!(admin, ["email"], enabled("Thanks!", "From [form-name]."))

      CMS.update_form_field!(email, %{name: "address"}, actor: admin)

      after_rename = reload(form, admin)
      assert after_rename.updated_at == form.updated_at
      assert after_rename.autoresponder_subject == "Thanks!"
    end

    test "succeeds over a stale token an earlier delete left in an enabled template" do
      admin = user(:admin)
      {form, [_email, a]} = form!(admin, ["email", "a"], enabled("[field:a]", "[field:a]"))

      # Before #2343 a delete never checked the template, so a production form
      # may hold a token for a field that no longer exists. Seeded, since that
      # delete is refused now.
      Ash.Seed.update!(form, %{autoresponder_body: "[field:a] and [field:gone]"})

      assert {:ok, _} = CMS.update_form_field(a, %{name: "b"}, actor: admin)

      form = reload(form, admin)
      assert form.autoresponder_subject == "[field:b]"
      assert form.autoresponder_body == "[field:b] and [field:gone]"
    end

    test "by an editor is refused, and the template is left alone" do
      admin = user(:admin)
      {form, [email]} = form!(admin, ["email"], enabled("Hi [field:email]", "b"))

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_form_field(email, %{name: "address"}, actor: user(:editor))

      assert field_names(form, admin) == ["email"]
      assert reload(form, admin).autoresponder_subject == "Hi [field:email]"
    end
  end

  describe "a delete" do
    test "is refused while the enabled template names the field" do
      admin = user(:admin)
      {form, [email]} = form!(admin, ["email"], enabled("Hi", "Thanks, [field:email]."))

      assert {:error, error} = CMS.destroy_form_field(email, actor: admin)

      assert error_message(error) =~
               "The autoresponder uses [field:email]: remove it from the Confirmations template first."

      assert field_names(form, admin) == ["email"]
    end

    test "goes through when the autoresponder is off" do
      admin = user(:admin)
      {form, [email]} = form!(admin, ["email"], disabled("Hi [field:email]", "[field:email]"))

      assert :ok = CMS.destroy_form_field(email, actor: admin)
      assert field_names(form, admin) == []
    end

    test "goes through when the enabled template does not name the field" do
      admin = user(:admin)

      {form, [_email, message]} =
        form!(admin, ["email", "message"], enabled("Hi [field:email]", "Thanks."))

      assert :ok = CMS.destroy_form_field(message, actor: admin)
      assert field_names(form, admin) == ["email"]
    end

    test "by an editor is refused" do
      admin = user(:admin)
      {form, [_email, message]} = form!(admin, ["email", "message"], disabled("s", "b"))

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_form_field(message, actor: user(:editor))

      assert field_names(form, admin) == ["email", "message"]
    end
  end

  describe "a move to another form" do
    test "is refused while the old form's enabled template names the field" do
      admin = user(:admin)
      {form, [email]} = form!(admin, ["email"], enabled("Hi [field:email]", "b"))
      {other, []} = form!(admin, [], disabled(nil, nil))

      assert {:error, error} = CMS.update_form_field(email, %{form_id: other.id}, actor: admin)
      assert error_message(error) =~ "the autoresponder uses [field:email]"

      assert field_names(form, admin) == ["email"]
      assert field_names(other, admin) == []
    end

    test "goes through when the old form's autoresponder is off" do
      admin = user(:admin)
      {form, [email]} = form!(admin, ["email"], disabled("Hi [field:email]", "b"))
      {other, []} = form!(admin, [], disabled(nil, nil))

      assert {:ok, _} = CMS.update_form_field(email, %{form_id: other.id}, actor: admin)
      assert field_names(form, admin) == []
      assert field_names(other, admin) == ["email"]
      assert reload(form, admin).autoresponder_subject == "Hi [field:email]"
    end
  end
end
