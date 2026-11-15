# Export nutrient totals from the iPhone

Publish one HealthKit quantity sample per eligible Logged Meal and nutrient,
using the meal ID and nutrient type as its stable identity and the meal revision
as its version. This keeps food details in BiteLens and lets retries and edits
converge on the same Health entry. Persist eligibility, pending work, and Health
write outcomes on the iPhone independently of cloud upload acknowledgments, so
either destination can recover without blocking meal logging.
