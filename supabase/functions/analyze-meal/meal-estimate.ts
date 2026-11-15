export type ProviderID = "openai" | "grok";

export type AnalysisInput = { photoBase64: string; notes: string } | { description: string };

export interface ProviderOutput {
  estimate: unknown;
  model: string;
  version: string;
}

export interface AnalysisProvider {
  analyze(input: AnalysisInput, signal: AbortSignal): Promise<ProviderOutput>;
}

export class ProviderFailure extends Error {
  readonly code: "provider_unavailable" | "refused" | "invalid_estimate";

  constructor(code: ProviderFailure["code"]) {
    super(code);
    this.code = code;
  }
}

const nullableAmount = { type: ["number", "null"] };
const text = { type: "string" };
const nutrients = {
  calories_kcal: nullableAmount,
  protein_g: nullableAmount,
  carbohydrates_g: nullableAmount,
  fat_g: nullableAmount,
  fiber_g: nullableAmount,
  sodium_mg: nullableAmount,
  alcohol_g: nullableAmount,
  caffeine_mg: nullableAmount,
  added_sugar_g: nullableAmount,
};
const item = {
  name: text,
  description: text,
  grams: nullableAmount,
  count: nullableAmount,
  purchased_quantity: nullableAmount,
  serving_description: text,
  nutrients: closedObject(nutrients),
};

export const schemaName = "meal_estimate_v3";
export const schemaVersion = "meal-estimate-v3";
export const estimateSchema = closedObject({
  image_kind: { type: "string", enum: ["food_photo", "receipt", "unknown"] },
  order_time: { type: ["string", "null"] },
  items: { type: "array", items: closedObject(item) },
});

function closedObject(properties: Record<string, object>) {
  return { type: "object", properties, required: Object.keys(properties), additionalProperties: false };
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasFields(value: unknown, fields: string[]): value is Record<string, unknown> {
  return isRecord(value) && Object.keys(value).length === fields.length &&
    fields.every((key) => Object.hasOwn(value, key));
}

function boundedText(value: unknown, maxLength: number): value is string {
  return typeof value === "string" && value.length <= maxLength;
}

function validAmount(value: unknown): boolean {
  return value === null ||
    (typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 10_000_000);
}

function normalizedOrderTime(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const match = /^(\d{4}-\d{2}-\d{2}T)?((?:[01]\d|2[0-3]):[0-5]\d)(Z|[+-](?:0\d|1[0-3]):[0-5]\d|[+-]14:00)?$/.exec(value);
  if (!match || match[0] !== value) return null;
  if (!match[1]) return value;
  const localTime = match[1] + match[2];
  const date = new Date(localTime + ":00Z");
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 16) === localTime ? value : null;
}

export function normalizeEstimate(output: ProviderOutput, provider: ProviderID, expectsImage: boolean) {
  const { estimate, model, version } = output;
  if (!boundedText(model, 200) || !model.trim() ||
    !hasFields(estimate, Object.keys(estimateSchema.properties)) ||
    !Array.isArray(estimate.items) || estimate.items.length > 24) {
    throw new ProviderFailure("invalid_estimate");
  }
  const validSource = expectsImage
    ? estimate.image_kind === "food_photo" || estimate.image_kind === "receipt"
    : estimate.image_kind === "unknown" && estimate.order_time === null;
  if (!validSource) throw new ProviderFailure("invalid_estimate");

  const isReceipt = estimate.image_kind === "receipt";
  const orderTime = isReceipt ? normalizedOrderTime(estimate.order_time) : null;
  if (expectsImage && estimate.items.length === 0 && orderTime === null) throw new ProviderFailure("invalid_estimate");
  const items = estimate.items.map((value: unknown) => {
    if (!hasFields(value, Object.keys(item)) ||
      !boundedText(value.name, 120) || !value.name.trim() ||
      !boundedText(value.description, 500) || !value.description.trim() ||
      !boundedText(value.serving_description, 160) || !value.serving_description.trim() ||
      !validAmount(value.grams) || !validAmount(value.count) || value.count === 0 ||
      (value.purchased_quantity !== null && (!isReceipt || value.purchased_quantity !== value.count)) ||
      !hasFields(value.nutrients, Object.keys(nutrients)) ||
      !Object.values(value.nutrients).every(validAmount)) {
      throw new ProviderFailure("invalid_estimate");
    }
    return {
      name: value.name.trim(),
      description: value.description.trim(),
      grams: value.grams,
      count: value.count,
      purchased_quantity: value.purchased_quantity,
      serving_description: value.serving_description.trim(),
      nutrients: value.nutrients,
    };
  });
  return {
    image_kind: expectsImage ? estimate.image_kind : null,
    order_time: orderTime,
    items,
    provenance: { provider, model: model.trim(), version: schemaVersion + "/" + version },
  };
}
