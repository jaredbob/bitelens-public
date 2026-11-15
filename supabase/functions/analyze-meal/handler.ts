import {
  type AnalysisInput,
  type AnalysisProvider,
  isRecord,
  normalizeEstimate,
  ProviderFailure,
  type ProviderID,
} from "./meal-estimate.ts";
import { isJPEG } from "./jpeg.ts";

const photoLifetimeMs = 168 * 60 * 60 * 1_000;
const maxPhotoBytes = 4 * 1024 * 1024;
const maxBase64Length = Math.ceil(maxPhotoBytes / 3) * 4;
const maxRequestBytes = maxBase64Length + 16 * 1024;

interface Config {
  authURL: string;
  authKey: string;
  access: { kind: "owner"; ownerID: string } | {
    kind: "beta";
    allowance: { key: string; dailyLimit: number };
  };
  providers: Partial<Record<ProviderID, AnalysisProvider>>;
  fetch: typeof fetch;
  now?: () => number;
  providerTimeoutMs?: number;
}

export function createAnalysisHandler(config: Config) {
  const now = config.now ?? Date.now;
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return problem(405, "method_not_allowed", { Allow: "POST" });
    }

    const authorization = request.headers.get("Authorization");
    if (!authorization || !/^Bearer [^\s,]+$/i.test(authorization)) {
      return problem(401, "unauthenticated");
    }
    const authHeaders = { Authorization: authorization, apikey: config.authKey };
    const forbidden = config.access.kind === "beta" ? "approval_required" : "owner_required";
    let userID: string;
    try {
      const auth = await config.fetch(config.authURL + "/auth/v1/user", {
        redirect: "error",
        headers: authHeaders,
        signal: AbortSignal.timeout(5_000),
      });
      if (!auth.ok) {
        await auth.body?.cancel();
        return [400, 401, 403].includes(auth.status)
          ? problem(401, "unauthenticated")
          : problem(503, "auth_unavailable");
      }
      const user: unknown = await auth.json();
      if (!isRecord(user) || typeof user.id !== "string" || !user.id || user.role !== "authenticated" ||
        user.is_anonymous === true) {
        return problem(403, forbidden);
      }
      userID = user.id;
      if (config.access.kind === "owner") {
        if (userID !== config.access.ownerID) return problem(403, forbidden);
      } else {
        const approval = await config.fetch(config.authURL + "/rest/v1/rpc/bitelens_is_approved", {
          method: "POST",
          redirect: "error",
          headers: { ...authHeaders, "Content-Type": "application/json" },
          signal: AbortSignal.timeout(5_000),
          body: "{}",
        });
        if (!approval.ok) {
          await approval.body?.cancel();
          return problem(503, "auth_unavailable");
        }
        const approved: unknown = await approval.json();
        if (approved === false) return problem(403, forbidden);
        if (approved !== true) return problem(503, "auth_unavailable");
      }
    } catch {
      return problem(503, "auth_unavailable");
    }

    if (request.headers.get("Content-Type")?.split(";")[0].trim().toLowerCase() !== "application/json") {
      return problem(415, "invalid_request");
    }
    let body: unknown;
    try {
      body = await readJSON(request);
    } catch (error) {
      return error instanceof RequestTooLarge
        ? problem(413, "request_too_large")
        : problem(400, "invalid_request");
    }
    if (!isRecord(body)) return problem(400, "invalid_request");
    const { provider, captured_at_ms: capturedAt, photo_base64: photo, notes = "", description } = body;
    if (provider !== "openai" && provider !== "grok") {
      return problem(400, "invalid_provider");
    }
    const adapter = config.providers[provider];
    if (!adapter) return problem(503, "provider_unavailable");
    let input: AnalysisInput;
    let photoExpiresAt: number | undefined;
    if (description !== undefined) {
      if (typeof description !== "string" || description.length > 2_000 || !description.trim() ||
        capturedAt !== undefined || photo !== undefined || Object.hasOwn(body, "notes")) {
        return problem(400, "invalid_request");
      }
      input = { description: description.trim() };
    } else {
      if (typeof capturedAt !== "number" || !Number.isSafeInteger(capturedAt) ||
        capturedAt < 0 || capturedAt > now() || typeof notes !== "string" || notes.length > 2_000) {
        return problem(400, "invalid_request");
      }
      photoExpiresAt = capturedAt + photoLifetimeMs;
      if (now() >= photoExpiresAt) return problem(410, "photo_expired");
      if (typeof photo !== "string" || photo.length > maxBase64Length) {
        return problem(400, "invalid_photo");
      }
      try {
        const bytes = atob(photo);
        if (bytes.length > maxPhotoBytes || btoa(bytes) !== photo || !isJPEG(bytes)) {
          return problem(400, "invalid_photo");
        }
      } catch {
        return problem(400, "invalid_photo");
      }
      // The photo might cross its cutoff while the authenticated body is decoded.
      if (now() >= photoExpiresAt) return problem(410, "photo_expired");
      input = { photoBase64: photo, notes: notes.trim() };
    }

    if (config.access.kind === "beta") {
      const { key, dailyLimit } = config.access.allowance;
      const headers = new Headers({ apikey: key, "Content-Type": "application/json" });
      if (!key.startsWith("sb_secret_")) headers.set("Authorization", `Bearer ${key}`);
      try {
        const reservation = await config.fetch(config.authURL + "/rest/v1/rpc/bitelens_reserve_meal_estimate", {
          method: "POST",
          redirect: "error",
          headers,
          signal: AbortSignal.timeout(5_000),
          body: JSON.stringify({
            p_user_id: userID, p_daily_limit: dailyLimit,
            p_photo_expires_at: photoExpiresAt === undefined ? null : new Date(photoExpiresAt).toISOString(),
          }),
        });
        if (!reservation.ok) {
          await reservation.body?.cancel();
          return problem(503, "allowance_unavailable");
        }
        const result: unknown = await reservation.json();
        if (!isRecord(result)) return problem(503, "allowance_unavailable");
        if (result.error === "approval_required") return problem(403, "approval_required");
        if (result.error === "photo_expired") return problem(410, "photo_expired");
        if (result.error === "allowance_exhausted" && typeof result.reset_at === "string") {
          const reset = Date.parse(result.reset_at);
          if (Number.isFinite(reset)) {
            return json({ error: "allowance_exhausted", reset_at: new Date(reset).toISOString() }, 429);
          }
        }
        if (result.error !== undefined || result.reserved !== true) return problem(503, "allowance_unavailable");
        if (photoExpiresAt !== undefined) {
          const reservationID = result.reservation_id;
          if (typeof reservationID !== "string" || !reservationID) return problem(503, "allowance_unavailable");
          // The image can cross its cutoff while the reservation is in flight.
          if (now() >= photoExpiresAt) {
            await refundMealEstimate(config, headers, reservationID);
            return problem(410, "photo_expired");
          }
        }
      } catch {
        return problem(503, "allowance_unavailable");
      }
    }

    const timeout = AbortSignal.timeout(config.providerTimeoutMs ?? 25_000);
    try {
      const estimate = normalizeEstimate(
        await adapter.analyze(input, timeout), provider, "photoBase64" in input,
      );
      return timeout.aborted ? problem(504, "timeout") : json(estimate, 200);
    } catch (error) {
      if (timeout.aborted) return problem(504, "timeout");
      if (error instanceof ProviderFailure) {
        return problem(error.code === "provider_unavailable" ? 503 : 422, error.code);
      }
      return problem(503, "provider_unavailable");
    }
  };
}

async function refundMealEstimate(config: Config, headers: Headers, reservationID: string) {
  const body = JSON.stringify({ p_reservation_id: reservationID });
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const refund = await config.fetch(config.authURL + "/rest/v1/rpc/bitelens_refund_meal_estimate", {
        method: "POST",
        redirect: "error",
        headers,
        signal: AbortSignal.timeout(5_000),
        body,
      });
      if (refund.ok) return;
      await refund.body?.cancel();
    } catch {
      // The refund may have committed. Reusing its ID makes a retry safe.
    }
  }
}

class RequestTooLarge extends Error {}

async function readJSON(request: Request): Promise<unknown> {
  if (Number(request.headers.get("Content-Length")) > maxRequestBytes) throw new RequestTooLarge();
  const reader = request.body?.getReader();
  if (!reader) throw new Error("Missing request body");
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let length = 0;
  let body = "";
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > maxRequestBytes) throw new RequestTooLarge();
      body += decoder.decode(value, { stream: true });
    }
    return JSON.parse(body + decoder.decode());
  } catch (error) {
    await reader.cancel().catch(() => {});
    throw error;
  } finally {
    reader.releaseLock();
  }
}

function problem(status: number, error: string, headers: Record<string, string> = {}) {
  return json({ error }, status, headers);
}

function json(value: unknown, status: number, headers: Record<string, string> = {}) {
  return Response.json(value, { status, headers: { "Cache-Control": "no-store", ...headers } });
}
