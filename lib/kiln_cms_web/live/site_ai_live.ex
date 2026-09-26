defmodule KilnCMSWeb.SiteAiLive do
  @moduledoc """
  A site's own AI provider (#1557): the provider, API key and models this
  site's SEO suggestions, block assist and `/api/ask` answers use, at
  `/editor/site-ai`.

  Before this, all three were `SEO_MODEL` / `ASSIST_MODEL` / `ASK_MODEL` and
  the provider key variables — one AI account for the whole deployment,
  changed by the operator with a redeploy. Now a site admin can send their
  site's AI requests to their own account with no redeploy. The operator's
  configuration stays underneath for every site that has not set one.

  Scoped to the request's org, like `/editor/site-mail`. Writes are
  policy-gated to org admins by `KilnCMS.CMS.SiteAiProvider`, and the
  `:admin_routes` live session gates on the same tier.

  ## What the page has to say

    * **Which provider each feature uses now** — this site's, the deployment's,
      or none. A blank model switches that feature off for the site while its
      own provider is on; the page says so rather than letting the admin think
      the deployment's provider picks it up.
    * **Where the content goes.** Every feature sends content off this server,
      and `/api/ask` does it for anonymous visitors.
    * **When the stored key can't be read.** After a `SECRET_KEY_BASE`
      rotation the row still looks fine, but every AI request for the site is
      refused. This page is the one place that can say so.

  The key field is write-only. It is never filled in, so a blank field keeps
  the stored key — unless the provider or endpoint changes, which drops it
  (`Changes.StoreAiApiKey`).
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.CMS.SiteAiProvider
  alias KilnCMS.LLM.SiteProvider

  @fields ~w(provider base_url seo_model assist_model ask_model)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("AI provider"))
     |> load_provider()}
  end

  @impl true
  def handle_event("validate", %{"ai" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, :form, to_form(Map.delete(params, "api_key"), as: :ai))}
  end

  def handle_event("save", %{"ai" => params}, socket) when is_map(params) do
    opts = [actor: socket.assigns.current_user, tenant: socket.assigns.current_org]

    # An existing row is updated, never re-upserted: the upsert leaves the key
    # out of what it overwrites (see `SiteAiProvider`'s moduledoc).
    result =
      case socket.assigns.row do
        nil -> CMS.save_site_ai_provider(attrs(params), opts)
        row -> CMS.update_site_ai_provider(row, attrs(params), opts)
      end

    case result do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("AI provider saved."))
         |> load_provider()}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Map.delete(params, "api_key"), as: :ai))
         |> put_flash(:error, error_message(error))}
    end
  end

  def handle_event("reset", _params, socket) do
    case socket.assigns.row do
      nil ->
        {:noreply, socket}

      row ->
        CMS.reset_site_ai_provider!(row,
          actor: socket.assigns.current_user,
          tenant: socket.assigns.current_org
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Removed. This site's AI features use the deployment's configuration again.")
         )
         |> load_provider()}
    end
  end

  defp attrs(params) do
    params
    |> Map.take(@fields)
    |> Map.put("enabled", params["enabled"] in [true, "true", "on"])
    |> Map.put("api_key", params["api_key"])
  end

  defp load_provider(socket) do
    row = current_row(socket)

    params =
      if row do
        %{
          "enabled" => row.enabled,
          "provider" => to_string(row.provider),
          "base_url" => row.base_url,
          "seo_model" => row.seo_model,
          "assist_model" => row.assist_model,
          "ask_model" => row.ask_model
        }
      else
        %{"enabled" => true, "provider" => "anthropic"}
      end

    org_id = KilnCMS.Accounts.org_id(socket.assigns.current_org)

    socket
    |> assign(:row, row)
    |> assign(:key_stored?, row && not is_nil(row.api_key_encrypted))
    |> assign(:key_readable?, is_nil(row) or SiteProvider.key_readable?(row))
    |> assign(:features, feature_status(org_id))
    |> assign(:form, to_form(params, as: :ai))
  end

  defp current_row(socket) do
    case CMS.list_site_ai_provider(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _ -> nil
    end
  end

  # One line per feature: whose provider it uses on this site right now.
  defp feature_status(org_id) do
    [
      {gettext("SEO suggestions"), KilnCMS.Seo.summary(org_id)},
      {gettext("Block assist"), KilnCMS.Assist.summary(org_id)},
      {gettext("Answers on /api/ask"), ask_summary(org_id)}
    ]
  end

  defp ask_summary(org_id), do: KilnCMS.LLM.summary(KilnCMS.Ask.route(org_id), nil)

  defp status_text(%{source: :site, error: nil, provider: provider}),
    do: gettext("This site's provider (%{provider})", provider: provider_label(provider))

  defp status_text(%{source: :site}),
    do: gettext("Refused: this site's provider is set but can't be used")

  defp status_text(%{source: :operator, provider: provider}) when is_binary(provider),
    do: gettext("The deployment's provider (%{provider})", provider: provider)

  defp status_text(%{source: :operator}), do: gettext("The deployment's provider")
  defp status_text(_off), do: gettext("Off")

  defp provider_options do
    Enum.map(SiteAiProvider.providers(), &{provider_label(&1), to_string(&1)})
  end

  defp provider_label(provider) when is_binary(provider) do
    case Enum.find(SiteAiProvider.providers(), &(to_string(&1) == provider)) do
      nil -> provider
      known -> provider_label(known)
    end
  end

  defp provider_label(:anthropic), do: "Anthropic"
  defp provider_label(:openai), do: "OpenAI"
  defp provider_label(:google), do: "Google Gemini"
  defp provider_label(:mistral), do: "Mistral"
  defp provider_label(:groq), do: "Groq"
  defp provider_label(:openrouter), do: "OpenRouter"
  defp provider_label(:xai), do: "xAI"
  defp provider_label(:openai_compatible), do: gettext("OpenAI-compatible endpoint")

  defp error_message(error) do
    ash_error_message(error,
      forbidden: gettext("You don't have permission to change this site's AI provider."),
      fallback: gettext("The AI provider could not be saved.")
    )
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :compatible?, assigns.form[:provider].value == "openai_compatible")

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      active={:site_ai}
    >
      <.header>
        {gettext("AI provider")}
        <:subtitle>
          {gettext("The AI account and models this site's suggestions, block assist and answers use.")}
        </:subtitle>
      </.header>

      <div id="site-ai-status" class="mt-6 card card-pad text-sm">
        <dl class="grid gap-x-6 gap-y-2 sm:grid-cols-[auto_1fr]">
          <%= for {label, summary} <- @features do %>
            <dt class="font-medium">{label}</dt>
            <dd class="text-base-content/80">{status_text(summary)}</dd>
          <% end %>
        </dl>
        <p class="mt-3 text-base-content/70">
          {gettext(
            "Each feature sends content to the provider: a page's text for suggestions, a block and the editor's instruction for assist, and published passages plus a visitor's question for answers. Answers are requested by anonymous visitors."
          )}
        </p>
      </div>

      <div
        :if={not @key_readable?}
        id="site-ai-key-unreadable"
        role="alert"
        class="mt-4 rounded-lg border border-error/40 bg-error/10 p-4 text-sm text-error-ink"
      >
        <p class="font-medium">{gettext("The saved API key can't be read. Re-enter it.")}</p>
        <p class="mt-1">
          {gettext(
            "The deployment's secret key has changed since it was saved. Until you enter it again, this site's AI requests are refused, not sent anywhere else."
          )}
        </p>
      </div>

      <.form
        for={@form}
        id="site-ai-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-8 space-y-6"
      >
        <.input
          field={@form[:enabled]}
          type="checkbox"
          label={gettext("Use this site's own AI provider")}
          value={@form[:enabled].value}
        />

        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            field={@form[:provider]}
            type="select"
            label={gettext("Provider")}
            options={provider_options()}
          />
          <.input
            field={@form[:api_key]}
            type="password"
            label={gettext("API key")}
            value=""
            autocomplete="new-password"
            placeholder={if @key_stored?, do: gettext("Saved. Leave blank to keep it.")}
            hint={
              gettext(
                "Stored encrypted and never shown again. Changing the provider or endpoint removes it."
              )
            }
          />
        </div>

        <.input
          :if={@compatible?}
          field={@form[:base_url]}
          type="url"
          label={gettext("Endpoint URL")}
          placeholder="https://llm.example.com/v1"
          hint={
            gettext(
              "The API root of a server that speaks OpenAI's chat completions. Must be https:// and publicly reachable."
            )
          }
        />

        <fieldset class="space-y-4">
          <legend class="text-sm font-medium">{gettext("Models")}</legend>
          <p class="text-sm text-base-content/70">
            {gettext(
              "As the provider names them. Leave one blank to switch that feature off for this site; the deployment's provider does not take it over."
            )}
          </p>
          <div class="grid gap-4 sm:grid-cols-3">
            <.input
              field={@form[:seo_model]}
              type="text"
              label={gettext("SEO suggestions")}
              placeholder="claude-sonnet-5"
              autocomplete="off"
            />
            <.input
              field={@form[:assist_model]}
              type="text"
              label={gettext("Block assist")}
              placeholder="claude-sonnet-5"
              autocomplete="off"
            />
            <.input
              field={@form[:ask_model]}
              type="text"
              label={gettext("Answers")}
              placeholder="claude-sonnet-5"
              autocomplete="off"
            />
          </div>
        </fieldset>

        <div class="flex flex-wrap items-center gap-3">
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
          <.button
            :if={@row}
            type="button"
            variant="ghost"
            phx-click="reset"
            data-confirm={
              gettext(
                "Remove this site's AI provider? Its AI features will use the deployment's configuration again."
              )
            }
          >
            {gettext("Remove")}
          </.button>
        </div>
      </.form>
    </Layouts.console>
    """
  end
end
