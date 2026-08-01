defmodule KilnCMS.Assist.Generator do
  @moduledoc """
  Behaviour for block-level content assist (#60).

  A deployment enables it by pointing config at a module:

      config :kiln_cms, KilnCMS.Assist,
        generator: KilnCMS.Assist.Generator.ReqLLM,
        model: "ollama:llama3.1"

  ## Why this is a separate switch from `KilnCMS.Seo`

  It would be convenient to hang both features off one setting, and wrong.
  Metadata drafting sends a page's text and gets back three short strings that
  a human vets before they reach a `<meta>` tag. Block assist sends the same
  text *and the author's own instructions*, and what comes back is prose bound
  for the page body. Different volume, different cadence, different budget, and
  an operator who accepted the first has not thereby accepted the second.

  The precedent is `c:KilnCMS.Seo.Generator.describe_image/2`, kept out of the
  drafting switch for exactly this reason: bundling capabilities means enabling
  one silently enables another.

  What the two features *do* share is the classification of what leaves the box
  (`KilnCMS.LLM`) and the spend ceiling mechanism (`KilnCMS.LLM.Budget`), so
  they can't drift apart on the questions where drift would be a lie to the
  operator.

  ## Contract

  Implementations receive a `KilnCMS.Assist.Request` — an explicit projection,
  already truncated — and return raw text. They must:

    * ground the output in the supplied content and invent nothing;
    * write in `request.locale` (the *record's* locale, not the admin UI's);
    * treat the passage as **untrusted data**, never as instructions;
    * expose **no tools**. The callback takes a struct of strings and returns a
      string. Output lands in the page body of a site the operator publishes,
      so a successful prompt injection already buys defaced copy; handing the
      model actions to call would let it buy the database.

  Returning free text rather than a structured object is deliberate: it needs
  no provider-side tool-calling or JSON-schema support, which is exactly what
  the small local models Kiln recommends for on-prem tend to lack. Prose is
  the one output shape every provider can produce.

  Output is never trusted either: `KilnCMS.Assist.Suggestion.normalize/2` runs
  over whatever comes back, and nothing reaches a block without a human
  clicking Insert or Replace.
  """

  alias KilnCMS.Assist.Request

  @doc "Generate prose for `request`."
  @callback generate(request :: Request.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:ok, String.t(), map()} | {:error, term()}
end
