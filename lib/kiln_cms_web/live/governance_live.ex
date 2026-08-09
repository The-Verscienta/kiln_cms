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
    if KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin do
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
    |> assign(:content, Governance.content_index(socket.assigns.current_org.id))
    |> assign(:witness, Governance.witness_status(socket.assigns.current_org.id))
  end

  defp apply_action(socket, :show, %{"type" => type, "id" => id}) do
    case Governance.trail(type, id, socket.assigns.current_org.id) do
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
  def handle_event("record_consent", %{"consent" => params}, socket) when is_map(params) do
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

    # The consent lands in the content's own site (epic #336) — without the
    # tenant it would default to the default org, invisible to the trail read
    # and to the RequiredConsent publish gate.
    case KilnCMS.CMS.record_consent(attrs,
           actor: socket.assigns.current_user,
           tenant: item.org_id
         ) do
      {:ok, _consent} ->
        {:noreply,
         socket
         |> assign(:trail, Governance.trail(item.type, item.id, item.org_id))
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
  # `%{attested, next, head}` when the attested prefix stops short of the head
  # (#811), else nil. Resolved in `Governance.trail/3`, not here — see there.
  attr :gap_range, :map, default: nil

  # Tamper-evidence status from the signed history anchors (#356).
  defp chain_badge(assigns) do
    ~H"""
    <p class="mt-2 text-sm" data-role="chain-status">
      <span
        :if={@chain == :verified}
        class="rounded bg-success/15 px-1.5 py-0.5 text-xs font-medium text-success"
      >
        <.icon name="hero-shield-check" class="size-3.5" />
        {gettext("Anchored history verified — chain intact, signature valid")}
      </span>
      <%!-- #811: a chain can have anchors that VERIFY and a newer one that does
            not. The verdict still reads `unsigned`, but calling that "intact"
            claims more than is known — versions past the attested prefix are
            anchored by a row nothing attests, and this is exactly the shape an
            INSERT+DELETE laundering produces. It is also what an honest key
            loss produces, which is why it is stated rather than called
            tampering. --%>
      <span
        :if={@gap_range}
        class="rounded bg-warning/15 px-1.5 py-0.5 text-xs font-medium text-warning"
      >
        <.icon name="hero-exclamation-triangle" class="size-3.5" />
        {gettext(
          "Attested only to version %{attested} — versions %{next}-%{head} are anchored but not attested",
          attested: @gap_range.attested,
          next: @gap_range.next,
          head: @gap_range.head
        )}
      </span>
      <span
        :if={@chain == :unsigned and is_nil(@gap_range)}
        class="rounded bg-success/10 px-1.5 py-0.5 text-xs font-medium text-success/80"
      >
        {gettext("History intact (anchor unsigned — no signing key configured)")}
      </span>
      <span
        :if={@chain == :unverifiable and is_nil(@gap_range)}
        class="rounded bg-warning/15 px-1.5 py-0.5 text-xs font-medium text-warning"
      >
        {gettext(
          "History intact; signed by a key we no longer hold — add its public half to KILN_PROVENANCE_RETIRED_KEY_FILES to re-check"
        )}
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

  attr :witnessed, :map, required: true

  # Which checkpoint currently witnesses THIS document, and at what anchor
  # position (#731). The chain badge above says the document's own history holds
  # together; this says whether anything outside the database vouches for it.
  #
  # `:none` renders nothing at all. A document younger than the last checkpoint
  # is unwitnessed for a perfectly ordinary reason, and so is every document on
  # a deployment that has not configured a sink — a badge on each of them would
  # be noise that teaches an operator to stop reading badges.
  defp witnessed_badge(assigns) do
    ~H"""
    <p :if={@witnessed.state != :none} class="mt-1 text-sm" data-role="witness-position">
      <span
        :if={@witnessed.state == :witnessed}
        class="rounded bg-success/10 px-1.5 py-0.5 text-xs font-medium text-success/80"
      >
        {gettext("Witnessed by checkpoint #%{sequence} at anchor position %{position}",
          sequence: @witnessed.sequence,
          position: @witnessed.anchor_position
        )}
        <span :if={@witnessed.attestation != :ok} class="text-base-content/60">
          · {witness_attestation_label(@witnessed.attestation)}
        </span>
      </span>
      <span
        :if={@witnessed.state == :unreadable}
        class="rounded bg-warning/15 px-1.5 py-0.5 text-xs font-medium text-warning"
      >
        <.icon name="hero-exclamation-triangle" class="size-3.5" />
        {gettext("This document's checkpoint entry could not be read — it cannot be verified")}
      </span>
      <span
        :if={@witnessed.state == :tampered}
        class="rounded bg-error/15 px-1.5 py-0.5 text-xs font-medium text-error"
      >
        <.icon name="hero-exclamation-triangle" class="size-3.5" />
        {gettext("CHECKPOINT TAMPERED: %{reason}", reason: @witnessed.reason)}
      </span>
    </p>
    """
  end

  defp witness_attestation_label(:unsigned), do: gettext("checkpoint unsigned")
  defp witness_attestation_label(:unverifiable), do: gettext("signed by a key we no longer hold")
  defp witness_attestation_label(_other), do: nil

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:governance}
    >
      <.index :if={is_nil(@trail)} content={@content} witness={@witness} />
      <.detail :if={@trail} trail={@trail} consent_form={@consent_form} />
    </Layouts.console>
    """
  end

  attr :witness, :map, required: true

  # Whether this deployment's history is actually being witnessed (#731).
  #
  # It leads the dashboard rather than sitting at the bottom, because the whole
  # point is that an operator should not be able to read a healthy-looking page
  # and infer a working witness. A silently unwitnessed deployment used to be
  # indistinguishable from a healthy one here — `witness_error` was written on
  # every failed publication and shown nowhere.
  #
  # "Off" and "broken" are rendered differently on purpose. Checkpointing
  # disabled, or no sink configured, are deliberate postures and get a neutral
  # note; a configured sink that is refusing publications is the alarming case
  # and is the only one that gets a warning tone.
  defp witness_panel(assigns) do
    ~H"""
    <section class="card card-pad space-y-3" data-role="witness-status">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h2 class="text-lg font-medium">{gettext("History witness")}</h2>
        <span class="font-mono text-xs text-base-content/60">{@witness.adapter}</span>
      </div>

      <p :if={not @witness.checkpointing?} class="text-sm text-base-content/70">
        {gettext(
          "Checkpointing is switched off, so no checkpoints are being minted and nothing is published to a witness."
        )}
      </p>

      <p
        :if={@witness.checkpointing? and not @witness.witnessing?}
        class="text-sm text-base-content/70"
      >
        {gettext(
          "No external witness is configured. Checkpoints are minted and stored in this database only, so they attest history against edits — but not against someone who can write to the database itself."
        )}
      </p>

      <p
        :if={@witness.checkpointing? and is_nil(@witness.latest)}
        class="text-sm text-base-content/60"
      >
        {gettext("No checkpoint has been minted yet.")}
      </p>

      <dl :if={@witness.latest} class="grid gap-3 text-sm sm:grid-cols-3">
        <div>
          <dt class="text-xs text-base-content/60">{gettext("Last checkpoint")}</dt>
          <dd class="tabular-nums">#{@witness.latest.sequence}</dd>
        </div>
        <div>
          <dt class="text-xs text-base-content/60">{gettext("Covering")}</dt>
          <dd>
            {gettext("%{count} document(s)", count: @witness.latest.document_count)}
            <span class="text-base-content/60">· {when_str(@witness.latest.covered_at)}</span>
          </dd>
        </div>
        <div>
          <dt class="text-xs text-base-content/60">{gettext("Published to the witness")}</dt>
          <dd>
            <span :if={@witness.latest.witnessed_at}>{when_str(@witness.latest.witnessed_at)}</span>
            <span :if={is_nil(@witness.latest.witnessed_at)} class="text-base-content/60">
              {gettext("not yet")}
            </span>
          </dd>
        </div>
      </dl>

      <%!-- The number that matters. One is a sink that was briefly unreachable
            and will be retried on the next run; a growing count is an outage
            nobody has noticed, which is why the oldest one is dated here. --%>
      <div
        :if={@witness.witnessing? and @witness.unwitnessed_count > 0}
        class="rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm text-warning-ink"
      >
        <p class="font-medium">
          {gettext("%{count} checkpoint(s) have not been accepted by the witness.",
            count: @witness.unwitnessed_count
          )}
        </p>
        <p :if={@witness.oldest_unwitnessed} class="mt-1">
          {gettext("The oldest covers history up to %{at}.",
            at: when_str(@witness.oldest_unwitnessed.covered_at)
          )}
        </p>
        <p :if={last_error(@witness)} class="mt-1 font-mono text-xs break-words">
          {last_error(@witness)}
        </p>
      </div>

      <p
        :if={@witness.witnessing? and @witness.unwitnessed_count == 0 and @witness.latest}
        class="text-sm text-success"
      >
        <.icon name="hero-shield-check" class="size-4" />
        {gettext("Every checkpoint has been accepted by the witness.")}
      </p>
    </section>
    """
  end

  # The error from the oldest failure rather than the newest: it is the one that
  # says what first went wrong, and a later run's message is often just the
  # symptom of the same outage.
  defp last_error(%{oldest_unwitnessed: %{witness_error: error}}) when is_binary(error), do: error
  defp last_error(%{latest: %{witness_error: error}}) when is_binary(error), do: error
  defp last_error(_witness), do: nil

  attr :content, :list, required: true
  attr :witness, :map, required: true

  defp index(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-semibold">{gettext("Governance")}</h1>
        <p class="text-sm text-base-content/70">
          {gettext("Audit trail, consent records, and point-in-time history for your content.")}
        </p>
      </div>

      <.witness_panel witness={@witness} />

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
        <.chain_badge chain={@trail.chain} gap_range={@trail.chain_gap_range} />
        <.witnessed_badge witnessed={@trail.witnessed} />
        <p :if={@trail.unanchored_tail > 0} class="mt-1 text-xs text-base-content/60">
          {gettext("%{count} edit(s) since the last anchor — covered at the next publish.",
            count: @trail.unanchored_tail
          )}
        </p>
        <div class="mt-3 flex gap-2">
          <a
            href={~p"/editor/governance/#{@trail.item.type}/#{@trail.item.id}/export.json"}
            class="btn btn-sm btn-default"
            download
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export trail (JSON)")}
          </a>
          <a
            href={~p"/editor/governance/#{@trail.item.type}/#{@trail.item.id}/export.csv"}
            class="btn btn-sm btn-default"
            download
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export trail (CSV)")}
          </a>
        </div>
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
              <select name="consent[kind]" class="field-select mt-1 w-full py-1" required>
                <option :for={kind <- KilnCMS.CMS.Consent.kinds()} value={kind}>{kind}</option>
              </select>
            </label>
            <label class="text-xs">
              {gettext("Reference (ticket / document id)")}
              <input name="consent[reference]" class="field-input mt-1 w-full py-1" />
            </label>
            <label class="text-xs">
              {gettext("Grantor")}
              <input name="consent[grantor]" class="field-input mt-1 w-full py-1" />
            </label>
            <label class="text-xs">
              {gettext("Note")}
              <input name="consent[note]" class="field-input mt-1 w-full py-1" />
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
                <th>{gettext("Who")}</th>
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
                <%!-- "Who" (#352): the acting user on the version, when the
                      write carried one (older versions predate attribution). --%>
                <td class="whitespace-nowrap text-xs text-base-content/70">
                  {e.actor || "—"}
                </td>
                <td class="max-w-md text-xs text-base-content/60">
                  <details :if={e.diffs != []}>
                    <summary class="cursor-pointer truncate">
                      {e.diffs |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}
                    </summary>
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
                  <%!-- Point-in-time delivery (#338) now covers dynamic (D17)
                        entries too, so every publish row links. --%>
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
