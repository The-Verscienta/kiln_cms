defmodule KilnCMSWeb.FormSettingsLive do
  @moduledoc """
  Per-site form settings (`/editor/forms/settings`, #1232): the org-wide embed
  allowlist (`KilnCMS.CMS.SiteEmbedSettings`, #1131) and the spam-check
  keyword list (`KilnCMS.CMS.FormSpamSettings`, #477).

  Both resources shipped managed only through the generic AshAdmin UI — which
  `config/prod.exs` compiles out (`dev_routes: false`), so on a production
  deployment an org admin had **no in-product way** to reach either: only the
  `iex` console or the database. For `SiteEmbedSettings` that undercut #1131's
  whole point, which was to give the *org admin*, not an operator with shell
  access, a way to set the default. This page is option 1 from the issue —
  the `SiteBranding` / `FeedSettings` bespoke-page shape — for the two of
  them together, because both are answers to "how do this site's forms
  behave" and neither is large enough to want a page of its own.

  Scoped to the request's org, like `/editor/feeds`; writes are policy-gated
  to org admins by both resources, and this LiveView sits in the
  `:admin_routes` live session whose `:live_admin_required` hook gates on the
  same tier, so the router guard and the resource policies agree.

  ## The embed default has three states, and the page says which

  Same tri-state as a form's own Embed tab, one rung up: **inherit** (no row,
  or a row with `embed_origins: nil` — the deployment's `EMBED_ORIGINS`
  governs), **this site only** (`[]`), or **a list**. The two "empty box"
  states are distinguished by a radio, for the reason
  `KilnCMSWeb.FormBuilderLive.form_params/1` gives: the box alone cannot say
  whether an empty list was meant. Saving "inherit" writes `nil` into the row
  rather than deleting it — `KilnCMS.Forms.EmbedPolicy.org_default/1` reads
  either as "fall through", and keeping the row keeps the spam keywords it
  shares nothing with but happens to sit beside in the UI honest: the two
  sections save independently, each to its own resource.

  Like #1130's Embed tab, this page never prints the deployment's
  `EMBED_ORIGINS` — on a shared deployment that is the union of every org's
  embedders. It does say when the operator has capped framing (#1133), because
  an admin whose entry is refused needs to know why.

  ## Keywords are one per line

  A textarea, split on newlines, trimmed, blanks dropped, de-duplicated
  case-insensitively — the check itself is a case-insensitive substring match
  (`Kiln.Forms.SpamCheck.Checks.DisallowedKeywords`), so two spellings of one
  keyword would only ever match together. Saving an empty box writes `[]`,
  which is "no keywords" — the same as never having set any, since the check
  reads `[]` as nothing to do; there is no inherit rung here, so no reset
  button either.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Form settings"))
     |> assign(:embed_draft, nil)
     |> assign(:keywords_draft, nil)
     |> load_settings()}
  end

  # ── embed default ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("save_embed", params, socket) do
    embed = if(is_map(params["embed"]), do: params["embed"], else: %{})

    case embed_origins_param(embed) do
      {:ok, origins} ->
        case CMS.save_site_embed_settings(%{embed_origins: origins},
               actor: socket.assigns.current_user,
               tenant: socket.assigns.current_org
             ) do
          {:ok, _row} ->
            {:noreply,
             socket
             |> assign(:embed_draft, nil)
             |> put_flash(:info, gettext("Embed default saved."))
             |> load_settings()}

          {:error, error} ->
            {:noreply,
             socket
             |> assign(:embed_draft, embed["origins"])
             |> put_flash(
               :error,
               error_message(error, gettext("Embed default could not be saved."))
             )}
        end

      {:error, message} ->
        {:noreply, socket |> assign(:embed_draft, embed["origins"]) |> put_flash(:error, message)}
    end
  end

  # ── spam keywords ──────────────────────────────────────────────────────────

  def handle_event("save_keywords", params, socket) do
    raw =
      case params do
        %{"spam" => %{"keywords" => raw}} when is_binary(raw) -> raw
        _other -> ""
      end

    case CMS.save_form_spam_settings(%{keywords: parse_keywords(raw)},
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> assign(:keywords_draft, nil)
         |> put_flash(:info, gettext("Spam keywords saved."))
         |> load_settings()}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:keywords_draft, raw)
         |> put_flash(:error, error_message(error, gettext("Spam keywords could not be saved.")))}
    end
  end

  # ── params ─────────────────────────────────────────────────────────────────

  # The radio and the box can contradict each other, and every way of resolving
  # that silently gets the admin's intent wrong — same refusal-not-guess rule as
  # the form's own Embed tab. Returns the value to write: `nil` (inherit), `[]`
  # (this site only), or the list.
  defp embed_origins_param(embed) do
    origins = KilnCMS.Config.OriginList.parse_list(embed["origins"])

    case {embed["mode"], origins} do
      {"inherit", []} ->
        {:ok, nil}

      {"closed", []} ->
        {:ok, []}

      {"list", [_ | _]} ->
        {:ok, origins}

      {"list", []} ->
        {:error, gettext("Add at least one site to embed on, or choose “This site only”.")}

      {mode, [_ | _]} when mode in ["inherit", "closed"] ->
        {:error,
         gettext("Choose “Only these sites” to use the list you typed, or clear the box.")}

      _unknown_mode ->
        {:error, gettext("Something went wrong.")}
    end
  end

  @doc false
  # One per line; trimmed, blanks dropped, case-insensitive duplicates dropped
  # (first spelling kept). Public-ish (`@doc false`) so the split rule can be
  # asserted directly.
  @spec parse_keywords(String.t()) :: [String.t()]
  def parse_keywords(raw) when is_binary(raw) do
    raw
    |> String.split(~r/\R/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  # ── state ──────────────────────────────────────────────────────────────────

  defp load_settings(socket) do
    opts = [actor: socket.assigns.current_user, tenant: socket.assigns.current_org]

    embed_row = first(CMS.list_site_embed_settings(opts))
    spam_row = first(CMS.list_form_spam_settings(opts))

    socket
    |> assign(:embed_row, embed_row)
    |> assign(:embed_mode, embed_mode(embed_row))
    |> assign(:spam_row, spam_row)
    # `EMBED_ORIGINS_LOCKED` (#1133) — read off the env directly rather than
    # through `KilnCMS.Forms.EmbedCeiling` so this page does not depend on that
    # PR's merge order; unset reads as off.
    |> assign(
      :ceiling_locked?,
      Application.get_env(:kiln_cms, :embed_origins_locked, false) == true
    )
    # Empty forms only to give `<.form>` a source; the inputs are named by hand.
    |> assign(:embed_form, to_form(%{}, as: :embed))
    |> assign(:spam_form, to_form(%{}, as: :spam))
  end

  defp first({:ok, [row | _rest]}), do: row
  defp first(_other), do: nil

  # The same three states `KilnCMSWeb.Embed.own_origins/1` classifies for a
  # form, read off the org row: no row and `nil` are both "inherit".
  defp embed_mode(%{embed_origins: []}), do: "closed"
  defp embed_mode(%{embed_origins: [_ | _]}), do: "list"
  defp embed_mode(_nil_row_or_nil_origins), do: "inherit"

  defp embed_origins_value(%{embed_origins: origins}) when is_list(origins),
    do: Enum.join(origins, ", ")

  defp embed_origins_value(_row), do: ""

  defp keywords_value(%{keywords: keywords}) when is_list(keywords), do: Enum.join(keywords, "\n")
  defp keywords_value(_row), do: ""

  defp keyword_count(%{keywords: keywords}) when is_list(keywords), do: length(keywords)
  defp keyword_count(_row), do: 0

  # Same shape as `FeedSettingsLive.error_message/1`: a Forbidden gets a plain
  # sentence, anything else its Ash errors rendered through
  # `Exception.message/1` — which is what interpolates an error's `vars` into
  # its `%{…}` placeholders (a `CspOrigins` or `EmbedCeiling` refusal names
  # the offending entry that way).
  defp error_message(%Ash.Error.Forbidden{}, _fallback),
    do: gettext("You don't have permission to change this site's form settings.")

  defp error_message(error, fallback) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.map_join(" ", &Exception.message/1)
    |> case do
      "" -> fallback
      message -> message
    end
  end

  # ── render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:forms}
    >
      <div class="space-y-8">
        <div>
          <.link navigate={~p"/editor/forms"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("Forms")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Form settings")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Settings that apply to every form on this site. A form's own Embed tab can still override the embed default for that form alone."
            )}
          </p>
        </div>

        <section class="card card-pad max-w-2xl space-y-3">
          <h2 class="text-lg font-medium">{gettext("Who may embed this site's forms")}</h2>
          <p class="text-xs text-base-content/60">
            {gettext(
              "The default for every form on this site that has not chosen its own list on its Embed tab. Pages on this site may always frame its forms."
            )}
          </p>
          <%!-- #1133: says a cap exists, never what is in it (#1130). --%>
          <p :if={@ceiling_locked?} class="text-xs text-base-content/60">
            {gettext(
              "The operator of this deployment has capped which sites may embed forms. You can narrow that list here but not add to it — ask them to allow a site that is refused."
            )}
          </p>

          <.form for={@embed_form} id="embed-default-form" phx-submit="save_embed" class="space-y-3">
            <fieldset class="space-y-1">
              <legend class="sr-only">{gettext("Embed default")}</legend>

              <label class="flex items-center gap-2 text-sm">
                <input
                  type="radio"
                  name="embed[mode]"
                  value="inherit"
                  checked={@embed_mode == "inherit"}
                  class="size-4 accent-primary"
                />
                {gettext("Use the deployment default")}
              </label>

              <label class="flex items-center gap-2 text-sm">
                <input
                  type="radio"
                  name="embed[mode]"
                  value="closed"
                  checked={@embed_mode == "closed"}
                  class="size-4 accent-primary"
                />
                {gettext("This site only")}
              </label>

              <label class="flex items-center gap-2 text-sm">
                <input
                  type="radio"
                  name="embed[mode]"
                  value="list"
                  checked={@embed_mode == "list"}
                  class="size-4 accent-primary"
                />
                {gettext("Only these sites:")}
              </label>
            </fieldset>

            <input
              id="embed-default-origins"
              name="embed[origins]"
              value={@embed_draft || embed_origins_value(@embed_row)}
              aria-label={gettext("Sites allowed to embed this site's forms")}
              placeholder="https://acme.com, https://blog.acme.com"
              class="field-input font-mono text-xs"
            />
            <p class="text-xs text-base-content/60">
              {gettext(
                "Comma-separated origins (scheme and host, optionally a port). Pages on this form's own site may always frame it."
              )}
            </p>

            <.button type="submit" variant="primary" phx-disable-with={gettext("Saving…")}>
              {gettext("Save")}
            </.button>
          </.form>
        </section>

        <section class="card card-pad max-w-2xl space-y-3">
          <h2 class="text-lg font-medium">{gettext("Spam keywords")}</h2>
          <p class="text-xs text-base-content/60">
            {gettext(
              "A submission whose text contains any of these words or phrases is scored as spam and held for review rather than delivered. Matching ignores case and applies to every form on this site."
            )}
          </p>

          <.form for={@spam_form} id="spam-keywords-form" phx-submit="save_keywords" class="space-y-3">
            <textarea
              id="spam-keywords"
              name="spam[keywords]"
              rows="8"
              aria-label={gettext("Spam keywords, one per line")}
              placeholder={gettext("one keyword or phrase per line")}
              class="field-input font-mono text-xs"
            >{@keywords_draft || keywords_value(@spam_row)}</textarea>
            <p class="text-xs text-base-content/60">
              {ngettext(
                "One per line. %{count} keyword saved.",
                "One per line. %{count} keywords saved.",
                keyword_count(@spam_row)
              )}
            </p>

            <.button type="submit" variant="primary" phx-disable-with={gettext("Saving…")}>
              {gettext("Save")}
            </.button>
          </.form>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
