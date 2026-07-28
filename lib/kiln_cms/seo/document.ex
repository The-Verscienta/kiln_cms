defmodule KilnCMS.Seo.Document do
  @moduledoc """
  The projection of a content record handed to a `KilnCMS.Seo.Generator`.

  A deliberate, explicit allow-list rather than the record itself: whatever is
  in here is what leaves the deployment when an operator has configured a
  hosted provider. Nothing else — no ids, no author, no custom fields, no
  audience, no internal state — can reach a third party by accident.
  """

  alias KilnCMS.Seo.BodyStats

  @type t :: %__MODULE__{
          title: String.t(),
          excerpt: String.t() | nil,
          body_text: String.t(),
          headings: [String.t()],
          locale: String.t(),
          content_type: String.t() | nil,
          seo_title: String.t() | nil,
          seo_description: String.t() | nil,
          seo_keywords: String.t() | nil,
          truncated?: boolean()
        }

  defstruct title: "",
            excerpt: nil,
            body_text: "",
            headings: [],
            locale: "en",
            content_type: nil,
            seo_title: nil,
            seo_description: nil,
            seo_keywords: nil,
            truncated?: false

  @elision "\n\n[…]\n\n"
  # How much of the budget the tail keeps. An article's conclusion carries a lot
  # of its topic signal, so a plain head cut throws away the summary.
  @tail_chars 1_500

  @doc """
  Build a document from loose attributes.

  `attrs` may be atom- or string-keyed and may carry either `:body_text`
  (already flattened) or `:blocks` (the stored block list, flattened here).
  """
  @spec new(map(), keyword()) :: t()
  def new(attrs, opts \\ []) do
    stats = attrs |> fetch(:blocks) |> body_stats(fetch(attrs, :body_text))

    %__MODULE__{
      title: string(fetch(attrs, :title)),
      excerpt: presence(fetch(attrs, :excerpt)),
      body_text: stats.text,
      headings: Enum.map(stats.headings, & &1.text),
      locale: presence(fetch(attrs, :locale)) || KilnCMS.I18n.default_locale(),
      content_type: presence(fetch(attrs, :content_type)),
      seo_title: presence(fetch(attrs, :seo_title)),
      seo_description: presence(fetch(attrs, :seo_description)),
      seo_keywords: presence(fetch(attrs, :seo_keywords))
    }
    |> truncate(Keyword.get(opts, :max_chars, KilnCMS.Seo.max_input_chars()))
  end

  @doc "Build a document from a persisted content record."
  @spec from_record(struct(), keyword()) :: t()
  def from_record(record, opts \\ []) do
    record
    |> Map.take([
      :title,
      :excerpt,
      :blocks,
      :locale,
      :seo_title,
      :seo_description,
      :seo_keywords
    ])
    |> Map.put(:content_type, opts[:content_type])
    |> new(opts)
  end

  @doc """
  Clamp `body_text` to `max_chars`, keeping the opening and the closing passage.

  Sets `truncated?` so the prompt can say so rather than letting the model
  assume it saw the whole document.
  """
  @spec truncate(t(), pos_integer()) :: t()
  def truncate(%__MODULE__{} = doc, max_chars) when max_chars > 0 do
    if String.length(doc.body_text) <= max_chars do
      doc
    else
      tail_size = min(@tail_chars, div(max_chars, 3))
      head_size = max(max_chars - tail_size, 1)

      head = String.slice(doc.body_text, 0, head_size)
      tail = String.slice(doc.body_text, -tail_size, tail_size)

      %{doc | body_text: head <> @elision <> tail, truncated?: true}
    end
  end

  def truncate(%__MODULE__{} = doc, _max_chars), do: doc

  defp body_stats(nil, body_text), do: %BodyStats{text: string(body_text)}

  defp body_stats(blocks, body_text) do
    case BodyStats.compute(blocks) do
      %BodyStats{text: ""} = stats -> %{stats | text: string(body_text)}
      stats -> stats
    end
  end

  defp fetch(attrs, key) do
    case Map.get(attrs, key) do
      nil -> Map.get(attrs, to_string(key))
      value -> value
    end
  end

  defp string(nil), do: ""
  defp string(value), do: value |> to_string() |> String.trim()

  defp presence(value) do
    case string(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end

defimpl Inspect, for: KilnCMS.Seo.Document do
  import Inspect.Algebra

  # The body is the bulk of the struct and shows up in logs, telemetry and
  # crash reports; summarize it rather than dumping the whole document.
  def inspect(doc, opts) do
    concat([
      "#KilnCMS.Seo.Document<",
      to_doc(
        %{
          title: doc.title,
          locale: doc.locale,
          body_chars: String.length(doc.body_text),
          headings: length(doc.headings),
          truncated?: doc.truncated?
        },
        opts
      ),
      ">"
    ])
  end
end
