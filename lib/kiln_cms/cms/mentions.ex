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
