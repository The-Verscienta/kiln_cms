defmodule KilnCMSWeb.ContentEditor.InspectorHistoryComponent do
  @moduledoc """
  The inspector rail's History panel (#1311): translations coverage and the
  version history with compare/restore. Markup moved verbatim from
  `KilnCMSWeb.ContentEditorLive.render/1`; the panel stays mounted and is
  toggled by CSS only (never `:if`). Events are untargeted, so they land on
  the enclosing LiveView.
  """

  use KilnCMSWeb, :live_component

  import KilnCMSWeb.ContentEditor.InspectorComponents,
    only: [compare_toggle: 1, inspector_section: 1]

  import KilnCMSWeb.ContentEditor.Shared, only: [version_label: 1]

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["space-y-4", @inspector_tab != :history && "hidden"]}>
      <.inspector_section :if={length(@translations) > 1} title={gettext("Translations")}>
        <ul class="space-y-2">
          <li
            :for={cov <- @translations}
            class="flex items-center justify-between gap-3 text-sm"
          >
            <span class="flex items-center gap-2">
              <span class="font-mono text-xs font-semibold uppercase">{cov.locale}</span>
              <span
                :if={cov.record && cov.record.id == @record.id}
                class="text-xs text-base-content/50"
              >
                {gettext("(this one)")}
              </span>
              <span
                :if={cov.stale?}
                class="rounded bg-warning/15 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-warning"
                title={gettext("The source locale was updated after this translation.")}
              >
                {gettext("Outdated")}
              </span>
            </span>
            <span
              :if={cov.record && cov.record.id == @record.id}
              class="text-xs text-base-content/70"
            >
              {state_label(cov.status)}
            </span>
            <.link
              :if={cov.record && cov.record.id != @record.id}
              navigate={~p"/editor/content/#{@kind}/#{cov.record.id}"}
              class="text-xs text-primary hover:underline"
            >
              {state_label(cov.status)} — {gettext("edit")}
            </.link>
            <%!-- `@may_write?` for the reason the header's Duplicate
                    button carries it (#922): this forks the record's
                    payload into a new draft, and read access to a record
                    is not enough to fork it. --%>
            <button
              :if={is_nil(cov.record) and @may_write?}
              type="button"
              phx-click="create_translation"
              phx-value-locale={cov.locale}
              class="btn btn-sm btn-default"
            >
              {gettext("Create translation")}
            </button>
          </li>
        </ul>
      </.inspector_section>

      <.inspector_section title={gettext("Version history (%{count})", count: length(@versions))}>
        <p :if={@versions == []} class="text-sm text-base-content/60">
          {gettext("No saved versions yet.")}
        </p>
        <div :if={@versions != []}>
          <p class="mb-2 text-xs text-base-content/60">
            {gettext("Select two to see what changed between them.")}
          </p>
          <ul class="space-y-2">
            <li class="flex items-center gap-2 text-sm">
              <.compare_toggle
                pick={@current_pick}
                picked={@current_pick in @compare_pick}
                label={gettext("Current draft")}
              />
              <span class="text-base-content/70">{gettext("Current draft")}</span>
            </li>
            <li
              :for={version <- @versions}
              class="flex items-center justify-between gap-3 text-sm"
            >
              <span class="flex min-w-0 items-center gap-2">
                <.compare_toggle
                  pick={version.id}
                  picked={version.id in @compare_pick}
                  label={version_label(version)}
                />
                <span class="text-base-content/70">
                  {version_label(version)}
                  <span
                    :if={version.id == @record.published_version_id}
                    class="ml-1 rounded bg-success/15 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-success"
                  >
                    {gettext("Live published")}
                  </span>
                </span>
              </span>
              <button
                type="button"
                phx-click="restore"
                phx-value-version_id={version.id}
                data-confirm={gettext("Restore content to this version?")}
                class="btn btn-sm btn-default"
              >
                {gettext("Restore")}
              </button>
            </li>
          </ul>
          <button
            type="button"
            phx-click="open_compare"
            disabled={length(@compare_pick) != 2}
            class="btn btn-sm btn-default mt-3 disabled:opacity-50"
          >
            {gettext("Compare selected")}
          </button>
        </div>
      </.inspector_section>
    </div>
    """
  end
end
