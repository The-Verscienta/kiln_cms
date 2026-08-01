defmodule KilnCMS.Assist.Request do
  @moduledoc """
  What a block-assist call sends, and nothing else.

  The same deliberate allow-list as `KilnCMS.Seo.Document`, for the same
  reason: whatever is in this struct is what leaves the deployment when an
  operator has configured a hosted provider. No ids, no author, no custom
  fields, no audience, no other block's content.

  It is narrower than the SEO document on purpose. Metadata drafting has to
  read the whole page to describe it; block assist works on **one block**, so
  it sends that block's text plus the little context needed to keep the voice
  consistent — the page title, its excerpt and its headings. A page with fifty
  blocks ships one of them.
  """

  alias KilnCMS.Assist
  alias KilnCMS.Assist.Action

  @type t :: %__MODULE__{
          action: Action.id(),
          instruction: String.t() | nil,
          text: String.t(),
          title: String.t(),
          excerpt: String.t() | nil,
          headings: [String.t()],
          content_type: String.t() | nil,
          locale: String.t(),
          truncated?: boolean()
        }

  defstruct action: :rewrite,
            instruction: nil,
            text: "",
            title: "",
            excerpt: nil,
            headings: [],
            content_type: nil,
            locale: "en",
            truncated?: false

  # A block long enough to be worth acting on. Below this, "summarize" and
  # "rewrite" are the model inventing rather than working.
  @min_text_chars 40
  @max_headings 12

  @doc """
  Build a request from loose attributes, clamping everything that varies.

  Both free-text fields are bounded here rather than at the prompt: `text` is
  the page's, `instruction` is the author's, and neither should be able to set
  the size of a paid request.
  """
  @spec new(map()) :: t()
  def new(attrs) do
    {text, truncated?} = clamp_text(string(fetch(attrs, :text)), Assist.max_input_chars())

    %__MODULE__{
      action: fetch(attrs, :action) || :rewrite,
      instruction: presence(fetch(attrs, :instruction)) |> clamp(Assist.max_instruction_chars()),
      text: text,
      truncated?: truncated?,
      title: string(fetch(attrs, :title)),
      excerpt: presence(fetch(attrs, :excerpt)),
      headings: headings(fetch(attrs, :headings)),
      content_type: presence(fetch(attrs, :content_type)),
      locale: presence(fetch(attrs, :locale)) || KilnCMS.I18n.default_locale()
    }
  end

  @doc """
  Whether this request has the inputs its action needs.

  Checked before the generator is reached so an impossible call costs nothing:
  `:summarize` on an empty block and `:draft` with no instruction are both
  reachable from the UI (the author can click before typing).
  """
  @spec validate(t()) :: :ok | {:error, :too_short | :no_instruction | :unknown_action}
  def validate(%__MODULE__{} = request) do
    case Action.fetch(request.action) do
      :error ->
        {:error, :unknown_action}

      {:ok, action} ->
        cond do
          action.needs_text? and String.length(request.text) < @min_text_chars ->
            {:error, :too_short}

          action.needs_instruction? and is_nil(request.instruction) ->
            {:error, :no_instruction}

          true ->
            :ok
        end
    end
  end

  @doc "The shortest block worth sending, in characters."
  @spec min_text_chars() :: pos_integer()
  def min_text_chars, do: @min_text_chars

  # Head-cut rather than the head-and-tail elision `KilnCMS.Seo.Document` uses:
  # every action here either continues from or rewrites the passage in order, so
  # a hole in the middle would produce prose that skips a paragraph.
  defp clamp_text(text, max) do
    if String.length(text) <= max,
      do: {text, false},
      else: {String.slice(text, 0, max), true}
  end

  defp headings(values) do
    values
    |> List.wrap()
    |> Enum.map(&presence/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_headings)
  end

  defp fetch(attrs, key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, to_string(key))
      value -> value
    end
  end

  defp clamp(nil, _max), do: nil
  defp clamp(value, max), do: String.slice(value, 0, max)

  # Anything that isn't already a string is absent. `to_string/1` on a non-binary
  # quietly manufactures content — the editor's `has_excerpt && value` idiom
  # yields the atom `false` for a type with no excerpt field, which would be sent
  # to the provider as the literal string "false".
  defp string(value) when is_binary(value), do: String.trim(value)
  defp string(_value), do: ""

  defp presence(value) do
    case string(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end

defimpl Inspect, for: KilnCMS.Assist.Request do
  import Inspect.Algebra

  # The block text is the bulk of the struct and shows up in logs, telemetry and
  # crash reports; summarize it rather than dumping the passage.
  def inspect(request, opts) do
    concat([
      "#KilnCMS.Assist.Request<",
      to_doc(
        %{
          action: request.action,
          locale: request.locale,
          text_chars: String.length(request.text),
          instruction?: not is_nil(request.instruction),
          truncated?: request.truncated?
        },
        opts
      ),
      ">"
    ])
  end
end
