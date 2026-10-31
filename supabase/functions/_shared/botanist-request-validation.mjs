// Runtime-neutral validation for the Botanist HTTP contract.
//
// Kept outside the Deno entry point so the exact production rules run in the
// Node test suite as well. Historical user turns are truncated, not rejected:
// older app versions allowed longer messages and one legacy turn must not
// permanently poison every follow-up in the thread.

// node:buffer resolves in both Node and Deno, keeping the validation contract
// shared by production and the Node suite.
import { Buffer } from "node:buffer";

export const maxQuestionCharacters = 1_000;
export const maxConversationMessages = 20;
export const maxPlantContextCharacters = 4_000;
export const maxPhotoBytes = 2 * 1024 * 1024;
export const maxPhotoAttachments = 2;
export const maxTotalPhotoBytes = 4 * 1024 * 1024;
// Two maximum JPEGs expand to about 5.34 MiB as base64. Leave room for the
// bounded transcript and context, but stop a caller-controlled body before the
// edge function parses an arbitrarily large JSON string into memory.
export const maxAskRequestBytes = 6 * 1024 * 1024;
const maxAssistantMessageCharacters = 1_500;

export const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class AskValidationError extends Error {}
export class AskPayloadTooLargeError extends Error {}

export async function boundedAskJSON(request, maximumBytes = maxAskRequestBytes) {
  const declaredLength = request.headers?.get?.("content-length");
  if (declaredLength && /^\d+$/.test(declaredLength) && Number(declaredLength) > maximumBytes) {
    throw new AskPayloadTooLargeError("That question and its photos are too large to send.");
  }
  if (!request.body) throw new SyntaxError("The request body is empty.");

  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maximumBytes) {
        await reader.cancel();
        throw new AskPayloadTooLargeError("That question and its photos are too large to send.");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

function optionalUUID(value, field) {
  if (value == null || value === "") return null;
  if (typeof value !== "string" || !uuidPattern.test(value)) {
    throw new AskValidationError(`${field} is invalid.`);
  }
  return value.toLowerCase();
}

function optionalPhoto(value) {
  if (value === undefined || value === null) return null;
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new AskValidationError("The attached photo is invalid.");
  }
  if (value.mimeType !== "image/jpeg" || typeof value.base64Data !== "string") {
    throw new AskValidationError("The attached photo must be a JPEG image.");
  }
  const maximumBase64Length = Math.ceil(maxPhotoBytes / 3) * 4 + 4;
  if (
    !value.base64Data
    || value.base64Data.length > maximumBase64Length
    || value.base64Data.length % 4 !== 0
    || !/^[A-Za-z0-9+/]+={0,2}$/.test(value.base64Data)
  ) {
    throw new AskValidationError("The attached photo is invalid or larger than 2 MB.");
  }
  const bytes = Buffer.from(value.base64Data, "base64");
  const isJPEG = bytes.length >= 3
    && bytes[0] === 0xff
    && bytes[1] === 0xd8
    && bytes[2] === 0xff;
  if (!isJPEG || bytes.length > maxPhotoBytes) {
    throw new AskValidationError("The attached photo is invalid or larger than 2 MB.");
  }
  return {
    photo: { mimeType: "image/jpeg", base64Data: value.base64Data },
    byteCount: bytes.length
  };
}

function optionalAttachments(value, conversation) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value) || value.length > maxPhotoAttachments) {
    throw new AskValidationError(`Attach no more than ${maxPhotoAttachments} photos.`);
  }

  const userMessageIndexes = new Map();
  conversation.forEach((message, index) => {
    if (message.role === "user" && message.id) userMessageIndexes.set(message.id, index);
  });
  const seenMessageIDs = new Set();
  let totalBytes = 0;
  const attachments = value.map((attachment) => {
    if (typeof attachment !== "object" || attachment === null || Array.isArray(attachment)) {
      throw new AskValidationError("The attached photo is invalid.");
    }
    const messageID = optionalUUID(attachment.messageID, "Photo message");
    if (!messageID || !userMessageIndexes.has(messageID)) {
      throw new AskValidationError("Each photo must belong to a user message in this conversation.");
    }
    if (seenMessageIDs.has(messageID)) {
      throw new AskValidationError("Only one photo may be attached to each message.");
    }
    seenMessageIDs.add(messageID);

    const validated = optionalPhoto(attachment);
    totalBytes += validated.byteCount;
    if (totalBytes > maxTotalPhotoBytes) {
      throw new AskValidationError("The attached photos are larger than 4 MB together.");
    }
    return { messageID, ...validated.photo };
  });
  // Comparison language depends on direction. Canonicalize the wire order even
  // if a caller sends the newest attachment first, so Photo 1 is always the
  // oldest evidence and the current-turn photo (when present) is last.
  return attachments.sort(
    (left, right) => userMessageIndexes.get(left.messageID) - userMessageIndexes.get(right.messageID)
  );
}

export function validatedAsk(body) {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new AskValidationError("A question is required.");
  }
  const raw = body.conversation;
  if (!Array.isArray(raw) || raw.length === 0) {
    throw new AskValidationError("A question is required.");
  }
  if (raw.length > maxConversationMessages) {
    throw new AskValidationError("That conversation is too long to send.");
  }

  const conversation = [];
  const seenMessageIDs = new Set();
  for (const entry of raw) {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) continue;
    const { role, content } = entry;
    if (role !== "user" && role !== "assistant") continue;
    if (typeof content !== "string") continue;
    const trimmed = content.trim();
    if (!trimmed) continue;
    const id = entry.id == null || entry.id === ""
      ? null
      : optionalUUID(entry.id, "Message");
    if (id && seenMessageIDs.has(id)) {
      throw new AskValidationError("Each conversation message must have a unique id.");
    }
    if (id) seenMessageIDs.add(id);
    conversation.push({ role, content: trimmed, id });
  }

  if (conversation.length === 0 || conversation.at(-1).role !== "user") {
    throw new AskValidationError("A question is required.");
  }
  if (conversation.at(-1).content.length > maxQuestionCharacters) {
    throw new AskValidationError("That question is a little long — try trimming it down.");
  }

  const boundedConversation = conversation.map((message, index) => {
    if (index === conversation.length - 1) return message;
    const limit = message.role === "user"
      ? maxQuestionCharacters
      : maxAssistantMessageCharacters;
    return { ...message, content: message.content.slice(0, limit) };
  });

  let plantContext = null;
  if (typeof body.plantContext === "string" && body.plantContext.trim()) {
    // A long living record is the caller doing the right thing. Losing the
    // oldest excess characters is safer than failing the current question.
    plantContext = body.plantContext.trim().slice(0, maxPlantContextCharacters);
  }

  const legacyPhoto = optionalPhoto(body.photo);
  const attachments = optionalAttachments(body.attachments, boundedConversation);
  if (legacyPhoto && attachments.length > 0) {
    throw new AskValidationError("Send photos using one attachment format at a time.");
  }
  const requestID = optionalUUID(body.requestID, "Request");
  const latestMessageID = boundedConversation.at(-1).id;
  if (requestID && requestID !== latestMessageID) {
    throw new AskValidationError("The request must identify the current user message.");
  }
  if (body.safetyOnly != null && typeof body.safetyOnly !== "boolean") {
    throw new AskValidationError("The safety-only option is invalid.");
  }

  return {
    conversation: boundedConversation,
    plantContext,
    plantID: optionalUUID(body.plantID, "Plant"),
    threadID: optionalUUID(body.threadID, "Conversation"),
    requestID,
    safetyOnly: body.safetyOnly === true,
    // `photo` stays for contract-v5 callers. Contract-v6 clients associate each
    // attachment with its original message, which lets the app quietly resend a
    // prior photo for a follow-up without pretending it was newly attached.
    photo: legacyPhoto?.photo ?? null,
    attachments
  };
}
