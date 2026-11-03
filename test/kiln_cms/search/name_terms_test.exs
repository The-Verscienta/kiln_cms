defmodule KilnCMS.Search.NameTermsTest do
  @moduledoc """
  Names written spaced or joined (proposal A5): `KilnCMS.Search.NameTerms`
  rewrites the query against the site's name terms, and the compound leg of
  `KilnCMS.Search.hybrid/3` matches the rewrites against titles and flagged
  name fields — `huangqi` finds Huang Qi, `xiao yao san` finds Xiaoyaosan.
  """
  # async: false — the hybrid tests read the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search
  alias KilnCMS.Search.NameTerms

  defp dict(words), do: MapSet.new(words)

  describe "variants/2" do
    test "joins adjacent words into a name term, two or three at a time" do
      assert NameTerms.variants("He Gu", dict(~w(hegu))) == [{"hegu", "hegu"}]

      assert NameTerms.variants("xiao yao san pills", dict(~w(xiaoyaosan))) ==
               [{"xiaoyaosan pills", "xiaoyaosan"}]

      assert NameTerms.variants("SP 9", dict(~w(sp9))) == [{"sp9", "sp9"}]
    end

    test "splits a word into two or three name terms" do
      assert NameTerms.variants("huangqi", dict(~w(huang qi))) == [{"huang qi", "huang qi"}]

      assert NameTerms.variants("is xiaoyaosan safe", dict(~w(xiao yao san))) ==
               [{"is xiao yao san safe", "xiao yao san"}]

      assert NameTerms.variants("hegu", dict(~w(he gu))) == [{"he gu", "he gu"}]
    end

    test "a one-character part must be a number" do
      assert NameTerms.variants("SP9", dict(~w(sp 9))) == [{"sp 9", "sp 9"}]
      assert NameTerms.variants("spa", dict(~w(sp a))) == []
    end

    test "accents and case are folded the way the dictionary is" do
      assert NameTerms.variants("Huángqí", dict(~w(huang qi))) == [{"huang qi", "huang qi"}]
    end

    test "nothing to join or split is no variants" do
      assert NameTerms.variants("huang qi tea", dict(~w(huang qi tea))) == []
      assert NameTerms.variants("huangqi", dict(~w(huang))) == []
      assert NameTerms.variants("huangqi", MapSet.new()) == []
      assert NameTerms.variants("", dict(~w(huang qi))) == []
    end
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "nt-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "nt-#{System.unique_integer([:positive])}"

  defp publish(admin, attrs) do
    page = CMS.create_page!(Map.put(attrs, :slug, slug()), actor: admin)
    CMS.publish_page!(page, %{}, actor: admin)
  end

  defp name_field(admin, name) do
    CMS.create_field_definition!(
      %{content_type: :page, name: name, label: name, field_type: :string, names_record: true},
      actor: admin
    )
  end

  describe "dictionary/1" do
    test "holds the words of published titles and flagged names, folded" do
      admin = admin()
      name_field(admin, "pinyin")
      publish(admin, %{title: "Astragalus Root", custom_fields: %{"pinyin" => "Huáng Qí"}})

      terms = NameTerms.dictionary(nil)
      assert MapSet.subset?(dict(~w(astragalus root huang qi)), terms)
    end

    test "no split is made from text that is not a name" do
      admin = admin()

      # The words are on the site — in a field nobody flagged as a name, and
      # in the title of a draft — but in no published name.
      CMS.create_field_definition!(
        %{content_type: :page, name: "notes", label: "Notes", field_type: :string},
        actor: admin
      )

      publish(admin, %{title: "Milk Vetch", custom_fields: %{"notes" => "zhong wen"}})
      CMS.create_page!(%{title: "Bai Zhu", slug: slug()}, actor: admin)

      terms = NameTerms.dictionary(nil)
      refute MapSet.member?(terms, "zhong")
      refute MapSet.member?(terms, "bai")
      assert NameTerms.variants("zhongwen", terms) == []
      assert NameTerms.variants("baizhu", terms) == []
      assert NameTerms.variants("milkvetch", terms) == [{"milk vetch", "milk vetch"}]
    end
  end

  describe "the compound leg in hybrid/3" do
    # Verscienta's evidence: `huangqi` reached Huang Qi at rank 30, and
    # `xiaoyaosan` and `He Gu` not at all. The catalogue carries near
    # neighbours sharing a word with each target, so a top-3 is earned.
    @neighbours [
      "Huang Lian",
      "Huang Bai",
      "Dang Gui",
      "Xiao Chai Hu Tang",
      "Xiao Jian Zhong Tang",
      "He Shou Wu",
      "Gu Sui Bu",
      "SP 6",
      "ST 36"
    ]

    defp catalogue(admin, names) do
      for title <- @neighbours, do: publish(admin, %{title: title})
      targets = Map.new(names, fn name -> {name, publish(admin, %{title: name})} end)
      KilnCMS.DataCase.drain_oban()
      targets
    end

    defp top3(query) do
      Search.hybrid(:page, query, actor: nil) |> Enum.take(3) |> Enum.map(& &1.id)
    end

    test "a joined query finds the name written spaced" do
      targets = catalogue(admin(), ["Huang Qi", "Xiao Yao San", "He Gu", "SP 9"])

      for {query, name} <- [
            {"huangqi", "Huang Qi"},
            {"xiaoyaosan", "Xiao Yao San"},
            {"hegu", "He Gu"},
            {"SP9", "SP 9"}
          ] do
        assert targets[name].id in top3(query), "#{query} should find #{name} in the top 3"
      end

      [hit] = Search.hybrid(:page, "huangqi", actor: nil) |> Enum.take(1)
      assert :compound in Search.hit_legs(hit)
    end

    test "the global sweep makes the rewrites once and every section uses them" do
      targets = catalogue(admin(), ["Xiao Yao San"])

      %{pages: [hit | _]} = Search.global("xiaoyaosan", sections: [:pages])
      assert hit.id == targets["Xiao Yao San"].id
      assert :compound in Search.hit_legs(hit)
    end

    test "a spaced query finds the name written joined" do
      targets = catalogue(admin(), ["Huangqi", "Xiaoyaosan", "Hegu", "SP9"])

      for {query, name} <- [
            {"huang qi", "Huangqi"},
            {"xiao yao san", "Xiaoyaosan"},
            {"He Gu", "Hegu"},
            {"SP 9", "SP9"}
          ] do
        assert targets[name].id in top3(query), "#{query} should find #{name} in the top 3"
      end
    end

    test "a flagged name field is matched written the other way too" do
      admin = admin()
      name_field(admin, "pinyin")

      herb =
        publish(admin, %{title: "Astragalus", custom_fields: %{"pinyin" => "Huang Qi"}})

      catalogue(admin, [])

      [hit | _] = Search.hybrid(:page, "huangqi", actor: nil)
      assert hit.id == herb.id
      assert :compound in Search.hit_legs(hit)
    end

    test "a split names only a record holding the whole of it" do
      admin = admin()
      # "Car" and "Pet" are both name terms, so `carpet` splits — but only
      # a name containing "car pet" confirms the split.
      car = publish(admin, %{title: "Car"})
      publish(admin, %{title: "Pet"})
      car_pet = publish(admin, %{title: "Car Pet"})
      KilnCMS.DataCase.drain_oban()

      hits = Search.hybrid(:page, "carpet", actor: nil)
      compound = for hit <- hits, :compound in Search.hit_legs(hit), do: hit.id
      assert compound == [car_pet.id]
      refute car.id in compound
    end

    test "a query with nothing to rewrite runs no compound leg" do
      catalogue(admin(), ["Huang Qi"])

      refute Enum.any?(
               Search.hybrid(:page, "huang qi", actor: nil),
               &(:compound in Search.hit_legs(&1))
             )
    end
  end
end
