defmodule KilnCMS.XmlTest do
  @moduledoc """
  Shared XML helpers — especially the xmerl name-budget guard (#1105).

  ## How "it did not intern the names" is asserted

  These tests used to compare `:erlang.system_info(:atom_count)` before and
  after the call and require the delta to stay under twenty. That counter is
  **VM-global**, so the delta was never the call's own interning: it included
  every atom every other process in the node created meanwhile, and an early
  test runs while the application is still finishing its boot. The number was
  therefore a function of unrelated timing — enlarging the Gettext catalogs was
  enough to take it from single digits to ~39, with the guard provably
  interning nothing (0 atoms, measured on the same call outside ExUnit). Warming
  the path first does not fix it either, because the noise is concurrent rather
  than first-call.

  So the assertion now states the guard's actual contract, which is sharper than
  a threshold and immune to whatever else the node is doing: **the names in the
  rejected document must not exist as atoms afterwards.**
  `String.to_existing_atom/1` answers that exactly, and it is what a leak would
  break — xmerl interns every element and attribute name it parses, so a guard
  that let the document through would make every one of these resolvable.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.Xliff.Document
  alias KilnCMS.Portability.WXR
  alias KilnCMS.Xml

  # Prefix for the crafted names. Distinctive enough that nothing else in the
  # node could have interned them for its own reasons, which is what makes their
  # absence meaningful.
  @poison "kilnpoisonname"

  # `max + 1` uniquely-named empty tags — one over the budget, so the guard must
  # refuse before xmerl ever sees them.
  defp poison_tags do
    max = Xml.max_names()
    {max, for(i <- 1..(max + 1), into: "", do: "<#{@poison}#{i}/>")}
  end

  # The guard's whole purpose: these names went past the parser and must not have
  # been interned. Sampled at both ends and the middle rather than all of them —
  # xmerl interns as it walks, so a leak cannot show up at #1 and not at #1000.
  defp refute_interned!(max) do
    for i <- [1, div(max, 2), max + 1] do
      assert_raise ArgumentError, fn -> String.to_existing_atom("#{@poison}#{i}") end
    end
  end

  describe "check_name_budget/2" do
    test "accepts a normal document well under the ceiling" do
      xml = ~s(<?xml version="1.0"?><rss><channel><item><title>Hi</title></item></channel></rss>)
      assert :ok = Xml.check_name_budget(xml)
    end

    test "refuses a crafted document of unique tag names before xmerl runs" do
      # One more distinct name than the budget. Built as binaries only — the
      # scan itself must not intern them.
      {max, tags} = poison_tags()
      xml = "<?xml version=\"1.0\"?><root>#{tags}</root>"

      assert {:error, {:too_many_names, count, ^max}} = Xml.check_name_budget(xml)
      assert count == max + 1

      refute_interned!(max)
    end

    test "counts attribute names toward the same budget" do
      max = 5
      # root + four unique attrs already = 5; a sixth attr tipspast.
      xml = ~s(<root a1="1" a2="2" a3="3" a4="4" a5="5"/>)
      assert {:error, {:too_many_names, 6, 5}} = Xml.check_name_budget(xml, max)
    end

    test "ignores names inside comments and CDATA" do
      xml = """
      <root><!-- <poison1/><poison2 a="x"/> --><![CDATA[<poison3/>]]><ok/></root>
      """

      assert :ok = Xml.check_name_budget(xml, 10)
    end
  end

  describe "callers refuse before parsing (#1105)" do
    test "Xliff.Document.parse/1" do
      {max, tags} = poison_tags()
      xml = ~s(<?xml version="1.0"?><xliff>#{tags}</xliff>)

      assert {:error, {:too_many_names, _, ^max}} = Document.parse(xml)
      refute_interned!(max)
    end

    test "WXR.parse/1" do
      {max, tags} = poison_tags()
      xml = ~s(<?xml version="1.0"?><rss><channel>#{tags}</channel></rss>)

      assert {:error, {:too_many_names, _, ^max}} = WXR.parse(xml)
      refute_interned!(max)
    end
  end
end
