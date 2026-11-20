"""Match contiguous English expressions against indexed ECDICT headwords."""
import re
import sqlite3
import string
from contextlib import closing

TOKEN = re.compile(r"[A-Za-z]+(?:['’‐‑-][A-Za-z]+)*")
MAX_WORDS = 16
PUNCTUATION = string.whitespace + string.punctuation + "“”‘’…。！？"
CHARACTERS = str.maketrans({"’": "'", "‐": "-", "‑": "-"})


def normalized(text):
    return " ".join(text.translate(CHARACTERS).lower().split())


def heads(db, word):
    # Keep the remaining expression intact, especially fixed plurals such as “beans”.
    row = db.execute("SELECT exchange FROM words WHERE word=?", (word,)).fetchone()
    exchange = dict(item.split(":", 1) for item in ((row[0] or "") if row else "").split("/") if ":" in item)
    forms = [word] + exchange.get("0", "").split(",")
    forms.extend(r[0] for r in db.execute("SELECT DISTINCT lemma FROM variants WHERE form=?", (word,)))
    return tuple(dict.fromkeys(f for f in forms if f and " " not in f))


def resolve(db, phrase):
    head, tail = normalized(phrase).split(" ", 1)
    for base in heads(db, head):
        entry = db.execute("SELECT * FROM words WHERE word=? AND translation != ''", (base + " " + tail,)).fetchone()
        if entry:
            return entry
    return None


def recognize(text, dictionary, cancelled=lambda: False):
    tokens = list(TOKEN.finditer(text))
    spellings = [normalized(m[0]) for m in tokens]
    ends = [i + 1 == len(tokens) or not text[m.end():tokens[i+1].start()].isspace()
            for i, m in enumerate(tokens)]
    matches, cache = [], {}
    with closing(sqlite3.connect(dictionary.as_uri() + "?mode=ro", uri=True)) as db:
        for offset in range(0, len(tokens), 32):
            if cancelled():
                return {}
            windows = []
            for start in range(offset, min(offset + 32, len(tokens))):
                if ends[start]:
                    continue
                head = spellings[start]
                if head not in cache:
                    cache[head] = heads(db, head)
                for end in range(start + 1, min(start + MAX_WORDS, len(tokens))):
                    tail = " " + " ".join(spellings[start+1:end+1])
                    windows.append((start, end, [base + tail for base in cache[head]]))
                    if ends[end]:
                        break
            keys = list(dict.fromkeys(k for _, _, options in windows for k in options))
            known = set()
            for i in range(0, len(keys), 400):
                batch = keys[i:i+400]
                placeholders = ",".join("?" for _ in batch)
                known.update(r[0].lower() for r in db.execute(
                    f"SELECT word FROM words WHERE word IN ({placeholders}) AND translation != ''", batch))
            for start, end, options in windows:
                lemma = next((k for k in options if k in known), None)
                if lemma:
                    matches.append((start, end, lemma))
    # Longer dictionary expressions take priority over embedded fragments.
    occupied, choices = set(), []
    for start, end, lemma in sorted(matches, key=lambda m: (m[0]-m[1], m[0])):
        span = range(start, end+1)
        if occupied.isdisjoint(span):
            occupied.update(span)
            choices.append({"first": start, "last": end, "lemma": lemma})
    choices.sort(key=lambda x: x["first"])
    exact = bool(choices and choices[0]["first"] == 0 and choices[0]["last"] == len(tokens)-1
                 and not text[:tokens[0].start()].strip(PUNCTUATION)
                 and not text[tokens[-1].end():].strip(PUNCTUATION))
    return {"choices": choices, "exact": exact}
