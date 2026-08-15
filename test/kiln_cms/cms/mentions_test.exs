defmodule KilnCMS.CMS.MentionsTest do
  @moduledoc """
  `@name` parsing and resolution for comment mentions (#801).

  Pure — candidates are plain maps, since the only thing that matters here is
  the name-matching rule. The end-to-end path (org scoping, opt-outs, which
  email fires) lives in `KilnCMS.CMS.CommentNotificationTest`.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.Mentions

  defp user(id, name), do: %{id: id, name: name}

  describe "handles/1" do
    test "finds handles and lowercases them, first-seen order, de-duplicated" do
      assert Mentions.handles("@Alice and @bob, then @Alice again") == ["alice", "bob"]
    end

    test "accepts the separators a name might be written with" do
      assert Mentions.handles("@alice-smith @alice_smith @alice.smith") ==
               ["alice-smith", "alice_smith", "alice.smith"]
    end

    test "is empty for a nil or handle-free body" do
      assert Mentions.handles(nil) == []
      assert Mentions.handles("no handles here") == []
    end

    # An email address in a comment body is not a mention of "example".
    test "an email address is not a handle" do
      assert Mentions.handles("mail alice@example.com about it") == []
    end

    test "a handle must start with a letter or digit" do
      assert Mentions.handles("@ @-nope @_nope") == []
    end
  end

  describe "resolve/2" do
    setup do
      %{people: [user(1, "Alice Smith"), user(2, "Bob Jones"), user(3, "Carol")]}
    end

    test "matches a full name however it was punctuated", %{people: people} do
      for handle <- ~w(@alicesmith @alice-smith @alice_smith @AliceSmith @Alice.Smith) do
        assert [%{id: 1}] = Mentions.resolve("hey #{handle} look", people)
      end
    end

    test "matches an unambiguous first name", %{people: people} do
      assert [%{id: 1}] = Mentions.resolve("@alice ping", people)
      assert [%{id: 3}] = Mentions.resolve("@carol ping", people)
    end

    test "returns each person once, in body order", %{people: people} do
      assert [%{id: 2}, %{id: 1}] =
               Mentions.resolve("@bob and @alice and @bobjones", people)
    end

    test "an unknown handle resolves to nobody", %{people: people} do
      assert Mentions.resolve("@nobody", people) == []
    end

    # The rule the moduledoc rests on: guessing would send someone else's
    # review feedback to the wrong person.
    test "an ambiguous handle resolves to nobody, but its unique forms still work" do
      people = [user(1, "Alice Smith"), user(2, "Alice Jones")]

      assert Mentions.resolve("@alice", people) == []
      assert [%{id: 1}] = Mentions.resolve("@alicesmith", people)
      assert [%{id: 2}] = Mentions.resolve("@alicejones", people)
    end

    test "a candidate with no name is never matched" do
      assert Mentions.resolve("@alice", [%{id: 1, name: nil}]) == []
    end
  end

  describe "unresolved/2" do
    test "reports handles that matched nothing or too much" do
      people = [user(1, "Alice Smith"), user(2, "Alice Jones")]

      assert Mentions.unresolved("@alice @alicesmith @nobody", people) == ["alice", "nobody"]
    end
  end

  describe "suggest/3" do
    setup do
      %{people: [user(1, "Alice Smith"), user(2, "Bob Jones"), user(3, "Carol Diaz")]}
    end

    test "matches a prefix of either the first name or the whole name", %{people: people} do
      assert [%{user: %{id: 1}}] = Mentions.suggest("ali", people)
      assert [%{user: %{id: 1}}] = Mentions.suggest("alicesm", people)
      assert [%{user: %{id: 2}}] = Mentions.suggest("bob", people)
    end

    test "normalises the query the same way a typed handle is", %{people: people} do
      for query <- ~w(Alice-Smith alice_smith ALICESMITH alice.smith) do
        assert [%{user: %{id: 1}}] = Mentions.suggest(query, people)
      end
    end

    test "an empty query offers the whole roster, by name", %{people: people} do
      assert [%{user: %{id: 1}}, %{user: %{id: 2}}, %{user: %{id: 3}}] =
               Mentions.suggest("", people)
    end

    test "offers the shortest handle that is unique", %{people: people} do
      assert [%{handle: "alice", ambiguous?: false}] = Mentions.suggest("ali", people)
    end

    # The rule the dropdown exists to keep: never offer a handle `resolve/2`
    # would then refuse. Both Alices match `@ali`, so neither is offered as
    # `alice` — each is offered as the full form that resolves to them alone.
    test "two Alices are each offered their own resolvable handle" do
      people = [user(1, "Alice Smith"), user(2, "Alice Jones")]

      assert [%{user: %{id: 2}, handle: jones}, %{user: %{id: 1}, handle: smith}] =
               Mentions.suggest("alice", people)

      assert jones == "alicejones"
      assert smith == "alicesmith"

      assert [%{id: 1}] = Mentions.resolve("@#{smith}", people)
      assert [%{id: 2}] = Mentions.resolve("@#{jones}", people)
    end

    # Every offered handle must resolve, whatever the roster looks like — this
    # is the invariant, checked against the resolver rather than restated.
    test "every suggestion for every prefix resolves to the person it names" do
      people = [
        user(1, "Alice Smith"),
        user(2, "Alice Jones"),
        user(3, "Alicia Smith"),
        user(4, "Bob")
      ]

      for query <- ~w(a al ali alic alice alicia b bob),
          suggestion <- Mentions.suggest(query, people) do
        refute suggestion.ambiguous?

        assert Mentions.resolve("@#{suggestion.handle}", people) == [suggestion.user],
               "@#{suggestion.handle} (offered for #{inspect(query)}) did not resolve to its own user"
      end
    end

    # Two people whose full names normalise identically: nothing can be offered
    # that resolves, so say so rather than pretend.
    test "identical names are flagged, not silently offered" do
      people = [user(1, "Alice Smith"), user(2, "alice smith")]

      assert [%{ambiguous?: true, handle: "alicesmith"}, %{ambiguous?: true}] =
               Mentions.suggest("alice", people)

      assert Mentions.resolve("@alicesmith", people) == []
    end

    test "a candidate with no name is never suggested" do
      assert Mentions.suggest("alice", [%{id: 1, name: nil}]) == []
      assert Mentions.suggest("", [%{id: 1, name: nil}]) == []
    end

    test "a query matching nobody suggests nobody", %{people: people} do
      assert Mentions.suggest("zzz", people) == []
    end

    test "honours the limit" do
      people = for n <- 1..20, do: user(n, "Person #{n}")
      assert length(Mentions.suggest("person", people, 5)) == 5
    end
  end
end
