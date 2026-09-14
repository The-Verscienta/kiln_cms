import Config

# A fragment of config/runtime.exs, evaluated by it inside its
# `config_env() == :prod` guard — nothing here applies in dev or test. It sits
# at the position this block always occupied; evaluation ORDER matters, see the
# header of config/runtime.exs before moving anything.

# ## Object storage (S3-compatible)
#
# Opt into the S3 adapter by setting S3_BUCKET. Works with AWS S3, Cloudflare
# R2, Backblaze B2, Wasabi, MinIO, etc. For any non-AWS provider, also set
# S3_ENDPOINT_HOST (see KilnCMS.Storage.S3 docs for per-provider hosts).
if bucket = System.get_env("S3_BUCKET") do
  config :kiln_cms, KilnCMS.Storage, adapter: KilnCMS.Storage.S3

  s3_opts =
    [
      bucket: bucket,
      public_base_url:
        System.get_env("S3_PUBLIC_BASE_URL") ||
          raise("S3_BUCKET is set but S3_PUBLIC_BASE_URL is missing")
    ]

  # Most buckets are made public at the bucket level; only send a per-object
  # canned ACL (e.g. "public_read") if the provider/bucket needs one.
  s3_opts =
    case System.get_env("S3_ACL") do
      nil -> s3_opts
      acl -> Keyword.put(s3_opts, :acl, String.to_atom(acl))
    end

  # Optional (#481): a SEPARATE bucket for gated documents — this app's own
  # AWS credentials read it directly, so it needs no public-read config, no
  # CDN, and no S3_PUBLIC_BASE_URL equivalent (see KilnCMS.Storage.S3 docs).
  # Without it, gating a document is refused rather than silently falling
  # back to the public bucket.
  s3_opts =
    case System.get_env("S3_PRIVATE_BUCKET") do
      nil -> s3_opts
      private_bucket -> Keyword.put(s3_opts, :private_bucket, private_bucket)
    end

  config :kiln_cms, KilnCMS.Storage.S3, s3_opts

  config :ex_aws,
    access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
    # R2 uses "auto"; B2/Wasabi/AWS use a real region.
    region: System.get_env("AWS_REGION") || "us-east-1"

  # Custom endpoint for any non-AWS S3-compatible store (R2/B2/Wasabi/MinIO).
  # Leave unset for AWS S3 (ExAws derives the host from the region).
  if endpoint_host = System.get_env("S3_ENDPOINT_HOST") do
    config :ex_aws, :s3,
      scheme: System.get_env("S3_ENDPOINT_SCHEME") || "https://",
      host: endpoint_host,
      port: String.to_integer(System.get_env("S3_ENDPOINT_PORT") || "443")
  end
end
