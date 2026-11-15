#!/usr/bin/env python3
"""Exercise the deployed migration through the loopback Auth and REST APIs."""

import argparse
import json
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from threading import Barrier
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlencode, urlparse
from urllib.request import Request, urlopen
from uuid import UUID, uuid4


class LocalSupabase:
    def __init__(self, status_path):
        status = json.loads(Path(status_path).read_text())
        self.config = status.get("env", status)
        self.api_url = self.config["API_URL"]
        parsed = urlparse(self.api_url)
        assert parsed.scheme in {"http", "https"} and parsed.hostname in {
            "127.0.0.1", "::1"
        }, "Use an isolated loopback Supabase project"

    def request(self, method, path, body=None, token=None, admin=False, statuses=(200,)):
        modern_key, legacy_key = ("SECRET_KEY", "SERVICE_ROLE_KEY") if admin else ("PUBLISHABLE_KEY", "ANON_KEY")
        key = self.config.get(modern_key) or self.config[legacy_key]
        headers = {"apikey": key, "Content-Type": "application/json"}
        if admin and key == self.config.get("SERVICE_ROLE_KEY"):
            headers["Authorization"] = f"Bearer {key}"
        if token:
            headers["Authorization"] = f"Bearer {token}"
        data = None if body is None else json.dumps(body).encode()
        try:
            with urlopen(Request(self.api_url + path, data, headers, method=method), timeout=10) as response:
                status, content = response.status, response.read()
        except HTTPError as error:
            status, content = error.code, error.read()
        try:
            result = json.loads(content) if content else None
        except ValueError:
            result = None
        code = result.get("code") if isinstance(result, dict) else None
        assert status in statuses, f"{method} {path} returned {status} ({code}), expected {statuses}"
        return result

    def create_user(self, user_id=None, metadata=None):
        email = f"meal-sync-{uuid4()}@example.com"
        password = str(uuid4())
        body = {"email": email, "password": password, "email_confirm": True}
        if metadata:
            body["user_metadata"] = metadata
        if user_id:
            body["id"] = user_id
        user = self.request("POST", "/auth/v1/admin/users", body, admin=True)
        return user["id"], email, password

    def sign_in(self, user):
        _, email, password = user
        result = self.request("POST", "/auth/v1/token?grant_type=password",
                              {"email": email, "password": password})
        assert result["user"]["id"] == user[0]
        return result["access_token"]

    def delete_user(self, user):
        self.request("DELETE", "/auth/v1/admin/users/" + user[0], admin=True)

    def set_approved(self, user, approved):
        user_id = UUID(user[0])
        if approved:
            self.seed_fixture(
                f"insert into bitelens_private.approved_accounts (user_id) values ('{user_id}')"
                " on conflict (user_id) do nothing"
            )
        else:
            self.seed_fixture(f"delete from bitelens_private.approved_accounts where user_id = '{user_id}'")

    def save(self, meal, token, statuses=(200,)):
        return self.request("POST", "/rest/v1/rpc/bitelens_create_meal", {"p_meal": meal},
                            token, statuses=statuses)


    def sync(self, meal_id, owner_id, revision, meal, token, statuses=(200,)):
        return self.request("POST", "/rest/v1/rpc/bitelens_sync_meal", {
            "p_meal_id": meal_id, "p_user_id": owner_id, "p_revision": revision, "p_meal": meal,
        }, token, statuses=statuses)

    def seed_foreign_meal(self, owner, meal, item):
        # Privileged setup only. All verification uses the public API with
        # the publishable key and real user JWTs.
        sql = f"""
            with foreign_meal as (
                insert into public.bitelens_meals
                    (id, user_id, payload_hash, meal_at, local_date, time_zone, confirmed_at, notes)
                values ('{meal}', '{owner}', pg_catalog.sha256('fixture'::bytea),
                        '2026-11-08 04:30Z', '2026-11-07', 'America/Los_Angeles', now(), '')
                returning id, user_id
            )
            insert into public.bitelens_meal_items
                (id, user_id, meal_id, position, name, description, serving_description)
            select '{item}', user_id, id, 0, 'Foreign fixture', '', ''
            from foreign_meal
        """
        self.seed_fixture(sql)

    def seed_foreign_observation(self, owner, observation):
        self.seed_fixture(f"""
            insert into public.bitelens_observations
                (id, user_id, revision, kind, symptom_id, payload_hash, observed_at, local_date,
                 time_zone, created_at, updated_at)
            values ('{observation}', '{owner}', 1, 'symptom', 'headache', pg_catalog.sha256('fixture'::bytea),
                    '2026-11-08 04:30Z', '2026-11-07', 'America/Los_Angeles', now(), now())
        """)

    def seed_fixture(self, sql):
        target = self.config["DB_URL"]
        parsed = urlparse(target)
        assert parsed.hostname in {"127.0.0.1", "::1"}
        if "sslmode" not in parse_qs(parsed.query):
            target = parsed._replace(query="&".join(filter(None, (parsed.query, "sslmode=disable")))).geturl()
        env = dict(os.environ, SUPABASE_TELEMETRY_DISABLED="1")
        process = subprocess.run(["supabase", "db", "query", f"--remote={target}", "--yes", sql],
                                 env=env, capture_output=True, timeout=15)
        assert process.returncode == 0, "Could not seed the isolated fixture"

    def read(self, table, token, *, id=None, statuses=(200,)):
        path = f"/rest/v1/bitelens_{table}"
        if id is not None:
            path += f"?id=eq.{id}"
        return self.request("GET", path, token=token, statuses=statuses)


def new_meal(owner):
    return {
        "id": str(uuid4()),
        "user_id": owner,
        "meal_at_epoch_seconds": 1794112200.234567,
        "local_date": "2026-11-07",
        "time_zone": "America/Los_Angeles",
        "confirmed_at_epoch_seconds": 1794225600,
        "notes": "Sauce served separately",
        "items": [
            {
                "id": str(uuid4()),
                "name": "Roasted carrots",
                "description": "With cumin",
                "portion_grams": 80.5,
                "serving_description": "One small side",
                "calories_kcal": 41.5,
                "protein_grams": None,
                "carbohydrates_grams": 8.2,
                "fat_grams": 0,
                "fiber_grams": 2.5,
                "sodium_milligrams": 111.25,
            },
            {
                "id": str(uuid4()),
                "name": "Water",
                "description": "",
                "serving_description": "One glass",
                "calories_kcal": 0,
            },
        ],
    }


def verify_readback(db, owner):
    token = db.sign_in(owner)
    meal = new_meal(owner[0])
    assert db.save(meal, token) == {"id": meal["id"], "revision": 1}
    # A fresh Auth sign-in can read the complete confirmed record.
    token = db.sign_in(owner)
    readback = db.request(
        "GET", "/rest/v1/bitelens_meals?select=*,bitelens_meal_items(*)&bitelens_meal_items.order=position"
        f"&id=eq.{meal['id']}", token=token,
    )
    assert len(readback) == 1
    saved = readback[0]
    for key in ("id", "user_id", "local_date", "time_zone", "notes"):
        assert saved[key] == meal[key], key
    assert saved["meal_at"] == "2026-11-08T04:30:00.234567+00:00"
    assert saved["confirmed_at"] == "2026-11-09T12:00:00+00:00"
    assert all(saved[key] is None for key in ("estimate_provider", "estimate_model", "estimate_version"))
    assert len(saved["bitelens_meal_items"]) == 2
    for index, (expected, actual) in enumerate(zip(meal["items"], saved["bitelens_meal_items"])):
        assert actual["position"] == index
        assert actual["meal_id"] == meal["id"] and actual["user_id"] == owner[0]
        for key, value in expected.items():
            assert actual[key] == value, key
    assert saved["bitelens_meal_items"][1]["portion_grams"] is None


def verify_beta_meal_access(db, owner, unapproved):
    with ExitStack() as fixtures:
        tester = db.create_user()
        fixtures.callback(db.delete_user, tester)
        db.set_approved(tester, True)
        revoked = db.create_user()
        fixtures.callback(db.delete_user, revoked)
        db.set_approved(revoked, True)

        owner_id, tester_id, revoked_id = owner[0], tester[0], revoked[0]
        owner_token, token = db.sign_in(owner), db.sign_in(tester)
        unapproved_token, revoked_token = db.sign_in(unapproved), db.sign_in(revoked)
        owner_meal, meal = new_meal(owner_id), new_meal(tester_id)
        db.save(owner_meal, owner_token)
        assert db.save(meal, token) == {"id": meal["id"], "revision": 1}

        meal_id, item_id = meal["id"], meal["items"][0]["id"]
        owner_meal_id, owner_item_id = owner_meal["id"], owner_meal["items"][0]["id"]
        meal["items"][0]["portion_grams"] = 45
        db.sync(meal_id, tester_id, 2, meal, token)
        assert db.sync(meal_id, tester_id, 2, meal, token) == {"id": meal_id, "revision": 2}
        saved_meal = db.read("meals", token, id=meal_id)
        saved_item = db.read("meal_items", token, id=item_id)
        assert saved_meal[0]["user_id"] == tester_id and saved_meal[0]["revision"] == 2
        assert saved_item[0]["user_id"] == tester_id and saved_item[0]["portion_grams"] == 45
        assert db.read("meal_items", owner_token, id=owner_item_id)[0]["portion_grams"] == 80.5
        for table, tester_row, owner_row in (
            ("meals", meal_id, owner_meal_id),
            ("meal_items", item_id, owner_item_id),
        ):
            assert db.read(table, owner_token, id=tester_row) == []
            assert db.read(table, token, id=owner_row) == []
            assert db.read(table, unapproved_token) == []

        for change in (dict(owner_meal, id=meal_id), None):
            db.sync(meal_id, owner_id, 3, change, owner_token, statuses=(409,))
        db.sync(meal_id, tester_id, 3, None, owner_token, statuses=(403,))
        collision = new_meal(owner_id)
        collision["items"][0]["id"] = item_id
        db.sync(collision["id"], owner_id, 1, collision, owner_token, statuses=(409,))
        assert db.read("meals", owner_token, id=collision["id"]) == []
        assert db.read("meals", token, id=meal_id) == saved_meal
        assert db.read("meal_items", token, id=item_id) == saved_item
        assert db.sync(meal_id, tester_id, 3, None, token) == {"id": meal_id, "revision": 3}
        db.sync(meal_id, owner_id, 3, None, owner_token, statuses=(409,))
        assert db.sync(meal_id, tester_id, 3, None, token) == {"id": meal_id, "revision": 3}
        assert db.read("meals", token, id=meal_id) == []
        assert db.read("meal_items", token, id=item_id) == []

        old_meal, removed_meal = new_meal(revoked_id), new_meal(revoked_id)
        db.save(old_meal, revoked_token)
        db.save(removed_meal, revoked_token)
        db.sync(removed_meal["id"], revoked_id, 2, None, revoked_token)
        prior_meal = db.read("meals", revoked_token, id=old_meal["id"])
        prior_item = db.read("meal_items", revoked_token, id=old_meal["items"][0]["id"])
        db.set_approved(revoked, False)

        for account, denied_token in ((unapproved, unapproved_token), (revoked, revoked_token)):
            assert db.read("meals", denied_token) == []
            assert db.read("meal_items", denied_token) == []
            new_record = new_meal(account[0])
            db.save(new_record, denied_token, statuses=(403,))
            db.sync(new_record["id"], account[0], 1, new_record, denied_token, statuses=(403,))
            db.sync(new_record["id"], account[0], 2, None, denied_token, statuses=(403,))
        db.sync(old_meal["id"], revoked_id, 2, dict(old_meal, notes="Rejected edit"), revoked_token,
                statuses=(403,))
        db.sync(old_meal["id"], revoked_id, 2, None, revoked_token, statuses=(403,))
        db.sync(removed_meal["id"], revoked_id, 2, None, revoked_token, statuses=(403,))
        db.request("GET", "/rest/v1/meal_tombstones", token=revoked_token, statuses=(404,))

        # Reinstatement takes effect on the same pre-revocation token.
        db.set_approved(revoked, True)
        assert db.read("meals", revoked_token, id=old_meal["id"]) == prior_meal
        assert db.read("meal_items", revoked_token, id=old_meal["items"][0]["id"]) == prior_item
        assert db.sync(removed_meal["id"], revoked_id, 2, None, revoked_token) == {
            "id": removed_meal["id"], "revision": 2,
        }


def verify_replay_and_atomicity(db, owner):
    token = db.sign_in(owner)
    meal = new_meal(owner[0])
    ack = {"id": meal["id"], "revision": 1}
    with ThreadPoolExecutor(max_workers=2) as executor:
        replies = list(executor.map(lambda _: db.save(meal, token), range(2)))
    assert replies == [ack, ack]
    # A later retry after an unobserved response sees the same complete write.
    assert db.save(meal, token) == ack
    changed = deepcopy(meal)
    changed["items"].reverse()
    assert db.save(changed, token, statuses=(409,))["code"] == "23505"
    assert len(db.read("meals", token, id=meal["id"])) == 1
    for position, item in enumerate(meal["items"]):
        saved = db.read("meal_items", token, id=item["id"])
        assert len(saved) == 1 and saved[0]["position"] == position

    invalid = new_meal(owner[0])
    invalid["items"][1]["fat_grams"] = -1
    assert db.save(invalid, token, statuses=(400,))["code"] == "23514"
    assert db.read("meals", token, id=invalid["id"]) == []
    assert db.read("meal_items", token, id=invalid["items"][0]["id"]) == []

    # A retry with the intended valid record can now write the whole meal.
    del invalid["items"][1]["fat_grams"]
    invalid.update(estimate_provider="grok", estimate_model="fixture-model", estimate_version="v1")
    assert db.save(invalid, token) == {"id": invalid["id"], "revision": 1}
    saved = db.read("meals", token, id=invalid["id"])[0]
    assert (saved["estimate_provider"], saved["estimate_model"], saved["estimate_version"]) == (
        "grok", "fixture-model", "v1"
    )


def verify_meal_model(db, owner):
    token = db.sign_in(owner)
    meal = new_meal(owner[0])
    meal.update(estimate_provider="openai", estimate_model="fixture", estimate_version="meal-estimate-v2")
    meal_id = meal["id"]
    estimate = dict(name="Spring roll", description="Vegetable spring rolls", serving_description="pieces",
                    consumed_count=5, portion_grams=250, calories_kcal=400, alcohol_grams=0,
                    added_sugar_grams=5)
    item_id = meal["items"][0]["id"]
    meal["items"][0] = dict(estimate, id=item_id, item_origin="ai", original_item_estimate=estimate)
    meal["items"][1].update(item_origin="manual", original_item_estimate=None)

    def save(revision, snapshot, statuses=(200,)):
        return db.sync(meal_id, owner[0], revision, snapshot, token, statuses=statuses)

    assert save(1, meal) == {"id": meal_id, "revision": 1}
    first = db.read("meals", token, id=meal_id)[0]
    assert first["created_at"] == first["updated_at"] and first["created_at"] != first["confirmed_at"]
    assert db.read("meal_items", token, id=item_id)[0]["is_corrected"] is False
    manual = db.read("meal_items", token, id=meal["items"][1]["id"])[0]
    assert manual["item_origin"] == "manual" and manual["original_item_estimate"] is None

    corrected = deepcopy(meal)
    corrected["items"][0].update(consumed_count=2.5, portion_grams=125, calories_kcal=200,
                                 added_sugar_grams=2.5)
    assert save(2, corrected) == {"id": meal_id, "revision": 2}
    saved = db.read("meal_items", token, id=item_id)[0]
    assert (saved["consumed_count"], saved["portion_grams"], saved["calories_kcal"]) == (2.5, 125, 200)
    assert (saved["alcohol_grams"], saved["caffeine_milligrams"], saved["added_sugar_grams"]) == (0, None, 2.5)
    assert saved["original_item_estimate"] == estimate and saved["is_corrected"] is True
    updated = db.read("meals", token, id=meal_id)[0]
    assert updated["created_at"] == first["created_at"] and updated["updated_at"] > first["updated_at"]
    assert updated["confirmed_at"] == first["confirmed_at"] and updated["meal_at"] == first["meal_at"]
    assert save(2, corrected) == {"id": meal_id, "revision": 2}
    assert db.read("meals", token, id=meal_id)[0] == updated

    for change in ({"calories_kcal": 1}, {"photo": "image"}, {"alcohol_grams": "0"}):
        invalid = deepcopy(corrected)
        invalid["items"][0]["original_item_estimate"].update(change)
        assert save(3, invalid, (400,))["code"] == "22023"
    assert save(3, meal) == {"id": meal_id, "revision": 3}
    assert db.read("meal_items", token, id=item_id)[0]["is_corrected"] is False


def verify_authorization(db, owner, outsider):
    owner_token = db.sign_in(owner)
    outsider_token = db.sign_in(outsider)
    approved = new_meal(owner[0])
    db.save(approved, owner_token)
    foreign_meal = str(uuid4())
    foreign_item = str(uuid4())
    db.seed_foreign_meal(outsider[0], foreign_meal, foreign_item)

    for table, own, foreign in (
        ("meals", approved["id"], foreign_meal),
        ("meal_items", approved["items"][0]["id"], foreign_item),
    ):
        assert db.read(table, owner_token, id=foreign) == []
        assert db.read(table, outsider_token, id=own) == []
        assert db.read(table, outsider_token, id=foreign) == []
        db.read(table, None, id=own, statuses=(401, 403, 404))

        path = f"/rest/v1/bitelens_{table}?id=eq.{own}"
        for token in (owner_token, outsider_token, None):
            rejected = (401, 403, 404)
            db.request("PATCH", path, {"user_id": outsider[0]}, token, statuses=rejected)
            db.request("DELETE", path, token=token, statuses=rejected)
            db.request("POST", f"/rest/v1/bitelens_{table}", {"id": str(uuid4())},
                       token, statuses=rejected)
        assert db.read(table, owner_token, id=own)[0]["user_id"] == owner[0]

    db.save(new_meal(owner[0]), None, statuses=(401, 403, 404))
    db.save(new_meal(owner[0]), outsider_token, statuses=(403,))
    db.save(new_meal(outsider[0]), outsider_token, statuses=(403,))
    db.save(new_meal(outsider[0]), owner_token, statuses=(403,))

    for association in ({"user_id": outsider[0]}, {"meal_id": foreign_meal}, {"photo": "image"}):
        invalid = new_meal(owner[0])
        invalid["items"][0].update(association)
        assert db.save(invalid, owner_token, statuses=(400,))["code"] == "22023"
        assert db.read("meals", owner_token, id=invalid["id"]) == []
    invalid = new_meal(owner[0])
    invalid["photo_id"] = str(uuid4())
    assert db.save(invalid, owner_token, statuses=(400,))["code"] == "22023"

    foreign_conflict = new_meal(owner[0])
    foreign_conflict["id"] = foreign_meal
    assert db.save(foreign_conflict, owner_token, statuses=(409,))["code"] == "23505"

    item_conflict = new_meal(owner[0])
    item_conflict["items"][1]["id"] = foreign_item
    assert db.save(item_conflict, owner_token, statuses=(409,))["code"] == "23505"
    assert db.read("meals", owner_token, id=item_conflict["id"]) == []
    assert db.read("meal_items", owner_token, id=item_conflict["items"][0]["id"]) == []


def verify_versioned_changes(db, owner, outsider):
    token, other_token = db.sign_in(owner), db.sign_in(outsider)
    original = new_meal(owner[0])
    original.update(estimate_provider="grok", estimate_model="fixture-snapshot", estimate_version="v1")
    meal_id = original["id"]

    def apply(revision, meal, statuses=(200,)):
        return db.sync(meal_id, owner[0], revision, meal, token, statuses=statuses)

    # A pending create can be replaced before either snapshot reaches Supabase.
    revised = deepcopy(original)
    removed = revised["items"].pop(0)
    revised["items"].append(new_meal(owner[0])["items"][0])
    revised["items"][0]["name"] = "Sparkling water"
    revised.update(notes="Moved to the next day", local_date="2026-11-08", meal_at_epoch_seconds=1794198600)
    assert apply(2, revised) == {"id": meal_id, "revision": 2}
    assert apply(2, revised) == {"id": meal_id, "revision": 2}
    assert db.save(original, token, statuses=(409,))["code"] == "23505"
    assert db.read("meal_items", token, id=removed["id"]) == []

    newest = deepcopy(revised)
    newest["items"].reverse()
    newest["items"][0]["portion_grams"] = 40
    newest["items"][0]["calories_kcal"] = 20.5
    newest["notes"] = "Half a portion"
    with ThreadPoolExecutor(max_workers=2) as executor:
        replies = list(executor.map(lambda _: apply(3, newest), range(2)))
    assert replies == [{"id": meal_id, "revision": 3}] * 2
    assert apply(2, revised, (409,))["code"] == "23505"

    # Invalid updates roll back the parent and the replacement item set.
    broken = deepcopy(newest)
    broken["notes"] = "Must not persist"
    broken["items"][1]["sodium_milligrams"] = -1
    assert apply(4, broken, (400,))["code"] == "23514"
    for key, value in (("user_id", outsider[0]), ("meal_id", str(uuid4())), ("photo", "image")):
        invalid = deepcopy(newest)
        invalid["items"][0][key] = value
        assert apply(4, invalid, (400,))["code"] == "22023"
    assert apply(4, dict(newest, estimate_model="fabricated"), (400,))["code"] == "22023"
    assert apply(4, dict(newest, user_id=outsider[0]), (403,))["code"] == "42501"
    db.sync(meal_id, outsider[0], 4, None, token, statuses=(403,))
    db.sync(meal_id, owner[0], 4, newest, other_token, statuses=(403,))
    db.sync(meal_id, owner[0], 4, None, other_token, statuses=(403,))
    db.sync(meal_id, owner[0], 4, None, None, statuses=(401, 403, 404))

    token = db.sign_in(owner)
    rows = db.request(
        "GET", "/rest/v1/bitelens_meals?select=*,bitelens_meal_items(*)&bitelens_meal_items.order=position"
        f"&id=eq.{meal_id}", token=token,
    )
    assert len(rows) == 1
    row = rows[0]
    assert (row["revision"], row["notes"], row["local_date"], row["estimate_model"]) == (
        3, newest["notes"], newest["local_date"], original["estimate_model"],
    )
    assert [item["id"] for item in row["bitelens_meal_items"]] == [item["id"] for item in newest["items"]]
    assert row["bitelens_meal_items"][0]["portion_grams"] == 40
    assert row["bitelens_meal_items"][0]["calories_kcal"] == 20.5
    assert db.read("meals", other_token, id=meal_id) == []

    # A lost deletion response is replayable, while older and newer snapshots
    # and the legacy create route all fail against the tombstone.
    assert apply(4, None) == {"id": meal_id, "revision": 4}
    assert apply(4, None) == {"id": meal_id, "revision": 4}
    assert apply(3, newest, (409,))["code"] == "23505"
    assert apply(5, newest, (409,))["code"] == "23505"
    assert db.save(original, token, statuses=(409,))["code"] == "23505"
    assert db.read("meals", token, id=meal_id) == []
    for item in newest["items"]:
        assert db.read("meal_items", token, id=item["id"]) == []

    # Deleting a never-uploaded create still guards against a delayed first save.
    unsent = new_meal(owner[0])
    unsent_id = unsent["id"]
    assert db.sync(unsent_id, owner[0], 2, None, token) == {"id": unsent_id, "revision": 2}
    db.save(unsent, token, statuses=(409,))
    assert db.read("meals", token, id=unsent_id) == []

    # A pre-existing foreign parent cannot be changed or tombstoned by the owner.
    foreign_meal, foreign_item = str(uuid4()), str(uuid4())
    db.seed_foreign_meal(outsider[0], foreign_meal, foreign_item)
    db.sync(foreign_meal, owner[0], 2, None, token, statuses=(409,))
    db.sync(foreign_meal, owner[0], 2, dict(newest, id=foreign_meal), token, statuses=(409,))


def sync_observation(db, observation_id, owner_id, revision, snapshot, token, statuses=(200,)):
    return db.request("POST", "/rest/v1/rpc/bitelens_sync_observation", {
        "p_observation_id": observation_id, "p_user_id": owner_id,
        "p_revision": revision, "p_observation": snapshot,
    }, token, statuses=statuses)


def new_observation(owner, kind="symptom", **fields):
    snapshot = {
        "id": str(uuid4()), "user_id": owner, "kind": kind,
        "observed_at_epoch_seconds": 1794112200.234567,
        "local_date": "2026-11-07", "time_zone": "America/Los_Angeles",
    }
    if kind == "symptom":
        snapshot["symptom_id"] = "headache"
    return dict(snapshot, **fields)


def verify_beta_observation_access(db, first, unapproved):
    with ExitStack() as fixtures:
        second = db.create_user()
        fixtures.callback(db.delete_user, second)
        db.set_approved(second, True)
        revoked = db.create_user()
        fixtures.callback(db.delete_user, revoked)
        db.set_approved(revoked, True)

        first_token, second_token = db.sign_in(first), db.sign_in(second)
        unapproved_token, revoked_token = db.sign_in(unapproved), db.sign_in(revoked)
        first_entry, second_entry = new_observation(first[0]), new_observation(second[0])
        for entry, token in ((first_entry, first_token), (second_entry, second_token)):
            ack = sync_observation(db, entry["id"], entry["user_id"], 1, entry, token)
            assert ack == {"id": entry["id"], "revision": 1}
            rows = db.read("observations", token, id=entry["id"])
            assert len(rows) == 1 and rows[0]["user_id"] == entry["user_id"]

        first_meal, second_meal = new_meal(first[0]), new_meal(second[0])
        db.save(first_meal, first_token)
        db.save(second_meal, second_token)
        urge = new_observation(second[0], "bingeEatingUrge", meal_id=second_meal["id"])
        urge_id, second_entry_id = urge["id"], second_entry["id"]
        assert sync_observation(db, urge_id, second[0], 1, urge, second_token) == {"id": urge_id, "revision": 1}
        assert db.read("observations", second_token, id=urge_id)[0]["meal_id"] == second_meal["id"]

        first_rows = db.read("observations", first_token)
        second_rows = db.read("observations", second_token)
        first_meals = db.read("meals", first_token, id=first_meal["id"])
        second_meals = db.read("meals", second_token, id=second_meal["id"])
        assert all(row["user_id"] == first[0] for row in first_rows)
        assert {row["id"] for row in second_rows} == {second_entry_id, urge_id}
        assert all(row["user_id"] == second[0] for row in second_rows)

        for owned_entry, owned_token, foreign_entry in (
            (first_entry, first_token, second_entry), (second_entry, second_token, first_entry),
        ):
            foreign_id, foreign_owner = foreign_entry["id"], foreign_entry["user_id"]
            for change in (foreign_entry, None):
                assert sync_observation(db, foreign_id, foreign_owner, 2, change,
                                        owned_token, (403,))["code"] == "42501"
            for change in (dict(owned_entry, id=foreign_id), None):
                assert sync_observation(db, foreign_id, owned_entry["user_id"], 2, change,
                                        owned_token, (409,))["code"] == "23505"

        foreign_link = dict(urge, meal_id=first_meal["id"])
        assert sync_observation(db, urge_id, second[0], 2, foreign_link, second_token, (409,))["code"] == "23503"
        assert db.read("observations", first_token) == first_rows
        assert db.read("observations", second_token) == second_rows
        assert db.read("meals", first_token, id=first_meal["id"]) == first_meals
        assert db.read("meals", second_token, id=second_meal["id"]) == second_meals

        edited = dict(urge, notes="After dinner")
        edited_ack = {"id": urge_id, "revision": 2}
        assert sync_observation(db, urge_id, second[0], 2, edited, second_token) == edited_ack
        saved = db.read("observations", second_token, id=urge_id)[0]
        assert saved["notes"] == "After dinner" and saved["meal_id"] == second_meal["id"]
        assert sync_observation(db, urge_id, second[0], 2, edited, second_token) == edited_ack
        assert db.read("observations", second_token, id=urge_id) == [saved]
        deleted_ack = {"id": urge_id, "revision": 3}
        assert sync_observation(db, urge_id, second[0], 3, None, second_token) == deleted_ack
        deleted = db.read("observations", second_token, id=urge_id)[0]
        assert deleted["deleted_at"] == deleted["updated_at"] and deleted["meal_id"] is None
        assert sync_observation(db, urge_id, second[0], 3, None, second_token) == deleted_ack
        assert db.read("observations", second_token, id=urge_id) == [deleted]
        assert db.read("observations", first_token, id=urge_id) == []

        retained, tombstone = new_observation(revoked[0]), new_observation(revoked[0])
        retained_id, tombstone_id = retained["id"], tombstone["id"]
        sync_observation(db, retained_id, revoked[0], 1, retained, revoked_token)
        sync_observation(db, tombstone_id, revoked[0], 1, tombstone, revoked_token)
        sync_observation(db, tombstone_id, revoked[0], 2, None, revoked_token)
        retained_rows = db.read("observations", revoked_token)
        assert {row["id"] for row in retained_rows} == {retained_id, tombstone_id}
        db.set_approved(revoked, False)

        for denied, token in ((unapproved, unapproved_token), (revoked, revoked_token)):
            assert db.read("observations", token) == []
            snapshot = new_observation(denied[0])
            assert sync_observation(db, snapshot["id"], denied[0], 1, snapshot, token, (403,))["code"] == "42501"
            assert sync_observation(db, first_entry["id"], first[0], 2, None, token, (403,))["code"] == "42501"
        for revision, change in ((1, retained), (2, dict(retained, notes="Denied edit")), (2, None)):
            assert sync_observation(db, retained_id, revoked[0], revision, change,
                                    revoked_token, (403,))["code"] == "42501"
        assert sync_observation(db, tombstone_id, revoked[0], 2, None, revoked_token, (403,))["code"] == "42501"

        # The same token sees its retained entries and tombstones after reinstatement.
        db.set_approved(revoked, True)
        assert db.read("observations", revoked_token) == retained_rows
        assert sync_observation(db, tombstone_id, revoked[0], 2, None, revoked_token) == {
            "id": tombstone_id, "revision": 2,
        }
        assert db.read("observations", first_token) == first_rows


def verify_observation_revisions(db, owner):
    owner_id = owner[0]
    token = db.sign_in(owner)
    observation = new_observation(owner_id, level="mild", notes="After lunch")
    observation_id = observation["id"]

    def apply(revision, snapshot, statuses=(200,)):
        return sync_observation(db, observation_id, owner_id, revision, snapshot, token, statuses)

    def read():
        return db.read("observations", token, id=observation_id)[0]

    # A newer offline snapshot can arrive before its original create.
    ack = {"id": observation_id, "revision": 2}
    with ThreadPoolExecutor(max_workers=2) as executor:
        assert list(executor.map(lambda _: apply(2, observation), range(2))) == [ack, ack]
    first = read()
    assert first["id"] == observation_id and first["user_id"] == owner_id and first["revision"] == 2
    assert first["kind"] == "symptom" and first["symptom_id"] == "headache"
    assert first["observed_at"] == "2026-11-08T04:30:00.234567+00:00"
    assert first["local_date"] == "2026-11-07" and first["time_zone"] == "America/Los_Angeles"
    assert first["level"] == "mild" and first["notes"] == "After lunch"
    assert first["created_at"] == first["updated_at"] and first["deleted_at"] is None
    assert apply(2, observation) == ack and read() == first
    assert apply(1, observation, (409,))["code"] == "23505"
    assert apply(2, dict(observation, notes="Same revision"), (409,))["code"] == "23505"
    assert apply(3, dict(observation, symptom_id="nausea"), (400,))["code"] == "22023"

    edited = dict(observation, level="moderate", notes="Moved to the next day",
                  observed_at_epoch_seconds=1794198600, local_date="2026-11-08")
    assert apply(3, edited) == {"id": observation_id, "revision": 3}
    updated = read()
    assert updated["created_at"] == first["created_at"] and updated["updated_at"] > first["updated_at"]
    assert (updated["revision"], updated["level"], updated["local_date"]) == (3, "moderate", "2026-11-08")

    assert apply(4, None) == {"id": observation_id, "revision": 4}
    deleted = read()
    assert deleted["created_at"] == first["created_at"] and deleted["updated_at"] > updated["updated_at"]
    assert deleted["deleted_at"] == deleted["updated_at"] and deleted["revision"] == 4
    assert deleted["notes"] is None and deleted["meal_id"] is None
    assert apply(4, None) == {"id": observation_id, "revision": 4} and read() == deleted
    assert apply(3, edited, (409,))["code"] == "23505"
    assert apply(5, edited, (409,))["code"] == "23505"

    # A delete received first still prevents an unsent snapshot from resurfacing.
    unsent = new_observation(owner_id)
    sync_observation(db, unsent["id"], owner_id, 2, None, token)
    assert sync_observation(db, unsent["id"], owner_id, 1, unsent, token, (409,))["code"] == "23505"


def verify_observation_authorization_and_validation(db, owner, outsider):
    owner_id, outsider_id = owner[0], outsider[0]
    token, other_token = db.sign_in(owner), db.sign_in(outsider)
    observation = new_observation(owner_id)
    observation_id = observation["id"]
    sync_observation(db, observation_id, owner_id, 1, observation, token)
    foreign_observation = str(uuid4())
    db.seed_foreign_observation(outsider_id, foreign_observation)
    assert db.read("observations", token, id=foreign_observation) == []
    assert db.read("observations", other_token) == []
    db.read("observations", None, statuses=(401, 403, 404))

    path = f"/rest/v1/bitelens_observations?id=eq.{observation_id}"
    for caller in (token, other_token, None):
        rejected = (401, 403, 404)
        db.request("PATCH", path, {"user_id": outsider_id}, caller, statuses=rejected)
        db.request("DELETE", path, token=caller, statuses=rejected)
        db.request("POST", "/rest/v1/bitelens_observations", {"id": str(uuid4())}, caller, statuses=rejected)
    assert db.read("observations", token, id=observation_id)[0]["user_id"] == owner_id
    for snapshot in (observation, None):
        assert sync_observation(db, observation_id, owner_id, 2, snapshot, other_token, (403,))["code"] == "42501"
        assert sync_observation(db, observation_id, outsider_id, 2, snapshot, token, (403,))["code"] == "42501"
    sync_observation(db, observation_id, owner_id, 2, None, None, (401, 403, 404))
    assert sync_observation(db, observation_id, owner_id, 2,
                            dict(observation, user_id=outsider_id), token, (403,))["code"] == "42501"
    for snapshot in (dict(observation, id=foreign_observation), None):
        assert sync_observation(db, foreign_observation, owner_id, 2, snapshot, token, (409,))["code"] == "23505"

    meal = new_meal(owner_id)
    db.save(meal, token)
    foreign_meal = str(uuid4())
    db.seed_foreign_meal(outsider_id, foreign_meal, str(uuid4()))
    urge = new_observation(owner_id, "bingeEatingUrge", meal_id=foreign_meal)
    assert sync_observation(db, urge["id"], owner_id, 1, urge, token, (409,))["code"] == "23503"

    for invalid, code in (
        ({"kind": "mood"}, "23514"),
        ({"symptom_id": None}, "23514"),
        ({"symptom_id": "notInCatalog"}, "23514"),
        ({"kind": "bingeEatingUrge"}, "23514"),
        ({"meal_id": meal["id"]}, "23514"),
        ({"level": "unknown"}, "23514"),
        ({"notes": {"text": "not plain text"}}, "22023"),
        ({"created_at": "2026-11-07T04:30:00Z"}, "22023"),
        ({"local_date": "today"}, "22023"),
        ({"observed_at_epoch_seconds": 4102444800}, "22023"),
    ):
        snapshot = dict(new_observation(owner_id), **invalid)
        assert sync_observation(db, snapshot["id"], owner_id, 1, snapshot, token, (400,))["code"] == code
        assert db.read("observations", token, id=snapshot["id"]) == []


def verify_observation_meal_links_and_feed(db, owner, outsider):
    owner_id = owner[0]
    token, other_token = db.sign_in(owner), db.sign_in(outsider)
    meal, replacement = new_meal(owner_id), new_meal(owner_id)
    for parent in (meal, replacement):
        db.save(parent, token)

    def apply(snapshot, revision=1, statuses=(200,)):
        return sync_observation(db, snapshot["id"], owner_id, revision, snapshot, token, statuses)

    def changes_since(checkpoint, caller=token):
        query = urlencode({"updated_at": f"gt.{checkpoint}", "order": "updated_at.asc,id.asc"})
        return db.request("GET", f"/rest/v1/bitelens_observations?{query}", token=caller)

    urges = [new_observation(owner_id, "bingeEatingUrge", meal_id=meal["id"], level="severe") for _ in range(3)]
    for urge in urges:
        assert apply(urge) == {"id": urge["id"], "revision": 1}
    replaced = dict(urges.pop(), meal_id=replacement["id"])
    assert apply(replaced, 2) == {"id": replaced["id"], "revision": 2}
    replacement_row = db.read("observations", token, id=replaced["id"])[0]
    assert replacement_row["meal_id"] == replacement["id"]
    before = {urge["id"]: db.read("observations", token, id=urge["id"])[0] for urge in urges}
    assert all(row["meal_id"] == meal["id"] for row in before.values())
    checkpoint = replacement_row["updated_at"]

    assert db.sync(meal["id"], owner_id, 2, None, token) == {"id": meal["id"], "revision": 2}
    unlinked = changes_since(checkpoint)
    assert len(unlinked) == 2 and {row["id"] for row in unlinked} == before.keys()
    assert [(row["updated_at"], row["id"]) for row in unlinked] == sorted(
        (row["updated_at"], row["id"]) for row in unlinked
    )
    assert changes_since(checkpoint, other_token) == []
    for row in unlinked:
        assert row == dict(before[row["id"]], meal_id=None, updated_at=row["updated_at"])
    assert db.read("observations", token, id=replaced["id"])[0] == replacement_row

    # A lost response can be replayed even if the original payload referenced the deleted meal.
    for urge in urges:
        assert apply(urge) == {"id": urge["id"], "revision": 1}
        assert apply(urge, 2, (409,))["code"] == "23503"
    pending = new_observation(owner_id, "bingeEatingUrge", meal_id=meal["id"])
    assert apply(pending, 1, (409,))["code"] == "23503"
    assert changes_since(checkpoint) == unlinked
    assert db.read("observations", token, id=pending["id"]) == []

    # The next real client revision can edit the unlinked urge or link a different meal.
    updated = dict(urges[0], meal_id=replacement["id"], notes="Correction")
    assert apply(updated, 2) == {"id": updated["id"], "revision": 2}
    changes = changes_since(unlinked[-1]["updated_at"])
    assert len(changes) == 1 and changes[0]["notes"] == "Correction"
    assert changes[0]["meal_id"] == replacement["id"]
    sync_observation(db, updated["id"], owner_id, 3, None, token)
    changes = changes_since(changes[0]["updated_at"])
    assert len(changes) == 1 and changes[0]["id"] == updated["id"]
    assert changes[0]["revision"] == 3 and changes[0]["deleted_at"] == changes[0]["updated_at"]


def verify_concurrent_observation_link_and_meal_deletion(db, owner):
    owner_id = owner[0]
    token = db.sign_in(owner)
    meal = new_meal(owner_id)
    db.save(meal, token)
    urge = new_observation(owner_id, "bingeEatingUrge")
    urge_id = urge["id"]
    sync_observation(db, urge_id, owner_id, 1, urge, token)
    linked = dict(urge, meal_id=meal["id"])
    start = Barrier(2)

    def link_urge():
        start.wait(timeout=5)
        return sync_observation(db, urge_id, owner_id, 2, linked, token, (200, 409))

    def delete_meal():
        start.wait(timeout=5)
        return db.sync(meal["id"], owner_id, 2, None, token)

    with ThreadPoolExecutor(max_workers=2) as executor:
        link = executor.submit(link_urge)
        deletion = executor.submit(delete_meal)
        assert deletion.result() == {"id": meal["id"], "revision": 2}
        link_result = link.result()
    saved = db.read("observations", token, id=urge_id)[0]
    assert saved["meal_id"] is None and saved["deleted_at"] is None
    if saved["revision"] == 2:
        assert link_result == {"id": urge_id, "revision": 2}
        assert sync_observation(db, urge_id, owner_id, 2, linked, token) == link_result
    else:
        assert saved["revision"] == 1 and link_result["code"] == "23503"
        assert sync_observation(db, urge_id, owner_id, 2, linked, token, (409,))["code"] == "23503"
    assert db.read("observations", token, id=urge_id)[0] == saved


def verify_beta_meal_estimate_allowance(db, owner, unapproved):
    path = "/rest/v1/rpc/bitelens_reserve_meal_estimate"

    def arguments(user, limit=10, photo_expires_at=None):
        return {"p_user_id": user[0], "p_daily_limit": limit, "p_photo_expires_at": photo_expires_at}

    def reserve(user, limit=10, photo_expires_at=None):
        return db.request("POST", path, arguments(user, limit, photo_expires_at), admin=True)

    assert reserve(unapproved) == {"error": "approval_required"}
    token = db.sign_in(owner)
    db.request("POST", path, arguments(owner), token=token, statuses=(403, 404))
    db.request("POST", path, arguments(owner), statuses=(401, 403, 404))
    db.request("POST", path, arguments(owner, 0), admin=True, statuses=(400,))
    db.request("POST", path, dict(arguments(owner), p_now="2026-01-01T00:00Z"),
               admin=True, statuses=(404,))
    assert reserve(owner, photo_expires_at="2026-01-01T00:00Z") == {"error": "photo_expired"}

    attempts = 14
    start = Barrier(attempts)

    def race(_):
        start.wait(timeout=5)
        return reserve(owner)

    with ThreadPoolExecutor(max_workers=attempts) as executor:
        results = list(executor.map(race, range(attempts)))
    assert results.count({"reserved": True}) == 10
    limited = [result for result in results if result.get("error") == "allowance_exhausted"]
    assert len(limited) == 4 and len({result["reset_at"] for result in limited}) == 1
    reset = datetime.fromisoformat(limited[0]["reset_at"].replace("Z", "+00:00"))
    assert reset.utcoffset() == timezone.utc.utcoffset(reset)
    assert (reset.hour, reset.minute, reset.second, reset.microsecond) == (0, 0, 0, 0)

    # Reinstatement preserves the earlier reservations. Another account starts independently.
    db.set_approved(owner, False)
    try:
        assert reserve(owner) == {"error": "approval_required"}
    finally:
        db.set_approved(owner, True)
    assert reserve(owner) == limited[0]
    with ExitStack() as fixtures:
        second = db.create_user()
        fixtures.callback(db.delete_user, second)
        db.set_approved(second, True)
        assert reserve(second, 1) == {"reserved": True}
        assert reserve(second, 1) == limited[0]

        third = db.create_user()
        fixtures.callback(db.delete_user, third)
        db.set_approved(third, True)
        photo = reserve(third, 2, "2100-01-01T00:00Z")
        assert photo["reserved"] is True
        refund_path = "/rest/v1/rpc/bitelens_refund_meal_estimate"
        refund = {"p_reservation_id": str(UUID(photo["reservation_id"]))}
        assert reserve(third, 2) == {"reserved": True}
        assert reserve(third, 2) == limited[0]
        db.request("POST", refund_path, refund, token=db.sign_in(third), statuses=(403, 404))
        db.request("POST", refund_path, refund, statuses=(401, 403, 404))
        assert reserve(third, 2) == limited[0]

        # Retry with the same ID after a possible lost refund response.
        def refund_once():
            db.request("POST", refund_path, refund, admin=True, statuses=(200, 204))

        with ThreadPoolExecutor(max_workers=2) as executor:
            retries = [executor.submit(refund_once) for _ in range(2)]
            for retry in retries:
                retry.result()
        assert reserve(third, 2) == {"reserved": True}
        refund_once()
        assert reserve(third, 2) == limited[0]

        # The REST RPC selects the database clock. The database owner can run the
        # same private reservation at fixed instants to straddle UTC midnight.
        second_id = UUID(second[0])
        db.seed_fixture(f"""
            do $verify$
            declare
                result jsonb;
                before_midnight uuid;
            begin
                perform pg_catalog.set_config('TimeZone', 'Pacific/Honolulu', true);
                result := bitelens_private.reserve_meal_estimate(
                    '{second_id}', 1, '2026-03-11 00:00:00.001Z', '2026-03-10 23:59:59.998Z'
                );
                before_midnight := (result->>'reservation_id')::uuid;
                if before_midnight is null then raise exception 'first UTC day rejected'; end if;
                result := bitelens_private.reserve_meal_estimate('{second_id}', 1, null, '2026-03-10 23:59:59.999Z');
                if result->>'error' is distinct from 'allowance_exhausted'
                    or (result->>'reset_at')::timestamptz is distinct from '2026-03-11 00:00Z'::timestamptz then
                    raise exception 'wrong reset before UTC midnight';
                end if;
                result := bitelens_private.reserve_meal_estimate('{second_id}', 1, null, '2026-03-11 00:00Z');
                if result <> '{{"reserved":true}}'::jsonb then raise exception 'new UTC day rejected'; end if;

                perform public.bitelens_refund_meal_estimate(before_midnight);
                result := bitelens_private.reserve_meal_estimate('{second_id}', 1, null, '2026-03-11 00:00Z');
                if result->>'error' is distinct from 'allowance_exhausted' then
                    raise exception 'refund released the new UTC day';
                end if;
                result := bitelens_private.reserve_meal_estimate('{second_id}', 1, null, '2026-03-10 23:59:59.999Z');
                if result <> '{{"reserved":true}}'::jsonb then raise exception 'refund did not release first UTC day'; end if;
            end;
            $verify$;
        """)


def main(status_path, beta):
    db = LocalSupabase(status_path)
    approved_owner = "00000000-0000-4000-8000-000000000001"
    owner = db.create_user(approved_owner)
    try:
        assert owner[0] == approved_owner, "Local Auth Admin must honor the explicit fixture UUID"
        if beta:
            db.set_approved(owner, True)
        else:
            db.save(new_meal(approved_owner), db.sign_in(owner), statuses=(403,))
            db.seed_fixture(
                f"insert into bitelens_private.approved_owner (user_id) values ('{UUID(approved_owner)}')"
            )
        verify_readback(db, owner)
        verify_replay_and_atomicity(db, owner)
        verify_meal_model(db, owner)
        verify_observation_revisions(db, owner)
        outsider = db.create_user(metadata={"user_id": approved_owner, "bitelens_owner": True})
        try:
            if beta:
                verify_beta_meal_access(db, owner, outsider)
                verify_beta_observation_access(db, owner, outsider)
                verify_beta_meal_estimate_allowance(db, owner, outsider)
            verify_authorization(db, owner, outsider)
            verify_versioned_changes(db, owner, outsider)
            verify_observation_authorization_and_validation(db, owner, outsider)
            verify_observation_meal_links_and_feed(db, owner, outsider)
            verify_concurrent_observation_link_and_meal_deletion(db, owner)
        finally:
            db.delete_user(outsider)
        print("Isolated meal and observation sync verified: authorization, revision replay, tombstones, and meal unlinking")
    finally:
        db.delete_user(owner)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("status_path")
    parser.add_argument("--beta", action="store_true", help="Exercise the beta-only migrations")
    args = parser.parse_args()
    main(args.status_path, args.beta)
