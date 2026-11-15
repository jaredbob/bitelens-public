import { createResponsesProvider, type ResponsesConfig } from "./responses.ts";

export function createGrokProvider(config: ResponsesConfig) {
  return createResponsesProvider(config, {
    endpoint: "https://api.x.ai/v1/responses",
    version: "grok-v4",
  });
}
