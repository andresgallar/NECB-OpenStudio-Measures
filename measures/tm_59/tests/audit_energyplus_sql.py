"""Independently check a TM59 report against raw EnergyPlus 25.2 SQL output."""

import argparse
import csv
import json
import math
import sqlite3
from collections import defaultdict
from contextlib import closing
from datetime import date, datetime, time, timedelta
from itertools import chain, groupby
from pathlib import Path
from statistics import fmean


def read_series(db, variable, key):
    records = db.execute(
        """
        SELECT t.Year, t.Month, t.Day, t.Hour, t.Minute, t.Interval, r.Value
        FROM ReportData r
        JOIN ReportDataDictionary d USING (ReportDataDictionaryIndex)
        JOIN Time t USING (TimeIndex)
        JOIN EnvironmentPeriods e USING (EnvironmentPeriodIndex)
        WHERE e.EnvironmentType = 3 AND t.WarmupFlag = 0
          AND d.ReportingFrequency = 'Zone Timestep'
          AND d.Name = ? COLLATE NOCASE AND d.KeyValue = ? COLLATE NOCASE
        ORDER BY t.TimeIndex
        """,
        (variable, key),
    )
    values = {}
    minutes = None
    for year, month, day, hour, minute, interval, value in records:
        # EnergyPlus SQL stores interval ends. Hour 24 is the next midnight.
        stamp = datetime(year, month, day) + timedelta(hours=hour, minutes=minute - interval)
        if stamp in values or (minutes is not None and interval != minutes):
            raise ValueError(f"Irregular or duplicate timestamps for {variable}, {key}")
        values[stamp] = value
        minutes = interval
    if not values or minutes is None or minutes <= 0 or 60 % minutes:
        raise ValueError(f"Missing or invalid zone timesteps for {variable}, {key}")
    return values, timedelta(minutes=minutes)


def adaptive_limits(weather, year, offset, edition, category):
    daily_samples = defaultdict(list)
    for stamp, temperature in weather.items():
        daily_samples[(stamp + offset).date()].append(temperature)
    daily = {day: fmean(samples) for day, samples in daily_samples.items()}
    may = date(year, 5, 1)
    if edition == "2026":
        weights = (0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0)
        april_seed = math.fsum(
            weight * daily[date(year, 4, day)] for day, weight in zip(range(23, 30), weights)
        ) / 3.8
        seed = 0.8 * april_seed + 0.2 * daily[date(year, 4, 30)]
        base = may
    else:
        base = date(year, 1, 1)
        seed = daily[base]

    result = {}
    for day_number in range((date(year, 10, 1) - may).days):
        day = may + timedelta(days=day_number)
        age = (day - base).days
        # Evaluate the exponential history directly, without the measure's recurrence.
        running = seed * 0.8 ** age + math.fsum(
            0.2 * 0.8 ** (lag - 1) * daily[day - timedelta(days=lag)]
            for lag in range(1, age + 1)
        )
        basis = min(30, max(10, running)) if edition == "2026" else running
        result[day] = (running, 0.33 * basis + (20.8 if category == "I" else 21.8))
    return result


def compare(actual, expected, label):
    equal = (
        math.isclose(float(actual), expected, abs_tol=1e-8, rel_tol=0)
        if isinstance(expected, float) and actual not in (None, "")
        else actual == expected
    )
    if not equal:
        raise ValueError(f"{label}: expected {expected!r}, got {actual!r}")


def audit_zone(db, csv_zone, rows, weather, step, limits, args):
    name = csv_zone.removeprefix("TM59 text: ")
    if name.startswith("'"):
        key_exists = db.execute(
            """
            SELECT 1 FROM ReportDataDictionary
            WHERE Name = 'Zone Operative Temperature' COLLATE NOCASE AND KeyValue = ? COLLATE NOCASE
            """,
            (name,),
        ).fetchone()
        if key_exists is None:
            name = name[1:]
    temperatures, zone_step = read_series(db, "Zone Operative Temperature", name)
    compare(zone_step, step, name)
    if temperatures.keys() != weather.keys():
        raise ValueError(f"{name}: operative temperature timestamps differ from outdoor timestamps")
    occupants = {}
    if args.edition == "2017":
        occupants, occupancy_step = read_series(db, "Zone People Occupant Count", name)
        compare(occupancy_step, step, f"{name} occupancy timestep")
        if occupants.keys() != weather.keys():
            raise ValueError(f"{name}: occupancy timestamps differ from outdoor timestamps")

    first_row = next(rows)
    room_type = first_row["RoomType"]
    criterion = {
        "living_kitchen": "A", "bedroom": "A", "living_kitchen_mechanical": "C",
        "bedroom_mechanical": "C", "communal": "D",
    }[room_type]
    if args.edition == "2017" and criterion != "A":
        raise ValueError(f"{name}: this audit covers only natural-ventilation mode in 2017")
    bedroom = room_type in ("bedroom", "bedroom_mechanical")
    offset = timedelta(hours=int(args.clock == "GMT"))
    step_hours = step.total_seconds() / 3600
    night_means = {}
    if bedroom and args.edition == "2026":
        for day in limits:
            start = datetime.combine(day, time(23)) - offset
            night_means[start] = fmean(
                temperatures[start + step * interval] for interval in range(timedelta(hours=9) // step)
            )

    occupied_steps = hot_steps = bedroom_samples = hot_bedroom_samples = 0
    bins = [0, 0, 0]
    sleep_limit = 27 if args.edition == "2026" and args.category == "II" else 26
    row_count = 0
    for row, stamp in zip(chain((first_row,), rows), temperatures, strict=True):
        row_count += 1
        label = f"{name}, {stamp}"
        compare(datetime.strptime(row["SimulationIntervalStart"], "%Y-%b-%d %H:%M:%S"), stamp, label)
        compare(row["RoomType"], room_type, f"{label} room type")
        compare(row["OccupiedCriterion"], criterion, f"{label} criterion")
        top = temperatures[stamp]
        compare(row["ZoneOperativeTemp_C"], top, f"{label} operative temperature")
        local = stamp + offset
        summer = local.date() in limits
        if summer:
            for index, threshold in enumerate((26, 27, 28)):
                bins[index] += top > threshold
        if args.edition == "2017":
            compare(row["ZonePeopleOccupantCount"], occupants[stamp], f"{label} occupants")
            occupied = summer and occupants[stamp] > 0
        else:
            occupied = summer and (bedroom or criterion == "D" or time(9) <= local.time() < time(22))

        hot = False
        if occupied:
            if criterion == "A":
                running, limit = limits[local.date()]
                compare(row["RunningMeanOutdoorTemp_C"], running, f"{label} running mean")
                hot = top >= limit + 0.5 - 5e-10
            else:
                limit = 26.0 if criterion == "C" else 28.0
                hot = top > limit
            compare(row["OccupiedCriterionLimit_C"], limit, f"{label} temperature limit")
        compare(row["OccupiedCriterionApplies"], str(occupied).lower(), f"{label} occupied")
        compare(row["OccupiedCriterionExceeds"], str(hot).lower(), f"{label} exceedance")
        occupied_steps += occupied
        hot_steps += hot

        if args.edition == "2026":
            mean = night_means.get(stamp)
            sample = mean is not None
            compare(row["BedroomNightMean_C"], mean if sample else "", f"{label} night mean")
            hot_bedroom = sample and mean > sleep_limit
        else:
            sample = bedroom and (local.time() >= time(22) or local.time() < time(7))
            hot_bedroom = sample and top > sleep_limit
        compare(row["CriterionBSample"], str(sample).lower(), f"{label} bedroom sample")
        compare(row["CriterionBExceeds"], str(hot_bedroom).lower(), f"{label} bedroom exceedance")
        bedroom_samples += sample
        hot_bedroom_samples += hot_bedroom

    return {
        "criterion": criterion, "rows": row_count,
        "occupied_hours": occupied_steps * step_hours, "exceeded_hours": hot_steps * step_hours,
        "percent": 100 * hot_steps / occupied_steps, "pass": 100 * hot_steps <= 3 * occupied_steps,
        "bedroom_exceedance": hot_bedroom_samples if args.edition == "2026" else hot_bedroom_samples * step_hours,
        "bedroom_pass": (
            hot_bedroom_samples <= 4 if args.edition == "2026" else 100 * hot_bedroom_samples <= bedroom_samples
        ) if bedroom else None,
        "bins": [count * step_hours for count in bins],
    }


def verify_outputs(path, zones, edition):
    workflow = json.loads(path.read_text(encoding="utf-8-sig"))
    steps = [
        {item["name"]: item["value"] for item in (step.get("result") or {}).get("step_values", [])}
        for step in workflow["steps"]
    ]
    (actual,) = [step for step in steps if "tm_crit_a_pass" in step]
    expected = {}
    for criterion in ("A", "C", "D"):
        prefix = f"tm_crit_{criterion.lower()}"
        matching = [row for row in zones if row["criterion"] == criterion]
        expected[prefix + "_pass"] = "N/A"
        if matching:
            worst = max(matching, key=lambda row: (row["percent"], row["exceeded_hours"]))
            expected[prefix + "_hours"] = worst["exceeded_hours"]
            expected[prefix + "_pct"] = worst["percent"]
            expected[prefix + "_pass"] = "Pass" if all(row["pass"] for row in matching) else "Fail"
    bedrooms = [row for row in zones if row["bedroom_pass"] is not None]
    expected["tm_crit_b_pass"] = "N/A"
    if bedrooms:
        key = "tm_crit_b_nights" if edition == "2026" else "tm_crit_b_hours"
        expected[key] = max(row["bedroom_exceedance"] for row in bedrooms)
        expected["tm_crit_b_pass"] = "Pass" if all(row["bedroom_pass"] for row in bedrooms) else "Fail"
    for index, word in enumerate(("six", "seven", "eight")):
        expected[f"tm_hours_over_twenty_{word}_c"] = max(row["bins"][index] for row in zones)
    reported = {key: value for key, value in actual.items() if key.startswith(("tm_crit_", "tm_hours_over_"))}
    compare(set(reported), set(expected), "registered output names")
    for key, value in expected.items():
        compare(reported[key], value, key)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sql", type=Path, help="EnergyPlus eplusout.sql")
    parser.add_argument("csv", type=Path, help="TM59 timestep CSV")
    parser.add_argument("--edition", required=True, choices=("2017", "2026"))
    parser.add_argument("--category", default="II", choices=("I", "II"))
    parser.add_argument("--clock", default="Local", choices=("Local", "GMT"))
    parser.add_argument("--out-osw", type=Path, help="Also verify registered outputs in out.osw")
    args = parser.parse_args()
    if args.edition == "2017" and args.clock != "Local":
        parser.error("2017 uses the simulation clock")

    try:
        with closing(sqlite3.connect(args.sql.resolve().as_uri() + "?mode=ro", uri=True)) as db:
            db.execute("PRAGMA trusted_schema = OFF")
            db.execute("PRAGMA query_only = ON")
            weather, step = read_series(db, "Site Outdoor Air Drybulb Temperature", "Environment")
            year = next(iter(weather)).year
            first = datetime(year, 1, 1)
            total = (datetime(year + 1, 1, 1) - first) // step
            if len(weather) != total or any(stamp != first + index * step for index, stamp in enumerate(weather)):
                raise ValueError("Expected one complete calendar year of outdoor temperatures")
            offset = timedelta(hours=int(args.clock == "GMT"))
            limits = adaptive_limits(weather, year, offset, args.edition, args.category)
            zones = {}
            with args.csv.open(encoding="utf-8-sig", newline="") as stream:
                groups = groupby(csv.DictReader(stream), key=lambda row: row["Zone"])
                for zone, rows in groups:
                    if zone in zones:
                        raise ValueError(f"Duplicate section for zone {zone}")
                    zones[zone] = audit_zone(db, zone, rows, weather, step, limits, args)
        if not zones:
            raise ValueError("The report contains no selected zones")
        if args.out_osw:
            verify_outputs(args.out_osw, list(zones.values()), args.edition)
    except (KeyError, OSError, TypeError, ValueError, ZeroDivisionError, sqlite3.Error) as error:
        parser.exit(1, f"TM59 audit failed: {error}\n")

    print(json.dumps(zones, indent=2))
    print(f"TM59:{args.edition} SQL audit passed for {sum(row['rows'] for row in zones.values()):,} rows.")


if __name__ == "__main__":
    main()
