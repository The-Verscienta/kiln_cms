defmodule KilnCMS.CMS.Mentions do
  @moduledoc """
  `@name` mentions in an editorial comment body (#801).

  Genuinely net-new — nothing else in Kiln resolves "notify this person about
  this record" — so the rules are spelled out here rather than inferred from a
  sibling.

  ## The handle is a normalised name, not a separate column

  Users have a freeform `name` ("Alice Smith") and no handle. Adding a handle
  column would mean a migration, a settings field, a uniqueness rule and a
  backfill for a feature whose whole job is convenience. Instead a mention
  matches against the name with case and separators removed:

      "Alice Smith"  ->  @alicesmith, @alice-smith, @alice_smith, @AliceSmith

  A mention is also matched against the **first word** of a name, so `@alice`
  finds Alice Smith — but only while it is unambiguous (see below).

  ## Ambiguity notifies nobody

  Two people called Alice, and `@alice` resolves to neither. Guessing would
  send someone else's review feedback to the wrong person, which is worse than
  the mention quietly not firing — the comment itself is still visible to
  everyone on the thread. `unresolved/2` reports which handles matched nothing
  so a UI can say so.

  ## Scope

  Candidates come from the org's own members. A mention can never reach a user
  outside the org the comment was written in, whatever the body says.
  """

  # `@` then a run of name characters. Deliberately no spaces: "@Alice Smith"
  # would make "@Alice Smith wrote" ambiguous with the prose after it, and the
  # normalised forms above already cover multi-word names.
  @handle ~r/(?<![\w@])@([a-z0-9][a-z0-9._-]{0,63})/i

  @doc """
  The handles a body mentions, lowercased and de-duplicated, in first-seen
  order — **as the author typed them**, so `unresolved/2` can report a miss in
  the same shape it appears in the comment. Matching normalises both sides;
  see `resolve/2`.

  `[]` for a nil or handle-free body.
  """
  @spec handles(String.t() | nil) :: [String.t()]
  def handles(nil), do: []

  def handles(body) when is_binary(body) do
    @handle
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  @doc """
  Resolve `body`'s handles against `candidates`, returning the matched users.

  Order follows the body. A handle matching more than one candidate resolves to
  none of them — see the moduledoc.
  """
  @spec resolve(String.t() | nil, [struct()]) :: [struct()]
  def resolve(body, candidates) do
    index = index(candidates)

    body
    |> handles()
    |> Enum.flat_map(fn handle ->
      case Map.get(index, normalise(handle)) do
        [user] -> [user]
        _none_or_many -> []
      end
    end)
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Candidates for a half-typed `@handle`, for the composer's autocomplete.

  Returns `%{user: user, handle: handle, ambiguous?: boolean}` maps sorted by
  name, at most `limit` of them (default 8). `query` is what the author has
  typed after the `@`, normalised the same way everything else here is, so
  `"Ali"`, `"ali-"` and `"ali"` are one query.

  **`handle` is the form that will actually resolve**, not the form that
  matched. Two Alices both match `@ali`, so neither is offered as `alice` —
  they are offered as `alicesmith` and `alicejones`, the shortest form of each
  that is unique in this org. Picking from a dropdown that suggested a handle
  `resolve/2` then refuses to resolve would be worse than having no dropdown
  at all: the author would watch themselves address someone and never find out
  nobody was told.

  `ambiguous?: true` is the case even that cannot fix — two members whose full
  names normalise identically. The handle is still returned so the mention can
  be typed and read by humans, and the flag is there for the UI to say it will
  not notify anyone.
  """
  @spec suggest(String.t() | nil, [struct()], pos_integer()) :: [
          %{user: struct(), handle: String.t(), ambiguous?: boolean()}
        ]
  def suggest(query, candidates, limit \\ 8) do
    index = index(candidates)
    normalised_query = normalise(query)

    candidates
    |> Enum.filter(&matches_prefix?(&1, normalised_query))
    |> Enum.sort_by(&sort_key/1)
    |> Enum.take(limit)
    |> Enum.map(fn user ->
      case unambiguous_form(user, index) do
        nil -> %{user: user, handle: fullest_form(user), ambiguous?: true}
        handle -> %{user: user, handle: handle, ambiguous?: false}
      end
    end)
  end

  # An empty query offers the whole roster — pressing `@` and pausing is a
  # request to see who is here, not a request for nothing.
  defp matches_prefix?(user, ""), do: forms(user) != []

  defp matches_prefix?(user, query),
    do: Enum.any?(forms(user), &String.starts_with?(&1, query))

  # The shortest form that names this user and nobody else. `forms/1` returns
  # the full normalised name and the first word, so this prefers `alice` when
  # she is the only Alice and falls back to `alicesmith` when she is not.
  defp unambiguous_form(user, index) do
    user
    |> forms()
    |> Enum.sort_by(&String.length/1)
    |> Enum.find(&match?([_single], Map.get(index, &1)))
  end

  # The most specific thing this user can be called — their whole name,
  # normalised. Only reached when even that collides with someone else's, so
  # it is offered as the closest thing to a handle that exists rather than as
  # one that will work.
  defp fullest_form(user) do
    case Enum.sort_by(forms(user), &String.length/1, :desc) do
      [longest | _rest] -> longest
      [] -> ""
    end
  end

  defp sort_key(%{name: name}) when is_binary(name), do: String.downcase(name)
  defp sort_key(_user), do: ""

  @doc """
  The handles in `body` that matched no single candidate — unknown or
  ambiguous. For telling an author their mention did not land.
  """
  @spec unresolved(String.t() | nil, [struct()]) :: [String.t()]
  def unresolved(body, candidates) do
    index = index(candidates)

    body
    |> handles()
    |> Enum.reject(&match?([_single], Map.get(index, normalise(&1))))
  end

  # handle -> [user, ...]. A user is indexed under every form that should find
  # them, so a collision on ANY of those forms makes that particular handle
  # ambiguous without poisoning the others: two Alices collide on "alice" while
  # "alicesmith" and "alicejones" each stay unique.
  defp index(candidates) do
    Enum.reduce(candidates, %{}, fn user, acc ->
      Enum.reduce(forms(user), acc, fn form, inner ->
        Map.update(inner, form, [user], &[user | &1])
      end)
    end)
  end

  defp forms(%{name: name}) when is_binary(name) do
    normalised = normalise(name)

    first =
      name
      |> String.split(~r/\s+/u, trim: true)
      |> List.first()
      |> normalise()

    Enum.uniq(Enum.reject([normalised, first], &(&1 == "")))
  end

  defp forms(_user), do: []

  # Everything that is not a letter or a digit goes, so the separator an author
  # happened to type (or omit) never decides whether a mention lands.
  defp normalise(nil), do: ""

  defp normalise(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]/u, "")
  end
end
