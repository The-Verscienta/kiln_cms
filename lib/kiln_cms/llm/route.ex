defmodule KilnCMS.LLM.Route do
  @moduledoc """
  Where one AI request goes: the model, and — for a site's own provider — the
  key and endpoint that go with it (#1557).

  Built by the feature facades (`KilnCMS.Seo`, `KilnCMS.Assist`, `KilnCMS.Ask`)
  from `KilnCMS.LLM.SiteProvider`'s answer, and spent by `KilnCMS.LLM.Client`.

    * `source: :operator` — the operator's configuration, exactly as before
      #1557. `model` is the operator's `"provider:model"` spec; the key is
      whatever `req_llm` finds in its own config and environment, and
      `api_key` / `base_url` here are `nil`.
    * `source: :site` — the site's own row. `api_key` and `base_url` are
      always the site's and never merged with anything of the operator's.

  `api_key` is left out of `inspect/2`, so a route that reaches a log line or
  a crash report does not take the key with it.
  """

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:source, :model]
  defstruct [:source, :provider, :model, :base_url, :api_key]

  @type t :: %__MODULE__{
          source: :operator | :site,
          provider: atom() | nil,
          model: String.t() | nil,
          base_url: String.t() | nil,
          api_key: String.t() | nil
        }

  @doc "The operator's route for a feature whose model spec is `model`."
  @spec operator(String.t() | nil) :: t()
  def operator(model), do: %__MODULE__{source: :operator, model: model}
end
