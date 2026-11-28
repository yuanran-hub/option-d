"""Offline selected-word lookup and atomic IELTS reading-vocabulary collection."""
import argparse
import csv
import fcntl
import html
import json
import os
import re
import sqlite3
import sys
import time
from concurrent.futures import ThreadPoolExecutor
import unicodedata

import context_notes
import phrase_lookup
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "vendor"))
ROOT = Path(os.environ.get("IELTS_LOOKUP_TEST_ROOT", Path.home() / "Library/Application Support/OptionD"))
DATA = Path(os.environ.get("OPTION_D_DICTIONARY_DATA", Path(__file__).resolve().parent / "data")).resolve()


def phonetic_supplements():
    """Verified pronunciations for entries missing them in the offline dictionary."""
    path = DATA / "phonetic_supplements.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def phonetic_label(value):
    phonetic = (value or "").strip().strip("/[]")
    return f"音标 /{phonetic}/" if phonetic else "音标待补"


def build_dictionary(source, target):
    temporary = target.with_suffix(".building")
    temporary.unlink(missing_ok=True)
    db = sqlite3.connect(temporary)
    db.execute("CREATE TABLE words (word TEXT PRIMARY KEY COLLATE NOCASE, phonetic TEXT, translation TEXT, definition TEXT, exchange TEXT)")
    db.execute("CREATE TABLE variants (form TEXT COLLATE NOCASE, lemma TEXT)")
    rows, variants, count = [], [], 0
    with source.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            word = row["word"].strip().lower()
            rows.append((word, row.get("phonetic", ""), row.get("translation", ""), row.get("definition", ""), row.get("exchange", "")))
            for part in row.get("exchange", "").split("/"):
                if ":" not in part:
                    continue
                kind, form = part.split(":", 1)
                if kind in {"p", "d", "i", "3", "r", "t", "s"} and form:
                    variants.append((form.lower(), word))
            count += 1
            if len(rows) >= 10000:
                db.executemany("INSERT OR REPLACE INTO words VALUES (?,?,?,?,?)", rows)
                db.executemany("INSERT INTO variants VALUES (?,?)", variants)
                rows, variants = [], []
    db.executemany("INSERT OR REPLACE INTO words VALUES (?,?,?,?,?)", rows)
    db.executemany("INSERT INTO variants VALUES (?,?)", variants)
    db.execute("CREATE INDEX variant_form ON variants(form)")
    db.commit()
    db.close()
    temporary.replace(target)
    return count


def clean_selection(value):
    value = unicodedata.normalize("NFKC", value).translate(phrase_lookup.CHARACTERS).replace("’", "'").replace("–", "-").replace("—", "-")
    value = re.sub(r"\s+", " ", value).strip(" \t\n.,;:!?\"'()[]{}")
    if len(value) > 220 or len(value.split()) > phrase_lookup.MAX_WORDS or not re.fullmatch(r"[A-Za-z][A-Za-z '\-]*", value):
        raise ValueError("请只复制一个英文单词或短语，再按 ⌥D。")
    return value


def dictionary_lookup(value, dictionary=DATA / "dictionary.sqlite", lemma_hint=""):
    surface = clean_selection(value)
    db = sqlite3.connect(f"file:{dictionary}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    word = surface.lower()
    row = db.execute("SELECT * FROM words WHERE word=?", (word,)).fetchone()
    # A contextual lemma supplied by macOS is accepted only when the dictionary
    # corroborates this word form. This also preserves noun “saw” versus verb “saw”.
    has_inflection = bool(row and "0:" in (row["exchange"] or ""))
    hint = lemma_hint.strip().lower()
    hinted = None
    if hint:
        candidate = db.execute("SELECT * FROM words WHERE word=?", (hint,)).fetchone()
        variants = {r[0] for r in db.execute("SELECT lemma FROM variants WHERE form=?", (word,))}
        origins = set()
        if row:
            ex = dict(p.split(":", 1) for p in (row["exchange"] or "").split("/") if ":" in p)
            origins = set(ex.get("0", "").split(","))
        if candidate and (hint == word or hint in variants or hint in origins):
            hinted = candidate
    if " " in word:
        row = phrase_lookup.resolve(db, word) or row
        has_inflection = False
    elif hinted:
        row = hinted
    elif row:
        exchange = dict(p.split(":", 1) for p in (row["exchange"] or "").split("/") if ":" in p)
        lemma = exchange.get("0", "").split(",")[0]
        if lemma and lemma != word:
            canonical = db.execute("SELECT * FROM words WHERE word=?", (lemma,)).fetchone()
            if canonical:
                row = canonical
    else:
        candidates = db.execute("SELECT DISTINCT lemma FROM variants WHERE form=? LIMIT 3", (word,)).fetchall()
        if len(candidates) == 1:
            row = db.execute("SELECT * FROM words WHERE word=?", (candidates[0]["lemma"],)).fetchone()
    result = {"surface": surface, "lemma": word, "phonetic": "", "translation": "", "definition": "", "found": False, "has_inflection": has_inflection}
    if row:
        result.update(dict(row))
        result["lemma"] = row["word"]
        result["found"] = bool(row["translation"])
    db.close()
    if not (result["phonetic"] or "").strip():
        supplement = phonetic_supplements().get(result["lemma"], {})
        result["phonetic"] = supplement.get("phonetic", "")
    for key in ("translation", "definition"):
        result[key] = (result[key] or "").replace("\\n", "\n")
    return result


def open_records(root):
    folder = root / "Reading" / ".查词数据"
    folder.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(folder / "records.sqlite", timeout=20)
    db.row_factory = sqlite3.Row
    db.execute("""CREATE TABLE IF NOT EXISTS entries (
        lemma TEXT PRIMARY KEY, phonetic TEXT, translation TEXT, definition TEXT,
        forms TEXT NOT NULL, first_seen TEXT NOT NULL, last_seen TEXT NOT NULL,
        count INTEGER NOT NULL, source TEXT, status TEXT NOT NULL)""")
    db.execute("""CREATE TABLE IF NOT EXISTS contexts (
        lemma TEXT NOT NULL, text TEXT NOT NULL, forms TEXT NOT NULL,
        first_seen TEXT NOT NULL, last_seen TEXT NOT NULL, source TEXT,
        PRIMARY KEY (lemma, text))""")
    db.execute("""CREATE TABLE IF NOT EXISTS book_deletions (
        lemma TEXT PRIMARY KEY, cutoff_ns INTEGER NOT NULL, token TEXT, payload TEXT)""")
    db.execute(context_notes.SCHEMA)
    db.commit()
    return db


def local_example(lemma, root=ROOT):
    overrides = DATA / "example_supplements.json"
    if overrides.exists():
        example = json.loads(overrides.read_text()).get(lemma)
        if example:
            return example
    for path in (DATA / "examples.sqlite", root / "Reading/.查词数据/examples.sqlite"):
        if not path.exists():
            continue
        with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
            row = db.execute("SELECT payload FROM examples WHERE lemma=?", (lemma,)).fetchone()
            if row:
                return json.loads(row[0])
    return None


def records(db, root=ROOT):
    items = [dict(r) for r in db.execute("SELECT * FROM entries ORDER BY first_seen, lemma")]
    occurrences = context_notes.for_export(db)
    for item in items:
        item["example"] = local_example(item["lemma"], root)
        item["contexts"] = [dict(r) for r in db.execute(
            "SELECT text, forms, first_seen, last_seen, source FROM contexts WHERE lemma=? ORDER BY first_seen, text", (item["lemma"],))]
        for context in item["contexts"]:
            context["forms"] = json.loads(context["forms"])
            positions = occurrences.get((item["lemma"], context["text"]))
            if positions:
                context["occurrences"] = positions
    return items


def atomic_write(path, text):
    temporary = path.with_suffix(path.suffix + ".new")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(path)


def export_records(root, items):
    from docx import Document
    from docx.shared import Inches, Pt, RGBColor
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn
    destination = root / "Reading"
    destination.mkdir(parents=True, exist_ok=True)
    payload = []
    for row in items:
        entry = dict(row)
        entry["forms"] = json.loads(entry["forms"])
        # Keep the original history in SQLite, but omit frequency from public files.
        entry.pop("count", None)
        payload.append(entry)
    supplements = phonetic_supplements()
    pronunciation_sources = {
        row["lemma"]: supplements[row["lemma"]]
        for row in payload
        if row["lemma"] in supplements
        and row["phonetic"] == supplements[row["lemma"]]["phonetic"]
    }
    atomic_write(destination / "查词自动收录.json", json.dumps({"pool": "reading", "source": "ECDICT", "phonetic_sources": pronunciation_sources, "entries": payload}, ensure_ascii=False, indent=2))

    doc = Document()
    section = doc.sections[0]
    section.page_width, section.page_height = Inches(8.5), Inches(11)
    section.top_margin = section.bottom_margin = Inches(0.6)
    section.left_margin = section.right_margin = Inches(0.65)
    for name, size in (("Normal", 9), ("Title", 16), ("Heading 1", 10.5)):
        style = doc.styles[name]
        style.font.name = "Arial"
        style.font.size = Pt(size)
        style.font.color.rgb = RGBColor(0, 0, 0)
        fonts = style.element.get_or_add_rPr().get_or_add_rFonts()
        for attribute in ("asciiTheme", "hAnsiTheme", "eastAsiaTheme", "cstheme"):
            fonts.attrib.pop(qn("w:" + attribute), None)
        fonts.set(qn("w:eastAsia"), "Songti SC")
    title_properties = doc.styles["Title"].element.get_or_add_pPr()
    for border in list(title_properties.findall(qn("w:pBdr"))):
        title_properties.remove(border)
    doc.styles["Normal"].paragraph_format.space_after = Pt(1)
    doc.styles["Normal"].paragraph_format.line_spacing = 1.05
    doc.styles["Heading 1"].paragraph_format.space_before = Pt(6)
    doc.styles["Heading 1"].paragraph_format.space_after = Pt(1)
    doc.add_paragraph("查词记录", "Title")
    doc.add_paragraph(f"已收录 {len(items)} 个词条。查词时自动更新，重复查询合并到同一词条。")
    if not items:
        doc.add_paragraph("选中英文单词或短语，按 ⌘C 复制，再按 ⌥D 查看中文。查过的词会自动出现在这里。")
    entry_paragraphs = []
    def entry_paragraph(*args):
        paragraph = doc.add_paragraph(*args)
        entry_paragraphs.append(paragraph)
        return paragraph
    for row in payload:
        entry_paragraphs.clear()
        heading = entry_paragraph(row["lemma"] + "    " + phonetic_label(row["phonetic"]), "Heading 1")
        meaning = entry_paragraph((row["translation"] or "词库暂无中文释义，已列入待补释义。").replace("\n", "；"))
        meaning.paragraph_format.keep_with_next = True
        example = row.get("example")
        if example:
            p = entry_paragraph("补充例句：" + example["text"])
            p.paragraph_format.keep_with_next = True
            if example.get("translation"):
                entry_paragraph(example["translation"])
        elif not row.get("contexts"):
            entry_paragraph("补充例句待补（暂未找到可靠例句）")
        for context in row.get("contexts", []):
            para = entry_paragraph("原文：")
            for fragment, bold in context_notes.segments(context):
                para.add_run(fragment).bold = bold
            for line in context_notes.note_lines(context):
                entry_paragraph(line)
        for paragraph in entry_paragraphs[:-1]:
            paragraph.paragraph_format.keep_with_next = True
        entry_paragraphs[-1].paragraph_format.keep_with_next = False
    for paragraph in doc.paragraphs:
        properties = paragraph._p.get_or_add_pPr()
        snap = OxmlElement("w:snapToGrid")
        snap.set(qn("w:val"), "0")
        properties.append(snap)
    target = destination / "查词自动收录.docx"
    temporary = target.with_suffix(".new.docx")
    doc.save(temporary)
    temporary.replace(target)

    def example_html(row):
        e = row.get("example")
        if not e:
            return "" if row.get("contexts") else "<p>补充例句待补</p>"
        return "<p>补充例句：" + html.escape(e["text"]) + "</p>" + ("<p>" + html.escape(e["translation"]) + "</p>" if e.get("translation") else "")
    def context_html(row):
        blocks = []
        for c in row.get("contexts", []):
            passage = "".join("<b>" + html.escape(s) + "</b>" if bold else html.escape(s)
                              for s, bold in context_notes.segments(c))
            notes = "".join("<p>" + html.escape(line) + "</p>" for line in context_notes.note_lines(c))
            blocks.append("<blockquote>原文：" + passage + notes + "</blockquote>")
        return "".join(blocks)
    cards = "".join(f"<article><h2>{html.escape(r['lemma'])}</h2><p class='phonetic'>{html.escape(phonetic_label(r['phonetic']))}</p><p class='meaning'>{html.escape(r['translation'] or '暂无中文释义，已列入待补')}</p>{example_html(r)}{context_html(r)}</article>" for r in payload)
    page = """<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>查词记录</title><style>body{font:14px/1.4 -apple-system,BlinkMacSystemFont,sans-serif;max-width:850px;margin:24px auto;padding:0 25px;background:#faf9f5;color:#242421}h1{font-size:22px}h2{font-size:17px;margin:0}small,footer{font-size:12px;color:#666}article{background:white;padding:12px;margin:8px 0;border:1px solid #e2e1db;border-radius:10px}.meaning{white-space:pre-wrap;margin:4px 0}input{box-sizing:border-box;width:100%;padding:12px;font-size:17px;border:1px solid #aaa;border-radius:8px}</style><h1>查词记录</h1>"""
    page += f"<p>已收录 {len(items)} 个词条。音标对应词条原形。查词后自动更新；刷新页面即可看到最新记录。</p><input id='search' placeholder='搜索单词或中文释义' aria-label='搜索词条'>"
    page += cards or "<p>选中英文单词，按 ⌘C 复制，再按 ⌥D。之后的整理自动完成。</p>"
    page += "<script>document.querySelector('#search').addEventListener('input',e=>document.querySelectorAll('article').forEach(a=>a.hidden=!a.textContent.toLowerCase().includes(e.target.value.toLowerCase())))</script></html>"
    atomic_write(destination / "查词自动收录.html", page)


def collect(value, root=ROOT, source="选词查词", save=True, dictionary=DATA / "dictionary.sqlite", context="", lemma_hint="", requested_ns=None, parts=None):
    requested_ns = time.time_ns() if requested_ns is None else requested_ns
    result = dictionary_lookup(value, dictionary, lemma_hint)
    context = context.strip()
    if parts:
        context_notes.validate_selection(context, parts, result["surface"])
    elif context and not re.search(r"(?<![A-Za-z])" + re.escape(result["surface"]) + r"(?![A-Za-z])", " ".join(context.translate(phrase_lookup.CHARACTERS).split()), re.I):
        raise ValueError("原文中没有找到所选词，未保存不匹配的原文。")
    if not save:
        result.update({"saved": False, "total": 0})
        return result
    folder = root / "Reading" / ".查词数据"
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / "writer.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        db = open_records(root)
        cutoff = db.execute("SELECT cutoff_ns FROM book_deletions WHERE lemma=?", (result["lemma"],)).fetchone()
        if cutoff and requested_ns <= cutoff[0]:
            db.close()
            return dict(result, saved=False, superseded_by_delete=True)
        now = datetime.now().astimezone().isoformat(timespec="seconds")
        previous = db.execute("SELECT forms, phonetic FROM entries WHERE lemma=?", (result["lemma"],)).fetchone()
        if previous and (previous["phonetic"] or "").strip():
            result["phonetic"] = previous["phonetic"]
        forms = json.loads(previous["forms"]) if previous else []
        if result["surface"] not in forms:
            forms.append(result["surface"])
        db.execute("""INSERT INTO entries VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(lemma) DO UPDATE SET forms=excluded.forms,
            phonetic=CASE WHEN trim(coalesce(entries.phonetic, ''))=''
                THEN excluded.phonetic ELSE entries.phonetic END,
            last_seen=excluded.last_seen""",
            (result["lemma"], result["phonetic"], result["translation"], result["definition"],
             json.dumps(forms, ensure_ascii=False), now, now, 0, source, "ready" if result["found"] else "needs_definition"))
        if context:
            old = db.execute("SELECT forms FROM contexts WHERE lemma=? AND text=?", (result["lemma"], context)).fetchone()
            context_forms = json.loads(old[0]) if old else []
            if result["surface"] not in context_forms:
                context_forms.append(result["surface"])
            db.execute("""INSERT INTO contexts VALUES (?,?,?,?,?,?)
                ON CONFLICT(lemma,text) DO UPDATE SET forms=excluded.forms, last_seen=excluded.last_seen""",
                (result["lemma"], context, json.dumps(context_forms, ensure_ascii=False), now, now, source))
            if parts:
                db.execute("INSERT OR IGNORE INTO occurrences(lemma,text,slot) VALUES(?,?,?)",
                           (result["lemma"], context, context_notes.slot_for(parts)))
        db.commit()
        items = records(db, root)
        db.close()
        result.update({"saved": True, "total": len(items)})
        try:
            export_records(root, items)
            result["document_updated"] = True
            (folder / "export-error.json").unlink(missing_ok=True)
        except Exception as error:
            result["document_updated"] = False
            result["export_error"] = str(error)
            atomic_write(folder / "export-error.json", json.dumps(result, ensure_ascii=False, indent=2))
        fcntl.flock(lock, fcntl.LOCK_UN)
    return result


def refresh_exports(root=ROOT, dictionary=DATA / "dictionary.sqlite"):
    """Backfill old pronunciations without changing lookup history, then re-export."""
    folder = root / "Reading" / ".查词数据"
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / "writer.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        db = open_records(root)
        filled = 0
        try:
            for row in records(db, root):
                if (row["phonetic"] or "").strip():
                    continue
                phonetic = dictionary_lookup(row["lemma"], dictionary)["phonetic"]
                if phonetic:
                    db.execute("UPDATE entries SET phonetic=? WHERE lemma=?", (phonetic, row["lemma"]))
                    filled += 1
            db.commit()
            items = records(db, root)
        finally:
            db.close()
        export_records(root, items)
        return {"total": len(items), "document_updated": True,
                "phonetics_filled": filled,
                "phonetics_pending": [row["lemma"] for row in items if not (row["phonetic"] or "").strip()]}


def serve(root=ROOT):
    """Immediate dictionary replies; ordered background persistence and exports."""
    import threading
    output_lock = threading.Lock()
    def emit(payload):
        with output_lock:
            print(json.dumps(payload, ensure_ascii=False), flush=True)
    def save_request(request):
        try:
            result = collect(request["term"], root, request.get("source", ""),
                             context=request.get("context", ""), lemma_hint=request.get("lemma_hint", ""),
                             requested_ns=request["requested_ns"], parts=request.get("parts"))
            emit(dict(result, id=request["id"], event="saved"))
        except Exception as error:
            emit({"id": request["id"], "event": "saved", "error": str(error), "saved": False})
    def enrich_request(request):
        try:
            result = dictionary_lookup(request["term"], lemma_hint=request.get("lemma_hint", ""))
            if not request.get("context") and not local_example(result["lemma"], root):
                from example_service import fetch_example
                if fetch_example(result["lemma"], root / "Reading/.查词数据/examples.sqlite"):
                    with (root / "Reading/.查词数据/writer.lock").open("a") as lock:
                        fcntl.flock(lock, fcntl.LOCK_EX)
                        db = open_records(root)
                        export_records(root, records(db, root))
                        db.close()
        except Exception:
            pass  # The saved entry remains explicitly marked pending; retry on next lookup.
    latest_scan = None
    def scan(request):
        try:
            result = phrase_lookup.recognize(request["text"], DATA / "dictionary.sqlite",
                                             cancelled=lambda: latest_scan != request["id"])
            if latest_scan == request["id"]:
                emit(dict(result, id=request["id"], event="phrases"))
        except Exception:
            emit({"id": request["id"], "event": "phrases", "choices": []})

    with ThreadPoolExecutor(max_workers=1) as scanner, ThreadPoolExecutor(max_workers=1) as writer, ThreadPoolExecutor(max_workers=1) as enricher:
        for line in sys.stdin:
            request = {}
            try:
                request = json.loads(line)
                if request.get("action") == "scan":
                    latest_scan = request["id"]
                    scanner.submit(scan, request)
                    continue
                if request.get("action", "lookup") != "lookup":
                    raise ValueError("不支持的查词操作。")
                request["requested_ns"] = time.time_ns()
                result = dictionary_lookup(request["term"], lemma_hint=request.get("lemma_hint", ""))
                emit(dict(result, id=request["id"], event="result"))
                future = writer.submit(save_request, request)
                future.add_done_callback(lambda _, req=request: enricher.submit(enrich_request, req))
            except Exception as error:
                emit({"id": request.get("id"), "event": "result", "error": str(error)})
        writer.shutdown(wait=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("term", nargs="?")
    parser.add_argument("--source", default="选词查词")
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--no-save", action="store_true")
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--export", action="store_true")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--context", default="")
    parser.add_argument("--lemma-hint", default="")
    args = parser.parse_args()
    try:
        if args.serve:
            serve(args.root)
            return
        if args.build:
            result = {"dictionary_entries": build_dictionary(DATA / "ecdict.csv", DATA / "dictionary.sqlite")}
        elif args.export:
            result = refresh_exports(args.root)
        else:
            result = collect(args.term or "", args.root, args.source, not args.no_save, context=args.context, lemma_hint=args.lemma_hint)
    except Exception as error:
        result = {"error": str(error), "saved": False}
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
