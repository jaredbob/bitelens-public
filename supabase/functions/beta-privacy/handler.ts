const policy = `BiteLens Beta Privacy Policy

BiteLens Beta keeps a meal and observation record for each approved tester. The beta administrator provisions your account and uses your email to manage sign-in, access, and support. Supabase Auth handles your password and issues sign-in tokens. The app stores its session in the iPhone Keychain.

Your record

The app saves your drafts, images, history, preferences, and pending changes in an account-specific area on your iPhone. Supabase hosts your confirmed meals, meal items, symptom entries, binge-eating urges, and the information needed to sync edits and deletions. Approved testers can access their own cloud records. The beta uploads changes when connected. A fresh install starts with an empty local history.

Meal Images stay on your iPhone apart from the analysis transfer described below. They expire seven days after capture or sharing. BiteLens removes expired images when it runs and can access them. The beta uses a separate backend project.

Optional Apple Health sharing

In beta versions with Apple Health support, you can choose separately in Settings to share meal nutrient totals and alcohol intake, or symptom type, time, and severity where available. Symptom sharing also records increased appetite at the time of an urge when you confirm it by saving a binge-eating urge. Meal images, notes, urge intensity, and meal links stay in BiteLens. BiteLens uses results of its Apple Health queries only on your iPhone to maintain its exported entries.

The first account to opt in can share from that installation. Signing out, switching accounts, or turning sharing off pauses exports and keeps entries already in Apple Health. You can manage write permissions and remove existing entries in the Health app.

Optional meal analysis

If you grant permission and request a Meal Estimate, BiteLens sends the image and any notes or your written meal description through Supabase to the provider you select. An image can include identifiable information visible on a receipt. OpenAI receives your OpenAI requests. xAI receives your Grok requests. Each provider processes the request to return an estimate. Avoid including details unrelated to the meal. BiteLens requests that providers disable storage of the response. Provider retention for security and abuse monitoring may still apply.

OpenAI API data controls
https://developers.openai.com/api/docs/guides/your-data

xAI API data and privacy
https://docs.x.ai/developers/faq/security

BiteLens keeps a daily attempt count for your account to enforce the limit across providers. You can withdraw permission for either provider in Settings. This stops future requests to that provider until you give permission again. Manual logging and sync remain available.

Access, retention, and deletion

BiteLens keeps cloud records while your account participates in the beta. Signing out closes your local record and preserves its data for your next sign-in on that iPhone. Revoking your approval blocks access to cloud services and preserves records for possible reinstatement. When you delete a synced record, BiteLens retains the identifiers and revision information needed to prevent a retry from restoring it.

Contact beta support to request deletion of your account and cloud records, ask about retained data, or get help removing the app’s local copy. To remove the local record from your iPhone, use Delete App.

Contact

Use the beta support address shown on the BiteLens Beta sign-in screen or the feedback email in TestFlight for privacy requests, account setup, or password recovery.
`;

export function servePrivacyPolicy(request: Request): Response {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
  }

  return new Response(request.method === "GET" ? policy : null, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}
