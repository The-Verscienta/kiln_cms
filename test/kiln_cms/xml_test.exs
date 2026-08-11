defmodule KilnCMS.XmlTest do
  @moduledoc """
  Shared XML helpers — especially the xmerl name-budget guard (#1105).
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.Xliff.Document
  alias KilnCMS.Portability.WXR
  alias KilnCMS.Xml

  describe "check_name_budget/2" do
    test "accepts a normal document well under the ceiling" do
      xml = ~s(<?xml version="1.0"?><rss><channel><item><title>Hi</title></item></channel></rss>)
      assert :ok = Xml.check_name_budget(xml)
    end

    test "refuses a crafted document of unique tag names before xmerl runs" do
      max = Xml.max_names()
      # One more distinct name than the budget. Built as binaries only — the
      # scan itself must not intern them.
      tags = for i <- 1..(max + 1), into: "", do: "<t#{i}/>"
      xml = "<?xml version=\"1.0\"?><root>#{tags}</root>"

      before = :erlang.system_info(:atom_count)

      assert {:error, {:too_many_names, count, ^max}} = Xml.check_name_budget(xml)
      assert count == max + 1

      # The guard is the whole defence: atom count must not move materially.
      after_count = :erlang.system_info(:atom_count)
      assert after_count - before < 20
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
      max = Xml.max_names()
      tags = for i <- 1..(max + 1), into: "", do: "<u#{i}/>"
      xml = ~s(<?xml version="1.0"?><xliff>#{tags}</xliff>)

      before = :erlang.system_info(:atom_count)
      assert {:error, {:too_many_names, _, ^max}} = Document.parse(xml)
      assert :erlang.system_info(:atom_count) - before < 20
    end

    test "WXR.parse/1" do
      max = Xml.max_names()
      tags = for i <- 1..(max + 1), into: "", do: "<u#{i}/>"
      xml = ~s(<?xml version="1.0"?><rss><channel>#{tags}</channel></rss>)

      before = :erlang.system_info(:atom_count)
      assert {:error, {:too_many_names, _, ^max}} = WXR.parse(xml)
      assert :erlang.system_info(:atom_count) - before < 20
    end
  end
end
