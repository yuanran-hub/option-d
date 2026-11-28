import io
import json
import sqlite3
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import backend
import context_notes
from book.book_edit import edit
from phrase_lookup import recognize

DICTIONARY = backend.DATA / "dictionary.sqlite"
NOTE = {"meaning": "越听越喜欢的作品", "translation": "这张专辑越听越有味道。", "nuance": ""}


class ContextTests(unittest.TestCase):
    def test_separable(self):
        examples = [
            ("They put the meeting off until Friday.", "put off", [1, 4]),
            ("She turned the offer down.", "turn down", [1, 4]),
            ("We looked it up.", "look up", [1, 3]),
            ("They called their annual meeting off.", "call off", [1, 5]),
            ("They picked her up from school.", "pick up", [1, 3]),
        ]
        for text, lemma, parts in examples:
            with self.subTest(text=text):
                result = recognize(text, DICTIONARY)
                self.assertFalse(result["exact"])
                self.assertIn(dict(first=parts[0], last=parts[1], lemma=lemma, parts=parts), result["choices"])

    def test_no_cross_clause_or_direction(self):
        for text in ["She turned the corner and walked down the street.", "They turned, the offer down.",
                     "She turned the chair down the street.", "They put it on the table.", "I looked him up and down."]:
            with self.subTest(text=text):
                self.assertFalse(any("parts" in x for x in recognize(text, DICTIONARY)["choices"]))

    def test_position_highlight_and_undo(self):
        text = "🙂 She turned the offer down, then turned to us."
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            result = backend.collect("turned down", root, context=text, parts=[1, 4])
            self.assertEqual(result["lemma"], "turn down")
            path = root / "Reading/查词自动收录.json"
            def context(): return json.loads(path.read_text())["entries"][0]["contexts"][0]
            self.assertEqual([s for s,b in context_notes.segments(context()) if b], ["turned", "down"])
            with sqlite3.connect(root/"Reading/.查词数据/records.sqlite") as db:
                db.execute("UPDATE occurrences SET note=?", (json.dumps(NOTE),))
            edit(root, "delete", "turn down", "receipt")
            edit(root, "undo", "turn down", "receipt")
            self.assertEqual(context()["occurrences"][0]["note"], NOTE)
            updated = dict(NOTE, meaning="我自己改的")
            change = dict(context=text, parts=[1,4], previous=NOTE, note=updated)
            edit(root, "sense_edit", "turn down", "", change)
            self.assertEqual(context()["occurrences"][0]["note"], updated)
            with self.assertRaises(ValueError):
                edit(root, "sense_edit", "turn down", "", change)
            self.assertIn(updated["meaning"], (root/"Reading/查词自动收录.html").read_text())
            from docx import Document
            self.assertIn(updated["meaning"], "\n".join(p.text for p in Document(root/"Reading/查词自动收录.docx").paragraphs))

    def test_retired_requests_do_not_collect_or_start_a_model(self):
        requests = [dict(id=action, action=action, term="efficient", context="An efficient way.", parts=[1])
                    for action in ("sense", "sense_edit")]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            lines = "\n".join(json.dumps(request) for request in requests)
            with patch("sys.stdin", io.StringIO(lines)), patch("subprocess.Popen") as process, redirect_stdout(io.StringIO()) as output:
                backend.serve(root)
            replies = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual([reply["id"] for reply in replies], ["sense", "sense_edit"])
            self.assertTrue(all("error" in reply for reply in replies))
            process.assert_not_called()
            self.assertFalse((root / "Reading").exists())


if __name__ == "__main__":
    unittest.main()
