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

  defp coerce(fields, params) do
    {data, errors} =
      Enum.reduce(fields, {%{}, %{}}, fn field, {data, errors} ->
        case resolve(field, Map.get(params, field.name)) do
          :skip -> {data, errors}
          {:ok, value} -> {Map.put(data, field.name, value), errors}
          {:error, message} -> {data, Map.put(errors, field.name, message)}
        end
      end)

    if errors == %{}, do: {:ok, data}, else: {:error, errors}
  end

  defp resolve(field, raw) do
    cond do
      blank?(raw) and field.required -> {:error, "is required"}
      blank?(raw) -> :skip
      true -> cast(field, raw)
    end
  end

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  defp cast(%{field_type: type}, value) when type in [:string, :text] do
    {:ok, value |> to_string() |> String.trim()}
  end

  defp cast(%{field_type: :email}, value) do
    str = value |> to_string() |> String.trim()

    if Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, str),
      do: {:ok, str},
      else: {:error, "must be an email address"}
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

  defp cast(%{field_type: :boolean}, value) do
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

  defp cast(%{field_type: :select, options: options}, value) do
    str = value |> to_string() |> String.trim()
    if str in options, do: {:ok, str}, else: {:error, "is not one of the allowed options"}
  end
end
