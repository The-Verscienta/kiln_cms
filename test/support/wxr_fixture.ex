defmodule KilnCMS.WXRFixture do
  @moduledoc """
  A WordPress WXR export in the shape a real one has (#487) — namespaces,
  `content:encoded` with classic un-wrapped paragraphs, both taxonomies on one
  `<category>` element name, an attachment referenced by `_thumbnail_id`, and a
  `0000-00-00` date on the draft.
  """

  @doc "A small but structurally faithful WXR document."
  @spec wxr(keyword()) :: String.t()
  def wxr(opts \\ []) do
    image_url = Keyword.get(opts, :image_url, "https://old.example.com/wp-content/pic.jpg")

    """
    <?xml version="1.0" encoding="UTF-8" ?>
    <rss version="2.0"
      xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
      xmlns:content="http://purl.org/rss/1.0/modules/content/"
      xmlns:wfw="http://wellformedweb.org/CommentAPI/"
      xmlns:dc="http://purl.org/dc/elements/1.1/"
      xmlns:wp="http://wordpress.org/export/1.2/">
    <channel>
      <title>Old Blog</title>
      <link>https://old.example.com</link>
      <wp:author>
        <wp:author_login><![CDATA[jo]]></wp:author_login>
        <wp:author_email><![CDATA[jo@old.example.com]]></wp:author_email>
        <wp:author_display_name><![CDATA[Jo Example]]></wp:author_display_name>
      </wp:author>

      <item>
        <title><![CDATA[Hello World]]></title>
        <link>https://old.example.com/2024/03/hello-world/</link>
        <dc:creator><![CDATA[jo]]></dc:creator>
        <content:encoded><![CDATA[First paragraph with <strong>bold</strong>.

    Second paragraph.

    <img src="#{image_url}" alt="A picture" />]]></content:encoded>
        <excerpt:encoded><![CDATA[A short summary.]]></excerpt:encoded>
        <wp:post_id>11</wp:post_id>
        <wp:post_date><![CDATA[2024-03-01 09:15:00]]></wp:post_date>
        <wp:post_date_gmt><![CDATA[2024-03-01 09:15:00]]></wp:post_date_gmt>
        <wp:post_name><![CDATA[hello-world]]></wp:post_name>
        <wp:status><![CDATA[publish]]></wp:status>
        <wp:post_type><![CDATA[post]]></wp:post_type>
        <category domain="category" nicename="news"><![CDATA[News]]></category>
        <category domain="post_tag" nicename="how-to"><![CDATA[How To]]></category>
        <category domain="post_tag" nicename="beginner"><![CDATA[Beginner]]></category>
        <wp:postmeta>
          <wp:meta_key><![CDATA[_thumbnail_id]]></wp:meta_key>
          <wp:meta_value><![CDATA[99]]></wp:meta_value>
        </wp:postmeta>
      </item>

      <item>
        <title><![CDATA[About Us]]></title>
        <link>https://old.example.com/about/</link>
        <content:encoded><![CDATA[<p>We are a company.</p>]]></content:encoded>
        <wp:post_id>12</wp:post_id>
        <wp:post_date><![CDATA[0000-00-00 00:00:00]]></wp:post_date>
        <wp:post_date_gmt><![CDATA[0000-00-00 00:00:00]]></wp:post_date_gmt>
        <wp:post_name><![CDATA[about]]></wp:post_name>
        <wp:status><![CDATA[draft]]></wp:status>
        <wp:post_type><![CDATA[page]]></wp:post_type>
      </item>

      <item>
        <title><![CDATA[Scheduled Later]]></title>
        <link>https://old.example.com/2030/soon/</link>
        <content:encoded><![CDATA[Not yet.]]></content:encoded>
        <wp:post_id>13</wp:post_id>
        <wp:post_date_gmt><![CDATA[2030-01-01 00:00:00]]></wp:post_date_gmt>
        <wp:post_name><![CDATA[soon]]></wp:post_name>
        <wp:status><![CDATA[future]]></wp:status>
        <wp:post_type><![CDATA[post]]></wp:post_type>
      </item>

      <item>
        <title><![CDATA[pic.jpg]]></title>
        <wp:post_id>99</wp:post_id>
        <wp:post_type><![CDATA[attachment]]></wp:post_type>
        <wp:attachment_url><![CDATA[#{image_url}]]></wp:attachment_url>
        <wp:postmeta>
          <wp:meta_key><![CDATA[_wp_attachment_image_alt]]></wp:meta_key>
          <wp:meta_value><![CDATA[Alt from the library]]></wp:meta_value>
        </wp:postmeta>
      </item>

      <item>
        <title><![CDATA[Main menu]]></title>
        <wp:post_id>14</wp:post_id>
        <wp:post_type><![CDATA[nav_menu_item]]></wp:post_type>
      </item>
    </channel>
    </rss>
    """
  end
end
