# Use confirmation time for missing meal sync timestamps

Some Logged Meals predate server write timestamps and would be invisible to
readers polling by update time. Fill only missing creation and update times
from the recorded confirmation time, accepting that this is an approximation of
the historical server write. Readers with an existing sync checkpoint need one
full reconciliation because a backfilled update time can predate that checkpoint.
