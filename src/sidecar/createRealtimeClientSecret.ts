import type { RealtimeClientSecret } from "../shared/types";
import { REALTIME_MODEL } from "../shared/samanthaConfig";

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
    throw new Error(`Failed to create client secret (${response.status}).`);
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
