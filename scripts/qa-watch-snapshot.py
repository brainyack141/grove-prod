#!/usr/bin/env python3
"""QA-only: prints a hex-encoded WatchSnapshot (schema 2) for `defaults write -data`."""
import json, sys, time, uuid

ref = time.time() - 978307200  # JSONEncoder's default Date = seconds since 2001
day = 86400
empty = len(sys.argv) > 1 and sys.argv[1] == "empty"
plants = [
    ("Monty", "Swiss cheese plant", "Living room", 82, "healthy", "stable", 0),
    ("Fern", "Boston fern", "Bathroom", 64, "monitor", "declining", 1),
    ("Sir Reginald the Magnificent Fiddle-Leaf", "Ficus lyrata", "Upstairs landing by the big window", 41, "attention", "declining", -1),
    ("Basil", "Ocimum basilicum", "Kitchen", 95, "thriving", "improving", 3),
    ("Spike", "Snake plant", "Office", 77, "healthy", "baseline", 5),
]
ps, ts = [], []
if not empty:
    for name, species, loc, score, band, trend, due in plants:
        pid = str(uuid.uuid4()).upper()
        ps.append({"id": pid, "nickname": name, "species": species, "location": loc,
                   "healthScore": score, "band": band, "trend": trend,
                   "nextCheckIn": ref + due * day, "lastWateredAt": ref - 3 * day})
    kinds = ["water", "inspectSoil", "checkIn", "fertilise", "rotate"]
    for i, p in enumerate(ps):
        ts.append({"id": str(uuid.uuid4()).upper(), "plantID": p["id"], "kind": kinds[i],
                   "dueDate": ref + (0 if i < 3 else 2) * day - 3600,
                   "detail": "Check the top 2 cm of soil before watering" if i == 1 else "",
                   "isSittingTask": i == 2})
snap = {"schemaVersion": 2, "generatedAt": ref, "streak": 12, "streakIsShielded": True,
        "plants": ps, "tasks": ts}
print(json.dumps(snap).encode().hex())
