defmodule KilnCMS.Forms.TemplatesTest do
  @moduledoc """
  Built-in form templates (`KilnCMS.Forms.Templates`): the compile-time
  registry, and template instantiation into a real form + fields.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Forms.Templates

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "tmpl-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "tmpl-#{System.unique_integer([:positive])}"

  test "the registry lists the built-in templates" do
    templates = Templates.list()

    assert length(templates) == 6

    for template <- templates do
      assert is_binary(template.key)
      assert is_binary(template.name) and template.name != ""
      assert is_list(template.fields) and template.fields != []
    end

    assert %{name: "Contact form"} = Templates.get("contact")
    assert Templates.get("does-not-exist") == nil
  end

  test "instantiating a template creates the form and its fields in order" do
    actor = admin()
    slug = slug()

    assert {:ok, form} =
             Templates.instantiate(Templates.get("contact"), "My contact form", slug,
               actor: actor
             )

    assert form.name == "My contact form"
    assert form.slug == slug
    assert form.success_message =~ "Thanks"
    assert form.submit_label == "Send message"

    fields = CMS.form_fields_for!(form.id, authorize?: false)
    assert Enum.map(fields, & &1.name) == ["full_name", "email", "subject", "message"]
    assert Enum.map(fields, & &1.position) == [0, 1, 2, 3]

    email = Enum.find(fields, &(&1.name == "email"))
    assert email.field_type == :email
    assert email.required
    assert email.width == :half
  end

  test "every built-in template instantiates cleanly (fields are valid)" do
    actor = admin()

    for template <- Templates.list() do
      assert {:ok, form} =
               Templates.instantiate(template, template.name, slug(), actor: actor)

      fields = CMS.form_fields_for!(form.id, authorize?: false)
      assert length(fields) == length(template.fields), "template #{template.key} lost fields"
    end
  end

  test "a duplicate slug fails and leaves nothing behind" do
    actor = admin()
    slug = slug()

    assert {:ok, _form} =
             Templates.instantiate(Templates.get("contact"), "First", slug, actor: actor)

    assert {:error, _error} =
             Templates.instantiate(Templates.get("contact"), "Second", slug, actor: actor)

    assert [form] = CMS.list_forms!(authorize?: false, query: [filter: [slug: slug]])
    assert form.name == "First"
  end
end
