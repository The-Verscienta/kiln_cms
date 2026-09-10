/** A non-2xx HTTP response from a Kiln surface. */
export class KilnHttpError extends Error {
  readonly status: number;
  readonly url: string;
  /** Parsed JSON error body when the server sent one, else the raw text. */
  readonly body: unknown;

  constructor(status: number, url: string, body: unknown) {
    super(`Kiln request failed: ${status} ${url}`);
    this.name = "KilnHttpError";
    this.status = status;
    this.url = url;
    this.body = body;
  }
}

/** Narrowing helper: `isKilnHttpError(err) && err.status === 404`. */
export function isKilnHttpError(error: unknown): error is KilnHttpError {
  return error instanceof KilnHttpError;
}
