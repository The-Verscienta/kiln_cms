defmodule KilnCMSWeb.ContentEditor.FieldEvents do
  @moduledoc """
  The content editor's side of a plugin field type's client hook calling the
  server (#1918, `c:Kiln.FieldType.handle_input_event/3`).

  A hook pushes `"kiln:field_event"`; `start/2` resolves the named field
  against the record's own field definitions and runs the type's callback
  under `start_async/3`, keyed per field. The editor process never waits on a
  plugin's I/O, and a newer event for a field cancels the one still running,
  so a type-ahead answers its latest keystroke rather than its slowest one.
  `handle_async/3` turns the outcome into a `"kiln:field_reply"` push event.

  Only fields attached to the record being edited are reachable: a client can
  name any field it likes, but one the editor didn't load answers an error
  without calling anything.
  """

  import Phoenix.LiveView, only: [cancel_async: 2, push_event: 3, start_async: 3]

  require Logger

  @reply "kiln:field_reply"

  @doc """
  Dispatch one `"kiln:field_event"` payload. Returns the socket — with a task
  started, or with an error reply pushed when the field can't answer.
  """
  def start(socket, %{"field" => field, "event" => event} = payload)
      when is_binary(field) and is_binary(event) do
    ref = ref(payload)
    params = params(payload)

    case handler(socket, field) do
      {:ok, module, definition} ->
        context = %{
          definition: definition,
          actor: socket.assigns.current_user,
          org: socket.assigns.current_org
        }

        key = async_key(field)

        socket
        |> cancel_async(key)
        |> start_async(key, fn -> {ref, call(module, event, params, context)} end)

      :error ->
        push_event(socket, @reply, %{field: field, ref: ref, error: "unhandled"})
    end
  end

  def start(socket, _payload), do: socket

  @doc """
  Push the outcome of a field event's task back to the hooks. A cancelled
  task (superseded by a newer event) pushes nothing.
  """
  def handle_async({__MODULE__, field}, result, socket) do
    case result do
      {:ok, {ref, {:ok, reply}}} ->
        push_event(socket, @reply, %{field: field, ref: ref, reply: reply})

      {:ok, {ref, {:error, message}}} when is_binary(message) ->
        push_event(socket, @reply, %{field: field, ref: ref, error: message})

      {:ok, {ref, :failed}} ->
        push_event(socket, @reply, %{field: field, ref: ref, error: "failed"})

      {:ok, {ref, other}} ->
        Logger.warning(
          "handle_input_event/3 for field #{inspect(field)} returned #{inspect(other)}; " <>
            "expected {:ok, reply} or {:error, message}"
        )

        push_event(socket, @reply, %{field: field, ref: ref, error: "failed"})

      # Superseded by a newer event, or the task was killed from outside —
      # `call/4` already turned the callback's own raises into a reply.
      {:exit, _reason} ->
        socket
    end
  end

  # Inside the task, so a raising callback still answers the hook it was
  # asked by (its ref) instead of leaving it waiting.
  defp call(module, event, params, %{definition: definition} = context) do
    module.handle_input_event(event, params, context)
  catch
    kind, reason ->
      Logger.warning(
        "#{inspect(module)}.handle_input_event/3 for field #{inspect(definition.name)} " <>
          "failed: " <> Exception.format(kind, reason, __STACKTRACE__)
      )

      :failed
  end

  defp async_key(field), do: {__MODULE__, field}

  defp handler(socket, field) do
    with %{} = definition <-
           Enum.find(Map.get(socket.assigns, :field_definitions, []), &(&1.name == field)),
         module when not is_nil(module) <- KilnCMS.CMS.FieldTypes.get(definition.field_type),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :handle_input_event, 3) do
      {:ok, module, definition}
    else
      _unhandled -> :error
    end
  end

  # Echoed back verbatim so the hook can match a reply to its request; only
  # scalars, so a client can't make the server hold or re-send a big payload.
  defp ref(%{"ref" => ref}) when is_integer(ref) or (is_binary(ref) and byte_size(ref) <= 64),
    do: ref

  defp ref(_payload), do: nil

  defp params(%{"params" => %{} = params}), do: params
  defp params(_payload), do: %{}
end
