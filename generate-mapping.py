#!/usr/bin/env python3
"""Generate SSID mapping file from the fleet CSV.

Usage: python3 generate-mapping.py <fleet.csv> > mapping.txt

Output format: org-code=bb-<epoch>, one per line (matches SSH config aliases).
"""

import csv
import sys


def main():
    if len(sys.argv) < 2:
        print("Usage: generate-mapping.py <fleet.csv>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        reader = csv.reader(f)
        headers = next(reader)
        for row in reader:
            if len(row) < 13:
                continue
            org = row[0].strip()
            code = row[1].strip()
            bb = row[12].strip()
            if not bb or not bb.startswith("bb-"):
                continue
            key = f"{org}-{code}".lower().replace(" ", "-")
            print(f"{key}={bb}")


if __name__ == "__main__":
    main()
