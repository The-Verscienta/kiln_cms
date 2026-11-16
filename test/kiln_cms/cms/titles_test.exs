defmodule KilnCMS.CMS.TitlesTest do
  @moduledoc """
  Computed record titles (#2287): a type's `title_template` builds `title` on
  save, through the computed-field language. Unit coverage of `Titles`, the
  definition-time validation, and the write paths on a dynamic type — create,
  update, the working copy of a live entry, promotion — plus the re-derive
  sweep.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.TitleRegeneration
  alias KilnCMS.CMS.Titles
  alias KilnCMS.CMS.Workers.TitleRegenerationWorker

  @person "{{ field.last_name }}, {{ field.first_name }} ({{ field.city }})"

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "titles-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp uniq, do: System.unique_integer([:positive])

  defp field!(actor, type, name, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{type_definition_id: type.id, name: name, label: name, field_type: :string},
        attrs
      ),
      actor: actor
    )
  end

  # A dynamic type with last_name / first_name / city fields, optionally with a
  # template (set after the fields exist, as the admin UI must).
  defp person_type!(actor, template \\ @person) do
    type = CMS.create_type_definition!(%{name: "person#{uniq()}", label: "Person"}, actor: actor)
    for name <- ~w(last_name first_name city), do: field!(actor, type, name)

    if template,
      do: CMS.update_type_definition!(type, %{title_template: template}, actor: actor),
      else: type
  end

  defp person!(actor, type, fields, attrs \\ %{}) do
    ContentTypes.create!(type.name, Map.merge(%{custom_fields: fields}, attrs), actor: actor)
  end

  defp jane, do: %{"last_name" => "Doe", "first_name" => "Jane", "city" => "Oslo"}

  describe "derive/2" do
    defp ctx(fields), do: %{document: %{}, fields: fields, today: ~D[2026-01-01]}

    test "builds the title from the fields, trimmed" do
      assert {:ok, "Doe, Jane (Oslo)"} = Titles.derive(@person, ctx(jane()))
    end

    test "a template over empty fields is blank, not literal punctuation" do
      assert :blank = Titles.derive(@person, ctx(%{}))
      assert :blank = Titles.derive(nil, ctx(jane()))
    end

    test "a long result is cut to the title limit" do
      long = String.duplicate("x", KilnCMS.Limits.line() + 200)
      assert {:ok, title} = Titles.derive("{{ field.bio }}", ctx(%{"bio" => long}))
      assert String.length(title) == KilnCMS.Limits.line()
    end

    test "a native number renders as text" do
      assert {:ok, "5"} = Titles.derive("{{ field.n }}", ctx(%{"n" => 5}))
    end
  end

  describe "validate/2" do
    test "accepts a field template and refuses broken syntax" do
      assert :ok = Titles.validate(@person, [])
      assert {:error, message} = Titles.validate("{{ slugfy(field.a) }}", [])
      assert message =~ "valid template"
    end

    test "refuses title and slug, which would be a cycle" do
      assert {:error, message} = Titles.validate("{{ title }} x", [])
      assert message =~ "title"
      assert {:error, message} = Titles.validate("{{ slug }}", [])
      assert message =~ "slug"
      # `field.title` is a custom field that shares the name, which is fine.
      assert :ok = Titles.validate("{{ field.title }}", [])
    end

    test "refuses a template over the length limit" do
      assert {:error, message} = Titles.validate(String.duplicate("a", 501), [])
      assert message =~ "too long"
    end

    test "with definitions, refuses unknown, private and cyclic-computed references" do
      defs = [
        %{name: "city", field_type: :string, private: false, compute: nil},
        %{name: "ssn", field_type: :string, private: true, compute: nil},
        %{name: "label", field_type: :computed, private: false, compute: "{{ title }} !"}
      ]

      assert :ok = Titles.validate("{{ field.city }}", definitions: defs)
      assert {:error, message} = Titles.validate("{{ field.nope }}", definitions: defs)
      assert message =~ "nope"
      assert {:error, message} = Titles.validate("{{ field.ssn }}", definitions: defs)
      assert message =~ "private"
      assert {:error, message} = Titles.validate("{{ field.label }}", definitions: defs)
      assert message =~ "title"
    end

    test "validate!/1 raises for a build-time template that is wrong" do
      assert Titles.validate!(nil) == nil
      assert Titles.validate!("{{ field.a }}") == "{{ field.a }}"
      assert_raise ArgumentError, ~r/title_template/, fn -> Titles.validate!("{{ title }}") end
    end
  end

  describe "the type definition" do
    test "stores a valid template" do
      actor = admin()
      type = person_type!(actor)
      assert type.title_template == @person
    end

    test "refuses title, slug, private and unknown field references" do
      actor = admin()
      type = person_type!(actor, nil)
      field!(actor, type, "secret", %{private: true})

      for {template, fragment} <- [
            {"{{ title }}", "title"},
            {"{{ slug }}", "slug"},
            {"{{ field.secret }}", "private"},
            {"{{ field.missing }}", "missing"},
            {"{{ nonsense(", "valid template"}
          ] do
        assert {:error, %Ash.Error.Invalid{} = error} =
                 CMS.update_type_definition(type, %{title_template: template}, actor: actor)

        assert Exception.message(error) =~ fragment
      end
    end

    test "changing the template enqueues a sweep; clearing it does not" do
      actor = admin()
      type = person_type!(actor, nil)

      CMS.update_type_definition!(type, %{title_template: "{{ field.last_name }}"}, actor: actor)
      assert_enqueued(worker: TitleRegenerationWorker, args: %{"kind" => type.name})

      cleared = CMS.get_type_definition!(type.id, actor: actor)

      Oban.Job |> KilnCMS.Repo.delete_all()
      CMS.update_type_definition!(cleared, %{title_template: nil}, actor: actor)
      refute_enqueued(worker: TitleRegenerationWorker)
    end
  end

  describe "writes on a dynamic type" do
    test "create derives the title, ignoring a supplied one, and the slug follows it" do
      actor = admin()
      type = person_type!(actor)
      entry = person!(actor, type, jane(), %{title: "Hand typed"})

      assert entry.title == "Doe, Jane (Oslo)"
      assert entry.slug == "doe-jane-oslo"
    end

    test "update re-derives when a source field changes and merges a partial payload" do
      actor = admin()
      type = person_type!(actor)
      entry = person!(actor, type, jane())

      updated = CMS.update_entry!(entry, %{custom_fields: %{"city" => "Bergen"}}, actor: actor)
      assert updated.title == "Doe, Jane (Bergen)"

      # A title-only PATCH is overwritten by the template, not an error.
      again = CMS.update_entry!(updated, %{title: "Something else"}, actor: actor)
      assert again.title == "Doe, Jane (Bergen)"
    end

    test "a source-field edit on a published entry does not move its slug" do
      actor = admin()
      type = person_type!(actor)
      entry = person!(actor, type, jane()) |> then(&CMS.publish_entry!(&1, %{}, actor: actor))
      assert entry.slug == "doe-jane-oslo"

      updated = CMS.update_entry!(entry, %{custom_fields: %{"last_name" => "Roe"}}, actor: actor)
      assert updated.title == "Roe, Jane (Oslo)"
      assert updated.slug == "doe-jane-oslo"
    end

    test "a blank result keeps the supplied title on create and the stored one on update" do
      actor = admin()
      type = person_type!(actor)

      scaffold =
        person!(actor, type, %{}, %{title: "Untitled person", slug: "untitled-#{uniq()}"})

      assert scaffold.title == "Untitled person"

      assert_raise Ash.Error.Invalid, fn -> person!(actor, type, %{}) end

      filled = person!(actor, type, jane())

      blanked =
        CMS.update_entry!(
          filled,
          %{custom_fields: %{"last_name" => "", "first_name" => "", "city" => ""}},
          actor: actor
        )

      assert blanked.title == "Doe, Jane (Oslo)"
    end

    test "a scaffold draft's first save derives the title and replaces the scaffold slug" do
      actor = admin()
      type = person_type!(actor)

      scaffold =
        person!(actor, type, %{}, %{title: "Untitled person", slug: "untitled-#{uniq()}"})

      saved = CMS.update_entry!(scaffold, %{custom_fields: jane()}, actor: actor)
      assert saved.title == "Doe, Jane (Oslo)"
      assert saved.slug == "doe-jane-oslo"
    end

    test "the title is cut to the limit" do
      actor = admin()
      type = CMS.create_type_definition!(%{name: "long#{uniq()}", label: "Long"}, actor: actor)
      field!(actor, type, "bio", %{field_type: :text})
      CMS.update_type_definition!(type, %{title_template: "{{ field.bio }}"}, actor: actor)

      entry =
        person!(actor, type, %{"bio" => String.duplicate("word ", 400)}, %{slug: "long-#{uniq()}"})

      assert String.length(entry.title) <= KilnCMS.Limits.line()
      assert String.length(entry.title) > 900
    end

    test "a computed field that reads the title sees the derived title" do
      actor = admin()
      type = person_type!(actor, nil)
      field!(actor, type, "heading", %{field_type: :computed, compute: "{{ title }} (profile)"})

      type =
        CMS.update_type_definition!(type, %{title_template: "{{ field.last_name }}"},
          actor: actor
        )

      entry = person!(actor, type, %{"last_name" => "Doe"})
      assert entry.title == "Doe"
      assert entry.custom_fields["heading"] == "Doe (profile)"
    end

    test "a private field made private after the template never reaches the title" do
      actor = admin()
      type = person_type!(actor)

      city =
        CMS.list_field_definitions!(actor: actor)
        |> Enum.find(&(&1.type_definition_id == type.id and &1.name == "city"))

      CMS.update_field_definition!(city, %{private: true}, actor: actor)

      entry = person!(actor, type, jane())
      # The value is gone; the template's own punctuation stays.
      assert entry.title == "Doe, Jane ()"
      refute entry.title =~ "Oslo"
    end

    test "each translation derives from its own fields" do
      actor = admin()
      type = person_type!(actor)
      en = person!(actor, type, jane())

      fr =
        person!(
          actor,
          type,
          %{"last_name" => "Dupont", "first_name" => "Jeanne", "city" => "Lyon"},
          %{locale: "fr"}
        )

      assert en.title == "Doe, Jane (Oslo)"
      assert fr.title == "Dupont, Jeanne (Lyon)"
    end
  end

  describe "the working copy of a live entry" do
    test "holds a derived working title; the live title moves on Publish changes" do
      actor = admin()
      type = person_type!(actor)
      live = person!(actor, type, jane()) |> then(&CMS.publish_entry!(&1, %{}, actor: actor))

      held =
        CMS.save_entry_working_copy!(
          live,
          %{fields: %{"custom_fields" => %{"city" => "Bergen"}}},
          actor: actor
        )

      assert held.title == "Doe, Jane (Oslo)"
      assert held.working_title == "Doe, Jane (Bergen)"
      assert held.working_copy_at

      promoted = CMS.publish_entry_changes!(held, %{}, actor: actor)
      assert promoted.title == "Doe, Jane (Bergen)"
      assert promoted.working_title == nil
      assert promoted.slug == "doe-jane-oslo"
    end

    test "a typed working title is overwritten by the template" do
      actor = admin()
      type = person_type!(actor)
      live = person!(actor, type, jane()) |> then(&CMS.publish_entry!(&1, %{}, actor: actor))

      held =
        CMS.save_entry_working_copy!(
          live,
          %{working_title: "Typed", fields: %{"custom_fields" => %{"city" => "Bergen"}}},
          actor: actor
        )

      assert held.working_title == "Doe, Jane (Bergen)"
    end
  end

  describe "the re-derive sweep" do
    test "retitles drafts and live entries, skips a pending working copy, and is idempotent" do
      actor = admin()
      type = person_type!(actor, nil)

      draft = person!(actor, type, jane(), %{title: "Old draft", slug: "d-#{uniq()}"})

      live =
        person!(actor, type, jane(), %{title: "Old live", slug: "l-#{uniq()}"})
        |> then(&CMS.publish_entry!(&1, %{}, actor: actor))

      held =
        person!(actor, type, jane(), %{title: "Old held", slug: "h-#{uniq()}"})
        |> then(&CMS.publish_entry!(&1, %{}, actor: actor))

      held = CMS.save_entry_working_copy!(held, %{working_title: "Held title"}, actor: actor)

      type = CMS.update_type_definition!(type, %{title_template: @person}, actor: actor)
      ct = ContentTypes.get(type.name, type.org_id)

      summary = TitleRegeneration.run(ct, type.org_id)
      assert %{changed: 2, skipped: 1, failed: 0, scanned: 3} = summary

      assert CMS.get_entry!(draft.id, actor: actor).title == "Doe, Jane (Oslo)"
      assert CMS.get_entry!(live.id, actor: actor).title == "Doe, Jane (Oslo)"
      assert CMS.get_entry!(held.id, actor: actor).title == "Old held"

      assert %{changed: 0, failed: 0} = TitleRegeneration.run(ct, type.org_id)
    end

    test "pages through the type, and the worker chains the next page" do
      actor = admin()
      type = person_type!(actor, nil)
      for n <- 1..3, do: person!(actor, type, jane(), %{title: "T#{n}", slug: "p#{n}-#{uniq()}"})
      type = CMS.update_type_definition!(type, %{title_template: @person}, actor: actor)
      ct = ContentTypes.get(type.name, type.org_id)

      first = TitleRegeneration.run_page(ct, type.org_id, nil, limit: 2)
      assert %{scanned: 2, changed: 2} = first
      assert first.next

      assert :ok =
               perform_job(TitleRegenerationWorker, %{
                 "kind" => type.name,
                 "org_id" => type.org_id,
                 "after" => first.next
               })

      assert %{changed: 0} = TitleRegeneration.run(ct, type.org_id)
    end

    test "a full page enqueues the next one" do
      actor = admin()
      type = person_type!(actor, nil)

      for n <- 1..101,
          do:
            Ash.Seed.seed!(KilnCMS.CMS.Entry, %{
              title: "T#{n}",
              slug: "s#{n}-#{uniq()}",
              type_definition_id: type.id,
              custom_fields: jane()
            })

      type = CMS.update_type_definition!(type, %{title_template: @person}, actor: actor)

      Oban.Job |> KilnCMS.Repo.delete_all()

      assert :ok =
               perform_job(TitleRegenerationWorker, %{
                 "kind" => type.name,
                 "org_id" => type.org_id
               })

      assert_enqueued(worker: TitleRegenerationWorker, args: %{"kind" => type.name})
    end
  end

  describe "sweep edge cases" do
    import ExUnit.CaptureLog

    test "a refused record is logged and fails the job, after chaining the next page" do
      actor = admin()
      type = person_type!(actor, nil)

      # `unpublish_at` before `scheduled_at`: every `:update` of this row is refused.
      Ash.Seed.seed!(KilnCMS.CMS.Entry, %{
        title: "Stuck",
        slug: "stuck-#{uniq()}",
        type_definition_id: type.id,
        custom_fields: jane(),
        scheduled_at: ~U[2030-01-02 00:00:00Z],
        unpublish_at: ~U[2030-01-01 00:00:00Z]
      })

      type = CMS.update_type_definition!(type, %{title_template: @person}, actor: actor)
      ct = ContentTypes.get(type.name, type.org_id)

      log =
        capture_log(fn ->
          assert %{failed: 1, changed: 0} = TitleRegeneration.run(ct, type.org_id)
        end)

      assert log =~ "refused its new title"

      capture_log(fn ->
        assert {:error, message} =
                 perform_job(TitleRegenerationWorker, %{
                   "kind" => type.name,
                   "org_id" => type.org_id
                 })

        assert message =~ "1 of 1"
      end)
    end

    test "overlapping sweeps for the same type and page collapse" do
      org = KilnCMS.Accounts.default_org_id()
      TitleRegenerationWorker.enqueue("dupe", org)
      TitleRegenerationWorker.enqueue("dupe", org)
      assert [_one] = all_enqueued(worker: TitleRegenerationWorker, args: %{"kind" => "dupe"})
    end

    test "a sweep never touches another site's same-named type" do
      actor = admin()
      type = person_type!(actor, nil)
      mine = person!(actor, type, jane(), %{title: "Mine", slug: "m-#{uniq()}"})

      other_org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Other #{uniq()}",
          slug: "other-#{uniq()}"
        })

      other_type =
        Ash.Seed.seed!(KilnCMS.CMS.TypeDefinition, %{
          name: type.name,
          label: "Person",
          path_segment: "people",
          org_id: other_org.id,
          title_template: @person
        })

      theirs =
        Ash.Seed.seed!(KilnCMS.CMS.Entry, %{
          title: "Theirs",
          slug: "t-#{uniq()}",
          type_definition_id: other_type.id,
          org_id: other_org.id,
          custom_fields: jane()
        })

      type = CMS.update_type_definition!(type, %{title_template: @person}, actor: actor)
      ct = ContentTypes.get(type.name, type.org_id)

      assert %{scanned: 1, changed: 1} = TitleRegeneration.run(ct, type.org_id)
      assert CMS.get_entry!(mine.id, actor: actor).title == "Doe, Jane (Oslo)"

      assert Ash.get!(KilnCMS.CMS.Entry, theirs.id, tenant: other_org.id, authorize?: false).title ==
               "Theirs"
    end

    test "a compiled type is swept through its descriptor" do
      actor = admin()

      page =
        CMS.create_page!(%{title: "Old title", slug: "cp-#{uniq()}", seo_title: "From SEO"},
          actor: actor
        )

      ct = %{ContentTypes.get(:page) | title_template: "{{ seo_title }}"}

      page_result = TitleRegeneration.run_page(ct, page.org_id, nil, limit: 1_000)
      assert page_result.changed >= 1
      assert CMS.get_page!(page.id, actor: actor).title == "From SEO"
    end

    test "retitling a draft does not move a hand-picked slug" do
      actor = admin()
      type = person_type!(actor)
      entry = person!(actor, type, jane(), %{slug: "hand-picked-#{uniq()}"})

      updated = CMS.update_entry!(entry, %{custom_fields: %{"last_name" => "Roe"}}, actor: actor)
      assert updated.title == "Roe, Jane (Oslo)"
      assert updated.slug == entry.slug
    end
  end
end
