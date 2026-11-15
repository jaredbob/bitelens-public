import { strict as assert } from "node:assert";
import { test } from "node:test";
import { createAnalysisHandler } from "../functions/analyze-meal/handler.ts";
import { createGrokProvider } from "../functions/analyze-meal/grok.ts";
import { createOpenAIProvider } from "../functions/analyze-meal/openai.ts";

const ownerID = "00000000-0000-4000-8000-000000000001";
const testerID = "759c33f8-a884-437b-a5ff-e82f0457fe43";
const reservationID = "8a92fb66-8bb1-437c-901c-a1045904c21f";
const providerIDs = ["openai", "grok"] as const;
const now = 1_800_000_000_000;
const photo = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAAf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AH//Z";
const estimate = {
  image_kind: "food_photo",
  order_time: null,
  items: [{
    name: "  Spring roll  ", description: "Vegetable spring rolls", grams: 250, count: 5, purchased_quantity: null,
    serving_description: "pieces",
    nutrients: { calories_kcal: 400, protein_g: 10, carbohydrates_g: 70, fat_g: 12, fiber_g: 5,
      sodium_mg: null, alcohol_g: 0, caffeine_mg: null, added_sugar_g: 5 },
  }],
};
const completed = {
  status: "completed", model: "fixture-actual-snapshot", error: null,
  output: [
    { type: "reasoning" },
    { type: "message", role: "assistant", status: "completed",
      content: [{ type: "output_text", text: JSON.stringify(estimate) }] },
  ],
};

function request(body: unknown = {
  provider: "openai", captured_at_ms: now - 1, photo_base64: photo, notes: "Half a bowl",
}, token: string | null = "owner-fixture-token") {
  const headers = new Headers({ "Content-Type": "application/json", apikey: "public-fixture-key" });
  if (token) headers.set("Authorization", "Bearer " + token);
  return new Request("https://supabase.test/functions/v1/analyze-meal", {
    method: "POST", headers, body: JSON.stringify(body),
  });
}

function fixture(options: {
  user?: { id: string; role: string; is_anonymous?: boolean };
  authStatus?: number;
  betaApproval?: () => Response;
  betaReservation?: (init: RequestInit) => Response;
  betaRefund?: () => Response;
  clock?: () => number;
  providerResponse?: (init: RequestInit) => Promise<Response> | Response;
  reportOpenAIFailure?: Parameters<typeof createOpenAIProvider>[0]["reportFailure"];
  timeoutMs?: number;
  disableProvider?: (typeof providerIDs)[number];
} = {}) {
  const calls: Record<"auth" | "approval" | "reservation" | "refund" | (typeof providerIDs)[number], RequestInit[]> = {
    auth: [], approval: [], reservation: [], refund: [], openai: [], grok: [],
  };
  const network: typeof fetch = async (input, init = {}) => {
    switch (String(input)) {
      case "https://supabase.test/auth/v1/user":
        calls.auth.push(init);
        return Response.json(options.user ?? { id: ownerID, role: "authenticated" }, {
          status: options.authStatus ?? 200,
        });
      case "https://supabase.test/rest/v1/rpc/bitelens_is_approved":
        calls.approval.push(init);
        return options.betaApproval?.() ?? Response.json(false);
      case "https://supabase.test/rest/v1/rpc/bitelens_reserve_meal_estimate":
        calls.reservation.push(init);
        return options.betaReservation?.(init) ?? Response.json(
          JSON.parse(String(init.body)).p_photo_expires_at ? { reserved: true, reservation_id: reservationID } : { reserved: true },
        );
      case "https://supabase.test/rest/v1/rpc/bitelens_refund_meal_estimate":
        calls.refund.push(init);
        return options.betaRefund?.() ?? Response.json(null);
      case "https://api.openai.com/v1/responses":
        calls.openai.push(init);
        return options.providerResponse?.(init) ?? Response.json(completed);
      case "https://api.x.ai/v1/responses":
        calls.grok.push(init);
        return options.providerResponse?.(init) ?? Response.json(completed);
      default:
        throw new Error("Unexpected outbound request");
    }
  };
  const providers = {
    openai: createOpenAIProvider({
      key: "fixture-openai", model: "fixture-openai-model", fetch: network,
      reportFailure: options.reportOpenAIFailure,
    }),
    grok: createGrokProvider({ key: "fixture-grok", model: "fixture-grok-model", fetch: network }),
  };
  if (options.disableProvider) delete (providers as Partial<typeof providers>)[options.disableProvider];
  return {
    calls,
    analyze: createAnalysisHandler({
      authURL: "https://supabase.test", authKey: "public-server-fixture-key",
      access: options.betaApproval
        ? { kind: "beta", allowance: { key: "sb_secret_fixture", dailyLimit: 2 } }
        : { kind: "owner", ownerID },
      providers,
      fetch: network, now: options.clock ?? (() => now), providerTimeoutMs: options.timeoutMs,
    }),
  };
}

const otherProvider = (provider: (typeof providerIDs)[number]) => provider === "openai" ? "grok" : "openai";

test("both beta providers reserve against one verified account and report the UTC reset", async () => {
  let reservations = 0;
  const { analyze, calls } = fixture({
    user: { id: testerID, role: "authenticated" },
    betaApproval: () => Response.json(true),
    betaReservation: () => Response.json(++reservations <= 2
      ? { reserved: true, reservation_id: reservationID }
      : { error: "allowance_exhausted", reset_at: "2027-01-16T00:00:00+00:00" }),
  });
  const send = (provider: (typeof providerIDs)[number]) => analyze(request({
    provider, captured_at_ms: now - 1, photo_base64: photo, user_id: ownerID, limit: 100,
  }, "tester-token"));

  assert.equal((await send("openai")).status, 200);
  assert.equal((await send("grok")).status, 200);
  const limited = await send("openai");
  assert.equal(limited.status, 429);
  assert.deepEqual(await limited.json(), { error: "allowance_exhausted", reset_at: "2027-01-16T00:00:00.000Z" });
  assert.equal(calls.openai.length, 1);
  assert.equal(calls.grok.length, 1);
  assert.equal(calls.refund.length, 0);
  assert.equal(calls.reservation.length, 3);
  for (const call of calls.reservation) {
    const headers = new Headers(call.headers);
    assert.equal(headers.get("apikey"), "sb_secret_fixture");
    assert.equal(headers.has("authorization"), false);
    assert.deepEqual(JSON.parse(String(call.body)), {
      p_user_id: testerID, p_daily_limit: 2, p_photo_expires_at: "2027-01-22T07:59:59.999Z",
    });
  }
});

test("beta checks live approval for the verified caller on every request", async () => {
  let approved = false;
  const { analyze, calls } = fixture({
    user: { id: testerID, role: "authenticated" },
    betaApproval: () => Response.json(approved),
  });
  const estimateRequest = (provider: (typeof providerIDs)[number]) =>
    request({ provider, captured_at_ms: now - 1, photo_base64: photo }, "tester-token");
  const unapproved = estimateRequest("openai");
  const denied = await analyze(unapproved);
  assert.equal(denied.status, 403);
  assert.deepEqual(await denied.json(), { error: "approval_required" });
  assert.equal(unapproved.bodyUsed, false);
  assert.equal(calls.openai.length + calls.grok.length, 0);
  assert.equal(calls.reservation.length, 0);

  approved = true;
  for (const provider of providerIDs) {
    assert.equal((await analyze(estimateRequest(provider))).status, 200);
  }
  approved = false;
  for (const provider of providerIDs) {
    assert.equal((await analyze(estimateRequest(provider))).status, 403);
    assert.equal(calls[provider].length, 1);
  }
  assert.equal(calls.auth.length, 5);
  assert.equal(calls.approval.length, 5);
  assert.equal(calls.reservation.length, 2);
  for (const call of calls.approval) {
    assert.equal(call.method, "POST");
    assert.equal(new Headers(call.headers).get("authorization"), "Bearer tester-token");
    assert.equal(new Headers(call.headers).get("apikey"), "public-server-fixture-key");
    assert.deepEqual(JSON.parse(String(call.body)), {});
  }
});

test("beta stops before provider work when identity or approval cannot be verified", async () => {
  for (const options of [
    { authStatus: 401, expectedStatus: 401, expectedApprovals: 0 },
    { user: { id: testerID, role: "authenticated", is_anonymous: true }, expectedStatus: 403, expectedApprovals: 0 },
    { user: { id: "", role: "authenticated" }, expectedStatus: 403, expectedApprovals: 0 },
    { user: { id: testerID, role: "service_role" }, expectedStatus: 403, expectedApprovals: 0 },
    { betaApproval: () => Response.json({ approved: true }), expectedStatus: 503, expectedApprovals: 1 },
    { betaApproval: () => Response.json(null, { status: 503 }), expectedStatus: 503, expectedApprovals: 1 },
  ]) {
    const { analyze, calls } = fixture({ betaApproval: () => Response.json(true), ...options });
    const incoming = request(undefined, "tester-token");
    assert.equal((await analyze(incoming)).status, options.expectedStatus);
    assert.equal(incoming.bodyUsed, false);
    assert.equal(calls.approval.length, options.expectedApprovals);
    assert.equal(calls.reservation.length, 0);
    assert.equal(calls.openai.length + calls.grok.length, 0);
  }
});

test("invalid beta inputs and unavailable adapters do not reserve an attempt", async () => {
  const { analyze, calls } = fixture({ betaApproval: () => Response.json(true), disableProvider: "grok" });
  for (const [body, expectedStatus] of [
    [{ provider: "openai", description: "   " }, 400],
    [{ provider: "openai", captured_at_ms: now - 1, photo_base64: "invalid!" }, 400],
    [{ provider: "openai", captured_at_ms: now - 168 * 60 * 60 * 1_000, photo_base64: photo }, 410],
    [{ provider: "grok", description: "One bowl of soup" }, 503],
  ] as const) {
    assert.equal((await analyze(request(body))).status, expectedStatus);
  }
  assert.equal(calls.reservation.length, 0);
  assert.equal(calls.openai.length + calls.grok.length, 0);
});

test("a beta reservation rechecks approval and fails closed before sending meal data", async () => {
  for (const [body, status, expectedStatus, error] of [
    [{ error: "approval_required" }, 200, 403, "approval_required"],
    [{ error: "photo_expired" }, 200, 410, "photo_expired"],
    [{ error: "allowance_exhausted", reset_at: "invalid" }, 200, 503, "allowance_unavailable"],
    [{ error: "unknown", reserved: true }, 200, 503, "allowance_unavailable"],
    [{ reserved: true }, 200, 503, "allowance_unavailable"],
    [{}, 200, 503, "allowance_unavailable"],
    [{}, 503, 503, "allowance_unavailable"],
  ] as const) {
    const { analyze, calls } = fixture({
      betaApproval: () => Response.json(true), betaReservation: () => Response.json(body, { status }),
    });
    const response = await analyze(request());
    assert.equal(response.status, expectedStatus);
    assert.deepEqual(await response.json(), { error });
    assert.equal(calls.reservation.length, 1);
    assert.equal(calls.openai.length + calls.grok.length, 0);
  }
});

test("a beta image crossing its cutoff during the reservation stays private and returns its attempt", async () => {
  let clock = now;
  let refunds = 0;
  const { analyze, calls } = fixture({
    clock: () => clock,
    betaApproval: () => Response.json(true),
    betaReservation: () => {
      clock++;
      return Response.json({ reserved: true, reservation_id: reservationID });
    },
    betaRefund: () => ++refunds === 1 ? new Response(null, { status: 503 }) : Response.json(null),
  });
  const response = await analyze(request({ provider: "openai", captured_at_ms: now - 168 * 60 * 60 * 1_000 + 1, photo_base64: photo }));
  assert.equal(response.status, 410);
  assert.deepEqual(await response.json(), { error: "photo_expired" });
  assert.equal(calls.openai.length + calls.grok.length, 0);
  assert.equal(calls.refund.length, 2);
  for (const call of calls.refund) {
    assert.equal(new Headers(call.headers).get("apikey"), "sb_secret_fixture");
    assert.deepEqual(JSON.parse(String(call.body)), { p_reservation_id: reservationID });
  }
});

test("both providers can return receipt quantities and an order-time suggestion", async () => {
  const receipt = {
    image_kind: "receipt",
    order_time: "2026-10-14T18:24-05:00",
    items: [{ ...estimate.items[0], purchased_quantity: 5 }],
  };
  for (const provider of providerIDs) {
    for (const [items, order_time] of [[receipt.items, "15:02"], [[], receipt.order_time]] as const) {
      const { analyze } = fixture({ providerResponse: () => Response.json({
        ...completed,
        output: [{ ...completed.output[1], content: [{ type: "output_text", text: JSON.stringify({ ...receipt, items, order_time }) }] }],
      }) });
      const response = await analyze(request({ provider, captured_at_ms: now - 1, photo_base64: photo }));
      assert.equal(response.status, 200);
      assert.deepEqual(await response.json(), {
        ...receipt,
        items: items.map((item) => ({ ...item, name: "Spring roll" })),
        order_time,
        provenance: { provider, model: "fixture-actual-snapshot", version: `meal-estimate-v3/${provider}-v4` },
      });
    }
  }
});

for (const provider of providerIDs) {
  test(`owner gets a normalized incomplete estimate from ${provider}`, async () => {
    const { analyze, calls } = fixture();
    const response = await analyze(request({ provider, captured_at_ms: now - 1, photo_base64: photo, notes: "Half a bowl" }));
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.deepEqual(await response.json(), {
      ...estimate,
      items: [{ ...estimate.items[0], name: "Spring roll" }],
      provenance: { provider, model: "fixture-actual-snapshot", version: `meal-estimate-v3/${provider}-v4` },
    });
    assert.equal(new Headers(calls.auth[0].headers).get("authorization"), "Bearer owner-fixture-token");
    assert.equal(new Headers(calls.auth[0].headers).get("apikey"), "public-server-fixture-key");
    assert.equal(calls[provider].length, 1);
    assert.equal(calls[otherProvider(provider)].length, 0);
    assert.equal(new Headers(calls[provider][0].headers).get("authorization"), `Bearer fixture-${provider}`);
    const sent = JSON.parse(String(calls[provider][0].body));
    assert.equal(sent.model, `fixture-${provider}-model`);
    assert.equal(sent.store, false);
    assert.equal(sent.background, provider === "openai" ? false : undefined);
    assert.equal(sent.conversation, undefined);
    assert.equal(sent.previous_response_id, undefined);
    assert.deepEqual(sent.input[0].content, [
      { type: "input_text", text: "Optional meal context: Half a bowl" },
      { type: "input_image", image_url: "data:image/jpeg;base64," + photo, ...(provider === "openai" ? { detail: "auto" } : {}) },
    ]);
    const format = sent.text.format;
    assert.equal(format.type, "json_schema");
    assert.equal(format.strict, true);
    assert.equal(format.schema.additionalProperties, false);
    const nutrients = format.schema.properties.items.items.properties.nutrients;
    assert.equal(nutrients.additionalProperties, false);
    assert.deepEqual(nutrients.required, ["calories_kcal", "protein_g", "carbohydrates_g", "fat_g", "fiber_g",
      "sodium_mg", "alcohol_g", "caffeine_mg", "added_sugar_g"]);
    assert.deepEqual(format.schema.properties.items.items.properties.count.type, ["number", "null"]);
    assert.deepEqual(nutrients.properties.sodium_mg.type, ["number", "null"]);
  });

  test(`owner gets an estimate from text alone with ${provider}`, async () => {
    const textEstimate = { ...estimate, image_kind: "unknown" };
    const { analyze, calls } = fixture({ providerResponse: () => Response.json({
      ...completed,
      output: [{ ...completed.output[1], content: [{ type: "output_text", text: JSON.stringify(textEstimate) }] }],
    }) });
    const response = await analyze(request({ provider, description: "  Five vegetable spring rolls  " }));
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.deepEqual(await response.json(), {
      ...textEstimate,
      image_kind: null,
      items: [{ ...estimate.items[0], name: "Spring roll" }],
      provenance: { provider, model: "fixture-actual-snapshot", version: `meal-estimate-v3/${provider}-v4-text-v1` },
    });
    const sent = JSON.parse(String(calls[provider][0].body));
    assert.deepEqual(sent.input[0].content, [{ type: "input_text", text: "Five vegetable spring rolls" }]);
    assert.equal(sent.store, false);
    assert.equal(calls[otherProvider(provider)].length, 0);
  });
}

test("blank, oversized, and mixed-source descriptions never reach a provider", async () => {
  const { analyze, calls } = fixture();
  for (const fields of [
    { description: " \n\t" },
    { description: null },
    { description: "🍜".repeat(1_001) },
    { description: "Soup", photo_base64: photo },
    { description: "Soup", captured_at_ms: now - 1 },
    { description: "Soup", notes: "" },
  ]) {
    const response = await analyze(request({ provider: "openai", ...fields }));
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), { error: "invalid_request" });
  }
  assert.equal(calls.openai.length + calls.grok.length, 0);
});

test("text estimates allow no identifiable items and reject receipt metadata", async () => {
  for (const [textEstimate, status] of [
    [{ image_kind: "unknown", order_time: null, items: [] }, 200],
    [{ ...estimate, image_kind: "receipt", order_time: "15:02" }, 422],
    [{ ...estimate, image_kind: "unknown", order_time: "15:02" }, 422],
    [{ ...estimate, image_kind: "unknown", items: [{ ...estimate.items[0], purchased_quantity: 5 }] }, 422],
  ] as const) {
    const { analyze } = fixture({ providerResponse: () => Response.json({
      ...completed,
      output: [{ ...completed.output[1], content: [{ type: "output_text", text: JSON.stringify(textEstimate) }] }],
    }) });
    const response = await analyze(request({ provider: "openai", description: "Lunch" }));
    assert.equal(response.status, status);
  }
});

test("unsigned, invalid, unapproved, and anonymous callers cannot consume the photo body", async () => {
  for (const entry of [
    { token: null, status: 401, options: {} },
    { token: "invalid", status: 401, options: { authStatus: 401 } },
    { token: "other", status: 403, options: { user: { id: "different-id", role: "authenticated" } } },
    { token: "anonymous", status: 403, options: { user: { id: ownerID, role: "authenticated", is_anonymous: true } } },
    { token: "service", status: 403, options: { user: { id: ownerID, role: "service_role" } } },
  ]) {
    const { analyze, calls } = fixture(entry.options);
    const incoming = request("deliberately invalid photo request", entry.token);
    assert.equal((await analyze(incoming)).status, entry.status);
    assert.equal(incoming.bodyUsed, false);
    assert.equal(calls.openai.length + calls.grok.length, 0);
    assert.equal(calls.auth.length, entry.token === null ? 0 : 1);
  }
});

test("unavailable selection, expired captures, and invalid images never reach a provider", async () => {
  const valid = { provider: "openai", captured_at_ms: now - 1, photo_base64: photo };
  for (const [changes, status, code] of [
    [{ provider: undefined }, 400, "invalid_provider"],
    [{ captured_at_ms: now - 168 * 60 * 60 * 1_000 }, 410, "photo_expired"],
    [{ captured_at_ms: now + 1 }, 400, "invalid_request"],
    [{ photo_base64: "bm90IGFuIGltYWdl" }, 400, "invalid_photo"],
    [{ photo_base64: "/9j/2Q==" }, 400, "invalid_photo"],
    [{ photo_base64: "A".repeat(5_700_000) }, 413, "request_too_large"],
    [{ notes: "a".repeat(2_001) }, 400, "invalid_request"],
  ] as const) {
    const { analyze, calls } = fixture();
    const response = await analyze(request({ ...valid, ...changes }));
    assert.equal(response.status, status);
    assert.deepEqual(await response.json(), { error: code });
    assert.equal(calls.openai.length + calls.grok.length, 0);
  }
  for (const provider of providerIDs) {
    const { analyze, calls } = fixture({ disableProvider: provider });
    assert.equal((await analyze(request({ ...valid, provider }))).status, 503);
    assert.equal(calls.openai.length + calls.grok.length, 0);
  }
});

test("failed, refused, incomplete and schema-invalid responses expose only stable errors", async () => {
  const message = completed.output[1];
  const withContent = (content: unknown[]) => ({ ...completed, output: [{ ...message, content }] });
  const withEstimate = (value: unknown) => withContent([{ type: "output_text", text: JSON.stringify(value) }]);
  const withNutrients = (nutrients: unknown) => withEstimate({ ...estimate, items: [{ ...estimate.items[0], nutrients }] });
  const cases = [
    [() => Response.json({ private: "do not return" }, { status: 429 }), 503, "provider_unavailable"],
    [() => Response.json({ ...completed, status: "incomplete" }), 422, "invalid_estimate"],
    [() => Response.json({ ...completed, model: undefined }), 422, "invalid_estimate"],
    [() => Response.json(withContent([{ type: "refusal", refusal: "do not return" }])), 422, "refused"],
    [() => Response.json(withContent([{ type: "output_text", text: "not JSON" }])), 422, "invalid_estimate"],
    [() => Response.json(withNutrients({ ...estimate.items[0].nutrients, sodium_mg: undefined })), 422, "invalid_estimate"],
    [() => Response.json(withNutrients({ ...estimate.items[0].nutrients, fiber_g: -1 })), 422, "invalid_estimate"],
    [() => Response.json(withNutrients({ ...estimate.items[0].nutrients, fiber_g: "0" })), 422, "invalid_estimate"],
    [() => Response.json(withNutrients({ ...estimate.items[0].nutrients, extra: 1 })), 422, "invalid_estimate"],
    [() => Response.json(withEstimate({ ...estimate, items: [{ ...estimate.items[0], count: 0 }] })), 422, "invalid_estimate"],
  ] as const;
  for (const provider of providerIDs) {
    for (const [providerResponse, status, code] of cases) {
      const { analyze, calls } = fixture({ providerResponse });
      const response = await analyze(request({ provider, captured_at_ms: now - 1, photo_base64: photo }));
      assert.equal(response.status, status);
      assert.deepEqual(await response.json(), { error: code });
      assert.equal(calls[provider].length, 1);
      assert.equal(calls[otherProvider(provider)].length, 0);
    }
  }
});

test("OpenAI rejection diagnostics omit upstream request data and credentials", async () => {
  const diagnostics: unknown[] = [];
  const { analyze } = fixture({
    providerResponse: () => Response.json({
      error: { code: "insufficient_quota", message: "private fixture", param: "private fixture" },
    }, { status: 429 }),
    reportOpenAIFailure: (failure) => diagnostics.push(failure),
  });
  const response = await analyze(request());
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "provider_unavailable" });
  assert.deepEqual(diagnostics, [{
    kind: "rejected", status: 429, code: "insufficient_quota", parameter: undefined,
  }]);
});

for (const provider of providerIDs) {
  test(`the ${provider} deadline returns a recoverable timeout without fallback`, async () => {
    let reserved = false;
    const { analyze, calls } = fixture({
      betaApproval: () => Response.json(true),
      betaReservation: () => {
        if (reserved) return Response.json({ error: "allowance_exhausted", reset_at: "2027-01-16T00:00:00Z" });
        reserved = true;
        return Response.json({ reserved: true, reservation_id: reservationID });
      },
      timeoutMs: 5,
      providerResponse: ({ signal }) => new Promise((_resolve, reject) => {
        const keepAlive = setTimeout(() => reject(new Error("provider did not receive deadline")), 1_000);
        signal!.addEventListener("abort", () => {
          clearTimeout(keepAlive);
          reject(signal!.reason);
        }, { once: true });
      }),
    });
    const response = await analyze(request({ provider, captured_at_ms: now - 1, photo_base64: photo }));
    assert.equal(response.status, 504);
    assert.deepEqual(await response.json(), { error: "timeout" });
    const retry = await analyze(request({ provider: otherProvider(provider), description: "One bowl of soup" }));
    assert.equal(retry.status, 429);
    assert.equal(calls[provider].length, 1);
    assert.equal(calls[otherProvider(provider)].length, 0);
  });
}
