import { execFileSync } from "node:child_process";

const keychainAccount = "nz.co.thinkingai.Grove";
const keychainService = "nz.co.thinkingai.Grove.gemini-api-key";

function localKeychainSecret() {
  try {
    return execFileSync(
      "security",
      ["find-generic-password", "-a", keychainAccount, "-s", keychainService, "-w"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
    ).trim();
  } catch {
    return undefined;
  }
}

export function loadGeminiAPIKey({
  environment = process.env,
  platform = process.platform,
  readLocalKeychain = localKeychainSecret
} = {}) {
  const deployedSecret = environment.GEMINI_API_KEY?.trim();
  if (deployedSecret) return deployedSecret;

  if (platform === "darwin" && environment.NODE_ENV !== "production") {
    const developmentSecret = readLocalKeychain()?.trim();
    if (developmentSecret) return developmentSecret;
  }

  throw new Error(
    "GEMINI_API_KEY is not configured. Set it in the deployment platform's secret manager."
  );
}

export const geminiSecretLocation = Object.freeze({
  environmentVariable: "GEMINI_API_KEY",
  keychainAccount,
  keychainService
});
