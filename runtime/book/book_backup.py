"""Create a portable backup from a read-only snapshot, without taking the lookup writer's lock."""
import argparse
import os
import sqlite3
import tempfile
from contextlib import closing
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import backend


def snapshot(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as live:
        with closing(sqlite3.connect(target)) as copy:
            live.backup(copy, pages=32, sleep=0.02)


def backup(root, target):
    # Build away from the final filename so cancelling or running out of space preserves prior backups.
    with tempfile.TemporaryDirectory(dir=target.parent) as folder:
        stage = Path(folder)
        reading = stage / "Reading"
        records = Path("Reading/.查词数据/records.sqlite")
        snapshot(root / records, stage / records)
        with closing(sqlite3.connect(stage / records)) as db:
            db.row_factory = sqlite3.Row
            backend.export_records(stage, backend.records(db, root))
        cache = records.parent / "examples.sqlite"
        if (root / cache).exists():
            snapshot(root / cache, stage / cache)
        bundle = stage / "词库.zip"
        with ZipFile(bundle, "w", compression=ZIP_DEFLATED) as archive:
            for file in reading.rglob("*"):
                if file.is_file():
                    archive.write(file, file.relative_to(stage))
        os.replace(bundle, target)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    backup(args.root, args.output)
