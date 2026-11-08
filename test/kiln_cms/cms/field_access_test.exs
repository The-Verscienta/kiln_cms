defmodule KilnCMS.CMS.FieldAccessTest do
  @moduledoc "The pure grammar of per-custom-field grants (#2281)."
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.FieldAccess

  describe "parse/1" do
    for {entry, expected} <- [
          {"custom_fields", :all},
          {"custom_fields.a", {:field, "a"}},
          {"custom_fields.a_1", {:field, "a_1"}},
          {"custom_fields.g.s", {:sub, "g", "s"}},
          {"title", :other},
          {"blocks", :other},
          {"custom_fields.", :invalid},
          {"custom_fields.A", :invalid},
          {"custom_fields.1a", :invalid},
          {"custom_fields.a.b.c", :invalid},
          {"custom_fields.a.", :invalid},
          {"custom_fieldsx", :invalid},
          {nil, :invalid},
          {42, :invalid}
        ] do
      test "#{inspect(entry)} is #{inspect(expected)}" do
        assert FieldAccess.parse(unquote(entry)) == unquote(Macro.escape(expected))
      end
    end
  end

  describe "per_key?/1" do
    for {grant, expected} <- [
          {nil, false},
          {[], false},
          {["title"], false},
          {["custom_fields"], false},
          {["custom_fields.a"], true},
          {["title", "custom_fields.g.s"], true},
          {["custom_fields.bad."], false}
        ] do
      test "#{inspect(grant)} is #{expected}" do
        assert FieldAccess.per_key?(unquote(grant)) == unquote(expected)
      end
    end
  end

  describe "writable?/2" do
    for {grant, path, expected} <- [
          {nil, ["a"], true},
          {[], ["a"], false},
          {["title"], ["a"], false},
          {["custom_fields"], ["a"], true},
          {["custom_fields"], ["g", "s"], true},
          {["custom_fields.a"], ["a"], true},
          {["custom_fields.a"], ["b"], false},
          {["custom_fields.g"], ["g"], true},
          {["custom_fields.g"], ["g", "s"], true},
          {["custom_fields.g"], ["h", "s"], false},
          {["custom_fields.g.s"], ["g", "s"], true},
          {["custom_fields.g.s"], ["g", "t"], false},
          {["custom_fields.g.s"], ["g"], false},
          {["custom_fields.s"], ["g", "s"], false}
        ] do
      test "#{inspect(grant)} on #{inspect(path)} is #{expected}" do
        assert FieldAccess.writable?(unquote(grant), unquote(path)) == unquote(expected)
      end
    end
  end

  describe "readable?/3" do
    for {read, write, path, expected} <- [
          {nil, nil, ["a"], true},
          {nil, [], ["a"], true},
          {[], nil, ["a"], false},
          {[], [], ["a"], false},
          {["custom_fields"], nil, ["a"], true},
          {["custom_fields.a"], nil, ["a"], true},
          {["custom_fields.a"], nil, ["b"], false},
          {[], ["custom_fields.a"], ["a"], true},
          {[], ["custom_fields"], ["a"], true},
          {[], ["custom_fields.b"], ["a"], false},
          {[], ["title"], ["a"], false}
        ] do
      test "read #{inspect(read)} write #{inspect(write)} on #{inspect(path)} is #{expected}" do
        assert FieldAccess.readable?(
                 unquote(read),
                 unquote(write),
                 unquote(path)
               ) == unquote(expected)
      end
    end
  end

  describe "hidden_names/3" do
    @defs [
      %{name: "secret", private: true},
      %{name: "other_secret", private: true},
      %{name: "public", private: false},
      %{name: "sub_secret", private: true, group_of_id: "g"},
      %{name: "link_secret", private: true, link_of_id: "r"}
    ]

    test "an unrestricted reader hides nothing" do
      assert FieldAccess.hidden_names(@defs, nil, nil) == []
    end

    test "an empty read grant hides every top-level private field, and only those" do
      assert FieldAccess.hidden_names(@defs, [], nil) == ["secret", "other_secret"]
    end

    test "a read entry or a write grant keeps a field visible" do
      assert FieldAccess.hidden_names(@defs, ["custom_fields.secret"], nil) == ["other_secret"]
      assert FieldAccess.hidden_names(@defs, [], ["custom_fields.other_secret"]) == ["secret"]
      assert FieldAccess.hidden_names(@defs, [], ["custom_fields"]) == []
      assert FieldAccess.hidden_names(@defs, ["custom_fields"], nil) == []
    end
  end

  describe "read entries" do
    @defs [%{name: "secret", private: true}, %{name: "public", private: false}]

    test "only private definitions may be named; stale names and the bare key pass" do
      assert FieldAccess.valid_read_entry?("custom_fields", @defs)
      assert FieldAccess.valid_read_entry?("custom_fields.secret", @defs)
      assert FieldAccess.valid_read_entry?("custom_fields.gone", @defs)
      refute FieldAccess.valid_read_entry?("custom_fields.public", @defs)
      refute FieldAccess.valid_read_entry?("custom_fields.g.s", @defs)
      refute FieldAccess.valid_read_entry?("title", @defs)
    end

    test "the shape check is syntax only" do
      assert FieldAccess.read_entry_shape?("custom_fields")
      assert FieldAccess.read_entry_shape?("custom_fields.anything")
      refute FieldAccess.read_entry_shape?("custom_fields.a.b")
      refute FieldAccess.read_entry_shape?("title")
    end
  end
end
