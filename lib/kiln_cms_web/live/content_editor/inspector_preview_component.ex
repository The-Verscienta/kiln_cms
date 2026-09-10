defmodule KilnCMSWeb.ContentEditor.InspectorPreviewComponent do
  @moduledoc """
  The inspector rail's Preview panel (#1311): the in-editor live preview,
  rendered through the same typed serializers as firing. Markup moved verbatim
  from `KilnCMSWeb.ContentEditorLive.render/1`; the panel stays mounted and is
  toggled by CSS only (never `:if`), so switching tabs costs no re-render of
  the form.
  """

  use KilnCMSWeb, :live_component

  import KilnCMSWeb.ContentEditor.InspectorComponents, only: [preview_article: 1]

  @impl true
  def render(assigns) do
    ~H"""
    <div class={[@inspector_tab != :preview && "hidden"]}>
      <p class="mb-2 flex items-center gap-1.5 text-xs text-base-content/50">
        <.icon name="hero-cursor-arrow-rays" class="size-3.5" />
        {gettext("Hover a block and click Edit to change it on the page.")}
      </p>
      <.preview_article
        form={@form}
        html={@preview_html}
        kind={@kind}
        slug={@record.slug}
      />
    </div>
    """
  end
end
