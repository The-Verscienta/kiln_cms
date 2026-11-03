defmodule KilnCMS.Search.Synonyms do
  @moduledoc """
  Query-time synonym expansion (proposal A7): the alternate wordings a site's
  `KilnCMS.CMS.SearchSynonym` rules give a query.

  `alternates/2` finds every rule term the query contains — at word
  boundaries, case-insensitively, a multi-word term as a phrase — and answers
  the query with that term replaced by each of its alternates: with
  `reishi ⇄ ling zhi`, "reishi tea" is also searched as "ling zhi tea". A group
  maps every term to every other one; a one-way rule maps its terms to
  `expands_to` and nothing back. Longer terms are tried first, so a rule on
  "ling zhi" is not pre-empted by one on "ling". An alternate whose wording
  the query already contains is skipped ("reishi ling zhi" needs no second
  "ling zhi"), and at most `max_alternates/0` are returned, in rule order —
  each one is a further keyword, title and alias read per content type
  (`KilnCMS.Search.hybrid/3`).

  The rules are read once per site and cached under the dynamic-type
  registry's TTL, busted by every rule write (`Changes.SynonymsChanged`), so
  a rule saved in the console applies to the next search. They are read as
  the system actor of the `:search` subsystem, failing closed: a refused read
  raises rather than caching "no synonyms".
  """

  alias KilnCMS.Cache
  alias KilnCMS.CMS.ContentTypes

  @ttl :timer.minutes(5)
  @max_alternates 4

  @typedoc "A trigger term and what it expands to, both normalized."
  @type mapping :: {String.t(), [String.t()]}

  @doc "The most alternates one query is expanded to."
  @spec max_alternates() :: pos_integer()
  def max_alternates, do: @max_alternates

  @doc """
  `term` as rules store it and queries are compared: trimmed, lowercased,
  inner whitespace collapsed to one space.
  """
  @spec normalize(String.t() | nil) :: String.t()
  def normalize(nil), do: ""

  def normalize(term) when is_binary(term) do
    term |> String.downcase() |> String.split() |> Enum.join(" ")
  end

  @doc """
  The alternate wordings of `query` on the site `tenant` (an org, an id, or
  nil for the default org) — `[]` when no rule applies, which keeps a site
  without synonyms at exactly the reads it made before.
  """
  @spec alternates(String.t(), KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil) ::
          [String.t()]
  def alternates(query, tenant) when is_binary(query) do
    case normalize(query) do
      "" -> []
      normalized -> expand(normalized, mappings(KilnCMS.Accounts.org_id(tenant)))
    end
  end

  @doc """
  `query`'s alternates under `mappings` — the matching half of `alternates/2`,
  without the database.
  """
  @spec expand(String.t(), [mapping()]) :: [String.t()]
  def expand(query, mappings) do
    normalized = normalize(query)

    mappings
    |> Enum.flat_map(&rewrites(&1, normalized))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == normalized))
    |> Enum.take(@max_alternates)
  end

  @doc """
  Every trigger term on the site with what it expands to, longest term first
  (ties in rule order). Enabled rules only.
  """
  @spec mappings(Ash.UUID.t()) :: [mapping()]
  def mappings(org_id) do
    if ContentTypes.cache_registry?() do
      Cache.fetch(Cache.search_synonyms_key(org_id), @ttl, fn -> load(org_id) end)
    else
      load(org_id)
    end
  end

  @doc "Drop `org_id`'s cached rules, on every node."
  @spec bust(Ash.UUID.t() | nil) :: :ok
  def bust(nil), do: :ok
  def bust(org_id), do: Cache.bust_search_synonyms(org_id)

  @doc """
  The trigger/target pairs one rule contributes: each term of a group maps to
  the group's other terms, and each term of a one-way rule to its targets.
  """
  @spec rule_mappings(KilnCMS.CMS.SearchSynonym.t() | map()) :: [mapping()]
  def rule_mappings(%{kind: :group, terms: terms}),
    do: Enum.map(terms, &{&1, List.delete(terms, &1)})

  def rule_mappings(%{kind: :one_way, terms: terms, expands_to: targets}),
    do: Enum.map(terms, &{&1, targets})

  defp load(org_id) do
    KilnCMS.CMS.list_search_synonyms!(
      query: [filter: [enabled: true], sort: [inserted_at: :asc, id: :asc]],
      actor: KilnCMS.SystemActor.new(:search),
      authorize_with: :error,
      tenant: org_id
    )
    |> Enum.flat_map(&rule_mappings/1)
    # A term in two rules expands to both rules' targets, under one entry.
    |> Enum.reduce({[], %{}}, fn {term, targets}, {order, acc} ->
      if Map.has_key?(acc, term),
        do: {order, Map.update!(acc, term, &Enum.uniq(&1 ++ targets))},
        else: {[term | order], Map.put(acc, term, targets)}
    end)
    |> then(fn {order, acc} -> order |> Enum.reverse() |> Enum.map(&{&1, acc[&1]}) end)
    |> Enum.with_index()
    |> Enum.sort_by(fn {{term, _targets}, index} -> {-String.length(term), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  # `query` with `term` replaced by each target it does not already name.
  defp rewrites({term, targets}, query) do
    pattern = phrase(term)

    if Regex.match?(pattern, query) do
      targets
      |> Enum.reject(&Regex.match?(phrase(&1), query))
      |> Enum.map(&replace(pattern, query, &1))
    else
      []
    end
  end

  # A function, not a replacement string: a `\1` in a rule is text.
  defp replace(pattern, query, target), do: Regex.replace(pattern, query, fn _ -> target end)

  # The term as a phrase: whole words only, so "ling" does not match inside
  # "lingering", and a multi-word term matches its words in order.
  defp phrase(term), do: ~r/(?<![[:alnum:]])#{Regex.escape(term)}(?![[:alnum:]])/u
end
