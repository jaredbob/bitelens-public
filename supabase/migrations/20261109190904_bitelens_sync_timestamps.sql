begin;

-- The writer checks tombstones before meals. Take the schema locks in that
-- order too. Set the default after adding the column to keep old times unknown.
alter table bitelens_private.meal_tombstones add column deleted_at timestamptz;
alter table bitelens_private.meal_tombstones
    alter column deleted_at set default pg_catalog.clock_timestamp();

alter table public.bitelens_meals
    alter column created_at set default pg_catalog.clock_timestamp(),
    alter column updated_at set default pg_catalog.clock_timestamp();

update public.bitelens_meals
set created_at = coalesce(created_at, confirmed_at),
    updated_at = coalesce(updated_at, confirmed_at)
where created_at is null or updated_at is null;

alter table public.bitelens_meals
    alter column created_at set not null,
    alter column updated_at set not null;

comment on column public.bitelens_meals.created_at is
    'First server save time. Missing legacy values were filled from confirmed_at.';
comment on column public.bitelens_meals.updated_at is
    'Most recent accepted server write time. Missing legacy values were filled from confirmed_at.';
comment on column bitelens_private.meal_tombstones.deleted_at is
    'When the server first accepted the deletion. NULL for deletions predating this column.';

comment on column public.bitelens_meal_items.calories_kcal is
    'Total kilocalories for the entire Consumed Portion of this Meal Item.';
comment on column public.bitelens_meal_items.protein_grams is
    'Total protein in grams for the entire Consumed Portion of this Meal Item.';
comment on column public.bitelens_meal_items.carbohydrates_grams is
    'Total carbohydrates in grams for the entire Consumed Portion of this Meal Item.';
comment on column public.bitelens_meal_items.fat_grams is
    'Total fat in grams for the entire Consumed Portion of this Meal Item.';
comment on column public.bitelens_meal_items.fiber_grams is
    'Total fiber in grams for the entire Consumed Portion of this Meal Item.';
comment on column public.bitelens_meal_items.sodium_milligrams is
    'Total sodium in milligrams for the entire Consumed Portion of this Meal Item.';
comment on column public.bitelens_meal_items.alcohol_grams is
    'Total pure alcohol in grams for the entire Consumed Portion of this Meal Item.';
comment on column public.bitelens_meal_items.caffeine_milligrams is
    'Total caffeine in milligrams for the entire Consumed Portion of this Meal Item.';
comment on column public.bitelens_meal_items.added_sugar_grams is
    'Total added sugar in grams for the entire Consumed Portion of this Meal Item.';

notify pgrst, 'reload schema';
commit;
