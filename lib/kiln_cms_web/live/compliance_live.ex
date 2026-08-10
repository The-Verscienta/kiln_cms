defmodule KilnCMSWeb.ComplianceLive do
  @moduledoc """
  Per-site claim checking (`/editor/compliance`, #857): whether the editor's
  Compliance panel runs for this site, whether a flagged claim refuses a
  publish, the disclaimer it requires, and the site's own claim vocabulary.

  Scoped to the request's org, like `/editor/feeds` — you configure the site you
  are on. Writes are policy-gated to org admins by `KilnCMS.CMS.SiteCompliance`,
  and this LiveView sits in the `:admin_routes` live session whose
  `:live_admin_required` hook gates on the same tier, so the router guard and
  the resource policy agree.

  ## Off is the state that most needed a page

  Claim checking shipped off, and the editor suppresses the whole panel when it
  is off, so nothing anywhere in the admin UI said the feature existed. This
  page is the answer `/editor/links` already gave for outbound link checking: a
  site that has not opted in gets an explanation and a button, not an empty
  form. A feature nobody can find is one nobody chose not to use.

  ## The form writes every column; "operator defaults" drops the row

  `KilnCMS.Compliance.Settings` resolves the site's row over
  `config :kiln_cms, KilnCMS.Compliance`, and the difference between *inherit*
  and *this site said so* lives in whether a row exists at all. So the form is
  seeded from the **resolved** settings — what the site does today, from
  wherever it came — and saving writes the lot as this site's own answer.
  "Use the operator defaults" destroys the row and goes back to inheriting.

  The one exception is the disclaimer, where blank means inherit: a text box has
  no third state, and an operator's required disclaimer dropped by an admin
  tabbing past an empty field is a compliance requirement lost by accident.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.Compliance.Settings

  @severities [:error, :warning, :info]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Claim checking"))
     |> load_settings()}
  end

  @impl true
  def handle_event("save", params, socket) do
    save(socket, attrs(params), gettext("Claim checking settings saved."))
  end

  # The explainer's one button. It sends the site's *current* settings with
  # `enabled` flipped rather than `%{enabled: true}` alone: every column on the
  # row has a default, and a default is applied on the create side of an upsert,
  # so a partial save would clear the phrase list of a site that had configured
  # one and then switched off.
  def handle_event("enable", _params, socket) do
    save(
      socket,
      %{current_attrs(socket) | enabled: true},
      gettext("Claim checking is on. The Compliance panel now appears in the editor.")
    )
  end

  def handle_event("reset", _params, socket) do
    # Re-read rather than destroying the struct assigned at mount: a second tab
    # (or a second click) may already have dropped it, and destroying a deleted
    # row raises out of the handler and takes the LiveView down, reloading the
    # page with no message. The sibling settings pages re-read for the reason.
    case current_row(socket) do
      nil ->
        {:noreply, load_settings(socket)}

      row ->
        # A destroy answers `:ok`, not `{:ok, record}`.
        case CMS.reset_site_compliance(row,
               actor: socket.assigns.current_user,
               tenant: socket.assigns.current_org
             ) do
          {:error, error} ->
            {:noreply, socket |> put_flash(:error, error_message(error)) |> load_settings()}

          _destroyed ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("This site follows the operator defaults again."))
             |> load_settings()}
        end
    end
  end

  defp save(socket, attrs, message) do
    case CMS.save_site_compliance(attrs,
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, _row} ->
        {:noreply, socket |> put_flash(:info, message) |> load_settings()}

      {:error, error} ->
        {:noreply, socket |> put_flash(:error, error_message(error)) |> load_settings()}
    end
  end

  # What this site does today, in the shape `:save` accepts. The three switches
  # and the disclaimer come from the *resolved* settings, so a site inheriting
  # an operator default keeps it when it writes its first row; the vocabulary
  # comes from the row, which is the only layer that has one.
  defp current_attrs(socket) do
    row = socket.assigns.row
    settings = socket.assigns.settings

    %{
      enabled: settings.enabled?,
      require_at_publish: settings.require_at_publish?,
      disclaimer: settings.disclaimer,
      use_shared_rules: if(row, do: row.use_shared_rules, else: true),
      phrases: if(row, do: row.phrases, else: []),
      phrase_severity: if(row, do: row.phrase_severity, else: :warning)
    }
  end

  defp load_settings(socket) do
    row = current_row(socket)
    # Resolved from the row already in hand rather than through
    # `Settings.for_org/1`, which would read the same single row again — and
    # always miss its cache on the save path, since the save just busted it.
    settings = Settings.for_row(row)

    socket
    |> assign(:row, row)
    |> assign(:settings, settings)
    |> assign(:defaults, Settings.defaults())
    |> assign(:form, to_form(form_params(row, settings), as: :compliance))
  end

  defp current_row(socket) do
    case CMS.list_site_compliance(
           actor: socket.assigns.current_user,
           tenant: socket.assigns.current_org
         ) do
      {:ok, [row | _rest]} -> row
      _other -> nil
    end
  end

  # Seeded from the resolved settings for the three switches and the disclaimer,
  # so the form opens showing what the site actually does today whether that came
  # from its row or from the config beneath it. The two vocabulary fields read
  # from the **row**: they have no config layer of their own, and rendering the
  # resolved rules into the phrase box would offer to save the shipped English
  # pack back as this site's own list.
  defp form_params(row, settings) do
    %{
      "enabled" => settings.enabled?,
      "require_at_publish" => settings.require_at_publish?,
      "use_shared_rules" => if(row, do: row.use_shared_rules, else: true),
      "disclaimer" => settings.disclaimer || "",
      "phrases" => if(row, do: Enum.join(row.phrases, "\n"), else: ""),
      "phrase_severity" => to_string(if(row, do: row.phrase_severity, else: :warning))
    }
  end

  # `params["compliance"]` is client-controlled and decoded from a query string,
  # so it is not necessarily a map: `compliance=x` decodes to a bare binary, and
  # reading a field off that would raise and crash the LiveView into a reconnect
  # loop.
  defp attrs(params) do
    fields =
      case params do
        %{"compliance" => %{} = fields} -> fields
        _absent -> %{}
      end

    %{
      enabled: checked?(fields["enabled"]),
      require_at_publish: checked?(fields["require_at_publish"]),
      use_shared_rules: checked?(fields["use_shared_rules"]),
      disclaimer: trimmed(fields["disclaimer"]),
      phrases: phrases(fields["phrases"]),
      phrase_severity: severity(fields["phrase_severity"])
    }
  end

  defp checked?(value), do: value in ["true", "on", true]

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_value), do: nil

  # One phrase per line, which is how a house style guide is written down.
  # Deduped and blank-stripped here rather than left to the scanner: the list is
  # rendered straight back into this box, and an admin who pasted a list with
  # trailing blank lines should not see them grow every time they save.
  defp phrases(value) when is_binary(value) do
    value
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp phrases(_value), do: []

  # Never `String.to_atom/1` on a form value — a select is only a suggestion
  # about what the client sends, and minting atoms from one is how a form
  # becomes an unbounded atom table.
  defp severity(value) do
    Enum.find(@severities, :warning, &(to_string(&1) == value))
  end

  defp severity_options do
    [
      {gettext("Advice only (warning)"), "warning"},
      {gettext("Blocks publishing (error)"), "error"},
      {gettext("Informational (info)"), "info"}
    ]
  end

  # The site's own rule reads as what it is; a shipped or operator-configured
  # code is humanized the way the editor panel's fallback message does.
  defp rule_label(%{code: code}) do
    if code == Settings.site_rule_code() do
      gettext("This site's phrases")
    else
      code |> Atom.to_string() |> String.replace("_", " ")
    end
  end

  defp severity_label(:error), do: gettext("Blocks publishing")
  defp severity_label(:warning), do: gettext("Warning")
  defp severity_label(_info), do: gettext("Info")

  defp severity_class(:error), do: "bg-error/15 text-error-ink"
  defp severity_class(:warning), do: "bg-warning/15 text-warning-ink"
  defp severity_class(_info), do: "bg-base-300 text-base-content"

  defp error_message(error) do
    case error do
      %Ash.Error.Forbidden{} ->
        gettext("You don't have permission to change this site's claim checking.")

      _other ->
        error
        |> Ash.Error.to_error_class()
        |> Map.get(:errors, [])
        |> Enum.map_join(" ", &describe_error/1)
        |> case do
          "" -> gettext("Claim checking settings could not be saved.")
          message -> message
        end
    end
  end

  defp describe_error(%{message: message} = error) when is_binary(message) do
    Enum.reduce(Map.get(error, :vars, []), message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp describe_error(error), do: Exception.message(error)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:compliance}
    >
      <.header>
        {gettext("Claim checking")}
        <:subtitle>
          {gettext(
            "Phrases in this site's content that a regulator, a clinic's counsel or a style guide would want a second look at before it goes live — shown to authors in the editor's Compliance panel."
          )}
        </:subtitle>
      </.header>

      <section :if={not @settings.enabled?} class="card card-pad mt-6">
        <h2 class="text-sm font-medium">{gettext("Claim checking is off for this site")}</h2>
        <p class="mt-2 text-sm text-base-content/70">
          {gettext(
            "With it on, the editor gains a Compliance panel that quotes back the phrases a document contains from a claims vocabulary — \"FDA approved\", \"no side effects\", \"guaranteed results\". It is advice: a match is a prompt to look, not a verdict, and nothing is blocked unless you separately turn on the publish gate."
          )}
        </p>
        <p class="mt-2 text-sm text-base-content/70">
          {gettext(
            "Nothing is scanned and no panel appears until you switch it on, and what you switch on applies to this site only."
          )}
        </p>
        <div class="mt-4 flex flex-wrap items-center gap-3">
          <.button variant="primary" size="sm" phx-click="enable">
            {gettext("Turn on claim checking")}
          </.button>
          <%!-- Offered here too, not only beside the form: a site that saved
                "off" has a row, and without this the only way back to
                inheriting the operator's settings would be to turn the feature
                on first just to be allowed to reset it. --%>
          <button
            :if={@row}
            type="button"
            phx-click="reset"
            data-confirm={
              gettext(
                "Remove this site's claim checking settings and follow the deployment defaults again?"
              )
            }
            class="btn btn-ghost btn-sm"
          >
            {gettext("Use the operator defaults")}
          </button>
        </div>
      </section>

      <div
        :if={is_nil(@row)}
        class="mt-6 rounded-lg border border-base-300 bg-base-200 p-4 text-sm"
      >
        <p class="font-medium">{gettext("This site is using the deployment defaults.")}</p>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "Nothing has been set for this site yet, so it follows whatever the operator configured for the whole deployment. Saving below gives this site its own settings."
          )}
        </p>
      </div>

      <.form
        :if={@settings.enabled?}
        for={@form}
        id="compliance-settings-form"
        phx-submit="save"
        class="mt-8 space-y-8"
      >
        <section class="space-y-2">
          <h2 class="text-sm font-medium">{gettext("What runs on this site")}</h2>
          <.input
            field={@form[:enabled]}
            type="checkbox"
            label={gettext("Show the Compliance panel in the editor")}
          />
          <.input
            field={@form[:require_at_publish]}
            type="checkbox"
            label={gettext("Refuse to publish a document containing a blocking claim")}
          />
          <p class="text-xs text-base-content/60">
            {gettext(
              "The publish gate acts only on rules marked as blocking. Authors editing a document that already carried a flagged phrase are not stopped for words they did not add."
            )}
          </p>
        </section>

        <section class="space-y-2">
          <h2 class="text-sm font-medium">{gettext("This site's vocabulary")}</h2>
          <.input
            field={@form[:use_shared_rules]}
            type="checkbox"
            label={gettext("Also use the rules this deployment ships")}
          />
          <.input
            field={@form[:phrases]}
            type="textarea"
            rows="8"
            label={gettext("Phrases to flag")}
            hint={
              gettext(
                "One per line. Matched case-insensitively on whole words, so \"cures\" does not match \"secures\". Whitespace between words is flexible, so a phrase still matches text the editor wrapped across a line."
              )
            }
          />
          <.input
            field={@form[:phrase_severity]}
            type="select"
            options={severity_options()}
            label={gettext("What a match on these phrases means")}
          />
        </section>

        <section class="space-y-2">
          <h2 class="text-sm font-medium">{gettext("Required disclaimer")}</h2>
          <.input
            field={@form[:disclaimer]}
            type="text"
            label={gettext("Text every body must contain")}
            hint={
              gettext(
                "Matched as a substring, ignoring case and line wrapping, so it can sit inside a longer paragraph — but not reworded. Leave blank to inherit whatever the operator configured."
              )
            }
          />
        </section>

        <div class="flex flex-wrap items-center gap-3">
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
          <button
            :if={@row}
            type="button"
            phx-click="reset"
            data-confirm={
              gettext(
                "Remove this site's claim checking settings and follow the deployment defaults again?"
              )
            }
            class="btn btn-ghost btn-sm"
          >
            {gettext("Use the operator defaults")}
          </button>
        </div>
      </.form>

      <section :if={@settings.enabled?} class="mt-10 rounded-lg bg-base-200 p-4 text-sm">
        <h2 class="font-medium">{gettext("Rules in effect")}</h2>
        <p class="mt-1 text-base-content/70">
          {gettext(
            "What a document on this site is checked against right now — the deployment's rules, unless you turned them off above, plus this site's own phrases."
          )}
        </p>
        <p :if={@settings.rules == []} class="mt-3 text-warning-ink">
          {gettext(
            "No rules apply, so every document reports as unchecked rather than as clean. Add some phrases, or put the deployment's rules back."
          )}
        </p>
        <ul :if={@settings.rules != []} class="mt-3 space-y-3">
          <li :for={rule <- @settings.rules}>
            <div class="flex flex-wrap items-center gap-2">
              <span class="font-medium capitalize">{rule_label(rule)}</span>
              <span class={["rounded px-1.5 py-0.5 text-xs", severity_class(rule.severity)]}>
                {severity_label(rule.severity)}
              </span>
            </div>
            <p class="mt-1 font-mono text-xs text-base-content/60">
              {Enum.join(rule.phrases, ", ")}
            </p>
          </li>
        </ul>
        <p class="mt-4 text-xs text-base-content/60">
          {gettext(
            "The shipped pack deliberately leaves out bare curative words — \"cures\", \"heals\", \"treats\" — because they have too many legitimate uses to flag without knowing a publication's subject. That is what the phrase list above is for."
          )}
        </p>
      </section>
    </Layouts.console>
    """
  end
end
