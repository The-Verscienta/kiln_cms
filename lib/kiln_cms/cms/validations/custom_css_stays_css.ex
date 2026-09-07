defmodule KilnCMS.CMS.Validations.CustomCssStaysCss do
  @moduledoc """
  Keeps `SiteCodeInjection.custom_css` inside the `<style>` element the layout
  emits it into (#1318).

  This is deliberately NOT a CSS sanitizer. The resource is stored XSS on
  purpose (see its moduledoc), and an org admin can already emit arbitrary
  markup through `head_html` — filtering the *stylesheet* field would remove
  nothing they don't hold elsewhere. What it must not do is silently change
  category: the layout wraps this value in `<style>…</style>`, and a value
  containing `</style` would close that element and continue as markup, turning
  a field labeled "CSS" into a second HTML field. Refusing the sequence keeps
  the label honest and keeps the emission site's reasoning local.

  The check is the tokenizer's, not a parser's: a browser ends style raw text
  at the first case-insensitive `</style` regardless of quoting or comments, so
  that exact sequence is what is refused — including inside what CSS would
  consider a string or a `/* comment */`, because the HTML tokenizer does not
  consider anything.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :custom_css) do
      value when value in [nil, ""] ->
        :ok

      value when is_binary(value) ->
        if String.contains?(String.downcase(value), "</style") do
          {:error,
           InvalidAttribute.exception(
             field: :custom_css,
             message: "must not contain \"</style\" — markup belongs in the head HTML field"
           )}
        else
          :ok
        end

      _other ->
        :ok
    end
  end
end
