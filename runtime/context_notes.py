"""Position-specific reading notes. Token indexes match the native passage tokenizer."""
import json
import re

from phrase_lookup import TOKEN, normalized

FIELDS = ("meaning", "translation", "nuance")
SCHEMA = """CREATE TABLE IF NOT EXISTS occurrences (
    lemma TEXT NOT NULL, text TEXT NOT NULL, slot TEXT NOT NULL, note TEXT,
    PRIMARY KEY (lemma,text,slot))"""


def slot_for(parts):
    return ",".join(str(x) for x in parts)


def surfaces(text, parts):
    tokens = list(TOKEN.finditer(text))
    if not parts or any(type(i) is not int or i < 0 or i >= len(tokens) for i in parts):
        raise ValueError("请在原文中重新选词。")
    if parts != sorted(set(parts)):
        raise ValueError("选词位置已变化，请重新选词。")
    return [tokens[i][0] for i in parts]


def validate_selection(text, parts, term):
    if normalized(" ".join(surfaces(text, parts))) != normalized(term):
        raise ValueError("所选词与原文位置不一致。")


def clean_note(note):
    if not isinstance(note, dict) or any(not isinstance(note.get(k), str) or len(note[k]) > 12000 for k in FIELDS):
        raise ValueError("解释格式不完整，请重试。")
    result = {key: note[key].strip() for key in FIELDS}
    if not result["meaning"]:
        raise ValueError("句中义不能为空。")
    return result


def read(db, lemma, text, slot, requested_ns):
    deleted = db.execute("SELECT cutoff_ns FROM book_deletions WHERE lemma=?", (lemma,)).fetchone()
    row = db.execute("SELECT note FROM occurrences WHERE lemma=? AND text=? AND slot=?",
                     (lemma, text, slot)).fetchone()
    if not row or (deleted and requested_ns <= deleted[0]):
        raise ValueError("这个原文位置尚未收录或已删除，请重新查词。")
    return json.loads(row[0]) if row[0] else None


def for_export(db):
    result = {}
    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='occurrences'").fetchone():
        for lemma, text, slot, note in db.execute("SELECT lemma,text,slot,note FROM occurrences"):
            parts = [int(i) for i in slot.split(",")]
            occurrence = {"parts": parts}
            if note:
                occurrence["note"] = json.loads(note)
            result.setdefault((lemma, text), []).append(occurrence)
        for group in result.values():
            group.sort(key=lambda item: item["parts"])
    return result


def segments(context):
    """Highlight the clicked tokens; use spelling matching for earlier records."""
    text = context["text"]
    tokens = list(TOKEN.finditer(text))
    marked = set()
    positioned = set()
    for item in context.get("occurrences", []):
        indices = item["parts"]
        marked.update(indices)
        positioned.add(normalized(" ".join(tokens[i][0] for i in indices)))
    for form in context["forms"]:
        if normalized(form) in positioned:
            continue
        pattern = re.escape(form).replace(r"\ ", r"\s+")
        for match in re.finditer(r"(?<![a-z])" + pattern + r"(?![a-z])", text, re.I):
            marked.update(i for i,m in enumerate(tokens) if match.start() <= m.start() < match.end())
    offset = 0
    for i in sorted(marked):
        token = tokens[i]
        yield text[offset:token.start()], False
        yield token[0], True
        offset = token.end()
    yield text[offset:], False


def note_lines(context):
    for occurrence in context.get("occurrences", []):
        note = occurrence.get("note")
        if note:
            yield "这句里 · " + note["meaning"]
            if note["translation"]:
                yield note["translation"]
            if note["nuance"]:
                yield note["nuance"]
