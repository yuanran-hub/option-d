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



# Only dictionary-listed, transitive verb/particle pairs accept an intervening object.
SEPARABLE = {
    "break": {"down", "up"}, "bring": {"back", "up"}, "call": {"back", "off"}, "carry": {"out"},
    "cut": {"off"}, "figure": {"out"}, "fill": {"in", "out"},
    "give": {"away", "back", "up"}, "hand": {"in", "out"},
    "hold": {"up"}, "leave": {"out"}, "let": {"down"},
    "look": {"up"}, "pay": {"back", "off"}, "pick": {"up", "out"},
    "point": {"out"}, "pull": {"off"}, "put": {"away", "back", "off", "on", "out"},
    "rule": {"out"}, "set": {"up"}, "sort": {"out"},
    "take": {"back", "off", "out", "over"}, "throw": {"away", "out"},
    "turn": {"down", "off", "on"}, "work": {"out"}, "write": {"down", "off"},
}
OBJECTS = set("me you him her it us them this that these those something someone everything nothing".split())
DETERMINERS = set("a an the my your his her its our their this that these those some another both".split())
BOUNDARIES = set("and or but nor so if when while because who which that where to of in for with from at by as is was were are be been have has had do does did will would can could may might must should".split())
AFTER_PARTICLE = set("and or but so yet because if when before after while until though for from with by at in on to again yesterday tomorrow today immediately completely instead too then".split())


def split_candidates(db, spellings, ends, cache, pos_cache, start):
    def categories(word):
        if word not in pos_cache:
            row = db.execute("SELECT translation FROM words WHERE word=?", (word,)).fetchone()
            pos_cache[word] = set(re.findall(r"(?:^|\\n)([a-z]+)\.", (row[0] or "") if row else ""))
        return pos_cache[word]

    def noun_group(words):
        if len(words) == 1 and words[0] in OBJECTS:
            return True
        has_det = words[0] in DETERMINERS
        core = words[1:] if has_det else words
        if not core or any(w in BOUNDARIES or w in DETERMINERS for w in core):
            return False
        return "n" in categories(core[-1]) and all(
            categories(w) & {"a", "adj", "n"} for w in core[:-1])

    for base in cache[spellings[start]]:
        particles = SEPARABLE.get(base)
        if not particles:
            continue
        for end in range(start + 2, min(start + 7, len(spellings))):
            if ends[end-2] or ends[end-1]:
                break
            particle = spellings[end]
            if particle not in particles or not noun_group(spellings[start+1:end]):
                continue
            if not ends[end] and spellings[end+1] not in AFTER_PARTICLE:
                continue
            if not ends[end] and spellings[end+1:end+3] in (["and", "down"], ["and", "up"]):
                continue
            yield start, end, [base + " " + particle], True


def recognize(text, dictionary, cancelled=lambda: False):
    tokens = list(TOKEN.finditer(text))
    spellings = [normalized(m[0]) for m in tokens]
    ends = [i + 1 == len(tokens) or not text[m.end():tokens[i+1].start()].isspace()
            for i, m in enumerate(tokens)]
    matches, cache, pos_cache = [], {}, {}
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
                windows.extend(split_candidates(db, spellings, ends, cache, pos_cache, start))
                for end in range(start + 1, min(start + MAX_WORDS, len(tokens))):
                    tail = " " + " ".join(spellings[start+1:end+1])
                    windows.append((start, end, [base + tail for base in cache[head]], False))
                    if ends[end]:
                        break
            keys = list(dict.fromkeys(k for _, _, options, _ in windows for k in options))
            known = set()
            for i in range(0, len(keys), 400):
                batch = keys[i:i+400]
                placeholders = ",".join("?" for _ in batch)
                known.update(r[0].lower() for r in db.execute(
                    f"SELECT word FROM words WHERE word IN ({placeholders}) AND translation != ''", batch))
            for start, end, options, split in windows:
                lemma = next((k for k in options if k in known), None)
                if lemma:
                    matches.append((start, end, lemma, split))
    # Longer dictionary expressions take priority over embedded fragments.
    occupied, choices = set(), []
    for start, end, lemma, split in sorted(matches, key=lambda m: (m[0]-m[1], m[3], m[0])):
        span = [start, end] if split else range(start, end+1)
        if occupied.isdisjoint(span):
            occupied.update(span)
            choices.append({"first": start, "last": end, "lemma": lemma, **({"parts": span} if split else {})})
    choices.sort(key=lambda x: x["first"])
    exact = bool(choices and "parts" not in choices[0] and choices[0]["first"] == 0 and choices[0]["last"] == len(tokens)-1
                 and not text[:tokens[0].start()].strip(PUNCTUATION)
                 and not text[tokens[-1].end():].strip(PUNCTUATION))
    return {"choices": choices, "exact": exact}
