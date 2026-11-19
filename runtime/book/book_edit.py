"""Edit the personal vocabulary, serializing with collection and all three exports."""
import fcntl
import json
import sys
import time
from contextlib import closing
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import backend


def remove(db, lemma, token):
    previous = db.execute("SELECT token FROM book_deletions WHERE lemma=?", (lemma,)).fetchone()
    if previous and previous["token"] == token:
        return
    entry = db.execute("SELECT * FROM entries WHERE lemma=?", (lemma,)).fetchone()
    if not entry:
        raise ValueError("这个词已从生词本删除。")
    contexts = db.execute("SELECT * FROM contexts WHERE lemma=?", (lemma,)).fetchall()
    payload = json.dumps({"entry": dict(entry), "contexts": [dict(c) for c in contexts]}, ensure_ascii=False)
    # Keep one undo across window closes. The small cutoffs still protect earlier queued writes.
    db.execute("UPDATE book_deletions SET payload=NULL,token=NULL WHERE token IS NOT NULL")
    db.execute("INSERT OR REPLACE INTO book_deletions VALUES (?,?,?,?)", (lemma, time.time_ns(), token, payload))
    db.execute("DELETE FROM contexts WHERE lemma=?", (lemma,))
    db.execute("DELETE FROM entries WHERE lemma=?", (lemma,))


def combined_forms(first, later):
    return json.dumps(list(dict.fromkeys(json.loads(first) + json.loads(later))), ensure_ascii=False)


def restore(db, lemma, token):
    receipt = db.execute("SELECT payload FROM book_deletions WHERE lemma=? AND token=?", (lemma, token)).fetchone()
    if not receipt:
        raise ValueError("这次删除的撤销记录已失效。")
    if receipt["payload"] is None:
        return
    deleted = json.loads(receipt["payload"])
    db.create_function("combined_forms", 2, combined_forms)
    db.execute("""INSERT INTO entries (lemma,phonetic,translation,definition,forms,first_seen,last_seen,count,source,status)
        VALUES (:lemma,:phonetic,:translation,:definition,:forms,:first_seen,:last_seen,:count,:source,:status)
        ON CONFLICT(lemma) DO UPDATE SET forms=combined_forms(excluded.forms,entries.forms),
        first_seen=min(entries.first_seen,excluded.first_seen),last_seen=max(entries.last_seen,excluded.last_seen),
        phonetic=coalesce(nullif(excluded.phonetic,''),entries.phonetic),
        translation=coalesce(nullif(excluded.translation,''),entries.translation),
        definition=coalesce(nullif(excluded.definition,''),entries.definition),
        count=max(entries.count,excluded.count),source=excluded.source,
        status=CASE WHEN coalesce(excluded.translation,'')!='' THEN excluded.status ELSE entries.status END""", deleted["entry"])
    for context in deleted["contexts"]:
        db.execute("""INSERT INTO contexts (lemma,text,forms,first_seen,last_seen,source)
            VALUES (:lemma,:text,:forms,:first_seen,:last_seen,:source)
            ON CONFLICT(lemma,text) DO UPDATE SET forms=combined_forms(excluded.forms,contexts.forms),
            first_seen=min(contexts.first_seen,excluded.first_seen),last_seen=max(contexts.last_seen,excluded.last_seen)""", context)
    db.execute("UPDATE book_deletions SET payload=NULL WHERE lemma=?", (lemma,))


def edit(root, action, lemma, token):
    folder = root / "Reading/.查词数据"
    with (folder / "writer.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with closing(backend.open_records(root)) as db:
            with db:
                if action == "delete":
                    remove(db, lemma, token)
                elif action == "undo":
                    restore(db, lemma, token)
                elif action != "sync":
                    raise ValueError("未知操作。")
            result = {"changed": action != "sync"}
            try:
                backend.export_records(root, backend.records(db, root))
                (folder / "export-error.json").unlink(missing_ok=True)
            except Exception as error:
                result["warning"] = str(error)
                backend.atomic_write(folder / "export-error.json", json.dumps(result, ensure_ascii=False))
            return result


if __name__ == "__main__":
    try:
        print(json.dumps(edit(Path(sys.argv[1]), *sys.argv[2:]), ensure_ascii=False))
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
