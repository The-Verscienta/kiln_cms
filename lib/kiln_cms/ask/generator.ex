defmodule KilnCMS.Ask.Generator do
  @moduledoc """
  Behaviour for the *generation* step of `/api/ask` (RAG, issue #339).

  Retrieval — finding the relevant published passages — is always done by
  `KilnCMS.Ask`. This behaviour is the optional second step that turns those
  passages into a synthesized, cited answer. A deployment enables it by pointing
  config at a module:

      config :kiln_cms, KilnCMS.Ask,
        generator: KilnCMS.Ask.Generator.ReqLLM,
        model: "ollama:llama3.1"

  Kiln ships `KilnCMS.Ask.Generator.ReqLLM` but **enables nothing by default**,
  so `/api/ask` returns retrieval-only out of the box (answer `null`, sources
  populated). The recommended production configuration is an **on-prem /
  no-egress** endpoint so content never leaves the deployment — see
  `KilnCMS.Ask.egress?/0`, which reports which choice the operator made.

  `sources` are the retrieved passages (`%{type, title, url, excerpt}`) in the
  order the endpoint will return them; an implementation should ground its
  answer in them, cite them by position, and must not invent facts.

  ## Why there are two arities

  `c:generate/2` is the original contract and is still the required one, so a
  bespoke generator written against the #361 documentation keeps working
  untouched. `c:generate/3` is optional and preferred when exported: it carries
  the request's context — currently `:locale`, the *content* locale the answer
  should be written in, which a two-argument generator has no way to learn.
  """
  @callback generate(question :: String.t(), sources :: [map()]) ::
              {:ok, String.t()} | {:error, term()}

  @callback generate(question :: String.t(), sources :: [map()], opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @optional_callbacks generate: 3
end
