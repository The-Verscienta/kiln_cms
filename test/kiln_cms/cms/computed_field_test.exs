defmodule KilnCMS.CMS.ComputedFieldTest do
  @moduledoc """
  The built-in computed field type (#429) end to end: definition-time formula
  validation, derivation on write, the read-only guarantee, and recomputation
  at fire time so a formula change reaches published content.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FieldTypes
  alias KilnCMS.Firing

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "computed-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "computed-#{System.unique_integer([:positive])}"

  defp define!(actor, compute, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :page,
          name: "derived_#{System.unique_integer([:positive])}",
          label: "Derived",
          field_type: :computed,
          compute: compute
        },
        attrs
      ),
      actor: actor
    )
  end

  defp blocks(text), do: [%{type: :rich_text, content: "<p>#{text}</p>", order: 0}]

  describe "registration and definition-time validation" do
    test "it registers as a field type without being a core one" do
      assert :computed in FieldDefinition.field_types()
      refute :computed in FieldTypes.core()
      assert FieldTypes.get(:computed) == KilnCMS.CMS.FieldTypes.Computed
    end

    test "a computed field needs a formula" do
      assert {:error, error} =
               CMS.create_field_definition(
                 %{content_type: :page, name: "no_formula", label: "X", field_type: :computed},
                 actor: admin()
               )

      assert Exception.message(error) =~ "needs a formula"
    end

    test "a broken formula is caught when the field is defined, not per record" do
      assert {:error, error} =
               CMS.create_field_definition(
                 %{
                   content_type: :page,
                   name: "bad_formula",
                   label: "X",
                   field_type: :computed,
                   compute: "{{ slugfy(title) }}"
                 },
                 actor: admin()
               )

      assert Exception.message(error) =~ "unknown function slugfy/1"
    end

    test "a formula on a non-computed type is cleared, not rejected" do
      # Rejecting would be a dead end: the admin form renders the formula input
      # only for `:computed`, so switching an existing computed field to another
      # type submits no `compute` and the error would land on a field with no
      # rendered input.
      assert {:ok, definition} =
               CMS.create_field_definition(
                 %{
                   content_type: :page,
                   name: "plain_string",
                   label: "X",
                   field_type: :string,
                   compute: "{{ title }}"
                 },
                 actor: admin()
               )

      assert definition.compute == nil
    end

    test "an existing computed field can be switched to another type" do
      actor = admin()
      definition = define!(actor, "{{ slugify(title) }}")

      assert {:ok, switched} =
               CMS.update_field_definition(definition, %{field_type: :string}, actor: actor)

      assert switched.field_type == :string
      assert switched.compute == nil
    end

    test "a computed field can't be required" do
      # There is no editor to require anything of — the input is read-only — so a
      # formula that evaluates blank would attach an uncorrectable error to every
      # create and every update of the whole content type.
      assert {:error, error} =
               CMS.create_field_definition(
                 %{
                   content_type: :page,
                   name: "must_derive",
                   label: "X",
                   field_type: :computed,
                   compute: "{{ title }}",
                   required: true
                 },
                 actor: admin()
               )

      assert Exception.message(error) =~ "can't be required"
    end
  end

  describe "derivation on write" do
    test "the value is derived from the document, keeping its native type" do
      actor = admin()
      words = define!(actor, "{{ word_count(body) }}")
      label = define!(actor, "{{ reading_time(body) }} min read")

      page =
        CMS.create_page!(
          %{title: "Post", slug: slug(), blocks: blocks("one two three four five")},
          actor: actor
        )

      assert page.custom_fields[words.name] == 5
      assert page.custom_fields[label.name] == "1 min read"
    end

    test "a formula can reference a sibling custom field's coerced value" do
      actor = admin()

      price =
        CMS.create_field_definition!(
          %{content_type: :page, name: "price", label: "Price", field_type: :float},
          actor: actor
        )

      tax =
        CMS.create_field_definition!(
          %{content_type: :page, name: "tax", label: "Tax", field_type: :float},
          actor: actor
        )

      total = define!(actor, "{{ round(sum(price, tax), 2) }}")

      page =
        CMS.create_page!(
          %{
            title: "Product",
            slug: slug(),
            custom_fields: %{price.name => "10.5", tax.name => "2.25"}
          },
          actor: actor
        )

      assert page.custom_fields[total.name] == 12.75
    end

    test "a submitted value for a computed field is discarded, not stored" do
      actor = admin()
      derived = define!(actor, "{{ slugify(title) }}")

      page =
        CMS.create_page!(
          %{
            title: "Real Title",
            slug: slug(),
            custom_fields: %{derived.name => "spoofed-by-the-client"}
          },
          actor: actor
        )

      assert page.custom_fields[derived.name] == "real-title"

      # Same on update: the read-only guarantee is not a create-only accident.
      {:ok, updated} =
        CMS.update_page(page, %{custom_fields: %{derived.name => "spoofed-again"}}, actor: actor)

      assert updated.custom_fields[derived.name] == "real-title"
    end

    test "it recomputes when the document changes, without being resubmitted" do
      actor = admin()
      derived = define!(actor, "{{ slugify(title) }}")

      page = CMS.create_page!(%{title: "First", slug: slug()}, actor: actor)
      assert page.custom_fields[derived.name] == "first"

      {:ok, updated} = CMS.update_page(page, %{title: "Second"}, actor: actor)
      assert updated.custom_fields[derived.name] == "second"
    end

    test "a blank result drops the key and never blocks the save" do
      actor = admin()
      blank = define!(actor, "{{ excerpt }}")

      page = CMS.create_page!(%{title: "No excerpt", slug: slug()}, actor: actor)
      refute Map.has_key?(page.custom_fields, blank.name)

      # The formula stays blank for this record, but an unrelated edit must
      # still save — a computed field can't make a document unsaveable.
      assert {:ok, updated} = CMS.update_page(page, %{title: "Retitled"}, actor: actor)
      refute Map.has_key?(updated.custom_fields, blank.name)
    end

    test "a whitespace-only result is blank on both the write and the fire path" do
      actor = admin()
      # Previously the write path dropped this (its blank? trims) while the fire
      # path kept it (it only tested for nil), so the record and its artifact
      # disagreed about whether the key existed.
      derived = define!(actor, "{{ concat(' ', ' ') }}")

      page = CMS.create_page!(%{title: "Spaces", slug: slug()}, actor: actor)
      refute Map.has_key?(page.custom_fields, derived.name)

      {:ok, %{json: json}} = Firing.Engine.fire(page, mode: :preview)
      refute Map.has_key?(json["custom_fields"], derived.name)
    end

    test "surrounding whitespace in a formula does not change the value's type" do
      actor = admin()
      padded = define!(actor, "  {{ word_count(body) }}  ")

      page =
        CMS.create_page!(
          %{title: "Post", slug: slug(), blocks: blocks("one two three")},
          actor: actor
        )

      # Not the string "3" — a trailing space must not demote it out of the
      # single-expression path, or custom_sort orders it lexically.
      assert page.custom_fields[padded.name] === 3
    end

    test "a computed field never feeds another computed field" do
      actor = admin()
      first = define!(actor, "{{ slugify(title) }}")
      second = define!(actor, "prefix-{{ #{first.name} }}")

      page = CMS.create_page!(%{title: "Chained", slug: slug()}, actor: actor)

      assert page.custom_fields[first.name] == "chained"
      # Deliberate: one pass, so the second sees nothing for the first.
      assert page.custom_fields[second.name] == "prefix-"
    end
  end

  describe "recomputation at fire time" do
    test "a changed formula reaches the artifact without re-saving the record" do
      actor = admin()
      derived = define!(actor, "{{ word_count(body) }}")

      page =
        CMS.create_page!(
          %{title: "Post", slug: slug(), blocks: blocks("one two three")},
          actor: actor
        )

      assert page.custom_fields[derived.name] == 3

      # The admin edits the formula; the record is untouched and still carries
      # the old stored value.
      {:ok, _} =
        CMS.update_field_definition(derived, %{compute: "{{ word_count(body) }} words"},
          actor: actor
        )

      reloaded = CMS.get_page!(page.id, actor: actor)
      assert reloaded.custom_fields[derived.name] == 3

      {:ok, %{json: json}} = Firing.Engine.fire(reloaded, mode: :preview)
      assert json["custom_fields"][derived.name] == "3 words"
    end

    test "a stale stored value can't ride out on an artifact" do
      actor = admin()
      derived = define!(actor, "{{ slugify(title) }}")

      page = CMS.create_page!(%{title: "Fresh", slug: slug()}, actor: actor)

      # Forge a stale value straight into storage, bypassing the write change.
      stale = Ash.Seed.update!(page, %{custom_fields: %{derived.name => "stale-value"}})
      assert stale.custom_fields[derived.name] == "stale-value"

      {:ok, %{json: json}} = Firing.Engine.fire(stale, mode: :preview)
      assert json["custom_fields"][derived.name] == "fresh"
    end

    test "editable custom fields fire as stored" do
      actor = admin()

      note =
        CMS.create_field_definition!(
          %{content_type: :page, name: "note", label: "Note", field_type: :string},
          actor: actor
        )

      page =
        CMS.create_page!(
          %{title: "Noted", slug: slug(), custom_fields: %{note.name => "hello"}},
          actor: actor
        )

      {:ok, %{json: json}} = Firing.Engine.fire(page, mode: :preview)
      assert json["custom_fields"][note.name] == "hello"
    end
  end
end
