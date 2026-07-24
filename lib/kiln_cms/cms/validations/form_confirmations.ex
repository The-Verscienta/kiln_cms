defmodule KilnCMS.CMS.Validations.FormConfirmations do
  @moduledoc """
  Write-time checks for a `Form`'s phase-6 settings so the submission
  pipeline can trust them:

    * `notify_email` — one or more comma-separated addresses;
    * `redirect_url` — required for a `:redirect` confirmation, and either a
      site-relative path (`/thanks`) or an absolute http(s) URL;
    * `notify_conditions` — the shared conditions shape;
    * `confirmation_variants` — a list of `%{"message", "conditions"}` maps,
      each conditions map well-shaped. An empty message is allowed (a
      half-built builder row) — the pipeline skips such variants.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.Validations.ConditionsShape

  @email ~r/\A[^\s@]+@[^\s@]+\z/

  @impl true
  def validate(changeset, _opts, _context) do
    Enum.find_value(
      [
        check_notify_email(Ash.Changeset.get_attribute(changeset, :notify_email)),
        check_redirect(
          Ash.Changeset.get_attribute(changeset, :confirmation_type),
          Ash.Changeset.get_attribute(changeset, :redirect_url)
        ),
        check_conditions(
          :notify_conditions,
          Ash.Changeset.get_attribute(changeset, :notify_conditions)
        ),
        check_variants(Ash.Changeset.get_attribute(changeset, :confirmation_variants))
      ],
      :ok,
      fn
        :ok ->
          nil

        {:error, field, message} ->
          {:error, InvalidAttribute.exception(field: field, message: message)}
      end
    )
  end

  defp check_notify_email(nil), do: :ok
  defp check_notify_email(""), do: :ok

  defp check_notify_email(value) do
    addresses = value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    if addresses != [] and Enum.all?(addresses, &Regex.match?(@email, &1)),
      do: :ok,
      else: {:error, :notify_email, "must be one or more email addresses, comma-separated"}
  end

  # A same-site path (`/thanks`, but NOT a protocol-relative `//host` — Phoenix
  # rejects those in `redirect(to:)`, 500ing every submission) or an absolute
  # http(s) URL.
  defp check_redirect(:redirect, url) do
    if is_binary(url) and Regex.match?(~r{\A(/(?!/)|https?://)}, url),
      do: :ok,
      else:
        {:error, :redirect_url, "a redirect confirmation needs a path (/thanks) or https:// URL"}
  end

  defp check_redirect(_type, _url), do: :ok

  defp check_conditions(field, conditions) do
    case ConditionsShape.check(conditions || %{}) do
      :ok -> :ok
      {:error, message} -> {:error, field, message}
    end
  end

  defp check_variants(nil), do: :ok

  defp check_variants(variants) when is_list(variants),
    do: Enum.find_value(variants, :ok, &broken_variant/1)

  defp check_variants(_other), do: {:error, :confirmation_variants, "must be a list"}

  defp broken_variant(%{} = variant) do
    cond do
      Map.keys(variant) -- ["message", "conditions"] != [] ->
        {:error, :confirmation_variants, "a variant allows only \"message\" and \"conditions\""}

      not is_binary(variant["message"] || "") ->
        {:error, :confirmation_variants, "a variant's message must be text"}

      true ->
        variant_conditions_error(variant)
    end
  end

  defp broken_variant(_not_a_map),
    do: {:error, :confirmation_variants, "each variant must be a map"}

  defp variant_conditions_error(variant) do
    case ConditionsShape.check(variant["conditions"] || %{}) do
      :ok -> nil
      {:error, message} -> {:error, :confirmation_variants, message}
    end
  end
end
