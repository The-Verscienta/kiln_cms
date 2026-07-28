defmodule KilnCMS.Seo.Generator do
  @moduledoc """
  Behaviour for the optional **drafting** step of the SEO panel (#60, #476).

  Analysis — the checks in `KilnCMS.Seo.Analyzer` — is always on, deterministic
  and local. This behaviour is the separate, opt-in step that proposes values
  for `seo_title`, `seo_description` and `seo_keywords` from the content itself.

  A deployment enables it by pointing config at a module:

      config :kiln_cms, KilnCMS.Seo,
        generator: KilnCMS.Seo.Generator.ReqLLM,
        model: "ollama:llama3.1"

  Unlike `KilnCMS.Ask.Generator`, Kiln *does* ship a working implementation —
  `KilnCMS.Seo.Generator.ReqLLM` — but it stays **disabled by default**
  (`generator: nil`), so a default install sends nothing anywhere. The shipped
  adapter is provider-agnostic and on-prem-capable: `req_llm` carries `ollama`
  and `vllm` providers and lets any provider's `base_url` be overridden, so
  pointing it at a local endpoint keeps content inside the deployment. That is
  an operator choice, and `KilnCMS.Seo.egress?/0` surfaces which one was made.

  ## Contract

  Implementations receive a `KilnCMS.Seo.Document` — a plain projection of the
  content, already truncated — and return a `KilnCMS.Seo.Draft`. They must:

    * ground every proposal in the supplied content and invent nothing;
    * write in `document.locale` (the *record's* locale, not the admin UI's);
    * treat the body as **untrusted data**, never as instructions;
    * expose **no tools**. The callback takes strings and returns strings.
      Drafted text lands in `<meta>` tags on the public site, so a successful
      prompt injection would already buy SEO cloaking on the operator's domain;
      handing the model actions to call would make that far worse.

  Output is never trusted either: `KilnCMS.Seo.Draft.normalize/1` runs over
  whatever comes back, and nothing is written to a record without a human
  clicking accept.
  """

  alias KilnCMS.Seo.Document
  alias KilnCMS.Seo.Draft

  @doc "Propose SEO metadata for `document`."
  @callback draft(document :: Document.t(), opts :: keyword()) ::
              {:ok, Draft.t()} | {:error, term()}

  @doc """
  Describe an image for alt text.

  Declared so the shape is fixed, but **not implemented by the shipped
  adapter** and not called anywhere yet: alt text needs a *vision* model, which
  is a different capability, a different cost tier, and a materially different
  egress decision (it ships the image bytes, not prose). Bundling it under the
  same switch would mean an operator who enabled description drafting silently
  started uploading their media library.
  """
  @callback describe_image(source :: map(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @optional_callbacks describe_image: 2
end
