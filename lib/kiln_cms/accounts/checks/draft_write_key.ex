defmodule KilnCMS.Accounts.Checks.DraftWriteKey do
  @moduledoc """
  The policy checks behind the `:draft_write` API-key scope (#2273).

  A `:draft_write` key is for a headless consumer's *service* — an app that
  submits content for human review. It may create drafts and edit its own
  drafts, and nothing else. It is deliberately NOT a variant of
  `KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess`, which stays untouched and
  keeps failing closed for every key whose access is not `:read_write`: a
  `:draft_write` key matches it, so every resource that forbids on it refuses
  this key. Only `Content` carves the key back in, through this module.

  One module, three `:mode`s, so the allowlist lives in one place:

    * `:any` — the actor authenticated with a `:draft_write` key.
    * `:outside_allowlist` — such an actor attempting anything the allowlist
      does not name. `Content` `forbid_if`s this ABOVE the admin bypass, so it
      holds whatever the key owner's role is *now* (the mint-time owner check is
      defense in depth, not the control).
    * `:within_allowlist` — such an actor attempting something the allowlist
      does name. The positive grant inside the `EditableContentType` write
      policy, which a viewer-tier owner would otherwise fail.

  ## The allowlist

    * `:create` — any. The new row is a draft (the state machine's only initial
      state) authored by the actor (`relate_actor`).
    * `:update` and `:autosave` — only a row that is still a `:draft` AND whose
      `author_id` is the key owner. A live document (`:published`, which also
      covers "Live · draft", a published row with a working copy) is refused, as
      is anyone else's draft.

  Everything else is refused, including `:submit_for_review` — a deliberate
  default-deny, so a service cannot move work into the review queue on its own;
  a human does that. The list is closed: an action added to `Content` later is
  forbidden to this key until someone adds it here.
  """
  use Ash.Policy.SimpleCheck

  @create_actions [:create]
  @draft_edit_actions [:update, :autosave]

  @doc "Actions a `:draft_write` key may run on `Content` (for tests and docs)."
  def allowed_actions, do: @create_actions ++ @draft_edit_actions

  @impl Ash.Policy.Check
  def describe(opts) do
    case Keyword.get(opts, :mode, :any) do
      :any -> "using a draft-write API key"
      :outside_allowlist -> "using a draft-write API key for anything but drafting"
      :within_allowlist -> "using a draft-write API key to draft"
    end
  end

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, opts) do
    case {draft_write?(actor), Keyword.get(opts, :mode, :any)} do
      {false, _} -> false
      {true, :any} -> true
      {true, :within_allowlist} -> allowed?(actor, context)
      {true, :outside_allowlist} -> not allowed?(actor, context)
    end
  end

  @doc false
  def draft_write?(%{__metadata__: %{using_api_key?: true} = metadata}) do
    match?(%KilnCMS.Accounts.ApiKey{access: :draft_write}, metadata[:api_key])
  end

  def draft_write?(_actor), do: false

  defp allowed?(_actor, %{subject: %Ash.Changeset{action: %{name: name, type: :create}}})
       when name in @create_actions,
       do: true

  defp allowed?(actor, %{
         subject: %Ash.Changeset{action: %{name: name, type: :update}, data: data} = subject
       })
       when name in @draft_edit_actions do
    tool_probe?(subject) or
      (Map.get(data, :state) == :draft and not is_nil(actor.id) and
         Map.get(data, :author_id) == actor.id)
  end

  defp allowed?(_actor, _context), do: false

  # AshAi's tool-listing probe ("may this actor run this action at all?") asks
  # `Ash.can?/3` about a BLANK record, which no row condition can satisfy, so
  # `update_*` would never be offered to this key. The probe runs no action; the
  # real call carries a loaded row and is judged on it. Only AshAi sets this
  # private context key, and a client cannot write `private`.
  defp tool_probe?(%Ash.Changeset{context: %{private: %{ash_ai_pre_check?: true}}}), do: true
  defp tool_probe?(_changeset), do: false
end
