"""
Generate anonymized synthetic test fixtures for LG166 and LG298.

Reads the real annotation structure, replaces identifying strings (strain names,
drug names), and replaces all OD measurements with synthetic logistic growth
curves that follow the same qualitative pattern as the real data.

Run from the repo root:
    python test/generate_fixtures.py
"""

import csv
import json
import os
import re
import numpy as np

RNG = np.random.default_rng(42)

FIXTURE_DIR = os.path.join(os.path.dirname(__file__), "fixtures", "clean")

# ---------------------------------------------------------------------------
# String anonymization
# ---------------------------------------------------------------------------

STRAIN_MAP = {
    "BW25113 (DSM)": "WT",
    "DA56652": "WT",
}

DRUG_MAP = {
    "Chloramphenicol": "Drug_A",
    "Rifampicin": "Drug_B",
    "CCCP": "Drug_C",
}

MEDIA_MAP = {
    "M9+glucose": "Media_1",
    "M9 + 0.2% Glucose": "Media_1",
}


def anonymize(s: str) -> str:
    for orig, repl in STRAIN_MAP.items():
        s = s.replace(orig, repl)
    for orig, repl in DRUG_MAP.items():
        s = s.replace(orig, repl)
    for orig, repl in MEDIA_MAP.items():
        s = s.replace(orig, repl)
    return s


# ---------------------------------------------------------------------------
# Synthetic growth curve generation
# ---------------------------------------------------------------------------

def logistic(t, N0, Nmax, gr, lag):
    """Three-parameter logistic growth model."""
    return N0 + (Nmax - N0) / (1.0 + np.exp(-gr * (t - lag)))


def synthetic_od(time: np.ndarray, is_blank: bool, nmax_base: float = 0.9) -> np.ndarray:
    """Return a synthetic OD trace."""
    if is_blank:
        base = 0.085 + RNG.uniform(-0.002, 0.002)
        noise = RNG.normal(0, 0.0008, len(time))
        od = base + noise
        return np.round(np.clip(od, 0.080, 0.092), 3)

    N0  = 0.090 + RNG.uniform(-0.003, 0.003)
    Nmax = nmax_base * (1.0 + RNG.uniform(-0.08, 0.08))
    gr  = 0.38 + RNG.uniform(-0.10, 0.10)
    lag = 10.0 + RNG.uniform(-4.0, 4.0)

    od = logistic(time, N0, Nmax, gr, lag)
    od += RNG.normal(0, 0.002, len(time))
    return np.round(np.clip(od, 0.075, 1.35), 3)


def nmax_from_condition(condition: str, base: float) -> float:
    """
    Derive Nmax from the (already anonymised) condition string.
    Higher drug concentrations → lower Nmax, following a simple MIC sigmoid.
    """
    m = re.search(r"Drug_[A-Z]_(\d+(?:\.\d+)?)", condition)
    if not m:
        return base
    conc = float(m.group(1))
    # Hill-type reduction: half-maximal at concentration 15
    reduction = 1.0 / (1.0 + (conc / 15.0) ** 1.5)
    return max(base * reduction, 0.10)


# ---------------------------------------------------------------------------
# Per-experiment definitions
# ---------------------------------------------------------------------------

WELLS_48 = [f"{r}{c}" for r in "ABCDEF" for c in range(1, 9)]


def blank_wells_from_annotation(annotation_path: str) -> set:
    """Return the set of wells marked 'b' in an annotation_clean.csv."""
    blanks = set()
    with open(annotation_path, newline="", encoding="utf-8") as f:
        for row in csv.reader(f):
            if len(row) >= 2 and row[1].strip() == "b":
                blanks.add(row[0].strip())
    return blanks


def read_time_column(data_path: str) -> np.ndarray:
    """Read the Time column from a data_channel_N.csv."""
    times = []
    with open(data_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            times.append(float(row["Time"]))
    return np.array(times)


# ---------------------------------------------------------------------------
# Write helpers
# ---------------------------------------------------------------------------

def write_data_csv(path: str, time: np.ndarray, od_matrix: dict):
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["Time"] + WELLS_48)
        for i, t in enumerate(time):
            row = [t] + [od_matrix[w][i] for w in WELLS_48]
            writer.writerow(row)


def anonymize_csv(src_path: str, dst_path: str):
    """Read, anonymize all cells, then write (handles src == dst safely)."""
    with open(src_path, newline="", encoding="utf-8") as fin:
        rows = [[anonymize(cell) for cell in row] for row in csv.reader(fin)]
    with open(dst_path, "w", newline="", encoding="utf-8") as fout:
        csv.writer(fout).writerows(rows)


write_annotation_clean = anonymize_csv
write_annotation_channel = anonymize_csv


# ---------------------------------------------------------------------------
# LG166 — single channel, 48 wells, ~493 time points
# ---------------------------------------------------------------------------

def generate_lg166():
    src = os.path.join(FIXTURE_DIR, "LG166")
    dst = src  # overwrite in place

    time = read_time_column(os.path.join(src, "data_channel_1.csv"))

    annotation_path = os.path.join(src, "annotation_clean.csv")
    blanks = blank_wells_from_annotation(annotation_path)

    # Read condition per well for Nmax scaling
    conditions = {}
    with open(annotation_path, newline="", encoding="utf-8") as f:
        for row in csv.reader(f):
            if len(row) >= 2:
                well = row[0].strip()
                # columns: well, condition, media, carbon, antibiotic, ...
                anon_row = [anonymize(c) for c in row]
                cond_parts = [p for p in anon_row[1:] if p and p not in ("b", "X")]
                conditions[well] = "_".join(cond_parts)

    od_matrix = {}
    for w in WELLS_48:
        is_blank = w in blanks
        cond = conditions.get(w, "")
        nmax = nmax_from_condition(cond, base=0.95)
        od_matrix[w] = synthetic_od(time, is_blank=is_blank, nmax_base=nmax)

    write_data_csv(os.path.join(dst, "data_channel_1.csv"), time, od_matrix)
    write_annotation_clean(annotation_path, annotation_path)

    # Per-channel annotation file
    ch_ann = os.path.join(src, "annotation_channel_1_media_M9+glucose.csv")
    if os.path.exists(ch_ann):
        write_annotation_channel(ch_ann, ch_ann)

    with open(os.path.join(dst, "metadata.json"), "w") as f:
        json.dump({"well_count": 48}, f)

    print(f"LG166: {len(time)} time points, {len(WELLS_48)} wells, {len(blanks)} blanks")


# ---------------------------------------------------------------------------
# LG298 — 3 channels, 48 wells, ~433 time points
# ---------------------------------------------------------------------------

# Per-channel blank wells (A8, B8, C8, D8, E8, F8 are blanks based on annotation)
LG298_BLANKS = {"A8", "B8", "C8", "D8", "E8", "F8"}

# Per-channel Nmax base (OD scale is lower than LG166 — fluorescence channels)
LG298_NMAX = {1: 0.38, 2: 0.42, 3: 0.35}


def generate_lg298():
    src = os.path.join(FIXTURE_DIR, "LG298")
    dst = src

    # Build conditions from channel-1 per-channel annotation (if present)
    ch1_ann = os.path.join(src, "annotation_channel_1_media_M9 + 0.2% Glucose.csv")
    conditions = {}
    if os.path.exists(ch1_ann):
        with open(ch1_ann, newline="", encoding="utf-8") as f:
            for row in csv.reader(f):
                if row:
                    well = row[0].strip()
                    cond = anonymize(row[1].strip()) if len(row) > 1 else ""
                    conditions[well] = cond

    for ch in [1, 2, 3]:
        data_path = os.path.join(src, f"data_channel_{ch}.csv")
        if not os.path.exists(data_path):
            continue

        time = read_time_column(data_path)
        nmax_base = LG298_NMAX[ch]

        od_matrix = {}
        for w in WELLS_48:
            is_blank = w in LG298_BLANKS
            cond = conditions.get(w, "")
            nmax = nmax_from_condition(cond, base=nmax_base)
            od_matrix[w] = synthetic_od(time, is_blank=is_blank, nmax_base=nmax)

        write_data_csv(data_path, time, od_matrix)
        print(f"LG298 ch{ch}: {len(time)} time points")

    # Anonymize all annotation files
    for fname in os.listdir(src):
        if fname.endswith(".csv"):
            fpath = os.path.join(src, fname)
            write_annotation_channel(fpath, fpath)

    # LG298 has no metadata.json — create one
    with open(os.path.join(dst, "metadata.json"), "w") as f:
        json.dump({"well_count": 48}, f)

    print(f"LG298: blanks={LG298_BLANKS}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    generate_lg166()
    generate_lg298()
    print("Done — synthetic fixtures written.")
