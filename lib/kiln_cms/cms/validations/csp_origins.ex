defmodule KilnCMS.CMS.Validations.CspOrigins do
  @moduledoc """
  Validates the per-site CSP source lists on `SiteCodeInjection` (#490).

  These strings are concatenated into a `Content-Security-Policy` header, so the
  validation is a security boundary, not tidiness. Two distinct hazards:

    * **Keyword sources.** `'unsafe-inline'`, `'unsafe-eval'`, `data:` and a bare
      `*` are all valid CSP syntax, and any one of them turns a settings form
      into a switch that disables the policy it is meant to be extending — for a
      site whose whole point is running third-party script. They are refused by
      name *and* by the general shape rule below, which admits only
      scheme-and-host.
    * **Header injection.** A newline, a semicolon or a comma in one of these
      values ends the directive (or the header) and lets the rest be chosen by
      the author. The shape rule excludes every one of those characters, so this
      cannot be reached by an odd-looking-but-passing value.

  Accepted shape: `https://host`, optionally `*.`-prefixed on the leftmost
  label, optionally with a port. `http://` is refused except for `localhost` and
  `127.0.0.1`, because a plaintext analytics endpoint on a published site is a
  mixed-content error at best and a tap on every reader at worst — but a
  developer pointing at a local Matomo needs it to work.
  """
  use Ash.Resource.Validation

  @fields [:script_src, :connect_src, :img_src]

  # Deliberately a whole-string anchor with a tight character class: `;`, `,`,
  # whitespace and control characters cannot appear anywhere in a match, so a
  # value that passes cannot end the directive it lands in.
  #
  # `\A`/`\z`, NOT `^`/`$`. In PCRE — which is what Elixir's `Regex` is — `$`
  # matches *before a final newline*, so `"https://ok.example\n"` satisfies a
  # `$`-anchored pattern and lands a newline inside a response header. That is
  # the one input this validation exists to stop, and the anchor that looks
  # right is the one that lets it through.
  @origin ~r"\Ahttps?://(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:\d{1,5})?\z"i

  @plaintext_ok ~w(localhost 127.0.0.1)

  @impl true
  def validate(changeset, _opts, _context) do
    Enum.reduce_while(@fields, :ok, fn field, :ok ->
      case Ash.Changeset.get_attribute(changeset, field) do
        nil -> {:cont, :ok}
        origins -> check(field, origins)
      end
    end)
  end

  @impl true
  def describe(_opts), do: [message: "must be an https origin", vars: []]

  defp check(field, origins) do
    case Enum.find(origins, &(not valid?(&1))) do
      nil -> {:cont, :ok}
      bad -> {:halt, error(field, bad)}
    end
  end

  @doc """
  Whether one string is an acceptable CSP source.

  Public so the shape can be asserted directly. Ash's `:string` type trims
  before this runs, so a value with surrounding whitespace never reaches it in
  practice — and that is not a reason for the pattern to accept one. Testing the
  predicate rather than only the action is what keeps the two independent.
  """
  @spec valid_origin?(term()) :: boolean()
  def valid_origin?(origin) when is_binary(origin) do
    Regex.match?(@origin, origin) and scheme_ok?(origin)
  end

  def valid_origin?(_origin), do: false

  defp valid?(origin), do: valid_origin?(origin)

  defp scheme_ok?("https://" <> _rest), do: true

  defp scheme_ok?("http://" <> rest) do
    rest |> String.split(":") |> List.first() |> Kernel.in(@plaintext_ok)
  end

  defp scheme_ok?(_origin), do: false

  defp error(field, bad) do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: field,
       message:
         "%{value} is not an allowed CSP source. Use a full origin such as " <>
           "https://plausible.io (a leading *. and a port are allowed). Keyword " <>
           "sources like 'unsafe-inline' and bare wildcards are refused: they would " <>
           "switch off the policy this list extends.",
       vars: [value: bad]
     )}
  end
end
