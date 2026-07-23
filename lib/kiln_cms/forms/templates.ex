defmodule KilnCMS.Forms.Templates do
  @moduledoc """
  Built-in form templates for the "start from a template" create flow
  (`/editor/forms`, phase 3 of `docs/form-builder-plan.md`).

  Each template is a JSON file in `priv/form_templates/` — form settings
  (success message, submit label) plus an ordered field list in `FormField`
  attribute shape. Files are embedded at compile time (`@external_resource`),
  so a release needs no runtime file access and a malformed template breaks
  the build, not the create flow. A plugin seam for contributed templates is
  deliberately deferred.
  """

  alias KilnCMS.CMS

  templates_glob =
    [__DIR__, "..", "..", "..", "priv", "form_templates", "*.json"]
    |> Path.join()
    |> Path.expand()

  @paths templates_glob |> Path.wildcard() |> Enum.sort()

  for path <- @paths do
    @external_resource path
  end

  @templates Enum.map(@paths, fn path ->
               data = path |> File.read!() |> Jason.decode!()

               %{
                 key: Path.basename(path, ".json"),
                 name: Map.fetch!(data, "name"),
                 description: Map.get(data, "description", ""),
                 form: Map.get(data, "form", %{}),
                 fields: Map.get(data, "fields", [])
               }
             end)

  @doc "All built-in templates, sorted by file name."
  @spec list() :: [map()]
  def list, do: @templates

  @doc "One template by its key (the JSON file's base name), or nil."
  @spec get(String.t()) :: map() | nil
  def get(key), do: Enum.find(@templates, &(&1.key == key))

  @doc """
  Create a form (with the caller's `name` + `slug`) and all of the template's
  fields, atomically — a failed field rolls the form back too. `opts` are the
  usual `actor:`/`tenant:` options.
  """
  @spec instantiate(map(), String.t(), String.t(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def instantiate(template, name, slug, opts) do
    form_params = Map.merge(template.form, %{"name" => name, "slug" => slug})

    KilnCMS.Repo.transaction(fn ->
      with {:ok, form} <- CMS.create_form(form_params, opts),
           :ok <- create_fields(template.fields, form.id, opts) do
        form
      else
        {:error, error} -> KilnCMS.Repo.rollback(error)
      end
    end)
  end

  defp create_fields(fields, form_id, opts) do
    fields
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {field, position}, :ok ->
      params = Map.merge(field, %{"form_id" => form_id, "position" => position})

      case CMS.create_form_field(params, opts) do
        {:ok, _field} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
