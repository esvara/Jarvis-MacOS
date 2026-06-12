import type { RealtimeClientSecret } from "../shared/types";
import { REALTIME_MODEL } from "../shared/samanthaConfig";

export class OpenAIKeyError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code?: string
  ) {
    super(message);
    this.name = "OpenAIKeyError";
  }
}

function describeOpenAIFailure(status: number, code?: string, apiMessage?: string): string {
  if (status === 401) {
    return "The OpenAI API key is invalid or was revoked. Check it at platform.openai.com/api-keys.";
  }
  if (code === "insufficient_quota") {
    return "The OpenAI account has no remaining credit. Add billing at platform.openai.com/account/billing.";
  }
  if (status === 429) {
    return "OpenAI rate limit reached. Wait a moment and try again.";
  }
  if (status === 403) {
    return "This API key is not allowed to use the Realtime API (check project permissions).";
  }
  const detail = apiMessage ? ` ${apiMessage}` : "";
  return `OpenAI request failed (HTTP ${status}).${detail}`;
}

export async function createRealtimeClientSecret(apiKey: string): Promise<RealtimeClientSecret> {
  const response = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      session: {
        type: "realtime",
        model: REALTIME_MODEL
      }
    })
  });

  if (!response.ok) {
    let code: string | undefined;
    let apiMessage: string | undefined;
    try {
      const body = (await response.json()) as {
        error?: { code?: string; message?: string };
      };
      code = body.error?.code;
      apiMessage = body.error?.message;
    } catch {
      // Non-JSON error body; status alone is enough.
    }
    throw new OpenAIKeyError(describeOpenAIFailure(response.status, code, apiMessage), response.status, code);
  }

  const data = (await response.json()) as {
    value?: string;
    expires_at?: number;
    client_secret?: { value?: string; expires_at?: number };
  };

  return {
    value: data.value ?? data.client_secret?.value ?? "",
    expiresAt: data.expires_at ?? data.client_secret?.expires_at
  };
}

/**
 * Checks that the stored key can mint a Realtime client secret — the exact
 * call the voice layer depends on — without starting a session.
 */
export async function validateApiKey(apiKey: string): Promise<{ valid: boolean; reason?: string }> {
  try {
    const secret = await createRealtimeClientSecret(apiKey);
    if (!secret.value) {
      return { valid: false, reason: "OpenAI did not return a usable client secret." };
    }
    return { valid: true };
  } catch (error) {
    if (error instanceof OpenAIKeyError) {
      return { valid: false, reason: error.message };
    }
    return {
      valid: false,
      reason: "Could not reach OpenAI to verify the key. Check your network connection."
    };
  }
}
