defmodule KilnCMS.Forms do
  @moduledoc """
  The public-form submission pipeline (admin-defined forms — see
  `KilnCMS.CMS.Form`).

  `submit/3` takes the raw visitor params and runs the whole gauntlet:

    * **honeypot** — the rendered form carries a visually-hidden `website`
      input; bots that fill it get a *fake success* (the submission is
      silently discarded, giving spam software nothing to learn from);
    * **coercion + validation** per `FormField` (required, type coercion to
      JSON-native values, select membership, email shape), unknown keys
      dropped;
    * **storage** as a `FormSubmission` (privacy-first: no IP/user agent);
    * **notification** — when the form has a `notify_email`, an Oban job on
      the `:mail` queue delivers a summary;
    * **webhook** — dispatches the `form.submitted` event with the form slug
      and coerced data.

  Rate limiting happens at the controller (`KilnCMSWeb.RateLimit`, `:form`
  bucket) so the transient IP never reaches this module.
  """

  alias KilnCMS.CMS

  @honeypot_field "website"

  @doc "The honeypot input name rendered into public forms."
  @spec honeypot_field() :: String.t()
  def honeypot_field, do: @honeypot_field

  @doc """
  One active form by slug within `org` (the request's site — epic #336), fields
  included, or nil. `org` defaults to the sole org so any tenant-less caller keeps
  working under the single-org rollout.
  """
  @spec get_active(String.t(), Ash.ToTenant.t() | nil) :: struct() | nil
  def get_active(slug, org \\ KilnCMS.Accounts.default_org_id()) when is_binary(slug) do
    case CMS.get_active_form_by_slug(slug, load: [:fields], authorize?: true, tenant: org) do
      {:ok, form} -> form
      _ -> nil
    end
  end

  @doc """
  Validate and record one submission. Returns:

    * `{:ok, submission}` — stored (and notifications queued);
    * `{:ok, :discarded}` — the honeypot tripped: report success upstream,
      store nothing;
    * `{:error, errors}` — a `%{"field" => "message"}` map for re-rendering.

  `opts`: `:locale` (recorded on the submission).
  """
  @spec submit(struct(), map(), keyword()) ::
          {:ok, struct() | :discarded} | {:error, %{optional(String.t()) => String.t()}}
  def submit(form, params, opts \\ []) when is_map(params) do
    cond do
      not form.active ->
        {:error, %{"form" => "is no longer accepting submissions"}}

      honeypot_tripped?(params) ->
        {:ok, :discarded}

      true ->
        case coerce(fields(form), params) do
          {:ok, data} -> {:ok, record(form, data, opts)}
          {:error, errors} -> {:error, errors}
        end
    end
  end

  defp honeypot_tripped?(params) do
    case Map.get(params, @honeypot_field) do
      value when is_binary(value) -> String.trim(value) != ""
      nil -> false
      _non_string -> true
    end
  end

  defp fields(%{fields: fields}) when is_list(fields), do: fields
  defp fields(form), do: CMS.form_fields_for!(form.id, authorize?: false, tenant: form.org_id)

  defp record(form, data, opts) do
    # Every write here is scoped to the form's own site (epic #336): the
    # submission lands in the form's org, and the webhook dispatch is scoped to it.
    submission =
      CMS.create_form_submission!(
        %{form_id: form.id, data: data, locale: Keyword.get(opts, :locale)},
        authorize?: false,
        tenant: form.org_id
      )

    notify(form, data)
    KilnCMS.Webhooks.dispatch("form.submitted", %{form: form.slug, data: data}, form.org_id)
    submission
  end

  defp notify(%{notify_email: email} = form, data) when is_binary(email) and email != "" do
    # `org_id` scopes the worker's form re-fetch to the form's site (epic #336).
    %{form_id: form.id, org_id: form.org_id, data: data}
    |> KilnCMS.Forms.NotificationWorker.new()
    |> Oban.insert!()
  end

  defp notify(_form, _data), do: :ok

  # --- coercion ---------------------------------------------------------------

  # Fields are folded in display order, so a field's conditions see exactly
  # the (coerced) values of the fields above it — the same subset the builder
  # lets rules reference. An invisible field is skipped wholesale: `required`
  # doesn't apply and any submitted value is discarded (no smuggling data
  # through fields the visitor never saw).
  defp coerce(fields, params) do
    {data, errors} = Enum.reduce(fields, {%{}, %{}}, &coerce_field(&1, &2, params))

    if errors == %{}, do: {:ok, data}, else: {:error, errors}
  end

  defp coerce_field(field, {data, errors}, params) do
    if visible?(field, data) do
      case resolve(field, Map.get(params, field.name)) do
        :skip -> {data, errors}
        {:ok, value} -> {Map.put(data, field.name, value), errors}
        {:error, message} -> {data, Map.put(errors, field.name, message)}
      end
    else
      {data, errors}
    end
  end

  @doc """
  Whether a field is visible given the (coerced) values submitted so far —
  the server-side twin of `form-conditions.js`. Empty conditions and
  incomplete rules (blank field name, unknown operator) evaluate as visible:
  a half-built rule must never hide data collection.
  """
  @spec visible?(struct() | map(), map()) :: boolean()
  def visible?(%{conditions: %{"rules" => rules} = conditions}, data) when is_list(rules) do
    results = Enum.map(rules, &rule_matches?(&1, data))

    case conditions["logic"] do
      "any" -> results == [] or Enum.any?(results)
      _all -> Enum.all?(results)
    end
  end

  def visible?(_field, _data), do: true

  defp rule_matches?(%{"field" => name} = rule, data) when is_binary(name) and name != "" do
    matches?(rule["operator"] || "eq", Map.get(data, name), rule["value"])
  end

  defp rule_matches?(_incomplete, _data), do: true

  # Checkbox (list) answers: eq/contains mean membership, neq means absence.
  defp matches?("eq", value, target) when is_list(value), do: to_string(target) in value
  defp matches?("eq", value, target), do: to_string(value) == to_string(target)
  defp matches?("neq", value, target), do: not matches?("eq", value, target)

  defp matches?("contains", value, target) when is_list(value), do: to_string(target) in value

  defp matches?("contains", value, target),
    do: String.contains?(to_string(value), to_string(target))

  defp matches?("empty", value, _target), do: value in [nil, "", []]
  defp matches?("not_empty", value, _target), do: value not in [nil, "", []]

  defp matches?("gt", value, target), do: numeric(value, target, &Kernel.>/2)
  defp matches?("lt", value, target), do: numeric(value, target, &Kernel.</2)

  # Unknown operator (newer schema than this node?) — never hide the field.
  defp matches?(_operator, _value, _target), do: true

  defp numeric(value, target, compare) do
    with {:ok, left} <- to_number(value),
         {:ok, right} <- to_number(target) do
      compare.(left, right)
    else
      _not_numeric -> false
    end
  end

  defp to_number(value) when is_number(value), do: {:ok, value}

  defp to_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {n, ""} -> {:ok, n}
      _invalid -> :error
    end
  end

  defp to_number(_other), do: :error

  defp resolve(%{field_type: type}, _raw) when type in [:heading, :divider, :page_break],
    do: :skip

  # A required consent isn't satisfied by any value — only by true (the
  # rendered checkbox posts "false" via its hidden twin when unchecked).
  defp resolve(%{field_type: :consent} = field, raw) do
    case {field.required, cast(field, raw)} do
      {true, {:ok, true}} -> {:ok, true}
      {true, _not_accepted} -> {:error, "must be accepted"}
      {false, _any} -> if blank?(raw), do: :skip, else: cast(field, raw)
    end
  end

  defp resolve(field, raw) do
    cond do
      blank?(raw) and field.required -> {:error, "is required"}
      blank?(raw) -> :skip
      true -> validated_cast(field, raw)
    end
  end

  defp blank?([]), do: true
  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  defp validated_cast(field, raw) do
    with {:ok, value} <- cast(field, raw),
         :ok <- apply_rules(field, value) do
      {:ok, value}
    end
  end

  defp cast(%{field_type: type}, value) when type in [:string, :text, :hidden] do
    {:ok, value |> to_string() |> String.trim()}
  end

  defp cast(%{field_type: :email}, value) do
    str = value |> to_string() |> String.trim()

    if Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, str),
      do: {:ok, str},
      else: {:error, "must be an email address"}
  end

  defp cast(%{field_type: :phone}, value) do
    str = value |> to_string() |> String.trim()
    digits = String.replace(str, ~r/[\s().\-]/, "")

    if Regex.match?(~r/\A\+?\d{5,20}\z/, digits),
      do: {:ok, str},
      else: {:error, "must be a phone number"}
  end

  defp cast(%{field_type: :url}, value) do
    str = value |> to_string() |> String.trim()

    case URI.new(str) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, str}

      _invalid ->
        {:error, "must be a web address (https://…)"}
    end
  end

  defp cast(%{field_type: :integer}, value) do
    case value do
      v when is_integer(v) ->
        {:ok, v}

      v ->
        case Integer.parse(to_string(v)) do
          {n, ""} -> {:ok, n}
          _ -> {:error, "must be a whole number"}
        end
    end
  end

  defp cast(%{field_type: :number}, value) do
    case value do
      v when is_number(v) ->
        {:ok, v}

      v ->
        case Float.parse(to_string(v)) do
          {n, ""} -> {:ok, n}
          _ -> {:error, "must be a number"}
        end
    end
  end

  defp cast(%{field_type: :rating}, value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n in 1..5 -> {:ok, n}
      _ -> {:error, "must be a rating from 1 to 5"}
    end
  end

  defp cast(%{field_type: type}, value) when type in [:boolean, :consent] do
    case value do
      v when is_boolean(v) -> {:ok, v}
      v when v in ["true", "1", "on"] -> {:ok, true}
      v when v in ["false", "0", "off"] -> {:ok, false}
      _ -> {:error, "must be a boolean"}
    end
  end

  defp cast(%{field_type: :date}, value) do
    case Date.from_iso8601(to_string(value)) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> {:error, "must be a date (YYYY-MM-DD)"}
    end
  end

  defp cast(%{field_type: type, options: options}, value) when type in [:select, :radio] do
    str = value |> to_string() |> String.trim()
    if str in options, do: {:ok, str}, else: {:error, "is not one of the allowed options"}
  end

  # Multi-choice: the browser posts `name[]` inputs as a list (a lone string
  # still counts as one choice). Every picked value must be a listed option.
  defp cast(%{field_type: :checkboxes, options: options}, value) do
    picked = value |> List.wrap() |> Enum.map(&(&1 |> to_string() |> String.trim()))

    if Enum.all?(picked, &(&1 in options)),
      do: {:ok, picked},
      else: {:error, "includes a value that is not one of the allowed options"}
  end

  # --- validation rules ---------------------------------------------------------

  # `field.validation` rules, enforced after a successful cast. Write-time
  # checking (Validations.FieldRules) keeps the map trustworthy; anything
  # malformed that slips through is skipped rather than blocking visitors.
  defp apply_rules(%{validation: rules}, value) when is_map(rules) and rules != %{} do
    message = rules["message"]

    Enum.find_value(rules, :ok, fn rule ->
      case broken_rule(rule, value) do
        nil -> nil
        default_message -> {:error, message || default_message}
      end
    end)
  end

  defp apply_rules(_field, _value), do: :ok

  defp broken_rule({"min_length", min}, value) when is_integer(min) and is_binary(value) do
    if String.length(value) < min, do: "must be at least #{min} characters"
  end

  defp broken_rule({"max_length", max}, value) when is_integer(max) and is_binary(value) do
    if String.length(value) > max, do: "must be at most #{max} characters"
  end

  defp broken_rule({"min", min}, value) when is_number(min) and is_number(value) do
    if value < min, do: "must be at least #{min}"
  end

  defp broken_rule({"max", max}, value) when is_number(max) and is_number(value) do
    if value > max, do: "must be at most #{max}"
  end

  defp broken_rule({"pattern", pattern}, value) when is_binary(pattern) and is_binary(value) do
    case Regex.compile("\\A(?:#{pattern})\\z") do
      {:ok, regex} -> if !safe_match?(regex, value), do: "is not in the expected format"
      _invalid -> nil
    end
  end

  defp broken_rule(_rule, _value), do: nil

  # Admin-authored pattern vs visitor-supplied value: bound the match so a
  # pathological combination can't stall the request (ReDoS). On timeout the
  # value is rejected — fail closed, the pattern exists to constrain input.
  defp safe_match?(regex, value) do
    task = Task.async(fn -> Regex.match?(regex, value) end)

    case Task.yield(task, 100) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timeout -> false
    end
  end
end
