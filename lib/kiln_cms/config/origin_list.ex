defmodule KilnCMS.Config.OriginList do
  @moduledoc """
  One parser for the origin-allowlist environment variables `config/runtime.exs`
  reads — `EMBED_ORIGINS` and `CORS_ORIGINS` (#651).

  Both implement the same contract: a lone `"*"` means "every origin", anything
  else is a comma-separated allowlist with blanks dropped, and blank or unset is
  the closed default. They were two hand-rolled copies of that, and they had
  already begun to diverge — `KilnCMSWeb.Embed` grew entry validation in #562
  and `KilnCMSWeb.CORS` did not, so nobody had asked the "is `*` mixed into a
  list handled?" question on the CORS side at all.

  This is the same argument `KilnCMS.Config.Env` makes for the boolean
  variables: "seven call sites, no two guaranteed to agree (#607)". These are
  not boolean, so they correctly do not go through that module — but the
  split/trim/wildcard half deserves the same single home, so a future
  normalization (trailing slashes, case, the literal `null` origin) lands in one
  place instead of one and a half.

  ## Semantics

    * `nil` or blank → `[]`, the closed default.
    * exactly `"*"` → `:all`.
    * otherwise → the comma-separated entries, trimmed, blanks dropped.

  ## Validation is the caller's, and so is what a failure costs

  Each variable's entries mean different things — a `frame-ancestors` source is
  interpolated into a CSP header, a CORS origin is compared for equality — so
  the *predicate* is passed in. So is the consequence, via `:on_invalid`,
  because the two are genuinely different and collapsing them would be wrong in
  one direction or the other:

    * `:discard_all` — one bad entry discards the whole value for `[]`.
      `EMBED_ORIGINS` needs this: a malformed entry there can *widen* the
      policy (a `;` appends CSP directives, a `*` mixed into a list grants every
      site), so a partially applied allowlist is not merely incomplete, it is
      dangerous.
    * `:keep` — bad entries are warned about and the rest are applied.
      `CORS_ORIGINS` wants this: an origin is compared for equality, so a
      malformed entry can only fail to match — it cannot widen anything. Failing
      the whole list closed on a stray typo would take a working integration
      down to fix a nuisance.

  What is shared either way is that the operator is told on stderr, naming the
  offending entries, rather than left with a setting that quietly isn't doing
  what it reads as doing.

  A validator is optional. Without one every non-blank entry is kept.
  """

  @typedoc "The config shape both variables resolve to."
  @type t :: :all | [String.t()]

  @doc """
  Parses an origin-list env value.

  ## Options

    * `:name` — the variable's name, for the warning. Required when `:validator`
      is given, since a warning that cannot name the setting is not actionable.
    * `:validator` — `(String.t() -> boolean())`.
    * `:on_invalid` — `:discard_all` (default) or `:keep`. See above; the choice
      belongs to what the entries are used for, not to this module.
    * `:describe` — what a valid entry is, e.g. `"frame-ancestors source"`.
      Defaults to `"origin"`.
    * `:example` — a sample value for the warning's closing hint.

  ## Examples

      iex> KilnCMS.Config.OriginList.parse(nil)
      []

      iex> KilnCMS.Config.OriginList.parse("  ")
      []

      iex> KilnCMS.Config.OriginList.parse("*")
      :all

      iex> KilnCMS.Config.OriginList.parse("https://a.test, ,https://b.test")
      ["https://a.test", "https://b.test"]
  """
  @spec parse(String.t() | nil, keyword()) :: t()
  def parse(value, opts \\ [])

  def parse(nil, _opts), do: []

  def parse(value, opts) when is_binary(value) do
    case String.trim(value) do
      "*" ->
        :all

      "" ->
        []

      trimmed ->
        trimmed
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> validate(value, opts)
    end
  end

  defp validate(entries, raw, opts) do
    case Keyword.get(opts, :validator) do
      nil -> entries
      validator -> reject_invalid(entries, Enum.reject(entries, validator), raw, opts)
    end
  end

  defp reject_invalid(entries, [], _raw, _opts), do: entries

  defp reject_invalid(entries, invalid, raw, opts) do
    name = Keyword.fetch!(opts, :name)
    describe = Keyword.get(opts, :describe, "origin")
    on_invalid = Keyword.get(opts, :on_invalid, :discard_all)
    plural = if length(invalid) == 1, do: "", else: "s"
    verb = if length(invalid) == 1, do: "is not a valid", else: "are not valid"

    outcome =
      case on_invalid do
        :discard_all ->
          "keeping the default (closed) rather than applying #{inspect(raw)} in part."

        :keep ->
          "it will never match a request. The rest of the list is applied."
      end

    hint =
      case Keyword.get(opts, :example) do
        nil -> ""
        example -> " Entries look like #{example}."
      end

    IO.warn(
      "#{name} contains #{Enum.map_join(invalid, ", ", &inspect/1)}, which #{verb} " <>
        "#{describe}#{plural}; #{outcome}#{hint}",
      []
    )

    if on_invalid == :keep, do: entries -- invalid, else: []
  end
end
