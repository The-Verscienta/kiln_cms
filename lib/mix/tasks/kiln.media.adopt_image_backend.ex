defmodule Mix.Tasks.Kiln.Media.AdoptImageBackend do
  @shortdoc "Hand the image backend the imported rows whose images it already holds (#1955)"

  @moduledoc """
  Adopts media rows imported by URL into the active image backend
  (`Kiln.ImageBackend`), so Kiln can derive, rotate, transform and delete
  them like any upload — see `KilnCMS.Media.Adoption`.

      mix kiln.media.adopt_image_backend --dry-run    # count, write nothing
      mix kiln.media.adopt_image_backend
      mix kiln.media.adopt_image_backend --org <uuid>

  A release has no Mix: there, run `KilnCMS.Release.adopt_image_backend/1`
  through `bin/kiln_cms rpc`.

  Needs a backend selected (`config :kiln_cms, :image_backend`) and
  configured. Only rows with no stored file are considered, and only those
  whose URL the backend recognises as its own. Each adopted row gets a
  variant job on the `:media` queue, which reads its dimensions back from the
  backend; this task returns once they are enqueued.
  """

  use Mix.Task

  alias KilnCMS.Media.Adoption

  @switches [dry_run: :boolean, org: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    org_id = opts[:org] || KilnCMS.Accounts.default_org_id()
    dry_run? = opts[:dry_run] == true

    case Adoption.run(org_id, dry_run?: dry_run?) do
      {:ok, report} -> Mix.shell().info(Adoption.describe(report, org_id, dry_run?))
      {:error, :no_active_backend} -> Mix.raise(Adoption.no_active_backend_message())
    end
  end
end
