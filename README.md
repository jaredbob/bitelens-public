# BiteLens

A personal native iPhone app for reviewing and recording photo-based meal estimates.
Targets iOS 18 or newer. It includes existing-account email/password sign-in, secure session
retention, approved-owner gating, explicit OpenAI/Grok selection, and camera-first offline capture.
Meal Drafts, optional notes, and chosen meal times persist locally. Private photos expire exactly
168 hours after capture. Review and correct an estimate, or enter a meal manually.
Confirmation, edits, and deletions update history and daily totals offline.
When the app is active and online, the confirmed structured changes sync to Supabase.

```sh
scripts/test-core.sh
scripts/test-ui.sh
scripts/generate-xcode-project.py
open BiteLens.xcodeproj
```

The Swift package has no third-party dependencies. The checked-in Xcode project uses its local
`BiteLensCore` product. Regenerate the project after changing project membership or settings.

The app requires your own Supabase project for sign-in and sync. Copy
[the local configuration example](App/Config/Local.xcconfig.example) to
App/Config/Local.xcconfig and follow [Supabase setup](docs/supabase-migrations.md).
The simulator smoke tests use synthetic configuration and fixtures.

See [iPhone setup and acceptance](docs/ios-setup.md),
[workflow integration](docs/workflow-integration.md),
[onboarding validation](docs/testing/onboarding.md),
[capture and draft validation](docs/testing/drafts.md), and
[iOS UI smoke tests](docs/testing/ui-smoke.md). For server setup and verification,
see [meal sync](docs/testing/meal-sync.md) and [meal analysis](docs/testing/meal-analysis.md).

See [TestFlight releases](docs/testflight.md) for the GitHub release checks and local signing steps.
