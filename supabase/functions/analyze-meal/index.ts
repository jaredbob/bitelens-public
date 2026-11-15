import { createGrokProvider } from "./grok.ts";
import { createAnalysisHandler } from "./handler.ts";
import { createOpenAIProvider } from "./openai.ts";

const openAIKey = Deno.env.get("BITELENS_OPENAI_API_KEY")?.trim();
const openAIModel = Deno.env.get("BITELENS_OPENAI_MODEL")?.trim();
const grokKey = Deno.env.get("BITELENS_GROK_API_KEY")?.trim();
const grokModel = Deno.env.get("BITELENS_GROK_MODEL")?.trim();
const publishableKeys = JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") ?? "{}");
const authURL = Deno.env.get("SUPABASE_URL")?.replace(/\/$/, "");
const authKey = publishableKeys.default ?? Deno.env.get("SUPABASE_ANON_KEY");
const deployment = Deno.env.get("BITELENS_DEPLOYMENT")?.trim();
const ownerID = Deno.env.get("BITELENS_OWNER_ID")?.trim().toLowerCase();
const validOwner = ownerID && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(ownerID);
const access = deployment === "beta"
  ? { kind: "beta", allowance: betaAllowance() } as const
  : deployment === "personal" && validOwner
  ? { kind: "owner", ownerID } as const
  : undefined;
if (!authURL || !authKey || !access) throw new Error("Unrecognized BiteLens analysis deployment");

function betaAllowance() {
  const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
  const key = secretKeys.default ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const limit = Deno.env.get("BITELENS_MEAL_ESTIMATE_DAILY_LIMIT")?.trim() ?? "10";
  const dailyLimit = Number(limit);
  if (typeof key !== "string" || !key || !/^[1-9][0-9]*$/.test(limit) || dailyLimit > 2_147_483_647) {
    throw new Error("Invalid BiteLens Beta Meal Estimate allowance configuration");
  }
  return { key, dailyLimit };
}

Deno.serve(createAnalysisHandler({
  authURL,
  authKey,
  access,
  providers: {
    openai: openAIKey && openAIModel
      ? createOpenAIProvider({
        key: openAIKey,
        model: openAIModel,
        fetch,
        reportFailure: (failure) => console.warn("bitelens_openai_failure", JSON.stringify(failure)),
      })
      : undefined,
    grok: grokKey && grokModel
      ? createGrokProvider({ key: grokKey, model: grokModel, fetch })
      : undefined,
  },
  fetch,
}));
