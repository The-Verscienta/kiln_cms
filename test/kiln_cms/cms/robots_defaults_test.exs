defmodule KilnCMS.CMS.RobotsDefaultsTest do
  @moduledoc """
  Per-type robots defaults (#2256): a type decides what `noindex` / `nofollow`
  start as for a NEW document. Only a flag the caller left out takes the
  default; an explicit value, a copy and an existing document keep theirs.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureIO

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Changes.ApplyRobotsDefaults
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Duplication

  # Compiled outside this module's lexical scope: `DataCase` imports
  # `Ecto.Changeset`, whose `validations/1` clashes with the resource DSL.
  setup_all do
    hidden = KilnCMS.CMS.RobotsDefaultsTest.HiddenType

    # The throwaway resource is not in any domain; the verifier's complaint is
    # beside the point, only the markers the macro injects are read.
    capture_io(:stderr, fn ->
      Code.compile_string("""
      defmodule KilnCMS.CMS.RobotsDefaultsTest.HiddenType do
        use KilnCMS.CMS.Content,
          type: :robots_defaults_fixture,
          plural: "robots_defaults_fixtures",
          table: "pages",
          domain: KilnCMS.CMS,
          noindex_default: true
      end
      """)
    end)

    {:ok, hidden: hidden}
  end

  defp uniq, do: System.unique_integer([:positive])

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "robots-def-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp type(admin, attrs) do
    CMS.create_type_definition!(
      Map.merge(%{name: "robotsdef#{uniq()}", label: "Robots"}, attrs),
      actor: admin
    )
  end

  defp entry(type, admin, attrs \\ %{}) do
    ContentTypes.create!(type.name, Map.merge(%{title: "E #{uniq()}"}, attrs), actor: admin)
  end

  describe "compiled types (macro options)" do
    test "the options are exposed as markers, defaulting to false", %{hidden: hidden} do
      assert hidden.__kiln_noindex_default__() == true
      assert hidden.__kiln_nofollow_default__() == false
      assert KilnCMS.CMS.Page.__kiln_noindex_default__() == false
      assert KilnCMS.CMS.Page.__kiln_nofollow_default__() == false
    end

    test "the descriptor carries them" do
      assert %{noindex_default: false, nofollow_default: false} = ContentTypes.get(:page)
    end

    test "the change fills only the flag the caller left out", %{hidden: hidden} do
      cs = fn params -> %{Ash.Changeset.new(hidden) | params: params} end

      omitted = ApplyRobotsDefaults.change(cs.(%{}), [], %{})
      assert Ash.Changeset.get_attribute(omitted, :noindex) == true
      assert Ash.Changeset.get_attribute(omitted, :nofollow) == false

      for params <- [%{noindex: false}, %{"noindex" => false}] do
        explicit = ApplyRobotsDefaults.change(cs.(params), [], %{})
        assert Ash.Changeset.get_attribute(explicit, :noindex) == false
      end
    end

    test "a non-boolean option fails the build" do
      assert_raise ArgumentError, ~r/noindex_default must be true or false/, fn ->
        capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule KilnCMS.CMS.RobotsDefaultsTest.BadOption do
            use KilnCMS.CMS.Content,
              type: :bad_robots,
              plural: "bad_robots",
              table: "pages",
              domain: KilnCMS.CMS,
              noindex_default: "yes"
          end
          """)
        end)
      end
    end

    test "a page without a default is indexable, as before" do
      page = CMS.create_page!(%{title: "P", slug: "p-#{uniq()}"}, actor: admin())
      assert {page.noindex, page.nofollow} == {false, false}
    end
  end

  describe "dynamic types (TypeDefinition)" do
    test "an omitted flag takes the type's default" do
      admin = admin()
      type = type(admin, %{noindex_default: true, nofollow_default: true})

      e = entry(type, admin)
      assert e.noindex and e.nofollow
    end

    test "an explicit value wins, either way" do
      admin = admin()
      type = type(admin, %{noindex_default: true})

      kept = entry(type, admin, %{noindex: false})
      assert kept.noindex == false

      plain = type(admin, %{})
      forced = entry(plain, admin, %{noindex: true})
      assert forced.noindex == true
      assert entry(plain, admin).noindex == false
    end

    test "a default set through an update applies to later entries only" do
      admin = admin()
      type = type(admin, %{})
      before = entry(type, admin)

      CMS.update_type_definition!(type, %{noindex_default: true}, actor: admin)

      after_update = entry(type, admin)
      assert after_update.noindex == true

      reread = CMS.get_entry!(before.id, actor: admin, tenant: before.org_id)
      assert reread.noindex == false
    end

    test "the registry descriptor follows an update" do
      admin = admin()
      type = type(admin, %{})
      assert %{noindex_default: false} = ContentTypes.get(type.name, type.org_id)

      CMS.update_type_definition!(type, %{noindex_default: true, nofollow_default: true},
        actor: admin
      )

      assert %{noindex_default: true, nofollow_default: true} =
               ContentTypes.get(type.name, type.org_id)
    end

    # A type that cannot be read must not read as "no default": the entry would
    # be created indexable in a type that may have meant to hide it.
    test "an unreadable type definition raises instead of creating an indexable entry" do
      type = type(admin(), %{noindex_default: true})

      changeset =
        KilnCMS.CMS.Entry
        |> Ash.Changeset.new()
        |> Map.put(:tenant, type.org_id)
        |> Ash.Changeset.force_change_attribute(:type_definition_id, Ash.UUID.generate())

      assert_raise Ash.Error.Invalid, fn -> ApplyRobotsDefaults.change(changeset, [], %{}) end
    end

    test "an entry with no type definition has no type default" do
      changeset = Ash.Changeset.new(KilnCMS.CMS.Entry)
      result = ApplyRobotsDefaults.change(changeset, [], %{})
      assert Ash.Changeset.get_attribute(result, :noindex) == false
    end

    test "a copy keeps the source's flags, not the type's default" do
      admin = admin()
      type = type(admin, %{noindex_default: true})
      source = entry(type, admin, %{noindex: false, nofollow: true})

      copy = Duplication.duplicate!(type.name, source, actor: admin, tenant: source.org_id)
      assert copy.noindex == false
      assert copy.nofollow == true
    end
  end
end
