defmodule KilnCMS.Backups.Lock.Actions.Request do
  @moduledoc """
  `KilnCMS.Backups.Lock`'s `:request` action (#2218): start a backup, queue it
  behind the running chain, or fold it into the queued one
  (`KilnCMS.Backups.Chain.request/1`).

  The policy has decided who may ask by the time this runs; the lock itself is
  written as `KilnCMS.Backups.system/0`, never as the caller. A person's id is
  kept on a queued request (`waiting_requested_by`).

  `components` (#2219) narrows a fresh backup to the database or the media.
  Refused (`KilnCMS.Backups.Refused`) when it repeats a component
  (`:invalid_components`), comes with `resume` (`:components_with_resume`: a
  resume backs up what its run did), or names `:media` on a deployment with no
  media directory (`:no_media_dir`).
  """
  use Ash.Resource.Actions.Implementation

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, Refused, WorkState}

  @impl true
  def run(input, _opts, context) do
    resume = Ash.ActionInput.get_argument(input, :resume)
    components = Ash.ActionInput.get_argument(input, :components)

    with :ok <- check_resume(resume),
         :ok <- check_components(components, resume) do
      attrs = %{
        trigger: Ash.ActionInput.get_argument(input, :trigger),
        resume: resume,
        components: components,
        requested_by: requested_by(context.actor)
      }

      case Chain.request(attrs) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> refused(reason)
      end
    end
  end

  defp check_resume(nil), do: :ok

  defp check_resume(resume),
    do: if(WorkState.valid_stamp?(resume), do: :ok, else: refused(:invalid_stamp))

  defp check_components(nil, _resume), do: :ok

  defp check_components(_components, resume) when resume != nil,
    do: refused(:components_with_resume)

  defp check_components(components, _resume) do
    cond do
      components == [] or Enum.uniq(components) != components -> refused(:invalid_components)
      :media in components and is_nil(Backups.media_dir()) -> refused(:no_media_dir)
      true -> :ok
    end
  end

  defp refused(reason), do: {:error, Refused.exception(reason: reason)}

  defp requested_by(%KilnCMS.Accounts.User{id: id}), do: id
  defp requested_by(_actor), do: nil
end
