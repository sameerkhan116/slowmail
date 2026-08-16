// APNs, over HTTP/2 with a token-based provider key.
//
// The payload is deliberately empty of content. "You have mail" is the entire
// product: no body, no sender, no count. Anything richer would hand the
// notification layer information the database spends the rest of this schema
// withholding.

const TOKEN_MAX_AGE_MS = 45 * 60 * 1000; // Apple rejects provider tokens older than an hour.

export type ApnsConfig = {
  keyId: string;
  teamId: string;
  privateKeyPem: string;
  bundleId: string;
  defaultEnvironment: "sandbox" | "production";
};

export type ApnsOutcome =
  | { ok: true }
  | { ok: false; retryable: true; reason: string }
  | { ok: false; retryable: false; reason: string; pruneToken: true };

export function readApnsConfig(): ApnsConfig {
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const privateKeyPem = Deno.env.get("APNS_PRIVATE_KEY");
  const bundleId = Deno.env.get("APNS_BUNDLE_ID");
  const environment = (Deno.env.get("APNS_ENVIRONMENT") ?? "production") as "sandbox" | "production";

  if (!keyId || !teamId || !privateKeyPem || !bundleId) {
    throw new Error(
      "APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY and APNS_BUNDLE_ID must be set as Supabase secrets",
    );
  }

  return { keyId, teamId, privateKeyPem, bundleId, defaultEnvironment: environment };
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function pemToPkcs8(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const raw = atob(body);
  const bytes = new Uint8Array(new ArrayBuffer(raw.length));
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

let cachedToken: { value: string; issuedAt: number } | null = null;

export async function providerToken(config: ApnsConfig, now = Date.now()): Promise<string> {
  if (cachedToken && now - cachedToken.issuedAt < TOKEN_MAX_AGE_MS) {
    return cachedToken.value;
  }

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(config.privateKeyPem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );

  const encoder = new TextEncoder();
  const header = base64url(encoder.encode(JSON.stringify({ alg: "ES256", kid: config.keyId })));
  const payload = base64url(
    encoder.encode(JSON.stringify({ iss: config.teamId, iat: Math.floor(now / 1000) })),
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    encoder.encode(`${header}.${payload}`),
  );

  const token = `${header}.${payload}.${base64url(new Uint8Array(signature))}`;
  cachedToken = { value: token, issuedAt: now };
  return token;
}

export function resetProviderTokenCache(): void {
  cachedToken = null;
}

// A token is dead for good on these; anything else is worth another attempt.
const FATAL_REASONS = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"]);

export async function sendMailArrivedPush(
  config: ApnsConfig,
  deviceToken: string,
  environment: string | null,
  fetchImpl: typeof fetch = fetch,
): Promise<ApnsOutcome> {
  const host = (environment ?? config.defaultEnvironment) === "sandbox"
    ? "https://api.sandbox.push.apple.com"
    : "https://api.push.apple.com";

  const jwt = await providerToken(config);

  const response = await fetchImpl(`${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": config.bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      // One knock per day per recipient: if two ever reach the device, the
      // collapse id makes the second replace the first rather than stack.
      "apns-collapse-id": "slowmail-delivery",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: {
        alert: { "title-loc-key": "YOU_HAVE_MAIL" },
        sound: "default",
        "thread-id": "slowmail-delivery",
      },
    }),
  });

  if (response.ok) {
    await response.body?.cancel();
    return { ok: true };
  }

  let reason = `apns_status_${response.status}`;
  try {
    const parsed = await response.json();
    if (typeof parsed?.reason === "string") reason = parsed.reason;
  } catch {
    // APNs sends an empty body on some statuses; the status alone is the reason.
  }

  if (response.status === 410 || FATAL_REASONS.has(reason)) {
    return { ok: false, retryable: false, reason, pruneToken: true };
  }

  return { ok: false, retryable: true, reason };
}
