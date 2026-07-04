defmodule ShowcaseWeb.ContactLive do
  @moduledoc """
  A public form, rendered from its KilnCMS schema (`GET /api/forms/:slug`) and
  submitted back over `POST /api/forms/:slug`. The field set is admin-defined —
  this LiveView just renders whatever the schema describes. The form slug is
  configurable (`config :showcase, :contact_form_slug`, default `"contact"`).
  """
  use ShowcaseWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    slug = Application.get_env(:showcase, :contact_form_slug, "contact")

    socket =
      case Showcase.Kiln.form_schema(slug) do
        {:ok, schema} -> assign(socket, schema: schema, missing?: false)
        _ -> assign(socket, schema: nil, missing?: true)
      end

    {:ok, assign(socket, slug: slug, sent: nil, errors: %{})}
  end

  @impl true
  def handle_event("submit", params, socket) do
    fields = Map.drop(params, ["_target", "_csrf_token"])

    case Showcase.Kiln.submit_form(socket.assigns.slug, fields) do
      {:ok, message} ->
        {:noreply, assign(socket, sent: message || "Thanks — we got your message.", errors: %{})}

      {:error, {:validation, errors}} ->
        {:noreply, assign(socket, errors: errors)}

      {:error, _} ->
        {:noreply, assign(socket, errors: %{"_" => "Couldn't submit right now. Try again."})}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>{(@schema && @schema["name"]) || "Contact"}</h1>

    <p :if={@missing?} class="page-intro">
      This demo renders whatever form KilnCMS serves at <code>/api/forms/{@slug}</code>. Create a form with that slug in the editor
      (<code>/editor/forms</code>) to see it appear here.
    </p>

    <p :if={@schema && @schema["description"]} class="page-intro">{@schema["description"]}</p>

    <div :if={@sent} class="flash flash-info">{@sent}</div>

    <form :if={@schema && is_nil(@sent)} phx-submit="submit">
      <p :if={@errors["_"]} class="flash flash-error">{@errors["_"]}</p>

      <.field :for={field <- @schema["fields"] || []} field={field} error={@errors[field["name"]]} />

      <%!-- Honeypot: hidden from humans, tempting to bots. Left empty on submit. --%>
      <input
        :if={@schema["honeypot_field"]}
        type="text"
        name={@schema["honeypot_field"]}
        tabindex="-1"
        autocomplete="off"
        style="position:absolute;left:-9999px"
        aria-hidden="true"
      />

      <button type="submit" class="btn">Send</button>
    </form>
    """
  end

  # ── one field per schema entry ──────────────────────────────────────────────

  attr :field, :map, required: true
  attr :error, :string, default: nil

  defp field(assigns) do
    ~H"""
    <label class="field">
      <span>{@field["label"]}{if @field["required"], do: " *"}</span>
      <.control field={@field} />
      <span :if={@field["help_text"]} class="hint">{@field["help_text"]}</span>
      <span :if={@error} class="hint" style="color:#b91c1c">{@error}</span>
    </label>
    """
  end

  attr :field, :map, required: true

  defp control(%{field: %{"type" => "text"}} = assigns) do
    ~H"""
    <textarea name={@field["name"]} required={@field["required"]}></textarea>
    """
  end

  defp control(%{field: %{"type" => "select"}} = assigns) do
    ~H"""
    <select name={@field["name"]} required={@field["required"]}>
      <option value="">—</option>
      <option :for={opt <- @field["options"] || []} value={opt}>{opt}</option>
    </select>
    """
  end

  defp control(%{field: %{"type" => "boolean"}} = assigns) do
    ~H"""
    <input type="hidden" name={@field["name"]} value="false" />
    <input type="checkbox" name={@field["name"]} value="true" style="width:auto" />
    """
  end

  defp control(assigns) do
    assigns = assign(assigns, :input_type, input_type(assigns.field["type"]))

    ~H"""
    <input type={@input_type} name={@field["name"]} required={@field["required"]} />
    """
  end

  # (heredoc form above avoids clashing with the `"` inside `@field["name"]`)

  defp input_type("email"), do: "email"
  defp input_type("integer"), do: "number"
  defp input_type("date"), do: "date"
  defp input_type(_), do: "text"
end
