"""Independent pre-execution oracle tests; no candidate converter invocation."""
import copy
import importlib.util
import pathlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("conversion_auditor", ROOT / "tools/oracle/audit-conversion-evidence.py")
A = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(A)
FIXTURES = ROOT / "fixtures/conversions"


class ConversionOracleTests(unittest.TestCase):
    def test_all_frozen_positive_sources_and_manual_targets(self):
        corpus = A.loads((FIXTURES / "corpus.json").read_bytes())
        self.assertEqual(A.digest((FIXTURES / "corpus.json").read_bytes()), A.CORPUS_SHA256)
        checked = 0
        for case in corpus["cases"]:
            if case["expected"]["status"] != "converted":
                continue
            with self.subTest(case=case["id"]):
                manual = case["expected"]["manual_semantics"]
                source = (FIXTURES / case["input"]).read_bytes()
                if case["from"] in ("xes", "csv"):
                    actual, losses = A.core(source, case["from"])
                    expected = A.loads((FIXTURES / manual["core_file"]).read_bytes())
                    self.assertEqual(actual, expected)
                    self.assertEqual(len(losses), manual["metadata_loss_count"])
                else:
                    actual = A.graph(source, case["from"])
                    expected = A.manual_graph(A.loads((FIXTURES / manual["graph_file"]).read_bytes()))
                    self.assertTrue(A.mapped_equal(expected, actual, A.isomorphic(expected, actual)))
                target = case["expected"].get("direct_target_file")
                if target:
                    data = (FIXTURES / target).read_bytes()
                    if case["to"] in ("xes", "csv"):
                        self.assertEqual(A.core(data, case["to"])[0], expected)
                    else:
                        self.assertTrue(A.isomorphic(expected, A.graph(data, case["to"])))
                checked += 1
        self.assertGreaterEqual(checked, 15)

    def test_weight_marking_order_absence_and_tau_corruptions(self):
        expected = A.graph((FIXTURES / "weighted-cycle.json").read_bytes(), "petri-json")
        corruptions = []
        changed = copy.deepcopy(expected); changed["arcs"][0]["weight"] += 1; corruptions.append(changed)
        changed = copy.deepcopy(expected); changed["initial"].pop("00000000-0000-0000-0000-000000000002"); corruptions.append(changed)
        changed = copy.deepcopy(expected); changed["finals"].reverse(); corruptions.append(changed)
        changed = copy.deepcopy(expected); changed["nodes"]["00000000-0000-0000-0000-000000000005"]["label"] = "Tau"; corruptions.append(changed)
        changed = copy.deepcopy(expected); changed["arcs"].pop(); corruptions.append(changed)
        for value in corruptions:
            with self.assertRaises(ValueError):
                A.isomorphic(expected, value)

    def test_complete_consistent_renaming_and_forged_map(self):
        expected = A.graph((FIXTURES / "integer-maxima.json").read_bytes(), "petri-json")
        mapping = {key: "renamed-" + key for key in expected["nodes"]}
        other = {"nodes": {mapping[key]: dict(value, id=mapping[key]) for key, value in expected["nodes"].items()},
                 "arcs": [{"source": mapping[a["source"]], "target": mapping[a["target"]], "weight": a["weight"]} for a in expected["arcs"]],
                 "initial": {mapping[key]: value for key, value in expected["initial"].items()},
                 "finals": [{mapping[key]: value for key, value in marking.items()} for marking in expected["finals"]]}
        self.assertTrue(A.mapped_equal(expected, other, mapping))
        self.assertTrue(A.isomorphic(expected, other))
        forged = dict(mapping); keys = list(forged); forged[keys[0]], forged[keys[1]] = forged[keys[1]], forged[keys[0]]
        self.assertFalse(A.mapped_equal(expected, other, forged))

    def test_order_loss_counts_and_nanosecond_normalization(self):
        actual, losses = A.core((FIXTURES / "flat-unicode.xes").read_bytes(), "xes")
        csv_core, _ = A.core((FIXTURES / "flat-unicode.csv").read_bytes(), "csv")
        self.assertEqual(actual, csv_core)
        changed = copy.deepcopy(actual); changed["traces"][0]["events"].reverse()
        self.assertNotEqual(actual, changed)
        self.assertEqual(losses, [])
        value, offset = A.instant("2026-10-22T06:02:03.123456789+05:00")
        self.assertEqual((value, offset), ("2026-10-22T01:02:03.123456789Z", 18000))
        self.assertEqual(len(A.core((FIXTURES / "rich.xes").read_bytes(), "xes")[1]), 6)
        self.assertEqual(len(A.core((FIXTURES / "extension-classifier.xes").read_bytes(), "xes")[1]), 2)
        with self.assertRaises(ValueError): A.instant("2026-10-22T01:02:03.1234567890Z")

    def test_unknown_behavior_and_duplicates_refused(self):
        pnml = (FIXTURES / "weighted-cycle.pnml").read_bytes()
        with self.assertRaises(ValueError): A.graph(pnml.replace(b"</transition>", b"<toolspecific evil='true'/></transition>", 1), "pnml")
        with self.assertRaises(ValueError): A.graph((FIXTURES / "unknown-json.json").read_bytes(), "petri-json")
        with self.assertRaises(ValueError): A.loads(b'{"tokens":1,"tokens":2}')
        with self.assertRaises(ValueError): A.xml(b'<!DOCTYPE x><pnml/>')
        with self.assertRaises(ValueError): A.local(FIXTURES, "../outside")
        self.assertEqual(A.loads(b'{"tokens":18446744073709551615}')["tokens"], 2**64 - 1)

    def test_scalar_lexemes_remain_exact_and_loss_location_not_semantics(self):
        _, losses = A.core((FIXTURES / "i64-extrema.xes").read_bytes(), "xes")
        self.assertEqual([row["value"] for row in losses], ["-9223372036854775808", "9223372036854775807", "-0"])
        changed = copy.deepcopy(losses); changed[1]["value"] = "9223372036854775808"
        self.assertNotEqual(A.canonical_losses(losses), A.canonical_losses(changed))
        located = [dict(row, location={"byte_offset": 4}) for row in losses]
        self.assertEqual(A.canonical_losses(losses), A.canonical_losses(located))

    def test_utf16_entity_autodetection_cannot_bypass_utf8_profile(self):
        source = '<!DOCTYPE pnml [<!ENTITY injected "expanded">]><pnml>&injected;</pnml>'
        for encoding in ("utf-16", "utf-16-le", "utf-16-be"):
            with self.subTest(encoding=encoding):
                encoded = source.encode(encoding)
                self.assertEqual(ET.fromstring(encoded).text, "expanded")
                with self.assertRaises((ValueError, UnicodeError)):
                    A.xml(encoded)
        with self.assertRaises(ValueError):
            A.xml(source.encode("utf-8"))
        with self.assertRaises(UnicodeError):
            A.xml(b"<pnml>\xff</pnml>")

    def test_actual_declarations_and_lexical_normalizations_not_report_assumptions(self):
        source = b'<log><trace><string key="concept:name" value="one"/><event><string key="concept:name" value="A"/><date key="time:timestamp" value="2026-10-22T01:02:03.123400+00:00"/></event></trace></log>'
        payload = b'case,activity,timestamp,lifecycle\r\none,A,2026-10-22T01:02:03.1234Z,\r\n'
        declared = {"source": A.declarations(source, "xes"), "target": A.declarations(payload, "csv"), "metadata_loss_count": 0}
        self.assertEqual(declared["source"]["xes.version"], {"present": False, "value": None})
        self.assertEqual(declared["source"]["xmlns"], {"present": False, "value": None})
        norms = A.lexical_normalizations(source, "xes")
        self.assertEqual(len(norms), 1)
        norms[0]["location"]["byte_offset"] = source.index(b"<event>")
        evidence = {"format_declarations": declared,
                    "normalizations": norms + [dict(declared, kind="format_declarations")]}
        A.log_report_integrity(evidence, source, "xes", payload, "csv", {"timestamp_normalization_count": 1})
        altered = copy.deepcopy(evidence)
        altered["format_declarations"]["source"]["xmlns"] = {"present": True, "value": "http://www.xes-standard.org/"}
        with self.assertRaises(ValueError): A.log_report_integrity(altered, source, "xes", payload, "csv")
        altered = copy.deepcopy(evidence); altered["normalizations"].pop(0)
        with self.assertRaises(ValueError): A.log_report_integrity(altered, source, "xes", payload, "csv")
        with self.assertRaises(ValueError): A.log_report_integrity(evidence, source, "xes", payload, "csv", {"timestamp_normalization_count": 0})

    def test_full_native_stream_integrity_and_explicit_projection_scope(self):
        # Synthetic validator-unit metadata, never evidence of a real process.
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            value = {"native_exit": 0, "stdout_complete": True, "stderr_complete": True,
                     "pid": 7, "native_creation_utc": "2026-10-22T00:00:00.0000000Z",
                     "stdout_sha256": A.digest(b"control"), "stdout_bytes_persisted": 7,
                     "stderr_sha256": A.digest(b""), "stderr_bytes_persisted": 0}
            (base / "case.process.json").write_text(__import__("json").dumps(value), encoding="utf-8")
            (base / "case.stdout").write_bytes(b"control"); (base / "case.stderr").write_bytes(b"")
            self.assertEqual(A.native(base, "case.process.json", 0), value)
            (base / "case.stdout").write_bytes(b"altered")
            with self.assertRaises(ValueError): A.native(base, "case.process.json", 0)
            self.assertEqual(A.native(base, "case.process.json", 0, "public_metadata_projection"), value)
            with self.assertRaises(ValueError): A.native(base, "case.process.json", 0, "silent_omission")

    def test_net_occurrence_inventory_has_exact_locations_and_no_phantom_tau(self):
        source = (FIXTURES / "weighted-cycle.pnml").read_bytes()
        target = (FIXTURES / "weighted-cycle.json").read_bytes()
        mapping = A.isomorphic(A.graph(source, "pnml"), A.graph(target, "petri-json"))
        inventory = A.net_inventory(source, "pnml", target, mapping)
        self.assertEqual(inventory["counts"], {"net_id": 1, "page_id": 1, "arc_id": 6,
            "place_display_name": 1, "tau_local_node_id": 1, "node_id_bijection": 5})
        self.assertEqual(inventory["entry_count"], 15)
        tau = next(row for row in inventory["entries"] if row["kind"] == "tau_local_node_id")
        self.assertEqual(tau["locator"], {"syntax": "xml", "path": "/pnml/net[0]/page[0]/transition[2]/toolspecific[0]", "attribute": "localNodeID"})
        self.assertEqual(tau["original_value"], "00000000-0000-0000-0000-000000000099")
        evidence = {"node_bijection": mapping, "normalization_inventory": inventory, "normalizations": sorted(inventory["counts"])}
        A.net_report_integrity(evidence, source, "pnml", target)
        for change in ("count", "locator", "value", "mapping", "omission", "phantom"):
            bad = copy.deepcopy(evidence); inv = bad["normalization_inventory"]
            if change == "count": inv["counts"]["arc_id"] -= 1
            elif change == "locator": inv["entries"][0]["locator"]["path"] += "/missing[0]"
            elif change == "value": inv["entries"][0]["original_value"] = "false"
            elif change == "mapping":
                entry = next(row for row in inv["entries"] if row["kind"] == "node_id_bijection")
                entry["changed"] = not entry["changed"]
            elif change == "omission": inv["entries"].pop(); inv["entry_count"] -= 1
            else: inv["entries"].append(copy.deepcopy(tau)); inv["entry_count"] += 1; inv["counts"]["tau_local_node_id"] += 1
            with self.subTest(change=change), self.assertRaises(ValueError):
                A.net_report_integrity(bad, source, "pnml", target)
        plain = source.replace(b'<toolspecific tool="ProM" version="6.4" activity="$invisible$" localNodeID="00000000-0000-0000-0000-000000000099"/>', b'')
        derived = A.net_inventory(plain, "pnml", target, mapping)
        self.assertNotIn("tau_local_node_id", derived["counts"])

    def test_boundary_coverage_cannot_be_replaced_by_embedded_expected_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "index.json"
            path.write_text(__import__("json").dumps({"schema_version": 1, "converter_sha256": "a" * 64,
                "cases": [{"id": "B01", "expected": {"all_nine_passed": True}}]}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "complete boundary cases"):
                A.audit_boundaries(path, "a" * 64)


if __name__ == "__main__":
    unittest.main()
