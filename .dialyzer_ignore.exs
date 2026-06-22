# Dialyzer warnings to ignore. Keep this list tight — only third-party /
# version-specific noise, never our own code.
[
  # ash_authentication_phoenix's controller typespecs reference
  # `Ash.Resource.record/0`, which Dialyzer can't resolve on some newer
  # OTP/Elixir combinations (seen on OTP 29 / Elixir 1.20). Third-party, benign.
  {"ash_authentication_phoenix/controller.ex", :unknown_type},
  ~r/Unknown type: Ash\.Resource\.record/
]
