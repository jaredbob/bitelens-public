# BiteLens

BiteLens supports personal food tracking by estimating meal contents, portions,
and nutrients from Meal Images and recording meals after review.

## Language

**BiteLens Account**:
A sign-in identity for one person's private BiteLens record.

**Meal**:
Food and drink consumed during one eating occasion, including a snack.

**Meal Image**:
An image used to estimate a Meal, such as a Meal Photo or an image of an
itemized receipt.

**Meal Photo**:
A Meal Image that shows the food or drink itself.

**Meal Item**:
A separately recorded food or drink in a Meal that can group interchangeable
pieces. Its nutrient amounts describe the entire Consumed Portion.

**Meal Estimate**:
An AI-generated description of a meal's contents with approximate portion sizes
and nutrient amounts. It can be corrected before the meal is logged.

**Original Item Estimate**:
The AI's identification, description, portion, and nutrient amounts for a Meal
Item before any corrections by the person logging it.

**Incomplete Estimate**:
A Meal Estimate with one or more unknown tracked nutrient values. Totals that
depend on an unknown value are also incomplete.

**Meal Draft**:
A captured meal awaiting analysis or confirmation. It does not yet count as a
Logged Meal.

**Consumed Portion**:
The total amount of a Meal Item actually consumed, which can differ from the
amount shown in a Meal Photo or listed on a receipt.

**Consumed Count**:
How many pieces or units of the same food or drink were consumed as part of one
Meal Item, when a count is meaningful.

**Purchased Quantity**:
How many units of a food or drink a receipt lists as ordered. It can serve as
the initial portion suggestion during review.

**Logged Meal**:
A meal whose contents, consumed portions, and estimated nutrients have been
reviewed and confirmed for the personal food record.

**Symptom Entry**:
A self-reported observation of one symptom at a chosen date and time, with
optional severity and notes. Repeated observations are separate entries.

**Binge-Eating Urge**:
A self-reported urge to binge eat at a chosen date and time, with optional
intensity and notes. It can stand on its own or be linked to one Logged Meal
eaten in response to the urge.

**Apple Health Sync**:
The optional transfer of nutrient totals and alcohol intake for Logged Meals
from BiteLens to Apple Health.

**Apple Health Backfill**:
An action in Settings that brings recent Logged Meals on the iPhone into ongoing
Apple Health Sync. It covers today and the previous 29 calendar days by recorded
local Meal Time.
