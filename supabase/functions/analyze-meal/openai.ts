import { createResponsesProvider, type ResponsesConfig } from "./responses.ts";

export function createOpenAIProvider(config: ResponsesConfig) {
  return createResponsesProvider(config, {
    endpoint: "https://api.openai.com/v1/responses",
    version: "openai-v4",
    requestOptions: { background: false },
    imageOptions: { detail: "auto" },
  });
}
