import assert from "node:assert/strict";
import test from "node:test";
import {
  AskPayloadTooLargeError,
  AskValidationError,
  boundedAskJSON,
  maxAskRequestBytes,
  maxPhotoAttachments,
  maxPhotoBytes,
  maxQuestionCharacters,
  validatedAsk
} from "../botanist-request-validation.mjs";

const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString("base64");
const currentMessageID = "a0e24564-4cf5-4b9c-a8a1-faae9198cdf6";
const previousMessageID = "b1e24564-4cf5-4b9c-a8a1-faae9198cdf6";

test("Botanist rejects an oversized wire body before JSON parsing", async () => {
  const declared = new Request("https://grove.test/botanist/ask", {
    method: "POST",
    headers: { "content-length": String(maxAskRequestBytes + 1) },
    body: "{}"
  });
  await assert.rejects(
    boundedAskJSON(declared),
    (error) => error instanceof AskPayloadTooLargeError
  );

  const streamed = {
    headers: new Headers(),
    body: new ReadableStream({
      start(controller) {
        controller.enqueue(new Uint8Array(maxAskRequestBytes));
        controller.enqueue(new Uint8Array([0]));
        controller.close();
      }
    })
  };
  await assert.rejects(
    boundedAskJSON(streamed),
    (error) => error instanceof AskPayloadTooLargeError
  );
});

test("Botanist accepts a follow-up after truncating a legacy long user turn", () => {
  const legacy = "a".repeat(maxQuestionCharacters + 400);
  const result = validatedAsk({
    conversation: [
      { role: "user", content: legacy },
      { role: "assistant", content: "What does the soil feel like?" },
      { role: "user", content: "It feels dry two centimetres down." }
    ]
  });

  assert.equal(result.conversation[0].content.length, maxQuestionCharacters);
  assert.equal(result.conversation.at(-1).content, "It feels dry two centimetres down.");
});

test("Botanist still rejects an overlong current question", () => {
  assert.throws(
    () => validatedAsk({
      conversation: [{ role: "user", content: "a".repeat(maxQuestionCharacters + 1) }]
    }),
    (error) => error instanceof AskValidationError
      && /question is a little long/i.test(error.message)
  );
});

test("Botanist rejects conversations that do not end in a user turn", () => {
  assert.throws(
    () => validatedAsk({ conversation: [{ role: "assistant", content: "Hello" }] }),
    /question is required/i
  );
});

test("Botanist trims plant context and normalises optional UUIDs", () => {
  const result = validatedAsk({
    conversation: [{ role: "user", content: "Should I water it?" }],
    plantContext: "x".repeat(5_000),
    plantID: "A0E24564-4CF5-4B9C-A8A1-FAAE9198CDF6",
    threadID: ""
  });

  assert.equal(result.plantContext.length, 4_000);
  assert.equal(result.plantID, "a0e24564-4cf5-4b9c-a8a1-faae9198cdf6");
  assert.equal(result.threadID, null);
  assert.equal(result.safetyOnly, false);
});

test("Botanist accepts only a boolean safety-only probe", () => {
  const result = validatedAsk({
    conversation: [{ role: "user", content: "My cat ate a pothos leaf." }],
    safetyOnly: true
  });
  assert.equal(result.safetyOnly, true);

  assert.throws(
    () => validatedAsk({
      conversation: [{ role: "user", content: "Should I water it?" }],
      safetyOnly: "true"
    }),
    /safety-only option is invalid/i
  );
});

test("Botanist accepts one bounded JPEG photo on the current question", () => {
  const result = validatedAsk({
    conversation: [{ role: "user", content: "What are these spots?" }],
    photo: { mimeType: "image/jpeg", base64Data: jpeg }
  });

  assert.deepEqual(result.photo, { mimeType: "image/jpeg", base64Data: jpeg });
});

test("Botanist associates two bounded photos with their original user messages", () => {
  const result = validatedAsk({
    requestID: currentMessageID,
    conversation: [
      { id: previousMessageID, role: "user", content: "This was it last week." },
      { id: "c2e24564-4cf5-4b9c-a8a1-faae9198cdf6", role: "assistant", content: "Keep watching it." },
      { id: currentMessageID, role: "user", content: "Is it improving?" }
    ],
    attachments: [
      // The server canonicalizes comparison order even when a caller reverses it.
      { messageID: currentMessageID, mimeType: "image/jpeg", base64Data: jpeg },
      { messageID: previousMessageID, mimeType: "image/jpeg", base64Data: jpeg }
    ]
  });

  assert.equal(result.requestID, currentMessageID);
  assert.equal(result.attachments.length, maxPhotoAttachments);
  assert.deepEqual(result.attachments.map((photo) => photo.messageID), [
    previousMessageID,
    currentMessageID
  ]);
});

test("Botanist rejects ambiguous message identities and unbound replay ids", () => {
  assert.throws(
    () => validatedAsk({
      requestID: currentMessageID,
      conversation: [
        { id: currentMessageID, role: "user", content: "The earlier wording." },
        { id: currentMessageID, role: "user", content: "The current wording." }
      ]
    }),
    /unique id/i
  );
  assert.throws(
    () => validatedAsk({
      requestID: currentMessageID,
      conversation: [{ role: "user", content: "No message id is attached." }]
    }),
    /identify the current user message/i
  );
});

test("Botanist rejects orphaned, duplicate, or mixed-format photo attachments", () => {
  const conversation = [{ id: currentMessageID, role: "user", content: "What changed?" }];
  assert.throws(
    () => validatedAsk({
      conversation,
      attachments: [{
        messageID: previousMessageID,
        mimeType: "image/jpeg",
        base64Data: jpeg
      }]
    }),
    /belong to a user message/i
  );
  assert.throws(
    () => validatedAsk({
      conversation,
      attachments: [
        { messageID: currentMessageID, mimeType: "image/jpeg", base64Data: jpeg },
        { messageID: currentMessageID, mimeType: "image/jpeg", base64Data: jpeg }
      ]
    }),
    /one photo may be attached/i
  );
  assert.throws(
    () => validatedAsk({
      conversation,
      photo: { mimeType: "image/jpeg", base64Data: jpeg },
      attachments: [{ messageID: currentMessageID, mimeType: "image/jpeg", base64Data: jpeg }]
    }),
    /one attachment format/i
  );
});

test("Botanist rejects a mismatched or oversized attachment", () => {
  assert.throws(
    () => validatedAsk({
      conversation: [{ role: "user", content: "What is this?" }],
      photo: { mimeType: "image/png", base64Data: jpeg }
    }),
    (error) => error instanceof AskValidationError && /JPEG/i.test(error.message)
  );

  const oversized = Buffer.alloc(maxPhotoBytes + 1, 0xff).toString("base64");
  assert.throws(
    () => validatedAsk({
      conversation: [{ role: "user", content: "What is this?" }],
      photo: { mimeType: "image/jpeg", base64Data: oversized }
    }),
    (error) => error instanceof AskValidationError && /2 MB/i.test(error.message)
  );
});
