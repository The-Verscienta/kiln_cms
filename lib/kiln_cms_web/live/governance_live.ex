defmodule KilnCMSWeb.GovernanceLive do
  @moduledoc """
  Compliance & governance dashboard (`/editor/governance`) — the visible home for
  the compliance cluster (#352). Per content item it surfaces the editorial
  version timeline (PaperTrail), the linked consents (#356), point-in-time access
  (#338), and a JSON export of the trail. Admin-only.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Governance

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_user.role == :admin do
      {:ok, assign(socket, :page_title, gettext("Governance"))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:trail, nil)
    |> assign(:content, Governance.content_index())
  end

  defp apply_action(socket, :show, %{"type" => type, "id" => id}) do
    case Governance.trail(type, id) do
      nil ->
        socket
        |> put_flash(:error, gettext("That content couldn't be found."))
        |> push_navigate(to: ~p"/editor/governance")

      trail ->
        socket
        |> assign(:trail, trail)
        |> assign(:consent_form, blank_consent_form())
    end
  end

  # Record a consent from the dashboard (#352 — consent management UI).
  @impl true
  def handle_event("record_consent", %{"consent" => params}, socket) do
    item = socket.assigns.trail.item

    attrs =
      %{
        content_type: item.type,
        content_id: item.id,
        kind: params["kind"],
        reference: presence(params["reference"]),
        grantor: presence(params["grantor"]),
        note: presence(params["note"])
      }

    case KilnCMS.CMS.record_consent(attrs, actor: socket.assigns.current_user) do
      {:ok, _consent} ->
        {:noreply,
         socket
         |> assign(:trail, Governance.trail(item.type, item.id))
         |> assign(:consent_form, blank_consent_form())
         |> put_flash(:info, gettext("Consent recorded."))}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't record that consent."))}
    end
  end

  defp blank_consent_form,
    do: to_form(%{"kind" => nil, "reference" => "", "grantor" => "", "note" => ""}, as: "consent")

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  # Point-in-time delivery URL (#338) for one publish instant.
  defp point_in_time_url(item, %DateTime{} = at) do
    "/api/content/#{item.type}/#{item.slug}?as_of=#{DateTime.to_iso8601(at)}"
  end

  defp when_str(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  # Compact display of a version value: strings verbatim, everything else
  # inspected and capped (block trees can be huge).
  defp diff_value(nil), do: gettext("(unset)")
  defp diff_value(value) when is_binary(value), do: String.slice(value, 0, 160)

  defp diff_value(value),
    do: value |> inspect(limit: 8, printable_limit: 160) |> String.slice(0, 160)

  attr :chain, :any, required: true

  # Tamper-evidence status from the signed history anchors (#356).
  defp chain_badge(assigns) do
    ~H"""
    <p class="mt-2 text-sm" data-role="chain-status">
      <span
        :if={@chain == :verified}
        class="rounded bg-success/15 px-1.5 py-0.5 text-xs font-medium text-success"
      >
        <.icon name="hero-shield-check" class="size-3.5" />
        {gettext("History verified — anchored chain intact and signature valid")}
      </span>
      <span
        :if={@chain == :unsigned}
        class="rounded bg-success/10 px-1.5 py-0.5 text-xs font-medium text-success/80"
      >
        {gettext("History intact (anchor unsigned — no signing key configured)")}
      </span>
      <span
        :if={@chain == :unanchored}
        class="rounded bg-base-200 px-1.5 py-0.5 text-xs font-medium text-base-content/60"
      >
        {gettext("Not yet anchored — anchors are minted at publish")}
      </span>
      <span
        :if={match?({:tampered, _}, @chain)}
        class="rounded bg-error/15 px-1.5 py-0.5 text-xs font-medium text-error"
      >
        <.icon name="hero-exclamation-triangle" class="size-3.5" />
        {gettext("HISTORY TAMPERED: %{reason}", reason: elem(@chain, 1))}
      </span>
    </p>
    """
  end

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      page_title={@page_title}
      active={:governance}
    >
      <.index :if={is_nil(@trail)} content={@content} />
      <.detail :if={@trail} trail={@trail} consent_form={@consent_form} />
    </Layouts.console>
    """
  end

  attr :content, :list, required: true

  defp index(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-semibold">{gettext("Governance")}</h1>
        <p class="text-sm text-base-content/70">
          {gettext("Audit trail, consent records, and point-in-time history for your content.")}
        </p>
      </div>

      <p :if={@content == []} class="text-sm text-base-content/60">{gettext("No content yet.")}</p>

      <ul :if={@content != []} class="card divide-y divide-base-content/10 overflow-hidden">
        <li :for={item <- @content} class="flex items-center justify-between p-3">
          <div class="min-w-0">
            <.link
              navigate={~p"/editor/governance/#{item.type}/#{item.id}"}
              class="text-sm font-medium hover:underline"
            >
              {item.title}
            </.link>
            <span class="ml-2 text-xs text-base-content/50">{item.type} · {item.state}</span>
          </div>
          <.link
            navigate={~p"/editor/governance/#{item.type}/#{item.id}"}
            class="btn btn-sm btn-default"
          >
            {gettext("Trail")}
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  attr :trail, :map, required: true
  attr :consent_form, :any, required: true

  defp detail(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <.link navigate={~p"/editor/governance"} class="text-sm text-base-content/60 hover:underline">
          &larr; {gettext("All content")}
        </.link>
        <h1 class="mt-1 text-2xl font-semibold">{@trail.item.title}</h1>
        <p class="text-sm text-base-content/60">
          {@trail.item.type} · {@trail.item.state}
        </p>
        <.chain_badge chain={@trail.chain} />
        <a
          href={~p"/editor/governance/#{@trail.item.type}/#{@trail.item.id}/export.json"}
          class="btn btn-sm btn-default mt-3"
          download
        >
          <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export trail (JSON)")}
        </a>
      </div>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">{gettext("Consent records")} ({length(@trail.consents)})</h2>
        <p :if={@trail.consents == []} class="text-sm text-base-content/60">
          {gettext("No consent recorded for this content.")}
        </p>
        <ul :if={@trail.consents != []} class="card divide-y divide-base-content/10 overflow-hidden">
          <li :for={c <- @trail.consents} class="p-3 text-sm">
            <span class="rounded bg-success/15 px-1.5 py-0.5 text-xs font-medium text-success">
              {c.kind}
            </span>
            <span :if={c.grantor} class="ml-2">{gettext("by")} {c.grantor}</span>
            <span :if={c.granted_at} class="ml-2 text-base-content/60">{when_str(c.granted_at)}</span>
            <code :if={c.reference} class="ml-2 text-xs text-base-content/60">{c.reference}</code>
          </li>
        </ul>

        <%!-- Record a consent without leaving the dashboard (#352). Stores a
              *reference* to the clearing document, never the document itself. --%>
        <details class="card p-3">
          <summary class="cursor-pointer text-sm font-medium">
            {gettext("Record a consent")}
          </summary>
          <.form
            for={@consent_form}
            id="record-consent-form"
            phx-submit="record_consent"
            class="mt-3 grid gap-2 sm:grid-cols-2"
          >
            <label class="text-xs">
              {gettext("Kind")}
              <select name="consent[kind]" class="select select-sm mt-1 w-full" required>
                <option :for={kind <- KilnCMS.CMS.Consent.kinds()} value={kind}>{kind}</option>
              </select>
            </label>
            <label class="text-xs">
              {gettext("Reference (ticket / document id)")}
              <input name="consent[reference]" class="input input-sm mt-1 w-full" />
            </label>
            <label class="text-xs">
              {gettext("Grantor")}
              <input name="consent[grantor]" class="input input-sm mt-1 w-full" />
            </label>
            <label class="text-xs">
              {gettext("Note")}
              <input name="consent[note]" class="input input-sm mt-1 w-full" />
            </label>
            <div class="sm:col-span-2">
              <.button type="submit" variant="primary">{gettext("Record consent")}</.button>
            </div>
          </.form>
        </details>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">{gettext("Version timeline")}</h2>
        <p :if={@trail.timeline == []} class="text-sm text-base-content/60">
          {gettext("No versions recorded.")}
        </p>
        <div :if={@trail.timeline != []} class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>{gettext("When")}</th>
                <th>{gettext("Action")}</th>
                <th>{gettext("Changed")}</th>
                <th>{gettext("Point in time")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={e <- @trail.timeline}>
                <td class="whitespace-nowrap text-base-content/70">{when_str(e.at)}</td>
                <td>
                  <span class={[
                    "rounded px-1.5 py-0.5 text-xs font-medium",
                    e.publish? && "bg-primary/15 text-primary",
                    !e.publish? && "bg-base-200 text-base-content/70"
                  ]}>
                    {e.action}
                  </span>
                </td>
                <td class="max-w-md text-xs text-base-content/60">
                  <details :if={e.diffs != []}>
                    <summary class="cursor-pointer truncate">{Enum.join(e.changed, ", ")}</summary>
                    <%!-- Side-by-side old → new per changed field (#352). --%>
                    <dl class="mt-2 space-y-1">
                      <div
                        :for={{field, {old, new}} <- e.diffs}
                        class="grid grid-cols-[8rem_1fr] gap-2"
                      >
                        <dt class="truncate font-medium">{field}</dt>
                        <dd class="min-w-0">
                          <span class="block truncate text-error/80 line-through">{diff_value(old)}</span>
                          <span class="block truncate text-success">{diff_value(new)}</span>
                        </dd>
                      </div>
                    </dl>
                  </details>
                  <span :if={e.diffs == []}>—</span>
                </td>
                <td>
                  <a
                    :if={e.publish?}
                    href={point_in_time_url(@trail.item, e.at)}
                    class="text-xs text-primary hover:underline"
                    target="_blank"
                    rel="noopener"
                  >
                    {gettext("View as of then")}
                  </a>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end
end
