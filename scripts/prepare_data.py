"""Fetch pinned upstream dictionaries and build the two offline search databases."""
import gzip
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))
from backend import build_dictionary

CACHE = ROOT / ".build/data"
ECDICT = "82c9872576b23118d7c42e920c11beb77f510ae2"
WORDSET = "4503bfafbe4556361a296b9d368c18168dfb56c3"


def download(url, name, digest):
    path = CACHE / name
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
        return path
    temp = path.with_suffix(".download")
    subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--output", str(temp), url], check=True)
    if hashlib.sha256(temp.read_bytes()).hexdigest() != digest:
        raise ValueError("Unexpected checksum for " + name)
    temp.replace(path)
    return path


def build_examples(source, destination):
    temp = destination.with_suffix(".building")
    temp.unlink(missing_ok=True)
    with gzip.open(source, "rt", encoding="utf-8") as stream:
        entries = json.load(stream)
    with sqlite3.connect(temp) as db:
        db.execute("CREATE TABLE examples (lemma TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        for spelling, entry in entries.items():
            word = spelling.lower()
            for meaning in entry.get("meanings", []):
                sentence = meaning.get("example", "").strip()
                if not (5 <= len(sentence.split()) <= 25):
                    continue
                if word not in sentence.lower() or not re.search(r"(?<![\w'-])" + re.escape(word) + r"(?![\w'-])", sentence, re.I):
                    continue
                payload = {"text": sentence, "source": "Wordset", "kind": "dictionary",
                           "sense": meaning.get("def", ""), "license": "CC BY-SA 4.0",
                           "source_url": "https://github.com/wordset/wordset-dictionary/tree/" + WORDSET}
                db.execute("INSERT OR IGNORE INTO examples VALUES (?, ?)", (word, json.dumps(payload, ensure_ascii=False)))
                break
    db.close()
    temp.replace(destination)


if __name__ == "__main__":
    CACHE.mkdir(parents=True, exist_ok=True)
    words = download(f"https://raw.githubusercontent.com/skywind3000/ECDICT/{ECDICT}/ecdict.csv",
                     "ecdict.csv", "1a6947e04785db63613a92e14903cdae7954f7e84860b10e68e5c7cbb3f9c3cf")
    examples = download(f"https://raw.githubusercontent.com/wordset/wordset-dictionary/{WORDSET}/allwords_wordset.json.gz",
                        "wordset.json.gz", "5702e39c0049de5a2ef4639ab44adb84d47110d998beafdd74f8e04f160f30c9")
    build_dictionary(words, CACHE / "dictionary.sqlite")
    build_examples(examples, CACHE / "examples.sqlite")
