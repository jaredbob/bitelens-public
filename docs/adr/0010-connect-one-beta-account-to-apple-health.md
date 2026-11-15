# Connect one Beta account to Apple Health per installation

HealthKit authorizes the app and writes to the iPhone’s Health record, which is
shared across BiteLens Accounts on that installation. The first account to opt
in to Apple Health Sync or Apple Health Symptom Sharing claims the connection
for the life of that installation. This prevents a second account from sending
its data to the same Health record through that installation.

Keep the two opt-ins and pending Health work with the connected account. Signing
out or switching accounts pauses its Health work and preserves existing samples.
Returning to the connected account resumes enabled exports. As with other local
work, an active account can export offline and after cloud approval is removed
until sign-out. See [ADR 0009](0009-isolate-multi-user-beta-from-personal-data.md).
