# 0069. An admin-entered backup endpoint is pinned per call, and only the operator opens private hosts

- **Status** — accepted (2026-11-17).
- **References** — [#2221](https://github.com/The-Verscienta/kiln_cms/issues/2221)
  (the S3 backup destination) and the owner's decisions recorded on it
  (2026-11-17): check and pin the endpoint on save and on every request,
  open private and loopback hosts only through a new
  `BACKUP_S3_PRIVATE_HOSTS`, allow `http://` only for those hosts, treat
  clock skew as permanent;
  [#2223](https://github.com/The-Verscienta/kiln_cms/issues/2223)
  (resumable uploads, which needs a permanent failure told from a
  transient one);
  [ADR 0068](0068-a-resumable-backup-upload-is-recorded-by-the-installation-that-started-it-and-only-it-aborts-it.md)
  (what a permanent failure does to a recorded upload).
- **Changelog** — the Unreleased section of
  [CHANGELOG.md](../../CHANGELOG.md): Added
  ([long form](../changelog/v1.11.0.md#s3-backup-destination)).

## The problem

An S3 backup destination's endpoint is typed into a form by a platform
admin, and the app then sends signed requests to it from inside the
deployment, with the database dump as the body. That is the shape of a
server-side request forgery: whoever controls the form chooses a host the
app connects to, and the app sits where the cloud metadata service, the
database and the operator's other private services can be reached. A
platform admin is trusted with backups, not with the network the app runs
in; on a hosted instance they are not the same person as the operator.

The store's answers are the second half of it. The host is the admin's
choice, so what it answers is too: the text of an error, its size, a
redirect elsewhere. And the answer decides what Kiln does next, since
ADR 0068 aborts a recorded upload on a permanent failure and keeps it on a
transient one.

## Decision

**The endpoint is checked as a webhook URL is, and the check is what is
connected to.** `KilnCMS.Backups.Destination.S3.Endpoint` parses the
settings offline (the adapter's `validate/1`, which the SDK keeps offline):
an `https://` URL with a host and nothing else, no user info, path, query
or fragment, and a host that is no `localhost`, `.local`, `.internal` or
metadata name and no private, loopback or link-local IP literal.
`Endpoint.pin/2` then resolves the host requests connect to, which is
`<bucket>.<host>` when the bucket is addressed virtual-hosted, and
answers one address only if every address the name resolves to is
allowed (`KilnCMS.Webhooks.SafeUrl.lookup/1` and `blocked_address?/1`).
It runs in a core validation on save
(`DestinationConfig.Validations.AdapterSettings`) and again at the start of
every adapter call, and `KilnCMS.Storage.S3.ReqClient` connects to the
pinned address with the original host for TLS and signing, and follows no
redirect. A name that resolves somewhere else by the next call is refused,
not followed.

**Only the operator opens a private host, by exact name.**
`BACKUP_S3_PRIVATE_HOSTS` is a comma-separated list of host names or IP
literals. A listed name may be `http://`, may resolve to a private or
loopback address, and may be a `.local` or `.internal` name. The name
compared is the one connected to, so listing `minio.lan` opens neither
`evil.minio.lan` nor a virtual-hosted `<bucket>.minio.lan`. An entry with a
scheme, port, path or wildcard is dropped when the list is parsed. The list
is read in every environment, from `config/runtime.exs`.

**Nothing opens a link-local or metadata address.** `169.254.0.0/16`,
`fe80::/10` and `fd00:ec2::254`, their IPv4-mapped and IPv4-compatible
forms, and the IPv4 address carried by a NAT64 (`64:ff9b::/96`) or 6to4
(`2002::/16`) address are refused for a listed host too, and so are the
metadata host names. Listing is for a store on the LAN; no store lives at
the metadata service's address.

**The request is built from the destination alone.** The signing config is
`ExAws.Config.Defaults.defaults(:s3)` overlaid with the destination's own
host, scheme, port, region and key pair
(`KilnCMS.Backups.Destination.S3.Client.aws_config/3`). The app's
`:ex_aws` config, which holds the media store's credentials, is never
merged in, so those credentials can't be sent to a host an admin typed.
ExAws's request layer is not used: Kiln signs with ExAws.Auth.headers/6 (internal to ExAws, its version pinned by the lock file)
and sends through `ReqClient` itself.

**An answer is classified from a fixed table, and the store's words are
never repeated.** `KilnCMS.Backups.Destination.S3.Errors` reads the HTTP
status, the `<Code>` of an error body, and two headers (`Date`,
`x-amz-bucket-region`, which must look like a region). The message is
Kiln's own sentence, naming the code only when the code is in the table.
The `<Message>` element is never read.

- **Permanent** (the destination fails at once, and ADR 0068 aborts its
  recorded upload): `AccessDenied`, `AllAccessDisabled`,
  `InvalidAccessKeyId`, `SignatureDoesNotMatch`, `NoSuchBucket`,
  `PermanentRedirect` or any `301` (wrong region or endpoint, naming the
  bucket's region when the header gives one), `AuthorizationHeaderMalformed`,
  `RequestTimeTooSkewed` or any `403` whose `Date` is more than five minutes
  from this server's clock, `InvalidPart`, `EntityTooLarge`,
  `InvalidBucketName`, and any redirect other than a `307`.
- **Transient** (retried by `KilnCMS.Backups.Retry`): any `5xx`, `SlowDown`,
  `429`, `RequestTimeout`, `BadDigest`, `XAmzContentSHA256Mismatch`, a
  `307`, a connection failure or timeout, and **every other `4xx`**.
- `NoSuchUpload` and `NoSuchKey` (or a `404` with no body) are the
  caller's to handle: an upload to start over, a file that isn't there.

A `403` to a `HEAD` has no body to read a code from. After the skew check,
it is asked once more as a `ListObjectsV2` with `max-keys=0`, whose code
says what was refused. A `200` to `CompleteMultipartUpload` carrying an
`<Error>` is an error, and a `HEAD` decides whether the object is there.
Every response body is capped (8 MiB, or a ranged read's own length but at
least 64 KiB) and cut off past it rather than buffered.

**Retries are bounded and never outlive the call.** Full-jitter exponential
backoff: up to six tries, each wait random up to `min(30 s, 1 s ×
2^(n-1))`, and no wait that would end within 30 seconds of the call's
deadline, which then answers `{:error, :deadline}` with the progress saved.

## Rejected

- **Trusting platform admins with any endpoint**, as `S3_ENDPOINT_HOST`
  trusts the operator. The operator sets an environment variable; an admin
  fills in a form. The two are not the same trust.
- **Checking the endpoint only on save.** DNS can change between save and
  backup; a check that isn't the connection is a check of something else.
- **Patterns or CIDR ranges in `BACKUP_S3_PRIVATE_HOSTS`.** A suffix or a
  range opens more than the one store the operator meant, and one exact
  name per store is short to write.
- **Opening link-local addresses for a listed host.** No S3 store is there,
  and the metadata service is.
- **Following redirects.** A redirect is a new host and a new resolution
  the pin never saw. S3 sends a `301` for a wrong region, which is better
  reported than followed.
- **ExAws's own request and retry layer.** It merges the app's `:ex_aws`
  config, follows its own redirect handling, and sleeps between retries
  without knowing the step's deadline.
- **Showing the store's `<Message>`.** It is text from a host the admin
  chose, shown in the console, in History and on the home page. A code from
  a fixed table carries what an operator needs.
- **Treating an unknown `4xx` as permanent.** Stores that speak S3 add
  codes of their own. A permanent answer aborts a recorded upload and fails
  the destination for the backup; a code Kiln doesn't know is safer
  retried, a bounded number of times, than taken as the end of an upload
  that might resume.

## Consequences

- A MinIO or Garage on the LAN needs one line from the operator, and a
  virtual-hosted bucket there needs its own name listed, or **Path style**.
- A name that doesn't resolve on the node serving the page can't be saved,
  and a name with only IPv6 (AAAA) addresses reads as not resolving, since
  the lookup asks for IPv4. An IPv6 literal works.
- An unknown `4xx` costs up to six tries before the destination fails for
  that attempt.
- Every error a store causes is one of a fixed set of sentences, so an
  operator searching the docs for one finds it.
- Two names for one store (`s3.amazonaws.com` and
  `s3.us-east-1.amazonaws.com`, a MinIO by name and by IP) are two stores
  to the overlap check when saving: it compares the endpoint as entered.
  Retention treats them as a possible overlap and prunes neither (#3088,
  ADR 0064).

## When to revisit

- If the SDK grows a way for a plugin's adapter to ask for a pinned,
  checked connection, the same policy can cover plugins' destinations.
- If a store Kiln supports answers a common `4xx` code that no retry fixes,
  add it to the permanent table rather than changing the default.
- If DNS resolution learns IPv6, AAAA-only hosts can be saved.
