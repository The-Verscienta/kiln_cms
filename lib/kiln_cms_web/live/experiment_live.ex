defmodule KilnCMSWeb.ExperimentLive do
  @moduledoc """
  `/editor/experiments/:id` (#982, #499 phase 2): one experiment — its
  variants authored against the document's real block tree, its results, and
  the lifecycle buttons (start, conclude, archive, promote).

  ## Variants are authored against the real block tree

  A variant's `patch` is keyed by a block's stable `id`
  (`%{"fields" => …, "blocks" => %{id => %{field => value}}}`), so hand-writing
  one means knowing uuids. Instead this page renders the document: the
  patchable scalars (`Variant.patchable_fields/0` — `title`, `excerpt`) and,
  for every top-level block and every child of a `columns` block, each
  `:string` field it declares, all **prefilled with the current value**. The
  editor edits copies; on save the form is **diffed against the document** and
  only what changed becomes the patch. So a patch is sparse by construction,
  and a field that was left alone is left out rather than pinned to today's
  value. Rich-text bodies are not offered here — a Portable Text body is not a
  one-line input — and a block with no readable `id` (a hand-written nested
  child, #865/#954) cannot be addressed by a patch and is not offered either.

  ## What a running experiment refuses

  A running experiment's variants are immutable
  (`KilnCMS.Experiments.Changes.RefuseWhenRunning`): changing a split or a
  patch mid-run invalidates every result gathered so far. The page does not
  offer add/edit/delete on a running experiment — it says why — rather than
  offering a form that fails on submit.

  ## Results, and what they refuse to say

  The panel is `KilnCMS.Experiments.Results.summarize/2`: per-variant
  impressions, conversions and rate. Below the sample-size floor no arm is
  called; above it the leader is named as "leading", never "significant".
  A **blocked** experiment (`Experiments.blocked_reason/1`, #1087) shows the
  reason **above** the counters and subordinates them: 0.0% next to a
  healthy-looking Running badge is the exact failure #1008 closed everywhere
  else. Phrases come from `KilnCMSWeb.ExperimentPhrases`, shared with the
  overview strip, so the two cannot grow separate lists.

  ## Promote is a separate act

  Concluding records the winner; **Promote** writes the winning patch into the
  document through the content type's ordinary `:update`, as this admin
  (`KilnCMS.Experiments.Promotion`) — a normal version, artifacts, webhooks. A
  second-running-experiment-per-document conflict, or `:start` without a
  goal, surfaces as the resource's own message rather than a constraint error.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Experiments
  alias KilnCMS.Experiments.{Promotion, Results, Variant}
  alias KilnCMSWeb.ExperimentPhrases

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Experiments.get_experiment(id, Keyword.put(actor_opts(socket), :load, [:variants])) do
      {:ok, experiment} ->
        {:ok,
         socket
         |> assign(:experiment_id, id)
         |> assign(:editing, nil)
         |> load(experiment)}

      {:error, _error} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That experiment doesn't exist."))
         |> push_navigate(to: ~p"/editor/experiments")}
    end
  end

  # ── lifecycle ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("start", _params, socket) do
    case Experiments.start_experiment(socket.assigns.experiment, actor_opts(socket)) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Experiment started.")) |> reload()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ash_error_message(error))}
    end
  end

  def handle_event("conclude", params, socket) do
    winner = blank_to_nil(Map.get(params, "winner_variant_id"))

    case Experiments.conclude_experiment(socket.assigns.experiment, winner, actor_opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Experiment concluded. The document is unchanged until you promote a winner.")
         )
         |> reload()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ash_error_message(error))}
    end
  end

  def handle_event("archive", _params, socket) do
    case Experiments.archive_experiment(socket.assigns.experiment, actor_opts(socket)) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Experiment archived.")) |> reload()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ash_error_message(error))}
    end
  end

  def handle_event("delete", _params, socket) do
    case Experiments.destroy_experiment(socket.assigns.experiment, actor_opts(socket)) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Experiment deleted."))
         |> push_navigate(to: ~p"/editor/experiments")}

      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Experiment deleted."))
         |> push_navigate(to: ~p"/editor/experiments")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ash_error_message(error))}
    end
  end

  def handle_event("promote", _params, socket) do
    case Promotion.promote(socket.assigns.experiment, actor_opts(socket)) do
      {:ok, _document} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Winner promoted — the document now carries the winning copy.")
         )
         |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, promote_error(reason))}
    end
  end

  # ── variants ───────────────────────────────────────────────────────────────

  def handle_event("edit_variant", %{"id" => "new"}, socket) do
    {:noreply, assign(socket, :editing, %{id: nil, name: "", weight: 1, patch: %{}})}
  end

  def handle_event("edit_variant", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.experiment.variants, &(&1.id == id)) do
      nil -> {:noreply, socket}
      variant -> {:noreply, assign(socket, :editing, variant)}
    end
  end

  def handle_event("cancel_variant", _params, socket),
    do: {:noreply, assign(socket, :editing, nil)}

  def handle_event("save_variant", %{"variant" => params}, socket) when is_map(params) do
    editing = socket.assigns.editing
    patch = diff_patch(params, socket.assigns.doc)

    attrs = %{
      name: Map.get(params, "name", ""),
      weight: parse_weight(Map.get(params, "weight")),
      patch: patch
    }

    result =
      case editing do
        %{id: nil} ->
          Experiments.create_variant(
            Map.put(attrs, :experiment_id, socket.assigns.experiment.id),
            actor_opts(socket)
          )

        %Variant{} = variant ->
          Experiments.update_variant(variant, attrs, actor_opts(socket))

        _ ->
          {:error, :no_variant}
      end

    case result do
      {:ok, _variant} ->
        {:noreply,
         socket
         |> assign(:editing, nil)
         |> put_flash(:info, gettext("Variant saved."))
         |> reload()}

      {:error, :no_variant} ->
        {:noreply, socket}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ash_error_message(error))}
    end
  end

  def handle_event("delete_variant", %{"id" => id}, socket) when is_binary(id) do
    with %Variant{} = variant <- Enum.find(socket.assigns.experiment.variants, &(&1.id == id)),
         :ok <- Experiments.destroy_variant(variant, actor_opts(socket)) do
      {:noreply, socket |> put_flash(:info, gettext("Variant removed.")) |> reload()}
    else
      {:ok, _} -> {:noreply, socket |> put_flash(:info, gettext("Variant removed.")) |> reload()}
      {:error, error} -> {:noreply, put_flash(socket, :error, ash_error_message(error))}
      _none -> {:noreply, socket}
    end
  end

  # ── state ──────────────────────────────────────────────────────────────────

  defp reload(socket) do
    case Experiments.get_experiment(
           socket.assigns.experiment_id,
           Keyword.put(actor_opts(socket), :load, [:variants])
         ) do
      {:ok, experiment} -> load(socket, experiment)
      {:error, _} -> push_navigate(socket, to: ~p"/editor/experiments")
    end
  end

  defp load(socket, experiment) do
    org = socket.assigns.current_org
    doc = document(experiment, socket)

    socket
    |> assign(:experiment, experiment)
    |> assign(:page_title, experiment.name)
    |> assign(:doc, doc)
    |> assign(:results, Results.summarize(experiment, org.id))
    |> assign(:enabled?, Experiments.enabled?())
  end

  # The document under test, projected to what a patch may address: the
  # patchable scalars and every addressable block's `:string` fields, each with
  # its current value. `nil` when the document is gone (the results panel then
  # says so via `blocked_reason/1`, and no variant form is offered).
  defp document(experiment, socket) do
    with ct when not is_nil(ct) <-
           ContentTypes.get(experiment.content_type, socket.assigns.current_org),
         {:ok, record} <- ContentTypes.get_record(ct, experiment.document_id, actor_opts(socket)) do
      %{
        record: record,
        title: record_title(record),
        fields:
          Enum.map(
            Variant.patchable_fields(),
            &{&1, to_string(Map.get(record, String.to_existing_atom(&1)) || "")}
          ),
        blocks: patchable_blocks(record)
      }
    else
      _ -> nil
    end
  end

  defp record_title(%{title: title}) when is_binary(title), do: title
  defp record_title(_record), do: gettext("(untitled)")

  # `[%{id, label, fields: [{name, current_value}]}]` for every block a patch
  # can address — top-level and `columns` children — with a readable `id`.
  defp patchable_blocks(record) do
    record
    |> Map.get(:blocks)
    |> List.wrap()
    |> Enum.map(&TypedBlocks.input_map/1)
    |> Enum.flat_map(&flatten_block/1)
    |> Enum.filter(&(&1.fields != []))
  end

  defp flatten_block(%{"_type" => type} = block) when is_binary(type) do
    own =
      case {Map.get(block, "id"), block_module(type)} do
        {id, module} when is_binary(id) and id != "" and not is_nil(module) ->
          [%{id: id, type: type, fields: string_fields(module, block)}]

        _ ->
          []
      end

    children =
      block
      |> Map.get("columns")
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"blocks" => children} when is_list(children) ->
          Enum.flat_map(children, &flatten_block/1)

        _ ->
          []
      end)

    own ++ children
  end

  defp flatten_block(_other), do: []

  defp block_module(type) do
    with {:ok, atom} <- safe_atom(type),
         {:ok, module} <- KilnCMS.Blocks.fetch(atom) do
      module
    else
      _ -> nil
    end
  end

  defp safe_atom(type) do
    {:ok, String.to_existing_atom(type)}
  rescue
    ArgumentError -> :error
  end

  # `:string` fields only, current value alongside. Structural keys are never
  # offered — `Assignment.safe_fields/1` refuses them anyway.
  defp string_fields(module, block) do
    module
    |> Kiln.Block.Info.fields()
    |> Enum.filter(&(&1.type == :string and &1.name not in [:id, :_type, :_version]))
    |> Enum.map(fn field ->
      key = Atom.to_string(field.name)
      {key, to_string(Map.get(block, key) || "")}
    end)
  end

  # Form → sparse patch: a value equal to the document's current value is left
  # out; only differences are written. Keys are the ones the form rendered
  # (`fields[title]`, `blocks[<id>][<field>]`), so nothing the document does not
  # have can be smuggled in — and `PatchShape` re-validates on write anyway.
  defp diff_patch(params, nil), do: patch_from_params(params, %{fields: [], blocks: []})
  defp diff_patch(params, doc), do: patch_from_params(params, doc)

  defp patch_from_params(params, doc) do
    fields = changed_fields(map_param(params, "fields"), Map.new(doc.fields))

    blocks =
      changed_blocks(
        map_param(params, "blocks"),
        Map.new(doc.blocks, &{&1.id, Map.new(&1.fields)})
      )

    %{}
    |> put_unless_empty("fields", fields)
    |> put_unless_empty("blocks", blocks)
  end

  defp map_param(params, key) do
    case Map.get(params, key) do
      %{} = map -> map
      _ -> %{}
    end
  end

  # Only patchable keys, only string values, only where different from the
  # document.
  defp changed_fields(values, current) do
    values
    |> Enum.filter(fn {key, value} ->
      key in Variant.patchable_fields() and is_binary(value) and
        value != Map.get(current, key, "")
    end)
    |> Map.new()
  end

  # Only blocks the document has, only fields the block declares, only where
  # different — a block with nothing changed is left out entirely.
  defp changed_blocks(values, current_blocks) do
    values
    |> Enum.flat_map(fn {id, block_values} ->
      case {Map.get(current_blocks, id), block_values} do
        {%{} = current, %{} = block_values} -> changed_block(id, block_values, current)
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp changed_block(id, values, current) do
    changed =
      values
      |> Enum.filter(fn {k, v} ->
        is_binary(v) and Map.has_key?(current, k) and v != current[k]
      end)
      |> Map.new()

    if changed == %{}, do: [], else: [{id, changed}]
  end

  defp put_unless_empty(patch, _key, value) when value == %{}, do: patch
  defp put_unless_empty(patch, key, value), do: Map.put(patch, key, value)

  # The value the form should show for a field: the variant's patched value if
  # it has one, else the document's.
  defp field_value(editing, "fields", key, current) do
    get_in(editing.patch, ["fields", key]) || current
  end

  defp field_value(editing, "blocks", {id, key}, current) do
    get_in(editing.patch, ["blocks", id, key]) || current
  end

  defp parse_weight(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp parse_weight(_), do: 1

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp actor_opts(socket),
    do: [actor: socket.assigns.current_user, tenant: socket.assigns.current_org]

  # An Ash write error as one sentence for the flash. `Exception.message/1`
  # interpolates an error's `vars` (reading `.message` off the struct hands
  # back a raw `%{value}` template).
  defp ash_error_message(%Ash.Error.Forbidden{}),
    do: gettext("You don't have permission to change experiments on this site.")

  defp ash_error_message(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.map_join(" ", &Exception.message/1)
    |> case do
      "" -> gettext("The change could not be saved.")
      message -> message
    end
  end

  defp promote_error(:not_concluded), do: gettext("Conclude the experiment before promoting.")
  defp promote_error(:no_winner), do: gettext("This experiment concluded without a winner.")

  defp promote_error(:winner_is_control),
    do: gettext("The control won — the document already reads that way; nothing to promote.")

  defp promote_error(:winner_missing), do: gettext("The winning variant no longer exists.")

  defp promote_error(:type_unknown),
    do: gettext("The document's content type is no longer on this site.")

  defp promote_error(:document_missing), do: gettext("The document under test no longer exists.")
  defp promote_error({:update_failed, error}), do: ash_error_message(error)

  defp percent(nil), do: "—"
  defp percent(rate), do: "#{Float.round(rate * 100, 1)}%"

  defp experiment_state_label(:draft), do: gettext("Draft")
  defp experiment_state_label(:running), do: gettext("Running")
  defp experiment_state_label(:concluded), do: gettext("Concluded")
  defp experiment_state_label(:archived), do: gettext("Archived")
  defp experiment_state_label(other), do: to_string(other)

  defp winner?(experiment, variant), do: experiment.winner_variant_id == variant.id

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:experiments}
    >
      <div class="space-y-8">
        <div>
          <.link
            navigate={~p"/editor/experiments"}
            class="text-sm text-base-content/60 hover:underline"
          >
            &larr; {gettext("Experiments")}
          </.link>
          <div class="mt-1 flex flex-wrap items-center gap-3">
            <h1 class="text-2xl font-semibold">{@experiment.name}</h1>
            <span class="badge badge-sm">{experiment_state_label(@experiment.state)}</span>
          </div>
          <p class="text-sm text-base-content/70">
            <%= if @doc do %>
              {gettext("Testing “%{title}”", title: @doc.title)}
            <% else %>
              {gettext("The document under test could not be read.")}
            <% end %>
          </p>
        </div>

        <%!-- ── lifecycle ─────────────────────────────────────────────── --%>
        <section class="card card-pad flex flex-wrap items-center gap-3">
          <.button :if={@experiment.state == :draft} phx-click="start" variant="primary">
            {gettext("Start")}
          </.button>
          <form
            :if={@experiment.state == :running}
            phx-submit="conclude"
            class="flex flex-wrap items-center gap-2"
          >
            <label for="winner" class="text-sm">{gettext("Conclude with winner")}</label>
            <select id="winner" name="winner_variant_id" class="field-input">
              <option value="">{gettext("no winner — just stop")}</option>
              <option :for={v <- @experiment.variants} value={v.id}>{v.name}</option>
            </select>
            <.button type="submit" variant="primary">{gettext("Conclude")}</.button>
          </form>
          <.button
            :if={@experiment.state == :concluded and @experiment.winner_variant_id}
            phx-click="promote"
            variant="primary"
            data-confirm={
              gettext(
                "Write the winning variant into the document? This edits the live content like a normal save."
              )
            }
          >
            {gettext("Promote winner into document")}
          </.button>
          <button
            :if={@experiment.state in [:draft, :running, :concluded]}
            type="button"
            phx-click="archive"
            data-confirm={gettext("Archive this experiment?")}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Archive")}
          </button>
          <button
            :if={@experiment.state == :draft}
            type="button"
            phx-click="delete"
            data-confirm={gettext("Delete this draft experiment and its variants?")}
            class="btn btn-ghost btn-sm text-error"
          >
            {gettext("Delete")}
          </button>
          <p :if={not @enabled?} class="w-full text-xs text-warning-ink">
            {gettext(
              "Experiments are switched off on this deployment: nothing is served or measured."
            )}
          </p>
        </section>

        <%!-- ── results ───────────────────────────────────────────────── --%>
        <section :if={@experiment.state in [:running, :concluded, :archived]} class="space-y-3">
          <h2 class="text-lg font-medium">{gettext("Results")}</h2>

          <%!-- #1087: a blocked experiment says so ABOVE its counters; the
               numbers below are subordinated because they cannot be produced. --%>
          <div
            :if={@results.blocked}
            id="results-blocked"
            class="rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm"
          >
            <p class="font-medium">{gettext("No usable result")}</p>
            <p class="mt-1 text-base-content/70">
              {gettext("This experiment cannot convert: %{reason}.",
                reason: ExperimentPhrases.blocked_headline(elem(@results.blocked, 0))
              )}
            </p>
          </div>

          <div class={["overflow-x-auto card", @results.blocked && "opacity-60"]}>
            <table class="table" id="results-table">
              <thead>
                <tr>
                  <th scope="col">{gettext("Variant")}</th>
                  <th scope="col">{gettext("Weight")}</th>
                  <th scope="col">{gettext("Impressions")}</th>
                  <th scope="col">{gettext("Conversions")}</th>
                  <th scope="col">{gettext("Rate")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @results.rows} id={"result-#{row.variant.id}"}>
                  <td>
                    <span class="font-medium">{row.variant.name}</span>
                    <span :if={row.variant.control} class="ml-1 text-xs text-base-content/60">{gettext(
                      "control"
                    )}</span>
                    <span
                      :if={@results.leader && @results.leader.id == row.variant.id}
                      class="ml-2 badge badge-sm badge-success"
                    >
                      {gettext("leading")}
                    </span>
                    <span
                      :if={winner?(@experiment, row.variant)}
                      class="ml-2 badge badge-sm badge-info"
                    >
                      {gettext("winner")}
                    </span>
                    <p :if={row.anomaly} class="text-xs text-warning-ink">
                      {ExperimentPhrases.anomaly_headline(elem(row.anomaly, 0))}
                    </p>
                  </td>
                  <td class="tabular-nums">{row.variant.weight}</td>
                  <td class="tabular-nums">{row.impressions}</td>
                  <td class="tabular-nums">{row.conversions}</td>
                  <td class="tabular-nums">{percent(row.rate)}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <p
            :if={not @results.decidable? and is_nil(@results.blocked)}
            id="results-floor"
            class="text-xs text-base-content/60"
          >
            {gettext(
              "Not enough data to call a leader: every variant needs at least %{floor} impressions first. Rates on fewer are shown but not compared.",
              floor: @results.floor
            )}
          </p>
          <p
            :if={@results.decidable? and is_nil(@results.leader) and is_nil(@results.blocked)}
            class="text-xs text-base-content/60"
          >
            {gettext("Every variant is over the floor and no arm leads outright.")}
          </p>
          <p :if={@results.leader} class="text-xs text-base-content/60">
            {gettext(
              "“Leading” means the highest rate so far over at least %{floor} impressions per arm — a comparison, not a significance test.",
              floor: @results.floor
            )}
          </p>
        </section>

        <%!-- ── variants ──────────────────────────────────────────────── --%>
        <section class="space-y-3">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 class="text-lg font-medium">
              {gettext("Variants")} ({length(@experiment.variants)})
            </h2>
            <.button
              :if={@experiment.state == :draft and not is_nil(@doc) and is_nil(@editing)}
              phx-click="edit_variant"
              phx-value-id="new"
              size="sm"
            >
              {gettext("Add variant")}
            </.button>
          </div>

          <p :if={@experiment.state == :running} class="text-xs text-base-content/60">
            {gettext(
              "A running experiment's variants are locked: changing a split or a patch mid-run would invalidate every result gathered so far. Conclude it first."
            )}
          </p>

          <ul class="card divide-y divide-base-content/10 overflow-hidden">
            <li
              :for={variant <- @experiment.variants}
              class="flex flex-wrap items-center justify-between gap-3 p-3"
            >
              <div class="min-w-0 flex-1">
                <span class="font-medium">{variant.name}</span>
                <span :if={variant.control} class="ml-1 text-xs text-base-content/60">{gettext(
                  "control"
                )}</span>
                <span class="ml-2 text-xs text-base-content/60">{gettext("weight %{weight}",
                  weight: variant.weight
                )}</span>
                <p :if={variant.patch != %{}} class="mt-1 font-mono text-xs text-base-content/60">
                  {Jason.encode!(variant.patch)}
                </p>
              </div>
              <div :if={@experiment.state == :draft and not variant.control} class="flex gap-2">
                <button
                  type="button"
                  phx-click="edit_variant"
                  phx-value-id={variant.id}
                  class="btn btn-ghost btn-sm"
                >
                  {gettext("Edit")}
                </button>
                <button
                  type="button"
                  phx-click="delete_variant"
                  phx-value-id={variant.id}
                  data-confirm={gettext("Remove this variant?")}
                  class="btn btn-ghost btn-sm text-error"
                >
                  {gettext("Remove")}
                </button>
              </div>
            </li>
          </ul>

          <%!-- The variant form: the document's patchable fields and blocks,
               prefilled, diffed on save. --%>
          <form
            :if={not is_nil(@editing) and not is_nil(@doc)}
            id="variant-form"
            phx-submit="save_variant"
            class="card card-pad space-y-4"
          >
            <div class="grid gap-3 sm:grid-cols-2">
              <div>
                <label for="variant-name" class="text-sm font-medium">{gettext("Variant name")}</label>
                <input
                  id="variant-name"
                  name="variant[name]"
                  value={@editing.name}
                  required
                  class="field-input mt-1"
                />
              </div>
              <div>
                <label for="variant-weight" class="text-sm font-medium">{gettext("Weight")}</label>
                <input
                  id="variant-weight"
                  name="variant[weight]"
                  type="number"
                  min="1"
                  value={@editing.weight}
                  class="field-input mt-1"
                />
              </div>
            </div>

            <fieldset class="space-y-2">
              <legend class="text-sm font-medium">{gettext("Document fields")}</legend>
              <p class="text-xs text-base-content/60">
                {gettext(
                  "Only these fields may be varied. Leave a field as it is to keep the document's value."
                )}
              </p>
              <div :for={{key, current} <- @doc.fields}>
                <label for={"field-#{key}"} class="text-xs text-base-content/70">{key}</label>
                <input
                  id={"field-#{key}"}
                  name={"variant[fields][#{key}]"}
                  value={field_value(@editing, "fields", key, current)}
                  class="field-input mt-1"
                />
              </div>
            </fieldset>

            <fieldset :if={@doc.blocks != []} class="space-y-3">
              <legend class="text-sm font-medium">{gettext("Blocks")}</legend>
              <p class="text-xs text-base-content/60">
                {gettext(
                  "Each block's text fields, addressed by the block's stable id — a patch survives reordering."
                )}
              </p>
              <div :for={block <- @doc.blocks} class="rounded-lg border border-base-300 p-3">
                <p class="text-xs font-medium text-base-content/70">
                  {block.type}
                  <span class="ml-1 font-mono text-base-content/50">{String.slice(block.id, 0, 8)}</span>
                </p>
                <div :for={{key, current} <- block.fields} class="mt-2">
                  <label for={"block-#{block.id}-#{key}"} class="text-xs text-base-content/70">{key}</label>
                  <input
                    id={"block-#{block.id}-#{key}"}
                    name={"variant[blocks][#{block.id}][#{key}]"}
                    value={field_value(@editing, "blocks", {block.id, key}, current)}
                    class="field-input mt-1"
                  />
                </div>
              </div>
            </fieldset>

            <div class="flex gap-2">
              <.button type="submit" variant="primary">{gettext("Save variant")}</.button>
              <button type="button" phx-click="cancel_variant" class="btn btn-ghost btn-sm">{gettext(
                "Cancel"
              )}</button>
            </div>
          </form>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
