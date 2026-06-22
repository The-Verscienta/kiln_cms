# Dialyzer warnings to ignore. Keep this list tight — only third-party /
# version-specific noise, never bugs in our own logic.
[
  # ash_authentication_phoenix's controller typespecs reference
  # `Ash.Resource.record/0`, which Dialyzer can't resolve on some newer
  # OTP/Elixir combinations (seen on OTP 29 / Elixir 1.20). Third-party, benign.
  {"ash_authentication_phoenix/controller.ex", :unknown_type},
  ~r/Unknown type: Ash\.Resource\.record/,

  # `KilnCMS.HTMLSanitizer.RichText` uses HtmlSanitizeEx's scrubber DSL, which
  # macro-generates `scrub/1`, `scrub_attribute/2`, `before_scrub/1` and the
  # `HtmlSanitizeEx.Scrubber` behaviour. Dialyzer can't see macro-generated
  # functions, so it reports them missing. They exist at runtime (exercised by
  # the test suite and public delivery) — false positives, not our bug.
  {"lib/kiln_cms/html_sanitizer/rich_text.ex", :unknown_function},
  {"lib/kiln_cms/html_sanitizer/rich_text.ex", :callback_info_missing},

  # `KilnCMSWeb.RateLimit` uses Hammer's `use Hammer` macro, which generates the
  # ETS backend calls (`Hammer.ETS.FixWindow.*`, `Hammer.ETS.start_link/1`) and
  # the `Hammer` behaviour. Same macro-visibility limitation as above; rate
  # limiting works at runtime.
  {"lib/kiln_cms_web/rate_limit.ex", :unknown_function},
  {"lib/kiln_cms_web/rate_limit.ex", :callback_info_missing}
]
