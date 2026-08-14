#!/usr/bin/env python3
"""Generate the compact, anonymized LG281 parser regression fixture.

The historical LG281 fixture contained a complete plate-reader export with
local paths, instrument metadata, inventory identifiers and real measurements.
This replacement preserves only the file structure needed by the Synergy and
LabGuru adapters. All labels are synthetic and all measurements are generated
from a fixed pseudo-random seed.

Run from the repository root:

    python test/generate_lg281_fixture.py
"""

from __future__ import annotations

import csv
import random
from pathlib import Path


ROOT = Path(__file__).resolve().parent / "fixtures"
RAW = ROOT / "raw" / "LG281"
CLEAN = ROOT / "clean" / "LG281"
ROWS = "ABCDEF"
WELLS = [f"{row}{column}" for row in ROWS for column in range(1, 9)]
TIMES = [f"00:{minute:02d}:00" for minute in range(0, 25, 6)]
SEED = 281


def write_csv(path: Path, rows: list[list[str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        csv.writer(handle, delimiter=";", lineterminator="\n").writerows(rows)


def measurement_values() -> dict[int, list[list[str]]]:
    rng = random.Random(SEED)
    values: dict[int, list[list[str]]] = {}
    for channel in range(1, 4):
        channel_rows = []
        for time_index in range(len(TIMES)):
            row = []
            for well_index in range(len(WELLS)):
                baseline = 0.04 * channel + 0.018 * time_index
                well_effect = 0.0005 * well_index
                value = baseline + well_effect + rng.uniform(-0.002, 0.002)
                row.append(f"{value:.6f}")
            channel_rows.append(row)
        values[channel] = channel_rows
    return values


def build_raw_data(values: dict[int, list[list[str]]]) -> None:
    width = 3 + len(WELLS)
    rows = [["Synthetic Synergy fixture", "ANONYMIZED"] + [""] * (width - 2)]
    for channel in range(1, 4):
        rows.append(["", "Time", f"T synthetic channel {channel}", *WELLS])
        for timestamp, readings in zip(TIMES, values[channel]):
            # Decimal commas deliberately exercise locale-aware parsing.
            rows.append(["", timestamp, "37", *[x.replace(".", ",") for x in readings]])
        rows.append([""] * width)
    write_csv(RAW / "data.csv", rows)


def build_plate_layout() -> None:
    rows = [
        ["Synthetic plate", "C_48", "", "Plate Layout", "", "", "", "", "", "", "", "", "", ""],
        ["", "", "", "Row", "Column", "Control", "Inventory Collection", "Inventory ID", "Item Name", "Stock ID", "Stock Name", "Concentration", "Well Annotation", "Color"],
    ]
    for well in WELLS:
        row, column = well[0], well[1:]
        annotation = "b" if column == "8" else "12&R1"
        rows.append(["", "", "", row, column, "no", "Bacterium", "TEST-ID", "TEST_STRAIN", "", "", "", annotation, ""])
        rows.append(["", "", "", row, column, "no", "Media", "TEST-ID", "TEST_MEDIUM", "", "", "", annotation, ""])
    write_csv(RAW / "plate.csv", rows)


def build_golden_data(values: dict[int, list[list[str]]]) -> None:
    for channel in range(1, 4):
        rows = [["Time", *WELLS]]
        for time_index, readings in enumerate(values[channel]):
            rows.append([f"{time_index / 10:.1f}", *readings])
        path = CLEAN / f"data_channel_{channel}.csv"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8", newline="") as handle:
            csv.writer(handle, lineterminator="\n").writerows(rows)


def build_golden_annotations() -> None:
    full = []
    reduced = []
    for well in WELLS:
        if well[1:] == "8":
            full.append([well, "b", "TEST_MEDIUM", "", ""])
            reduced.append([well, "b"])
        else:
            full.append([well, "TEST_STRAIN", "TEST_MEDIUM", "R1", "12"])
            reduced.append([well, "TEST_STRAIN_TEST_MEDIUM_R1"])
    write_csv(CLEAN / "annotation_clean.csv", full)
    for channel in (1, 2):
        write_csv(CLEAN / f"annotation_channel_{channel}_media_TEST_MEDIUM.csv", reduced)


def main() -> None:
    values = measurement_values()
    build_raw_data(values)
    build_plate_layout()
    build_golden_data(values)
    build_golden_annotations()
    print(f"Wrote anonymized LG281 fixture (seed={SEED})")


if __name__ == "__main__":
    main()
