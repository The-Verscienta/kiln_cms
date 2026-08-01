defmodule KilnCMS.Assist.Action do
  @moduledoc """
  The fixed menu of things block assist can be asked to do.

  A closed table rather than a free-form prompt field, for three reasons:

    * an action id is safe to accept from the browser — the LiveView looks it
      up here and an unknown one is simply rejected, so no part of the system
      prompt is ever attacker-chosen;
    * each action states its own length and grounding rules, which is most of
      what makes the output usable without editing;
    * `needs_text?` / `needs_instruction?` let the caller refuse a call that
      couldn't work (summarizing an empty block) *before* spending a token.

  Prompt text here is deliberately English and not run through Gettext. It is
  addressed to the model, not to the author, and the language the model must
  *write* in is pinned separately from the record's locale (see
  `KilnCMS.Assist.Prompt`). Translating the instructions would change model
  behaviour with the admin's UI language, which is not the same axis.
  """

  @type id :: :draft | :continue | :summarize | :rewrite | :shorten | :expand

  @type t :: %{
          id: id(),
          needs_text?: boolean(),
          needs_instruction?: boolean(),
          goal: String.t()
        }

  @actions [
    %{
      id: :draft,
      needs_text?: false,
      needs_instruction?: true,
      goal:
        "Write new prose for this section of the page, following the author's instruction. " <>
          "Aim for two to four short paragraphs unless the instruction asks otherwise."
    },
    %{
      id: :continue,
      needs_text?: true,
      needs_instruction?: false,
      goal:
        "Continue the supplied passage from where it stops, in the same voice and tense. " <>
          "Write one or two further paragraphs. Do not restate what is already there."
    },
    %{
      id: :summarize,
      needs_text?: true,
      needs_instruction?: false,
      goal:
        "Summarize the supplied passage in a single short paragraph. " <>
          "Cover only what the passage says."
    },
    %{
      id: :rewrite,
      needs_text?: true,
      needs_instruction?: false,
      goal:
        "Rewrite the supplied passage so it reads more clearly. Keep every fact, claim, " <>
          "number and name exactly as given, and keep roughly the same length."
    },
    %{
      id: :shorten,
      needs_text?: true,
      needs_instruction?: false,
      goal:
        "Rewrite the supplied passage to be substantially shorter — about half its length — " <>
          "keeping every fact and dropping only padding."
    },
    %{
      id: :expand,
      needs_text?: true,
      needs_instruction?: false,
      goal:
        "Expand the supplied passage with more detail drawn from the passage and the page " <>
          "context. Do not introduce facts, statistics, dates or names that are not present."
    }
  ]

  @ids Enum.map(@actions, & &1.id)

  @doc "Every action, in the order the editor offers them."
  @spec all() :: [t()]
  def all, do: @actions

  @doc "The action ids, in display order."
  @spec ids() :: [id()]
  def ids, do: @ids

  @doc """
  Look an action up by id.

  Accepts the string a LiveView event carries and never mints an atom from it:
  the string is matched against the known ids, so an unrecognized value returns
  `:error` rather than growing the atom table.
  """
  @spec fetch(id() | String.t()) :: {:ok, t()} | :error
  def fetch(id) when is_atom(id) do
    case Enum.find(@actions, &(&1.id == id)) do
      nil -> :error
      action -> {:ok, action}
    end
  end

  def fetch(id) when is_binary(id) do
    case Enum.find(@actions, &(Atom.to_string(&1.id) == id)) do
      nil -> :error
      action -> {:ok, action}
    end
  end

  def fetch(_id), do: :error
end
