defmodule KilnCMS.Automation.Validations.ActionConfig do
  @moduledoc """
  Validates a rule's `config` against the `action` that will read it (#944).

  `config` is a free `:map` typed into a JSON textarea, and every reaction read
  it defensively — a missing or misspelled key produced a `Logger.warning` and
  `:ok`. So a rule could be saved, listed as **enabled**, and render green in
  `/editor/automation` while being structurally incapable of doing anything,
  forever, with the only evidence in a server log the admin who typed it is not
  reading.

  Two shapes made that more than theoretical:

    * **`"allow_egress": "true"`** — the *string*. Every other key in that
      textarea (`to`, `subject`, `topic`, `segment_id`) is a string, so this is
      the natural mistake. `:suggest_metadata` requires the JSON boolean and
      correctly fails closed, which means the rule looks configured and emails
      nothing.
    * **A missing `to`** on `:send_email` or on any of the four intelligence
      reactions, all of which deliver by email and nothing else.

  ## Why unknown keys are refused, not ignored

  A typo is the failure this exists to catch, and an ignored key is a typo that
  survives the form. `%{"recipient" => "team@example.com"}` on `:send_email` is
  a rule that will never send, and it reads as configured. Refusing an
  unrecognized key turns that into a message beside the field.

  The cost is that adding a config key to a reaction means adding it here too.
  That is the intended coupling, and it is one-way: `@shapes` is the single
  description of what a reaction accepts, and `KilnCMSWeb.AutomationLive`
  renders its per-action key hint by *reading* `shapes/0` rather than by
  restating it. A hand-maintained list of the same keys beside the field would
  be a doc that drifts from its own enforcement — the shape of the bug this
  validation exists to end.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Social.Account

  # One entry per action kind. `:required` must be present and well-typed;
  # `:optional` must be well-typed when present; anything else is refused.
  #
  # `:email` and `:provider` are deliberately shallow checks. This is a
  # configuration form, not an address verifier — the value of catching
  # "team at example.com" here is that it is caught at all, and a stricter rule
  # would start refusing addresses that work.
  @shapes %{
    send_email: %{
      required: [{"to", :email}],
      optional: [{"subject", :template}, {"body", :template}]
    },
    broadcast: %{required: [], optional: [{"topic", :string}]},
    invalidate_cache: %{required: [], optional: []},
    reindex: %{required: [], optional: []},
    newsletter: %{
      required: [],
      optional: [{"segment_id", :string}, {"subject", :template}]
    },
    social_post: %{
      required: [{"provider", :provider}],
      optional: [{"template", :template}]
    },
    flag_duplicates: %{required: [{"to", :email}], optional: []},
    suggest_tags: %{required: [{"to", :email}], optional: []},
    suggest_links: %{required: [{"to", :email}], optional: []},
    suggest_metadata: %{
      required: [{"to", :email}],
      optional: [{"allow_egress", :boolean}]
    },
    create_task: %{
      required: [],
      # All optional: with none of them the reaction still works — it assigns to
      # the content's author, a week out, with a default note. `assignee_id` is
      # the fallback for content whose author cannot hold a task, which is a
      # thing a team discovers rather than anticipates.
      optional: [
        {"assignee_id", :string},
        {"due_in_days", :day_count},
        {"note", :template}
      ]
    }
  }

  @doc """
  What one action kind accepts: `%{required: [...], optional: [...]}`.

  Public so the admin UI can describe a reaction from the same source that
  enforces it, and so a test can assert every kind in
  `KilnCMS.Automation.Rule.action_kinds/0` has an entry.
  """
  @spec shape(atom()) :: %{required: list(), optional: list()} | nil
  def shape(action), do: Map.get(@shapes, action)

  @doc "The shape table, keyed by action kind."
  @spec shapes() :: map()
  def shapes, do: @shapes

  @impl true
  def validate(changeset, _opts, _context) do
    action = Ash.Changeset.get_attribute(changeset, :action)
    config = Ash.Changeset.get_attribute(changeset, :config) || %{}

    case shape(action) do
      # No action yet, or one with no entry. `action`'s own `one_of` constraint
      # reports the second case; duplicating it here would report it twice.
      nil -> :ok
      shape -> check(shape, config)
    end
  end

  @impl true
  def describe(_opts), do: [message: "is not valid for this action", vars: []]

  defp check(shape, config) when is_map(config) do
    known = Enum.map(shape.required ++ shape.optional, &elem(&1, 0))

    with :ok <- missing(shape.required, config),
         :ok <- unknown(known, config) do
      typed(shape.required ++ shape.optional, config)
    end
  end

  # A non-map `config` can't reach here through the resource (the attribute is
  # `:map`), but a validation that assumes its input is a courtesy to nobody.
  defp check(_shape, _config), do: error("must be a JSON object.")

  defp missing(required, config) do
    case Enum.find(required, fn {key, _type} -> blank?(Map.get(config, key)) end) do
      nil -> :ok
      {key, _type} -> error("is missing `#{key}`, which this action needs to do anything.")
    end
  end

  defp unknown(known, config) do
    case Enum.find(Map.keys(config), &(&1 not in known)) do
      nil ->
        :ok

      key ->
        error(
          "has no `#{key}` for this action. It accepts: #{list(known)}. " <>
            "An unrecognized key is usually a typo, and a rule saved with one " <>
            "looks configured while doing nothing."
        )
    end
  end

  defp typed(fields, config) do
    fields
    |> Enum.reject(fn {key, _type} -> is_nil(Map.get(config, key)) end)
    |> Enum.find_value(:ok, fn {key, type} ->
      value = Map.get(config, key)

      unless well_typed?(type, value) do
        error("`#{key}` #{expectation(type)}, got #{inspect(value)}.")
      end
    end)
  end

  # A JSON boolean, never the string "true". Coercing it here would be the
  # wrong kind of generous: `allow_egress` is the switch that permits an
  # unattended reaction to send page bodies off-site, and "what counts as true"
  # is not a thing to guess at on an egress gate. `RuleWorker` already fails
  # closed on it; this makes the near-miss visible where it was typed.
  defp well_typed?(:boolean, value), do: is_boolean(value)

  # A review window, in days. Bounded here as well as in `RuleWorker` — the
  # worker clamps because it must not trust stored config (a rule may predate
  # this validation, or be seeded), and this refuses because a typo is worth
  # catching where it was typed rather than silently becoming seven.
  defp well_typed?(:day_count, value), do: is_integer(value) and value >= 1 and value <= 365
  defp well_typed?(:string, value), do: is_binary(value) and String.trim(value) != ""
  defp well_typed?(:template, value), do: well_typed?(:string, value)

  defp well_typed?(:email, value) do
    well_typed?(:string, value) and Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/u, value)
  end

  defp well_typed?(:provider, value) do
    well_typed?(:string, value) and Enum.any?(Account.providers(), &(to_string(&1) == value))
  end

  defp expectation(:boolean), do: "must be the JSON boolean true or false (not a string)"
  defp expectation(:day_count), do: "must be a whole number of days between 1 and 365"
  defp expectation(:email), do: "must be an email address"
  defp expectation(:provider), do: "must be one of #{list(Account.providers())}"
  defp expectation(_type), do: "must be a non-empty string"

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp list(values), do: values |> Enum.map_join(", ", &to_string/1)

  defp error(message) do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: :config,
       message: "Action config " <> message
     )}
  end
end
