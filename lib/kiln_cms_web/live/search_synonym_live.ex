defmodule KilnCMSWeb.SearchSynonymLive do
  @moduledoc """
  The site's search synonyms and aliases (proposal A7), at
  `/editor/search-synonyms`: list, add, edit, switch off and (admins) delete
  `KilnCMS.CMS.SearchSynonym` rules, and try a query against them.

  A rule saved here applies to the next search on every surface —
  `/api/search`, `/api/ask`, the `/mcp` `search_content` tool, the public
  `/search` page and the ⌘K palette — because they all search through
  `KilnCMS.Search.hybrid/3`, which reads the rules (`KilnCMS.Search.Synonyms`).

  Editor-gated by the route; every write re-asks the resource policy, which
  admits editors to create and update and only admins to delete. The delete
  button is drawn from `CMS.can_destroy_search_synonym?/3`, so an editor is
  offered "Turn off" instead of a button that would be refused.

  "Try a query" runs the matcher over the rules on screen (`Synonyms.expand/2`)
  — enabled ones only, as search does — so an editor sees what a query will
  also be searched as before a reader does.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS
  alias KilnCMS.Search.Synonyms

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Search synonyms"))
     |> assign(:editing, nil)
     |> assign(:form, to_form(blank(), as: :rule))
     |> assign(:trial, "")
     |> load_rules()}
  end

  @impl true
  def handle_event("validate", %{"rule" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, :form, to_form(params, as: :rule))}
  end

  def handle_event("save", %{"rule" => params}, socket) when is_map(params) do
    attrs = %{
      kind: if(params["kind"] == "one_way", do: :one_way, else: :group),
      terms: split(params["terms"]),
      expands_to: split(params["expands_to"]),
      enabled: params["enabled"] in ["true", "on"]
    }

    case save(socket.assigns.editing, attrs, socket) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> assign(:editing, nil)
         |> assign(:form, to_form(blank(), as: :rule))
         |> load_rules()
         |> put_flash(:info, gettext("Synonym rule saved. Search uses it from the next query."))}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: :rule))
         |> put_flash(:error, message(error))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) when is_binary(id) do
    case find(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That rule is no longer listed."))}

      rule ->
        params = %{
          "kind" => to_string(rule.kind),
          "terms" => Enum.join(rule.terms, ", "),
          "expands_to" => Enum.join(rule.expands_to, ", "),
          "enabled" => to_string(rule.enabled)
        }

        {:noreply, socket |> assign(:editing, rule) |> assign(:form, to_form(params, as: :rule))}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(:editing, nil) |> assign(:form, to_form(blank(), as: :rule))}
  end

  def handle_event("toggle", %{"id" => id}, socket) when is_binary(id) do
    with %{} = rule <- find(socket, id),
         {:ok, _rule} <-
           CMS.update_search_synonym(rule, %{enabled: not rule.enabled}, opts(socket)) do
      {:noreply, load_rules(socket)}
    else
      _error -> {:noreply, put_flash(socket, :error, gettext("Couldn't change that rule."))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) when is_binary(id) do
    with %{} = rule <- find(socket, id),
         :ok <- CMS.destroy_search_synonym(rule, opts(socket)) do
      {:noreply, socket |> load_rules() |> put_flash(:info, gettext("Synonym rule deleted."))}
    else
      _error -> {:noreply, put_flash(socket, :error, gettext("Couldn't delete that rule."))}
    end
  end

  def handle_event("try", %{"q" => q}, socket) when is_binary(q) do
    {:noreply, assign(socket, :trial, q)}
  end

  # --- data ---

  defp save(nil, attrs, socket), do: CMS.create_search_synonym(attrs, opts(socket))
  defp save(rule, attrs, socket), do: CMS.update_search_synonym(rule, attrs, opts(socket))

  defp load_rules(socket) do
    rules =
      CMS.list_search_synonyms!(
        Keyword.put(opts(socket), :query, sort: [inserted_at: :asc, id: :asc])
      )

    actor = socket.assigns.current_user
    org = socket.assigns.current_org

    socket
    |> assign(:rules, rules)
    |> assign(
      :deletable,
      MapSet.new(
        for rule <- rules,
            CMS.can_destroy_search_synonym?(actor, rule, tenant: org),
            do: rule.id
      )
    )
    |> assign(
      :mappings,
      rules |> Enum.filter(& &1.enabled) |> Enum.flat_map(&Synonyms.rule_mappings/1)
    )
  end

  defp find(socket, id), do: Enum.find(socket.assigns.rules, &(&1.id == id))

  defp opts(socket), do: [actor: socket.assigns.current_user, tenant: socket.assigns.current_org]

  defp blank, do: %{"kind" => "group", "terms" => "", "expands_to" => "", "enabled" => "true"}

  # Terms are typed comma-separated; a term may itself be several words.
  defp split(nil), do: []
  defp split(text), do: text |> String.split(",") |> Enum.map(&String.trim/1)

  defp message(%Ash.Error.Forbidden{}),
    do: gettext("You don't have permission to change search synonyms.")

  defp message(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.map(&Map.get(&1, :message))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> gettext("Couldn't save that rule.")
      messages -> Enum.join(messages, "; ")
    end
  end

  defp one_way?(form), do: form[:kind].value in ["one_way", :one_way]

  defp trial_alternates("", _mappings), do: []
  defp trial_alternates(q, mappings), do: Synonyms.expand(q, mappings)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:search_synonyms}
    >
      <.header>
        {gettext("Search synonyms")}
        <:subtitle>
          {gettext(
            "Words your readers search for that your content doesn't use. A search naming one is also run with the others, ranked just below matches on the reader's own words — on the site, the search and ask APIs, and MCP."
          )}
        </:subtitle>
      </.header>

      <div class="mt-6 grid gap-6 lg:grid-cols-3">
        <section class="card card-pad lg:col-span-2" aria-labelledby="synonym-form-title">
          <h2 id="synonym-form-title" class="text-sm font-medium">
            {if @editing, do: gettext("Edit rule"), else: gettext("Add a rule")}
          </h2>
          <.form
            for={@form}
            id="synonym-form"
            phx-change="validate"
            phx-submit="save"
            class="mt-3 space-y-3"
          >
            <.input
              field={@form[:kind]}
              type="select"
              label={gettext("Kind")}
              options={[
                {gettext("Equivalent — every term finds the others"), "group"},
                {gettext("One-way — the terms find the targets, not back"), "one_way"}
              ]}
            />
            <.input
              field={@form[:terms]}
              label={if one_way?(@form), do: gettext("When a search says"), else: gettext("Terms")}
              placeholder={gettext("reishi, ling zhi, ganoderma")}
            />
            <p class="-mt-2 text-xs text-base-content/60">
              {gettext("Separate terms with commas. A term can be several words.")}
            </p>
            <.input
              :if={one_way?(@form)}
              field={@form[:expands_to]}
              label={gettext("Also search for")}
              placeholder={gettext("traditional chinese medicine")}
            />
            <.input field={@form[:enabled]} type="checkbox" label={gettext("Apply this rule")} />
            <div class="flex items-center gap-2">
              <.button variant="primary" size="sm" phx-disable-with={gettext("Saving…")}>
                {if @editing, do: gettext("Save rule"), else: gettext("Add rule")}
              </.button>
              <.button :if={@editing} type="button" size="sm" phx-click="cancel">
                {gettext("Cancel")}
              </.button>
            </div>
          </.form>
        </section>

        <section class="card card-pad" aria-labelledby="synonym-try-title">
          <h2 id="synonym-try-title" class="text-sm font-medium">{gettext("Try a query")}</h2>
          <form id="synonym-try" phx-change="try" phx-submit="try" class="mt-3">
            <label for="synonym-try-q" class="sr-only">{gettext("Query")}</label>
            <input
              id="synonym-try-q"
              name="q"
              type="search"
              value={@trial}
              phx-debounce="200"
              autocomplete="off"
              placeholder={gettext("reishi tea")}
              class="field-input"
            />
          </form>
          <div class="mt-3 text-sm" aria-live="polite">
            <%= case trial_alternates(@trial, @mappings) do %>
              <% [] -> %>
                <p :if={@trial != ""} class="text-base-content/60">
                  {gettext("No rule applies — searched as typed.")}
                </p>
              <% alternates -> %>
                <p class="text-base-content/60">{gettext("Also searched as:")}</p>
                <ul id="synonym-try-results" class="mt-1 space-y-1">
                  <li :for={alternate <- alternates} class="font-medium">{alternate}</li>
                </ul>
            <% end %>
          </div>
        </section>
      </div>

      <.empty_state
        :if={@rules == []}
        class="mt-6"
        icon="hero-arrows-right-left"
        title={gettext("No synonyms yet")}
      >
        {gettext(
          "Add one when readers search for a name your content doesn't use — the zero-result searches in Analytics are a good place to look."
        )}
      </.empty_state>

      <div :if={@rules != []} class="card mt-6 overflow-x-auto">
        <table class="table" id="synonym-rules">
          <thead>
            <tr>
              <th>{gettext("Rule")}</th>
              <th>{gettext("Kind")}</th>
              <th>{gettext("Status")}</th>
              <th><span class="sr-only">{gettext("Actions")}</span></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={rule <- @rules}
              id={"synonym-#{rule.id}"}
              class={[
                "transition-colors",
                @editing && @editing.id == rule.id && "bg-base-200",
                not rule.enabled && "text-base-content/50"
              ]}
            >
              <th scope="row" class="font-medium">
                <%= if rule.kind == :one_way do %>
                  {Enum.join(rule.terms, ", ")}
                  <span aria-hidden="true" class="mx-1 text-base-content/40">&rarr;</span>
                  <span class="sr-only">{gettext("also searches")}</span>
                  {Enum.join(rule.expands_to, ", ")}
                <% else %>
                  <span :for={{term, i} <- Enum.with_index(rule.terms)}>
                    <span :if={i > 0} aria-hidden="true" class="mx-1 text-base-content/40">
                      &harr;
                    </span>
                    {term}
                  </span>
                <% end %>
              </th>
              <td>
                <.badge variant="outline">
                  {if rule.kind == :one_way, do: gettext("one-way"), else: gettext("equivalent")}
                </.badge>
              </td>
              <td>
                <.badge :if={rule.enabled} variant="success">{gettext("on")}</.badge>
                <.badge :if={not rule.enabled}>{gettext("off")}</.badge>
              </td>
              <td class="text-right whitespace-nowrap">
                <button
                  type="button"
                  phx-click="edit"
                  phx-value-id={rule.id}
                  class="btn btn-sm btn-ghost"
                >
                  {gettext("Edit")}
                </button>
                <button
                  type="button"
                  phx-click="toggle"
                  phx-value-id={rule.id}
                  class="btn btn-sm btn-ghost"
                >
                  {if rule.enabled, do: gettext("Turn off"), else: gettext("Turn on")}
                </button>
                <button
                  :if={MapSet.member?(@deletable, rule.id)}
                  type="button"
                  phx-click="delete"
                  phx-value-id={rule.id}
                  data-confirm={gettext("Delete this rule? Search stops using it at once.")}
                  aria-label={gettext("Delete rule")}
                  class="btn btn-sm btn-ghost text-base-content/60 hover:text-error"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.console>
    """
  end
end
