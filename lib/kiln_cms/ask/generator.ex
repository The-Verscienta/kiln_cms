defmodule KilnCMS.Ask.Generator do
  @moduledoc """
  Behaviour for the *generation* step of `/api/ask` (RAG, issue #339).

  Retrieval — finding the relevant published passages — is always done by
  `KilnCMS.Ask`. This behaviour is the optional second step that turns those
  passages into a synthesized, cited answer. A deployment enables it by pointing
  config at a module:

      config :kiln_cms, KilnCMS.Ask, generator: MyApp.LocalLlmGenerator

  Kiln ships **no** generator by default, so `/api/ask` returns retrieval-only
  out of the box (answer `null`, sources populated). The intended production
  implementation is an **on-prem / no-egress** model (e.g. via `req_llm`/`ash_ai`
  against a local endpoint) so content never leaves the deployment — but that is
  an operator choice, kept out of the core (Phase 2).

  `sources` are the retrieved passages (`%{type, title, url, excerpt}`); an
  implementation should ground its answer in them and must not invent facts.
  """
  @callback generate(question :: String.t(), sources :: [map()]) ::
              {:ok, String.t()} | {:error, term()}
end
