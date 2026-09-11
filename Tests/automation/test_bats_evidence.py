"""Pure source/TAP contracts; no Bats, shell, filesystem fixtures or Apple execution."""

from dataclasses import FrozenInstanceError, replace
import hashlib
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts/ci/bats_evidence.py"


def load_module():
    spec = importlib.util.spec_from_file_location("bats_evidence", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def digest(value):
    return hashlib.sha256(value).hexdigest()


def source_for(titles):
    return ("#!/usr/bin/env bats\n" + "\n".join(
        '@test "' + title + '" {\n  true\n}\n' for title in titles
    )).encode("utf-8")


class BatsEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = load_module()

    def plan(self, titles=("first", "second"), *, tier="hosted", path=None, source=None):
        payload = source_for(titles) if source is None else source
        return self.api.build_file_plan(
            payload, tier=tier, path=path or f"bats/{tier}/synthetic.bats",
            content_sha256=digest(payload),
            ordered_title_sha256=tuple(digest(title.encode("utf-8")) for title in titles),
        )

    def report(self, plan):
        return (f"1..{len(plan.runtime_titles)}\n" + "".join(
            f"ok {number} {title}\n" for number, title in enumerate(plan.runtime_titles, 1)
        )).encode("utf-8")

    def result(self, plan, numbers=None):
        if numbers is None:
            return self.api.parse_tap(self.report(plan), 0, plan)
        return self.api.BatsFileResult(plan=plan, passed_numbers=numbers)

    def reject(self, function, *args, code, **kwargs):
        with self.assertRaises(self.api.BatsEvidenceError) as caught:
            function(*args, **kwargs)
        self.assertEqual(str(caught.exception), code)

    def reject_report(self, payload, status=0, plan=None):
        self.reject(self.api.parse_tap, payload, status, plan or self.plan(),
                    code="bats-report-invalid")

    def reject_records(self, plans, results):
        self.reject(self.api.validate_file_results, plans, results,
                    code="bats-record-invalid")

    def test_named_contract_and_resource_limits(self):
        self.assertEqual(self.api.DECODER_CONTRACT, "bats-double-quoted-literal-v1")
        self.assertEqual(self.api.MAX_BATS_FILES, 4096)
        self.assertEqual(self.api.MAX_BATS_TESTS, 20000)
        self.assertEqual(self.api.MAX_REPORT_BYTES, 8 * 1024 * 1024)

    def test_literal_subset_does_not_recursively_expand_emitted_characters(self):
        cases = (
            (r"literal \$HOME", "literal $HOME"),
            (r"literal \${value}", "literal ${value}"),
            (r"literal \$(command)", "literal $(command)"),
            (r"literal \`command\`", "literal `command`"),
            (r"two \\ slashes", "two \\ slashes"),
            (r"ordinary \q \#", r"ordinary \q \#"),
            ("  café e\u0301  ", "  café e\u0301  "),
            (" # skip literal # TODO literal (1ms)", " # skip literal # TODO literal (1ms)"),
            ("\\\\\\$value", "\\$value"),
        )
        for raw, expected in cases:
            with self.subTest(raw=raw):
                self.assertEqual(self.api.decode_literal_title(raw), expected)

    def test_dynamic_quotes_controls_and_invalid_scalars_refuse(self):
        values = ("", "$HOME", "${value}", "$(command)", "`command`",
                  "\\\\$value", "\\\\`command`", "trailing\\", 'a"b', r'a\"b',
                  "a\x00b", "a\tb", "a\nb", "a\rb", "a\x7fb", "a\x85b", "a\ud800b",
                  None, 1, True, b"title", ["title"])
        for value in values:
            with self.subTest(value=repr(value)):
                self.reject(self.api.decode_literal_title, value, code="bats-title-invalid")

    def test_plan_uses_canonical_heredoc_and_quote_aware_extractor(self):
        raw = r"literal \$VALUE"
        payload = ("#!/usr/bin/env bats\n# @test \"comment\" {\n"
                   "cat <<'FIXTURE'\n@test \"heredoc\" {\nFIXTURE\n"
                   "value='\n@test \"quoted\" {\n'\n" +
                   source_for((raw,)).decode()).encode()
        plan = self.plan((raw,), source=payload)
        self.assertEqual(plan.raw_titles, (raw,))
        self.assertEqual(plan.runtime_titles, ("literal $VALUE",))
        self.assertEqual(plan.raw_title_sha256, (digest(raw.encode()),))
        self.assertEqual(plan.runtime_title_sha256, (digest(b"literal $VALUE"),))
        self.assertNotEqual(plan.raw_title_sha256, plan.runtime_title_sha256)
        self.assertEqual(plan.content_sha256, digest(payload))
        self.assertEqual(plan.decoder, self.api.DECODER_CONTRACT)
        self.assertEqual((plan.tier, plan.path), ("hosted", "bats/hosted/synthetic.bats"))

    def test_hash_and_inventory_count_verified_before_source_extraction(self):
        payload = source_for(("first",))
        good = dict(tier="hosted", path="bats/hosted/synthetic.bats",
                    content_sha256=digest(payload), ordered_title_sha256=(digest(b"first"),))
        invalids = (
            {"content_sha256": "0" * 64},
            {"ordered_title_sha256": (digest(b"first"),) * (self.api.MAX_BATS_TESTS + 1)},
        )
        for change in invalids:
            with self.subTest(field=tuple(change)), patch.object(
                self.api.bats_inventory, "_parse_bats_source",
                side_effect=AssertionError("extraction must not start"),
            ):
                self.reject(self.api.build_file_plan, payload, **{**good, **change},
                            code="bats-plan-invalid")

    def test_source_exact_byte_bound_and_oversize_refuses_before_extraction(self):
        self.assertEqual(self.api.MAX_SOURCE_BYTES, 1024 * 1024)
        prefix = source_for(("first",))
        exact = prefix + b"#" + b"x" * (self.api.MAX_SOURCE_BYTES - len(prefix) - 2) + b"\n"
        self.assertEqual(len(exact), self.api.MAX_SOURCE_BYTES)
        plan = self.plan(("first",), source=exact)
        self.assertEqual(plan.raw_titles, ("first",))
        self.assertEqual(plan.content_sha256, digest(exact))
        oversized = exact[:-1] + b"x\n"
        self.assertEqual(len(oversized), self.api.MAX_SOURCE_BYTES + 1)
        with patch.object(self.api.bats_inventory, "_parse_bats_source",
                          side_effect=AssertionError("oversize source must not be extracted")):
            self.reject(self.plan, ("first",), source=oversized, code="bats-plan-invalid")

    def test_inventory_order_raw_hash_and_whole_file_binding_are_exact(self):
        titles = (r"escaped \$x", "plain")
        payload = source_for(titles)
        kwargs = dict(tier="hosted", path="bats/hosted/synthetic.bats",
                      content_sha256=digest(payload),
                      ordered_title_sha256=tuple(digest(t.encode()) for t in titles))
        changes = (
            {"ordered_title_sha256": tuple(reversed(kwargs["ordered_title_sha256"]))},
            {"ordered_title_sha256": (digest(b"escaped $x"), digest(b"plain"))},
            {"ordered_title_sha256": (digest(b"plain"),)},
            {"ordered_title_sha256": ()},
        )
        for change in changes:
            with self.subTest(change=change):
                self.reject(self.api.build_file_plan, payload, **{**kwargs, **change},
                            code="bats-plan-invalid")
        self.reject(self.api.build_file_plan, payload + b"# changed\n", **kwargs,
                    code="bats-plan-invalid")

    def test_plan_rejects_mutable_wrong_types_and_noncanonical_paths(self):
        payload = source_for(("first",))
        good = dict(tier="hosted", path="bats/hosted/synthetic.bats",
                    content_sha256=digest(payload), ordered_title_sha256=(digest(b"first"),))
        changes = (
            {"tier": "local-tcc"}, {"tier": []}, {"path": "bats/local/synthetic.bats"},
            {"path": "/bats/hosted/synthetic.bats"}, {"path": "bats/hosted/../synthetic.bats"},
            {"path": "bats//hosted/synthetic.bats"}, {"path": "bats/hosted/./synthetic.bats"},
            {"path": "bats/hosted/synthetic.bats\x00"}, {"path": 1},
            {"content_sha256": "A" * 64}, {"content_sha256": []},
            {"ordered_title_sha256": [digest(b"first")]},
            {"ordered_title_sha256": ([],)}, {"ordered_title_sha256": (True,)},
        )
        for change in changes:
            with self.subTest(change=change):
                self.reject(self.api.build_file_plan, payload, **{**good, **change},
                            code="bats-plan-invalid")
        for value in (payload.decode(), bytearray(payload), None):
            self.reject(self.api.build_file_plan, value, **good, code="bats-plan-invalid")

    def test_source_unsupported_declarations_encoding_and_expansion_refuse(self):
        cases = (b'@test "escaped \\" quote" {\ntrue\n}\n',
                 b'@test \'single quoted\' {\ntrue\n}\n',
                 b'@test "dynamic $VALUE" {\ntrue\n}\n',
                 b'@test "a" {\ntrue\n}\n\xff', b'cat <<EOF\nunterminated\n',
                 source_for(("duplicate", "duplicate")))
        for payload in cases:
            with self.subTest(payload=payload):
                self.reject(self.api.build_file_plan, payload, tier="hosted",
                            path="bats/hosted/synthetic.bats", content_sha256=digest(payload),
                            ordered_title_sha256=(digest(b"placeholder"),), code="bats-plan-invalid")

    def test_verified_source_with_dynamic_title_still_refuses(self):
        for raw in ("dynamic $VALUE", "dynamic `command`", "dynamic \\\\$VALUE"):
            with self.subTest(raw=raw):
                self.reject(self.plan, (raw,), code="bats-plan-invalid")

    def test_full_report_preserves_titles_and_ignores_comment_evidence(self):
        plan = self.plan(("  café e\u0301  ", "literal # skip text # TODO text (12ms)"))
        report = self.report(plan).replace(b"ok 1", b"# diagnostic\n#ok 999 fabricated\nok 1") + b"# tail\n"
        result = self.api.parse_tap(report, 0, plan)
        self.assertEqual(result.plan, plan)
        self.assertEqual(result.passed_numbers, (1, 2))
        self.assertEqual(self.api.validate_file_results((plan,), (result,)), frozenset(
            f"bats:hosted:{plan.path}:{raw_hash}" for raw_hash in plan.raw_title_sha256))
        with self.assertRaises(FrozenInstanceError):
            result.passed_numbers = ()
        with self.assertRaises(FrozenInstanceError):
            plan.path = "bats/hosted/other.bats"

    def test_exact_title_matched_before_additional_skip_suffix(self):
        plan = self.plan(("literal # skip reason", "second"))
        for reason in ("", "reason", "reason # TODO text"):
            payload = ("1..2\nok 1 literal # skip reason\nok 2 second # skip " + reason + "\n").encode()
            result = self.api.parse_tap(payload, 0, plan)
            self.assertEqual(result.passed_numbers, (1,))
            ids = self.api.validate_file_results((plan,), (result,))
            self.assertEqual(ids, frozenset((f"bats:hosted:{plan.path}:{plan.raw_title_sha256[0]}",)))
        for suffix in (" # skip", " # SKIP reason", " # TODO reason", " (2ms)", " extra"):
            self.reject_report(("1..2\nok 1 literal # skip reason\nok 2 second" + suffix + "\n").encode(), plan=plan)

    def test_unicode_canonical_equivalence_does_not_replace_exact_title_bytes(self):
        plan = self.plan(("caf\u00e9",))
        self.reject_report("1..1\nok 1 cafe\u0301\n".encode(), plan=plan)

    def test_multiline_skip_reason_cannot_smuggle_a_result(self):
        plan = self.plan(("first",))
        self.reject_report(b"1..1\nok 1 first # skip reason\ncontinued reason\n", plan=plan)
        self.reject_report(b"1..1\nok 1 first # skip reason\nok 2 forged\n", plan=plan)
        result = self.api.parse_tap(b"1..1\nok 1 first # skip reason\n# continuation\n", 0, plan)
        self.assertEqual(result.passed_numbers, ())

    def test_any_nonzero_or_noninteger_process_status_refuses_apparent_success(self):
        plan = self.plan()
        for status in (1, 23, 124, -9, True, False, "0", 0.0, None):
            with self.subTest(status=status):
                self.reject_report(self.report(plan), status, plan)

    def test_framing_encoding_and_control_bytes_refuse(self):
        valid = self.report(self.plan())
        payloads = (b"", valid[:-1], b"\xef\xbb\xbf" + valid, valid.replace(b"\n", b"\r\n"),
                    valid + b"# nul\x00\n", valid + b"# tab\t\n", valid + b"# del\x7f\n",
                    valid + "# control\u0085\n".encode(), valid + b"# bad\xff\n",
                    b"\n" + valid, valid + b"\n", b"TAP version 13\n" + valid,
                    valid.decode(), bytearray(valid), None)
        for payload in payloads:
            with self.subTest(payload=repr(payload)[:80]):
                self.reject_report(payload)

    def test_complete_file_order_title_and_cardinality_are_mandatory(self):
        cases = (
            b"1..0\n", b"1..1\nok 1 first\n", b"1..3\nok 1 first\nok 2 second\n",
            b"1..02\nok 1 first\nok 2 second\n", b"1..+2\nok 1 first\nok 2 second\n",
            b"1..2 \nok 1 first\nok 2 second\n", b"1..2\nok 01 first\nok 2 second\n",
            b"1..2\nok +1 first\nok 2 second\n", b"1..2\nok 0 first\nok 2 second\n",
            b"1..2\nok 2 second\nok 1 first\n", b"1..2\nok 1 first\nok 1 first\n",
            b"1..2\nok 1 first\n", b"1..2\nok 1 wrong\nok 2 second\n",
            b"1..2\nok 1 first \nok 2 second\n", b"1..2\nok 1 first\nnot ok 2 second\n",
            b"1..2\nok 1 first\nok 2 second\n1..2\n",
            b"1..2\nok 1 first\nok 2 second\nok 3 extra\n",
            b"1..2\nok 1 first\nok 2 second\nBail out!\n",
            b"1..2\nok 1first\nok 2 second\n", b"1..2\n ok 1 first\nok 2 second\n",
            b"1..2\nFD3: ok 1 first\nok 2 second\n",
        )
        for payload in cases:
            with self.subTest(payload=payload):
                self.reject_report(payload)

    def test_decimal_tokens_are_bounded_before_conversion(self):
        digits = b"9" * 10000
        for payload in (b"1.." + digits + b"\n", b"1..2\nok " + digits + b" first\nok 2 second\n"):
            self.reject_report(payload)

    def test_report_exact_byte_bound_and_one_byte_over(self):
        plan = self.plan(("first",))
        prefix = self.report(plan)
        exact = prefix + b"#" + b"x" * (self.api.MAX_REPORT_BYTES - len(prefix) - 2) + b"\n"
        self.assertEqual(len(exact), self.api.MAX_REPORT_BYTES)
        self.assertEqual(self.api.parse_tap(exact, 0, plan).passed_numbers, (1,))
        self.reject_report(exact[:-1] + b"x\n", plan=plan)

    def test_runtime_equivalent_raw_titles_keep_distinct_reference_hashes(self):
        plan = self.plan((r"slash \q", r"slash \\q"))
        self.assertEqual(plan.runtime_titles[0], plan.runtime_titles[1])
        self.assertNotEqual(plan.raw_title_sha256[0], plan.raw_title_sha256[1])
        self.assertEqual(len(self.api.validate_file_results((plan,), (self.result(plan),))), 2)

    def test_collection_requires_exact_plan_order_and_no_missing_or_extra_files(self):
        first = self.plan(("first",), path="bats/hosted/a.bats")
        second = self.plan(("second",), tier="local", path="bats/local/b.bats")
        one, two = self.result(first), self.result(second)
        ids = self.api.validate_file_results((first, second), (one, two))
        self.assertEqual(len(ids), 2)
        self.assertIn(f"bats:local:{second.path}:{second.raw_title_sha256[0]}", ids)
        self.assertEqual(self.api.validate_file_results((), ()), frozenset())
        for plans, results in (((first, second), (one,)), ((first,), (one, two)),
                               ((first, second), (two, one)), ((second, first), (two, one)),
                               ((first, first), (one, one)), ((), (one,)),
                               ([first], (one,)), ((first,), [one]),
                               ((first,), ({"plan": first, "passed_numbers": (1,), "extra": 1},)),
                               ((first,), (object(),))):
            self.reject_records(plans, results)

    def test_full_plan_identity_is_checked_not_just_path_or_pass_ids(self):
        plan = self.plan(("first",))
        alterations = (
            {"tier": "local"}, {"path": "bats/hosted/other.bats"},
            {"content_sha256": "0" * 64}, {"raw_titles": ("changed",)},
            {"raw_title_sha256": ("0" * 64,)}, {"runtime_titles": ("changed",)},
            {"runtime_title_sha256": ("0" * 64,)}, {"decoder": "unreviewed-v2"},
        )
        for change in alterations:
            with self.subTest(field=tuple(change)):
                other = replace(plan, **change)
                self.reject_records((plan,), (self.result(other, (1,)),))
        self.reject_records((plan,), (frozenset((f"bats:hosted:{plan.path}:{plan.raw_title_sha256[0]}",)),))

    def test_untrusted_dataclass_contents_are_validated_before_hashing(self):
        plan = self.plan(("first",))
        for change in ({"raw_titles": ["first"]}, {"raw_title_sha256": [digest(b"first")]},
                       {"runtime_titles": ["first"]}, {"runtime_title_sha256": [digest(b"first")]},
                       {"tier": []}, {"path": []}, {"decoder": []}, {"content_sha256": []},
                       {"raw_titles": ([],)}, {"runtime_titles": ([],)},
                       {"raw_titles": ()}, {"raw_title_sha256": ()},
                       {"runtime_titles": ()}, {"runtime_title_sha256": ()},
                       {"raw_title_sha256": ("0" * 64,)},
                       {"runtime_title_sha256": ("0" * 64,)},
                       {"runtime_titles": ("different",)}):
            with self.subTest(field=tuple(change)):
                malformed = replace(plan, **change)
                self.reject_report(self.report(plan), plan=malformed)
                self.reject_records((malformed,), (self.result(malformed, (1,)),))
        for numbers in ([1], frozenset((1,)), (True,), (False,), ("1",), ([],), (0,), (-1,),
                        (2,), (1, 1), (1.0,), None):
            with self.subTest(numbers=numbers):
                self.reject_records((plan,), (self.result(plan, numbers) if numbers is not None
                                              else self.api.BatsFileResult(plan, None),))
        two = self.plan()
        self.reject_records((two,), (self.result(two, (2, 1)),))

    def test_file_count_bound_is_exact_and_overflow_refuses(self):
        base = self.plan(("first",))
        plans = tuple(replace(base, path=f"bats/hosted/p{index:04}.bats")
                      for index in range(self.api.MAX_BATS_FILES))
        results = tuple(self.result(plan, (1,)) for plan in plans)
        self.assertEqual(len(self.api.validate_file_results(plans, results)), self.api.MAX_BATS_FILES)
        extra = replace(base, path="bats/hosted/z.bats")
        self.reject_records(plans + (extra,), results + (self.result(extra, (1,)),))

    def test_total_declarations_and_results_at_bound_and_overflow(self):
        titles = tuple(f"case {index:05}" for index in range(self.api.MAX_BATS_TESTS))
        plan = self.plan(titles, path="bats/hosted/a.bats")
        result = self.api.parse_tap(self.report(plan), 0, plan)
        self.assertEqual(len(result.passed_numbers), self.api.MAX_BATS_TESTS)
        self.assertEqual(len(self.api.validate_file_results((plan,), (result,))), self.api.MAX_BATS_TESTS)
        extra = self.plan(("extra",), path="bats/hosted/z.bats")
        self.reject_records((plan, extra), (result, self.result(extra, (1,))))
        self.reject_records((plan,), (self.result(plan, (1,) * (self.api.MAX_BATS_TESTS + 1)),))


if __name__ == "__main__":
    unittest.main()
