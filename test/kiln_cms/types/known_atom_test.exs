defmodule KilnCMS.Types.KnownAtomTest do
  @moduledoc """
  `KnownAtom` reads what a newer release stored without failing and without
  minting atoms, and writes as strictly as `:atom` (#2509).
  """
  use ExUnit.Case, async: true

  alias KilnCMS.KnownAtomEmbedded
  alias KilnCMS.Types.KnownAtom
  alias KilnCMS.Types.UnknownAtom

  @one_of [one_of: [:alpha, :beta]]

  # A name no code here holds as an atom, fresh per call so no earlier test
  # (or this one, run twice) could have created it.
  defp never_an_atom,
    do: "zz_known_atom_#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000_000)}"

  defp atom_exists?(name) do
    _atom = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end

  describe "cast_stored" do
    test "a known value loads as its atom" do
      assert {:ok, :alpha} = Ash.Type.cast_stored(KnownAtom, "alpha", @one_of)
    end

    test "a name with no atom loads as UnknownAtom, and no atom is created" do
      name = never_an_atom()
      refute atom_exists?(name)

      assert {:ok, %UnknownAtom{value: ^name}} = Ash.Type.cast_stored(KnownAtom, name, @one_of)
      assert {:ok, %UnknownAtom{value: ^name}} = Ash.Type.cast_stored(KnownAtom, name, [])

      refute atom_exists?(name)
    end

    test "an existing atom outside one_of loads as UnknownAtom, not as that atom" do
      # `:ok` exists in every VM; plain `:atom` would load it despite `one_of`.
      assert {:ok, %UnknownAtom{value: "ok"}} = Ash.Type.cast_stored(KnownAtom, "ok", @one_of)
      assert {:ok, %UnknownAtom{value: "nil"}} = Ash.Type.cast_stored(KnownAtom, "nil", @one_of)
    end

    test "with no one_of, any existing atom loads, as with :atom" do
      assert {:ok, :ok} = Ash.Type.cast_stored(KnownAtom, "ok", [])
    end

    test "nil stays nil" do
      assert {:ok, nil} = Ash.Type.cast_stored(KnownAtom, nil, @one_of)
    end
  end

  describe "cast_from_embedded" do
    test "a known value loads as its atom, singly and in an array" do
      assert {:ok, :alpha} = Ash.Type.cast_from_embedded(KnownAtom, "alpha", @one_of)

      assert {:ok, [:alpha, :beta]} =
               Ash.Type.cast_from_embedded({:array, KnownAtom}, ["alpha", "beta"], items: @one_of)
    end

    test "a name with no atom loads as UnknownAtom, singly and in an array, creating no atom" do
      name = never_an_atom()
      other = never_an_atom()

      assert {:ok, %UnknownAtom{value: ^name}} =
               Ash.Type.cast_from_embedded(KnownAtom, name, @one_of)

      assert {:ok, [:alpha, %UnknownAtom{value: ^other}, :beta]} =
               Ash.Type.cast_from_embedded({:array, KnownAtom}, ["alpha", other, "beta"],
                 items: @one_of
               )

      refute atom_exists?(name)
      refute atom_exists?(other)
    end

    test "an existing atom outside one_of loads as UnknownAtom, as text or as an atom" do
      assert {:ok, %UnknownAtom{value: "ok"}} =
               Ash.Type.cast_from_embedded(KnownAtom, "ok", @one_of)

      assert {:ok, %UnknownAtom{value: "ok"}} =
               Ash.Type.cast_from_embedded(KnownAtom, :ok, @one_of)

      assert {:ok, :beta} = Ash.Type.cast_from_embedded(KnownAtom, :beta, @one_of)

      assert {:ok, [%UnknownAtom{value: "ok"}, :alpha]} =
               Ash.Type.cast_from_embedded({:array, KnownAtom}, [:ok, "alpha"], items: @one_of)
    end

    test "unsafe_to_atom? cannot switch atom creation back on" do
      name = never_an_atom()

      assert {:ok, %UnknownAtom{value: ^name}} =
               Ash.Type.cast_from_embedded(KnownAtom, name, @one_of ++ [unsafe_to_atom?: true])

      refute atom_exists?(name)
    end

    test "nil stays nil" do
      assert {:ok, nil} = Ash.Type.cast_from_embedded(KnownAtom, nil, @one_of)
      assert {:ok, nil} = Ash.Type.cast_from_embedded({:array, KnownAtom}, nil, items: @one_of)
    end

    test "an embedded resource reads an unknown value and dumps it back unchanged" do
      name = never_an_atom()
      stored = %{"kind" => name, "kinds" => ["alpha", name]}

      assert {:ok, %KnownAtomEmbedded{} = record} =
               Ash.Type.cast_from_embedded(KnownAtomEmbedded, stored, [])

      assert record.kind == %UnknownAtom{value: name}
      assert record.kinds == [:alpha, %UnknownAtom{value: name}]
      refute atom_exists?(name)

      assert {:ok, dumped} = Ash.Type.dump_to_embedded(KnownAtomEmbedded, record, [])
      assert %{kind: ^name, kinds: ["alpha", ^name]} = dumped
    end

    test "an embedded resource still refuses an unknown value as input" do
      assert {:error, _} =
               Ash.Type.cast_input(KnownAtomEmbedded, %{"kind" => "zz_embedded_input"}, [])
    end
  end

  describe "dump" do
    test "an UnknownAtom dumps back to the text it was loaded from" do
      unknown = %UnknownAtom{value: "zz_dumped"}
      assert {:ok, "zz_dumped"} = Ash.Type.dump_to_native(KnownAtom, unknown, @one_of)
      assert {:ok, "zz_dumped"} = Ash.Type.dump_to_embedded(KnownAtom, unknown, @one_of)
    end

    test "an atom dumps as :atom dumps it" do
      assert {:ok, "alpha"} = Ash.Type.dump_to_native(KnownAtom, :alpha, @one_of)
    end
  end

  describe "cast_input stays strict" do
    test "a known value casts" do
      assert {:ok, :beta} = Ash.Type.cast_input(KnownAtom, "beta", @one_of)
      assert {:ok, :beta} = Ash.Type.cast_input(KnownAtom, :beta, @one_of)
    end

    test "a name with no atom is refused, and no atom is created" do
      name = never_an_atom()
      assert {:error, _} = Ash.Type.cast_input(KnownAtom, name, @one_of)
      refute atom_exists?(name)
    end

    test "an atom outside one_of is refused" do
      assert {:error, _} = Ash.Type.cast_input(KnownAtom, :ok, @one_of)
      assert {:error, _} = Ash.Type.cast_input(KnownAtom, "ok", @one_of)
    end

    # Deliberate (see the moduledoc): these columns are never round-tripped
    # from a loaded record, so a struct as input is a bug, not a value.
    test "an UnknownAtom is refused as input" do
      assert {:error, _} =
               Ash.Type.cast_input(KnownAtom, %UnknownAtom{value: "zz_input"}, @one_of)
    end
  end

  describe "UnknownAtom" do
    test "renders, encodes and prints as its stored text, HTML-escaped when rendered" do
      unknown = %UnknownAtom{value: "zz_<b>&"}

      assert to_string(unknown) == "zz_<b>&"
      assert Jason.encode!(%{type: unknown}) == ~s({"type":"zz_<b>&"})

      assert unknown |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary() ==
               "zz_&lt;b&gt;&amp;"
    end
  end
end
