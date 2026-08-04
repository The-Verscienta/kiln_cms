defmodule Kiln.Forms.SpamCheck.Context do
  @moduledoc """
  The snapshot every spam check is judged against — the `Kiln.Advisory.Context`
  analogue for #477.

  `data` is the coerced, JSON-native field-value map `KilnCMS.Forms.submit/3`
  already produces (only defined field keys). `keywords` is the caller's
  per-org disallowed-keyword list (`KilnCMS.CMS.FormSpamSettings`), resolved
  once by the caller rather than queried per check.

  ## `facts`, for what a pure function cannot compute

  Checks are pure; `submission-fill-time` needs a wall-clock delta the caller
  computed from a signed render-time token, which is exactly what `facts` is
  for in `Kiln.Advisory.Context` too — a caller-computed answer, paid for once,
  by the caller that knows when it's affordable.
  """

  @type t :: %__MODULE__{
          data: %{String.t() => term()},
          locale: String.t() | nil,
          keywords: [String.t()],
          facts: %{atom() => term()}
        }

  defstruct data: %{}, locale: nil, keywords: [], facts: %{}

  @spec new(map(), keyword()) :: t()
  def new(data, opts \\ []) do
    %__MODULE__{
      data: data || %{},
      locale: Keyword.get(opts, :locale),
      keywords: Keyword.get(opts, :keywords) || [],
      # `|| %{}` rather than only a default: an explicit `facts: nil` from a
      # caller must not reach `fact/3` and `BadMapError` there instead.
      facts: Keyword.get(opts, :facts) || %{}
    }
  end

  @doc """
  A caller-computed fact, or `default` when this caller did not compute it.

      fact(context, :fill_time_ms)
  """
  @spec fact(t(), atom(), term()) :: term()
  def fact(%__MODULE__{facts: facts}, key, default \\ nil), do: Map.get(facts, key, default)

  @doc """
  Every string field value, concatenated — the text surface a check that
  scans free text (link density, keywords, script) reads.
  """
  @spec text(t()) :: String.t()
  def text(%__MODULE__{data: data}) do
    data |> Map.values() |> Enum.filter(&is_binary/1) |> Enum.join(" ")
  end
end
