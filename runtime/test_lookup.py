import html
import importlib.util
import json
import tempfile
import time
import unittest
from pathlib import Path
from book.book_edit import edit

spec = importlib.util.spec_from_file_location("lookup_backend", Path(__file__).with_name("backend.py"))
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)
from docx import Document


class LookupAcceptance(unittest.TestCase):
    def test_phrase_discovery_matches_whole_words_and_dictionary_inflections(self):
        from phrase_lookup import recognize
        db = backend.DATA / "dictionary.sqlite"
        for text in ["He finally spilled the beans about the surprise party.",
                     "😃 She spills the beans again.", "They spilt the beans."]:
            scan = recognize(text, db)
            self.assertFalse(scan["exact"])
            self.assertIn("spill the beans", [m["lemma"] for m in scan["choices"]])
        self.assertTrue(recognize("“out of the blue!”", db)["exact"])
        self.assertFalse(recognize("123 out of the blue", db)["exact"])
        for text in ["spill. The beans", "spilled 2 the beans", "spilled the beansprouts"]:
            self.assertNotIn("spill the beans", [m["lemma"] for m in recognize(text, db)["choices"]])

    def test_phrase_collection_preserves_distinct_contexts_and_deduplicates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = "He finally spilled the beans about the surprise party."
            second = "She always spills the\nbeans."
            for term, sentence in [("spilled the beans", first), ("spills the beans", second),
                                   ("spilled the beans", first)]:
                self.assertTrue(backend.collect(term, root, context=sentence)["document_updated"])
            entry, = json.loads((root / "Reading/查词自动收录.json").read_text())["entries"]
            self.assertEqual(entry["lemma"], "spill the beans")
            self.assertIn("说漏嘴", entry["translation"])
            self.assertEqual({c["text"] for c in entry["contexts"]}, {first, second})
            self.assertEqual(entry["forms"], ["spilled the beans", "spills the beans"])
            self.assertFalse(backend.dictionary_lookup("read the room")["found"])

    def test_scanning_alone_creates_no_files(self):
        import subprocess, sys
        with tempfile.TemporaryDirectory() as tmp:
            req = {"action": "scan", "id": "suggest", "text": "He broke the ice."}
            output = subprocess.check_output([sys.executable, backend.__file__, "--root", tmp, "--serve"],
                                             input=json.dumps(req) + "\n", text=True, timeout=10)
            result = json.loads(output)
            self.assertEqual(result["event"], "phrases")
            self.assertIn({"first": 1, "last": 3, "lemma": "break the ice"}, result["choices"])
            self.assertFalse(list(Path(tmp).iterdir()))

    def test_delete_updates_exports_and_stale_lookup_cannot_reinsert_word(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            sentence = "Different policies affected the outcome."
            backend.collect("policies", root, context=sentence)
            backend.collect("outcome", root, context=sentence)
            queued = time.time_ns()
            edit(root, "delete", "policy", "receipt")
            late = backend.collect("policies", root, context=sentence, requested_ns=queued)
            self.assertTrue(late["superseded_by_delete"])
            output = root / "Reading/查词自动收录"
            entries = json.loads(output.with_suffix(".json").read_text())["entries"]
            self.assertEqual([e["lemma"] for e in entries], ["outcome"])
            self.assertEqual(entries[0]["contexts"][0]["text"], sentence)
            self.assertNotIn("<h2>policy</h2>", output.with_suffix(".html").read_text())
            headings = [p.text for p in Document(output.with_suffix(".docx")).paragraphs if p.style.name == "Heading 1"]
            self.assertEqual(len(headings), 1)
            self.assertTrue(headings[0].startswith("outcome "))

    def test_undo_combines_new_encounters_and_retries_without_duplication(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            old, new = "We compared their policies.", "The policy will change."
            backend.collect("policies", root, context=old)
            edit(root, "delete", "policy", "receipt")
            backend.collect("policy", root, context=new)
            edit(root, "delete", "policy", "receipt")
            for _ in range(2):
                edit(root, "undo", "policy", "receipt")
            entries = json.loads((root / "Reading/查词自动收录.json").read_text())["entries"]
            self.assertEqual(len(entries), 1)
            self.assertEqual(entries[0]["forms"], ["policies", "policy"])
            self.assertCountEqual([c["text"] for c in entries[0]["contexts"]], [old, new])

    def test_changed_word_form_and_duplicate_lookup_share_one_entry(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            first = backend.collect("policies", root)
            second = backend.collect("policy", root)
            self.assertTrue(first["found"])
            self.assertTrue(second["document_updated"])
            self.assertEqual(first["lemma"], "policy")
            output = json.loads((root / "Reading" / "查词自动收录.json").read_text())
            self.assertEqual(len(output["entries"]), 1)
            entry = output["entries"][0]
            self.assertNotIn("count", entry)
            db = backend.open_records(root)
            self.assertEqual(backend.records(db)[0]["count"], 0)
            db.close()
            self.assertEqual(entry["forms"], ["policies", "policy"])
            self.assertTrue((root / "Reading" / "查词自动收录.docx").is_file())

    def test_saved_files_include_pronunciation_without_lookup_frequency(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            backend.collect("policy", root)
            result = backend.collect("policy", root)
            self.assertTrue(result["phonetic"])
            output = json.loads((root / "Reading" / "查词自动收录.json").read_text())
            self.assertEqual(len(output["entries"]), 1)
            self.assertNotIn("count", output["entries"][0])
            doc_text = "\n".join(p.text for p in Document(root / "Reading" / "查词自动收录.docx").paragraphs)
            html_text = (root / "Reading" / "查词自动收录.html").read_text()
            for text in (doc_text, html.unescape(html_text)):
                self.assertIn("音标 /" + result["phonetic"] + "/", text)
                self.assertNotRegex(text, r"查询\s*\d+\s*次")

    def test_backfill_preserves_old_history_and_custom_definitions(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            backend.collect("policy", root)
            backend.collect("bird", root)
            db = backend.open_records(root)
            db.execute("UPDATE entries SET phonetic='', translation='用户校订释义', count=7 WHERE lemma='policy'")
            db.execute("UPDATE entries SET phonetic='保留既有标注' WHERE lemma='bird'")
            db.commit()
            before = backend.records(db)
            db.close()
            result = backend.refresh_exports(root)
            self.assertEqual(result["phonetics_filled"], 1)
            self.assertEqual(result["phonetics_pending"], [])
            db = backend.open_records(root)
            after = backend.records(db)
            db.close()
            for old, new in zip(before, after):
                if old["lemma"] == "policy":
                    self.assertEqual(new["phonetic"], backend.dictionary_lookup("policy")["phonetic"])
                    old["phonetic"] = new["phonetic"]
                self.assertEqual(old, new)
            self.assertEqual(backend.refresh_exports(root)["phonetics_filled"], 0)

    def test_duplicate_lookup_repairs_missing_stored_pronunciation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            backend.collect("policy", root)
            db = backend.open_records(root)
            db.execute("UPDATE entries SET phonetic='' WHERE lemma='policy'")
            db.commit()
            db.close()
            result = backend.collect("policies", root)
            db = backend.open_records(root)
            row = backend.records(db)[0]
            db.close()
            self.assertEqual(row["phonetic"], result["phonetic"])
            self.assertTrue(row["phonetic"])
            self.assertEqual(row["forms"], '["policy", "policies"]')
            self.assertEqual(row["count"], 0)

    def test_missing_pronunciation_is_labelled_without_invention(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            backend.collect("zzzzxvnsword", root)
            result = backend.refresh_exports(root)
            self.assertEqual(result["phonetics_pending"], ["zzzzxvnsword"])
            doc_text = "\n".join(p.text for p in Document(root / "Reading" / "查词自动收录.docx").paragraphs)
            self.assertIn("音标待补", doc_text)

    def test_contexts_merge_by_lemma_but_keep_distinct_sentences(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            a = "These policies were effective."
            b = "The policy changed yesterday."
            backend.collect("policies", root, context=a)
            backend.collect("policies", root, context=a)
            backend.collect("policy", root, context=b)
            output = json.loads((root / "Reading/查词自动收录.json").read_text())
            self.assertEqual(len(output["entries"]), 1)
            row = output["entries"][0]
            self.assertEqual(row["lemma"], "policy")
            self.assertEqual(len(row["contexts"]), 2)
            self.assertEqual({c["text"] for c in row["contexts"]}, {a, b})
            text = "\n".join(p.text for p in Document(root / "Reading/查词自动收录.docx").paragraphs)
            self.assertIn(a, text)
            self.assertIn(b, text)
            self.assertNotIn("count", row)

    def test_irregular_and_ambiguous_lemmas(self):
        self.assertEqual(backend.dictionary_lookup("went")["lemma"], "go")
        self.assertEqual(backend.dictionary_lookup("children")["lemma"], "child")
        self.assertEqual(backend.dictionary_lookup("saw", lemma_hint="saw")["lemma"], "saw")
        self.assertEqual(backend.dictionary_lookup("saw", lemma_hint="see")["lemma"], "see")
        self.assertEqual(backend.dictionary_lookup("policies", lemma_hint="cat")["lemma"], "policy")

    def test_mismatched_context_is_not_saved(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaises(ValueError):
                backend.collect("policy", root, context="Nothing relevant here.")
            self.assertFalse((root / "Reading").exists())

    def test_single_word_exports_example_without_creating_fake_context(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            backend.collect("policy", root)
            row = json.loads((root / "Reading/查词自动收录.json").read_text())["entries"][0]
            self.assertTrue(row["example"]["text"])
            self.assertEqual(row["contexts"], [])
            doc = Document(root / "Reading/查词自动收录.docx")
            self.assertEqual(doc.styles["Normal"].font.size.pt, 9)
            self.assertIn("补充例句", "\n".join(p.text for p in doc.paragraphs))

    def test_invalid_selection_does_not_create_records(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaises(ValueError):
                backend.collect("contact@example.com", root)
            self.assertFalse((root / "Reading").exists())

    def test_unknown_term_is_marked_pending_without_invented_definition(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            result = backend.collect("zzzzxvnsword", root)
            self.assertFalse(result["found"])
            self.assertEqual(result["translation"], "")
            output = json.loads((root / "Reading" / "查词自动收录.json").read_text())
            self.assertEqual(output["entries"][0]["status"], "needs_definition")

    def test_british_spelling_remains_in_recorded_surface(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            result = backend.collect("individualise", root)
            self.assertTrue(result["found"])
            output = json.loads((root / "Reading" / "查词自动收录.json").read_text())
            self.assertIn("individualise", output["entries"][0]["forms"])


if __name__ == "__main__":
    unittest.main()
