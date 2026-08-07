defmodule KilnCMS.Slug do
  @moduledoc """
  URL slug generation shared by content and taxonomy.

  `slugify/1` is the mechanical transform: transliterate diacritics, downcase,
  drop punctuation, collapse whitespace/underscores to single hyphens.

  `derive/1` builds an SEO-style slug from a content title: `slugify/1` plus
  stripping common English stop words ("a", "the", "of", …) so titles like
  "A Guide to the Kiln" become "guide-kiln". If stripping would leave nothing
  (the title is only stop words), the unstripped slug is returned instead.
  """

  @stop_words ~w(a an the and or but nor of for to in on at by with from as into onto)

  # Base32's alphabet, lower-cased: a slug is `[a-z0-9-]`, and base64's `+` `/`
  # `=` are not. 8 characters is far more entropy than this needs — the point is
  # not to be unguessable, it is to not repeat across a restart.
  @suffix_alphabet ~c"abcdefghijklmnopqrstuvwxyz234567"
  @suffix_digits ~c"234567"
  @suffix_length 8

  @doc """
  A random suffix for a placeholder slug, unique across VM restarts.

  `System.unique_integer/1` is **not** usable for this, and was: it is a
  per-BEAM counter that resets to a low value every time the VM starts, while
  the rows it must not collide with live in Postgres and outlive any number of
  restarts. So a fresh node hands out `untitled-1`, `untitled-2`, … again and
  the create fails with "slug has already been taken" (#834).

  That reproduced roughly 1-in-5 in the E2E suite, whose server restarts often
  against a database that is not dropped in between — but nothing about it is
  test-only. Any production node restart re-enters the same low range, and the
  drafts it collides with are exactly the ones a previous boot created.

  ## Why it leads with a digit

  A plain base32 suffix is 8 characters of `[a-z2-7]` — and so is any 8-letter
  lowercase word. `untitled-thoughts` would have been indistinguishable from a
  generated slug, and `random_suffix?/1` is what decides whether a title edit
  may *overwrite* a slug, so that false positive would silently rewrite a URL
  the author chose. Leading with a digit costs nothing and no English word
  does it.

  The modulo below is very slightly biased (256 is not a multiple of 6 or 32).
  That is fine and deliberate: this is a collision-avoidance nonce, not a
  secret, and nothing downstream treats it as unguessable.
  """
  @spec random_suffix() :: String.t()
  def random_suffix do
    <<lead, rest::binary>> = :crypto.strong_rand_bytes(@suffix_length)

    [
      Enum.at(@suffix_digits, rem(lead, length(@suffix_digits)))
      | for(<<byte <- rest>>, do: Enum.at(@suffix_alphabet, rem(byte, length(@suffix_alphabet))))
    ]
    |> List.to_string()
  end

  @suffix_pattern ~r/\A[2-7][a-z2-7]{7}\z/

  @doc """
  Whether `value` has the shape `random_suffix/0` produces.

  Exposed so the *detector* and the *generator* cannot drift apart.
  `KilnCMS.CMS.Slugs.underived?/2` decides whether a slug is still an
  auto-generated scaffold that a title edit may replace; it used to recognise
  the scaffold by `untitled-<digits>`, which silently stopped matching the
  moment the suffix stopped being a counter. The symptom would have been mild
  and baffling — typing a title no longer updates a new draft's slug — and no
  test would have caught it, because the two lived in different modules with
  no shared definition.
  """
  @spec random_suffix?(String.t()) :: boolean()
  def random_suffix?(value) when is_binary(value), do: Regex.match?(@suffix_pattern, value)
  def random_suffix?(_value), do: false

  @doc "Title → SEO slug with stop words stripped; \"\" when nothing usable remains."
  def derive(title) when is_binary(title) do
    slug = slugify(title)

    case slug |> String.split("-", trim: true) |> Enum.reject(&(&1 in @stop_words)) do
      [] -> slug
      words -> Enum.join(words, "-")
    end
  end

  def derive(_title), do: ""

  @doc """
  The first comma-separated keyphrase of an SEO keywords string — the focus
  keyphrase that takes priority over the title when deriving a slug. `""`
  when blank/nil.
  """
  def focus_keyphrase(keywords) when is_binary(keywords) do
    keywords |> String.split(",", parts: 2) |> hd() |> String.trim()
  end

  def focus_keyphrase(_keywords), do: ""

  @doc """
  A string's **content words**: slugified with stop words stripped, so
  "Guide to the Kiln" and "guide-kiln" compare equal.

  The one normalization every keyphrase comparison runs on *both* sides, so
  that slug linting and the SEO advisories can never drift apart on what
  counts as a match. Note it strips **English** stop words — callers must treat
  keyphrase checks as en-biased.
  """
  @spec content_words(String.t() | nil) :: [String.t()]
  def content_words(text), do: text |> to_string() |> derive() |> String.split("-", trim: true)

  @doc "Whether every word in `needles` appears in `haystack`."
  @spec subset?([String.t()], [String.t()]) :: boolean()
  def subset?(needles, haystack), do: Enum.all?(needles, &(&1 in haystack))

  @doc "Plain slug transform (no stop-word stripping) — used for taxonomy names."
  def slugify(text) when is_binary(text) do
    text
    # NFD + strip combining marks transliterates "Café" → "Cafe" instead of
    # the accented letter vanishing entirely in the ASCII filter below.
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.replace(~r/[\s_-]+/, "-")
    |> String.trim("-")
  end

  def slugify(_text), do: ""
end
