defmodule KilnCMS.Blocks.NewsletterSignup do
  @moduledoc """
  A newsletter sign-up form placed in content (#1870).

  The newsletter already had a public `POST /newsletter/subscribe` (#586), but
  nothing an editor could put on a page posted to it: the rich-text sanitizer
  strips a raw `<form>`, and the `form` block embeds a form built under
  `/editor/forms`, whose submissions land in the forms inbox, not the
  subscriber list. So a sign-up box on the home page took a theme edit.

  The block carries only presentation — a heading, an intro line, the button
  label and whether to ask for a name. The subscribe semantics stay where they
  are: double opt-in, the same "check your inbox" page for every outcome, and
  the shared honeypot (`KilnCMS.Forms.honeypot_field/0`) that `subscribe/2`
  already checks. A subscriber joins the site that serves the page, because the
  endpoint resolves the tenant from the request.

  Unlike `form`, the fired `:web` artifact is the real form rather than a
  placeholder: there is no per-form schema to fetch, and the endpoint is
  CSRF-free (`:public_form`) precisely so a fired artifact can host it. Its
  `action` is relative, so a frontend on another origin points it at its Kiln
  host — the `:json` surface carries `action` and `honeypot_field` for that.
  """
  use Kiln.Block
  use Gettext, backend: KilnCMSWeb.Gettext

  @action "/newsletter/subscribe"

  block :newsletter_signup do
    field :heading, :string, description: "Shown above the form, e.g. \"Get release notes\"."
    field :intro, :string, description: "One line on what subscribers receive and how often."
    field :button_label, :string, description: "Defaults to \"Subscribe\"."
    field :collect_name, :boolean, default: false, description: "Also ask for a name."
  end

  @doc "Where the form posts: the site's own sign-up endpoint."
  @spec action() :: String.t()
  def action, do: @action

  @doc "The submit button's text — the editor's label, or the default."
  @spec button_label(map()) :: String.t()
  def button_label(block) do
    case trimmed(block.button_label) do
      nil -> gettext("Subscribe")
      label -> label
    end
  end

  # Match plain variables, never `%__MODULE__{}` — the struct is built at
  # @before_compile, so matching it breaks clean compiles (see divider.ex).
  @impl Kiln.Block.Renderer
  def render(block, :web) do
    [
      ~s(<form class="kiln-newsletter-signup" method="post" action="),
      @action,
      ~s(">),
      optional("h2", block.heading),
      optional("p", block.intro),
      name_input(block),
      ~s(<label>),
      esc(gettext("Email")),
      ~s( <input type="email" name="email" required autocomplete="email"/></label>),
      # Hidden from people, filled by bots; `subscribe/2` answers a filled one
      # with the same page and stores nothing.
      ~s(<div style="position:absolute;left:-9999px" aria-hidden="true"><label>),
      esc(gettext("Leave this field empty")),
      ~s( <input type="text" name="),
      KilnCMS.Forms.honeypot_field(),
      ~s(" tabindex="-1" autocomplete="off"/></label></div>),
      ~s(<button type="submit">),
      esc(button_label(block)),
      ~s(</button></form>)
    ]
  end

  def render(block, :json),
    do: %{
      "_type" => "newsletter_signup",
      "heading" => trimmed(block.heading),
      "intro" => trimmed(block.intro),
      "button_label" => button_label(block),
      "collect_name" => block.collect_name == true,
      "action" => @action,
      "honeypot_field" => KilnCMS.Forms.honeypot_field()
    }

  # A sign-up box says nothing about the page's subject.
  def render(_block, _surface), do: nil

  # `button_label` is always a string on delivery (the default fills it), and
  # `action`/`honeypot_field` are what a headless frontend needs to post.
  @impl Kiln.Block.Renderer
  def json_schema do
    %{
      "properties" => %{
        "button_label" => %{"type" => "string"},
        "collect_name" => %{"type" => "boolean", "default" => false},
        "action" => %{
          "type" => "string",
          "format" => "uri-reference",
          "description" => "Where to POST `email` (and `name`), relative to the Kiln host."
        },
        "honeypot_field" => %{
          "type" => "string",
          "description" => "An input to render hidden and leave empty; a filled one is dropped."
        }
      }
    }
  end

  @impl Kiln.Block.Renderer
  def search_text(block) do
    [block.heading, block.intro]
    |> Enum.map(&trimmed/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp name_input(block) do
    if block.collect_name == true do
      [
        ~s(<label>),
        esc(gettext("Name")),
        ~s( <input type="text" name="name" autocomplete="name"/></label>)
      ]
    else
      []
    end
  end

  defp optional(tag, text) do
    case trimmed(text) do
      nil -> []
      text -> ["<", tag, ">", esc(text), "</", tag, ">"]
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
