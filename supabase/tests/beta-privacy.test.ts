import { strict as assert } from "node:assert";
import { test } from "node:test";
import { servePrivacyPolicy } from "../functions/beta-privacy/handler.ts";

const policyURL = "https://supabase.test/functions/v1/beta-privacy";

test("visitors can read the beta privacy policy without signing in", async () => {
  const response = servePrivacyPolicy(new Request(policyURL));

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "text/plain; charset=utf-8");
  const policy = await response.text();
  assert.match(policy, /^BiteLens Beta Privacy Policy/);
  assert.match(policy, /OpenAI/);
  assert.match(policy, /xAI/);
  assert.match(policy, /request deletion/);
  assert.match(policy, /TestFlight/);
});

test("the policy URL accepts HEAD and rejects writes", async () => {
  const head = servePrivacyPolicy(new Request(policyURL, { method: "HEAD" }));
  assert.equal(head.status, 200);
  assert.equal(head.headers.get("Content-Type"), "text/plain; charset=utf-8");
  assert.equal(await head.text(), "");

  const post = servePrivacyPolicy(new Request(policyURL, { method: "POST", body: "data" }));
  assert.equal(post.status, 405);
  assert.equal(post.headers.get("Allow"), "GET, HEAD");
});
