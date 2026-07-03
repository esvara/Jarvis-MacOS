import { GoogleGenAI } from "@google/genai";
import type { RealtimeClientSecret } from "../shared/types";

/// Ephemeral client credentials for the non-OpenAI voice providers. The
/// pattern mirrors createRealtimeClientSecret: the sidecar holds the real API
/// key and hands the WKWebView a short-lived secret.

export class VoiceProviderKeyError extends Error {
  constructor(
    message: string,
    readonly status: number
  ) {
    super(message);
    this.name = "VoiceProviderKeyError";
  }
}

export async function createGrokClientSecret(apiKey: string): Promise<RealtimeClientSecret> {
  const response = await fetch("https://api.x.ai/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({ expires_after: { seconds: 300 } })
  });

  if (!response.ok) {
    const detail = await safeErrorMessage(response);
    if (response.status === 401) {
      throw new VoiceProviderKeyError("The xAI API key is invalid or was revoked. Check it at console.x.ai.", 401);
    }
    throw new VoiceProviderKeyError(`xAI client-secret request failed (HTTP ${response.status}).${detail}`, response.status);
  }

  const data = (await response.json()) as {
    value?: string;
    token?: string;
    client_secret?: { value?: string; expires_at?: number };
    expires_at?: number;
  };
  return {
    value: data.value ?? data.client_secret?.value ?? data.token ?? "",
    expiresAt: data.expires_at ?? data.client_secret?.expires_at
  };
}

export async function createGeminiAuthToken(apiKey: string): Promise<RealtimeClientSecret> {
  try {
    const client = new GoogleGenAI({ apiKey, httpOptions: { apiVersion: "v1alpha" } });
    const expireTime = new Date(Date.now() + 30 * 60_000).toISOString();
    const newSessionExpireTime = new Date(Date.now() + 60_000).toISOString();
    const token = await client.authTokens.create({
      config: { uses: 1, expireTime, newSessionExpireTime }
    });
    return { value: token.name ?? "" };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (/401|API key not valid|PERMISSION_DENIED/i.test(message)) {
      throw new VoiceProviderKeyError("The Gemini API key is invalid. Check it at aistudio.google.com/apikey.", 401);
    }
    throw new VoiceProviderKeyError(`Gemini auth-token request failed: ${message}`, 500);
  }
}

export async function validateGrokApiKey(apiKey: string): Promise<{ valid: boolean; reason?: string }> {
  try {
    const secret = await createGrokClientSecret(apiKey);
    return secret.value
      ? { valid: true }
      : { valid: false, reason: "xAI did not return a usable client secret." };
  } catch (error) {
    return { valid: false, reason: error instanceof Error ? error.message : "Could not reach xAI." };
  }
}

export async function validateGeminiApiKey(apiKey: string): Promise<{ valid: boolean; reason?: string }> {
  try {
    const token = await createGeminiAuthToken(apiKey);
    return token.value
      ? { valid: true }
      : { valid: false, reason: "Gemini did not return a usable auth token." };
  } catch (error) {
    return { valid: false, reason: error instanceof Error ? error.message : "Could not reach Google." };
  }
}

async function safeErrorMessage(response: Response): Promise<string> {
  try {
    const body = (await response.json()) as { error?: { message?: string } | string };
    const message = typeof body.error === "string" ? body.error : body.error?.message;
    return message ? ` ${message}` : "";
  } catch {
    return "";
  }
}
