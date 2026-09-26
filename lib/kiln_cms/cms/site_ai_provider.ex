defmodule KilnCMS.CMS.SiteAiProvider do
  @moduledoc """
  A site's own AI provider (#1557): the provider, API key and model per feature
  (SEO suggestions, block assist, `/api/ask` answers) this site's AI requests
  use, entered by the site's admin at `/editor/site-ai` instead of by the
  operator in `SEO_MODEL` / `ASSIST_MODEL` / `ASK_MODEL` and the provider key
  variables `req_llm` reads.

  The second of the per-site integrations #1322 moves out of the environment,
  built the way `KilnCMS.CMS.SiteMailRelay` set the pattern. Read through
  `KilnCMS.LLM.SiteProvider`, which owns the precedence rule and the fail
  direction; nothing else should read this row.

  ## Who can write it, and what that means

  Org admin, like every `KilnCMS.CMS.OrgSettings` resource. On a hosted
  deployment that is a tenant, so:

    * **The API key is database-only.** It is encrypted into
      `api_key_encrypted` (`KilnCMS.Keys.Vault`) and never read back into a
      form. There is no env-var or file source for it: a tenant who could
      point "the API key" at an environment variable could send
      `SECRET_KEY_BASE` — or the operator's own `ANTHROPIC_API_KEY` — to a
      provider endpoint of their choosing.
    * **The provider is a closed list.** Hosted providers go to their own fixed
      API host. The one tenant-chosen host is the `:openai_compatible` base URL,
      which must be `https://`, is SSRF-checked at save
      (`Validations.AiBaseUrl`), and is dialled only through
      `KilnCMS.SafeFetch`, which checks and pins it again on every request.
      `ollama` and `vllm` are not offered: their default endpoint is
      `localhost`, which on this server is the operator's machine.

  Reads are admin-only too. The row names the site's AI vendor and account.

  ## The key on a save

  A blank key keeps the stored one — the form never has it to send back.
  **Changing the provider or the base URL drops the stored key** unless a new
  one comes with the change, because the key was entered for the old
  destination: keeping it would let anyone who can edit the row (another admin
  of this site) redirect a key they were never shown to a host they control.
  A hosted provider with no key is refused. `api_key_encrypted` is left out of
  the upsert's `upsert_fields` for the reason `SiteMailRelay` gives.

  ## Models

  One per feature, as the provider names it (`claude-sonnet-5`, `gpt-5-mini`).
  A blank model switches **that feature off for this site** while the row is
  on — it does not hand the feature back to the operator's provider (see
  `KilnCMS.LLM.SiteProvider`).
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_ai_providers",
    accept: [:enabled, :provider, :base_url, :seo_model, :assist_model, :ask_model],
    save_arguments: [{:api_key, :string, sensitive?: true}],
    save_changes: [KilnCMS.CMS.Changes.StoreAiApiKey],
    read: :admin

  @providers [
    :anthropic,
    :openai,
    :google,
    :mistral,
    :groq,
    :openrouter,
    :xai,
    :openai_compatible
  ]

  @doc "Every provider a site may choose, in the order the form offers them."
  @spec providers() :: [atom()]
  def providers, do: @providers

  postgres do
    # Ash casts `provider` to an atom on read, so an out-of-band write of any
    # other string would crash the read — and with it every AI request for the
    # site. Same guard as `site_mail_relays.security`.
    check_constraints do
      check_constraint :provider, "site_ai_provider_provider_must_be_known",
        check:
          "provider IN ('anthropic', 'openai', 'google', 'mistral', 'groq', 'openrouter', 'xai', 'openai_compatible')"
    end
  end

  validations do
    validate present(:base_url), where: [attribute_equals(:provider, :openai_compatible)]
    validate KilnCMS.CMS.Validations.AiBaseUrl

    validate match(:seo_model, ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]*\z/),
      message: "must be a model name like claude-sonnet-5, without spaces"

    validate match(:assist_model, ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]*\z/),
      message: "must be a model name like claude-sonnet-5, without spaces"

    validate match(:ask_model, ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]*\z/),
      message: "must be a model name like claude-sonnet-5, without spaces"
  end

  attributes do
    # Off keeps the details but sends every feature back to the operator's
    # configuration — the way back from a broken key that does not mean
    # retyping everything.
    attribute :enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    attribute :provider, :atom do
      default :anthropic
      allow_nil? false
      public? true
      constraints one_of: @providers
    end

    # Only for `:openai_compatible`: the API root, e.g.
    # `https://llm.example.com/v1`. `/chat/completions` is appended to it.
    attribute :base_url, :string,
      public?: true,
      constraints: [max_length: 2048]

    attribute :seo_model, :string, public?: true, constraints: [max_length: 200]
    attribute :assist_model, :string, public?: true, constraints: [max_length: 200]
    attribute :ask_model, :string, public?: true, constraints: [max_length: 200]

    # Set only by `Changes.StoreAiApiKey`, from the `:api_key` argument.
    # `Vault.Ciphertext`, not plain `:binary`, so `mix kiln.vault.reencrypt`
    # walks it across a `SECRET_KEY_BASE` rotation (#1487).
    attribute :api_key_encrypted, KilnCMS.Keys.Vault.Ciphertext do
      sensitive? true
      writable? false
    end
  end
end
