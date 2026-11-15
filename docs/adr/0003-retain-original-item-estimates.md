# Retain original item estimates for confirmed meals

Measuring the size and direction of a correction requires both the original and
current values. Preserve the normalized Original Item Estimate for each
AI-derived item that becomes part of a Logged Meal. The current values determine
whether the item shows as corrected, so restoring the original clears the marker.
Limit the stored comparison to those two structured versions and keep drafts on
the phone under [ADR 0002](0002-normalize-ai-provider-estimates.md).
