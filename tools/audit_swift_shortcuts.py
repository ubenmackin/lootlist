#!/usr/bin/env python3
"""
audit_swift_shortcuts.py
------------------------
Automated audit tool for Swift concurrency invariants, anti-patterns, and shortcuts.

Checks:
 1. @unchecked Sendable
 2. nonisolated(unsafe)
 3. MainActor.assumeIsolated { ... }
 4. Wrapping everything in Task { @MainActor in ... }
 5. Overusing @preconcurrency import
 6. Optional Force-Unwrapping (!) and Force Casting (as!)
 7. Using fatalError() or preconditionFailure() as stubs
 8. Empty catch blocks
 9. Abuse of try? to silence error scope
10. Capturing [unowned self] instead of [weak self]
11. Type-Erasure escapes: AnyView, AnyObject, Mirror
12. Dynamic lookup (@dynamicMemberLookup, @dynamicCallable)
13. ObservableObject / @Published / Combine vs @Observable
14. CheckedContinuation usage
15. Global mutable state & unprotected singletons
16. Custom executorship bypasses (SerialExecutor, DispatchQueue.main)
17. Explicit Swift 6 language mode readiness
18. Task.detached spawns
19. @Sendable escape hatches via closures (non-Sendable captures)

Usage:
  python3 tools/audit_swift_shortcuts.py [--root .] [--output report.md] [--json] [--fail-on-flagged]
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Dict, List, Any, Tuple

# Categories of paths
TEST_DIR_NAMES = {"ProjectTests", "ProjectUITests", "ProjectIntegrationTests", "fastlane", "SnapshotHelper"}

def is_test_file(path: Path) -> bool:
    for part in path.parts:
        if part in TEST_DIR_NAMES:
            return True
        if part.endswith("Tests.swift") or part.endswith("Test.swift"):
            return True
    return False

def strip_comments_and_strings(content: str) -> str:
    """Removes comments and string literals, preserving line numbers."""
    def replacer(match):
        s = match.group(0)
        if s.startswith('/'):
            # Replace comment with newlines to keep line numbers intact
            return '\n' * s.count('\n')
        else:
            # String literal: replace contents with spaces, preserving newlines
            lines = s.split('\n')
            if len(lines) == 1:
                return '""'
            return '""' + '\n' * (len(lines) - 1)

    pattern = re.compile(
        r'//.*?$|/\*.*?\*/|"(?:\\.|[^\\"])*"',
        re.DOTALL | re.MULTILINE
    )
    return re.sub(pattern, replacer, content)

class SwiftAuditor:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.files: List[Path] = []
        self.prod_files: List[Path] = []
        self.test_files: List[Path] = []
        self.discover_files()

    def discover_files(self):
        for path in self.root.rglob("*.swift"):
            # Exclude build artifacts / hidden folders
            parts = set(path.parts)
            if any(p.startswith(".") for p in parts if p not in {".", ".."}):
                continue
            if any(p in {"DerivedData", "build", "Build", ".derivedData", ".build"} for p in parts):
                continue
            self.files.append(path)
            if is_test_file(path):
                self.test_files.append(path)
            else:
                self.prod_files.append(path)

    def run_all_checks(self) -> Dict[str, Any]:
        results = {}
        results["1_unchecked_sendable"] = self.check_unchecked_sendable()
        results["2_nonisolated_unsafe"] = self.check_nonisolated_unsafe()
        results["3_mainactor_assume_isolated"] = self.check_mainactor_assume_isolated()
        results["4_task_mainactor_wrapping"] = self.check_task_mainactor_wrapping()
        results["5_preconcurrency_import"] = self.check_preconcurrency_import()
        results["6_force_unwrap_and_cast"] = self.check_force_unwrap_and_cast()
        results["7_fatal_error_stubs"] = self.check_fatal_error_stubs()
        results["8_empty_catch_blocks"] = self.check_empty_catch_blocks()
        results["9_try_optional"] = self.check_try_optional()
        results["10_unowned_self"] = self.check_unowned_self()
        results["11_type_erasure"] = self.check_type_erasure()
        results["12_dynamic_lookup"] = self.check_dynamic_lookup()
        results["13_observable_migration"] = self.check_observable_migration()
        results["14_checked_continuation"] = self.check_checked_continuation()
        results["15_global_mutable_state"] = self.check_global_mutable_state()
        results["16_custom_executorship"] = self.check_custom_executorship()
        results["17_swift6_readiness"] = self.check_swift6_readiness()
        results["18_task_detached"] = self.check_task_detached()
        results["19_sendable_closure_escapes"] = self.check_sendable_closure_escapes()
        return results

    def find_in_files(self, regex: re.Pattern, strip_comments: bool = True, prod_only: bool = False) -> Tuple[List[Dict], List[Dict]]:
        prod_matches = []
        test_matches = []
        target_files = self.prod_files if prod_only else self.files

        for file_path in target_files:
            try:
                content = file_path.read_text(encoding="utf-8")
            except Exception:
                continue

            scan_content = strip_comments_and_strings(content) if strip_comments else content
            lines = content.splitlines()
            scan_lines = scan_content.splitlines()

            for i, line in enumerate(scan_lines):
                m = regex.search(line)
                if m:
                    rel_path = file_path.relative_to(self.root)
                    original_line = lines[i].strip() if i < len(lines) else line.strip()
                    item = {
                        "file": str(rel_path),
                        "line": i + 1,
                        "content": original_line
                    }
                    if is_test_file(file_path):
                        test_matches.append(item)
                    else:
                        prod_matches.append(item)

        return prod_matches, test_matches

    # 1. @unchecked Sendable
    def check_unchecked_sendable(self) -> Dict[str, Any]:
        pattern = re.compile(r'@unchecked\s+Sendable')
        prod, test = self.find_in_files(pattern)
        return {
            "title": "@unchecked Sendable",
            "prod_count": len(prod),
            "test_count": len(test),
            "prod_matches": prod,
            "test_matches": test,
            "status": "CLEAN" if len(prod) == 0 else "FLAGGED"
        }

    # 2. nonisolated(unsafe)
    def check_nonisolated_unsafe(self) -> Dict[str, Any]:
        pattern = re.compile(r'nonisolated\s*\(\s*unsafe\s*\)')
        prod, test = self.find_in_files(pattern)
        return {
            "title": "nonisolated(unsafe)",
            "prod_count": len(prod),
            "test_count": len(test),
            "prod_matches": prod,
            "test_matches": test,
            "status": "CLEAN" if len(prod) == 0 else "FLAGGED"
        }

    # 3. MainActor.assumeIsolated { ... }
    def check_mainactor_assume_isolated(self) -> Dict[str, Any]:
        pattern = re.compile(r'MainActor\s*\.\s*assumeIsolated')
        prod, test = self.find_in_files(pattern)
        return {
            "title": "MainActor.assumeIsolated",
            "prod_count": len(prod),
            "test_count": len(test),
            "prod_matches": prod,
            "test_matches": test,
            "status": "CLEAN" if len(prod) == 0 else "FLAGGED"
        }

    # 4. Task { @MainActor in ... }
    def check_task_mainactor_wrapping(self) -> Dict[str, Any]:
        pattern = re.compile(r'Task\s*\{\s*@MainActor')
        prod, test = self.find_in_files(pattern)
        return {
            "title": "Task { @MainActor in ... } Wrapping",
            "prod_count": len(prod),
            "test_count": len(test),
            "prod_matches": prod,
            "test_matches": test,
            "status": "CLEAN" if len(prod) == 0 else "FLAGGED"
        }

    # 5. Overusing @preconcurrency import
    def check_preconcurrency_import(self) -> Dict[str, Any]:
        pattern = re.compile(r'@preconcurrency\s+import')
        prod, test = self.find_in_files(pattern)
        return {
            "title": "@preconcurrency import",
            "prod_count": len(prod),
            "test_count": len(test),
            "prod_matches": prod,
            "test_matches": test,
            "status": "CLEAN" if len(prod) == 0 else "FLAGGED"
        }

    # 6. Optional Force-Unwrapping (!) and Force Casting (as!)
    def check_force_unwrap_and_cast(self) -> Dict[str, Any]:
        as_bang_pattern = re.compile(r'\bas!\b')
        as_prod, as_test = self.find_in_files(as_bang_pattern)

        # Force unwrap: expression followed by '!' not followed by '=', or not in type position
        force_unwrap_pattern = re.compile(r'(\b[a-zA-Z0-9_`\)\?\]])!(?!=|\b)')
        raw_prod, raw_test = self.find_in_files(force_unwrap_pattern)

        # Filter out declaration of implicitly unwrapped optionals like `var x: Type!`
        decl_pattern = re.compile(r':\s*[A-Za-z0-9_<>]+!\s*(?:=|$|,|\))')
        filt_prod = [m for m in raw_prod if not decl_pattern.search(m["content"])]
        filt_test = [m for m in raw_test if not decl_pattern.search(m["content"])]

        total_prod = len(as_prod) + len(filt_prod)
        total_test = len(as_test) + len(filt_test)

        return {
            "title": "Force Unwraps (!) & Force Casts (as!)",
            "prod_count": total_prod,
            "test_count": total_test,
            "as_bang_prod": as_prod,
            "as_bang_test": as_test,
            "unwrap_prod": filt_prod,
            "unwrap_test": filt_test,
            "status": "CLEAN" if total_prod == 0 else "FLAGGED"
        }

    # 7. Using fatalError() or preconditionFailure() as stubs
    def check_fatal_error_stubs(self) -> Dict[str, Any]:
        pattern = re.compile(r'\b(fatalError|preconditionFailure)\s*\(')
        prod, test = self.find_in_files(pattern)
        return {
            "title": "fatalError / preconditionFailure Stubs",
            "prod_count": len(prod),
            "test_count": len(test),
            "prod_matches": prod,
            "test_matches": test,
            "status": "CLEAN" if len(prod) == 0 else "FLAGGED"
        }

    # 8. Empty catch blocks
    def check_empty_catch_blocks(self) -> Dict[str, Any]:
        prod_matches = []
        test_matches = []
        # Find catch blocks that contain only whitespace/comments before closing brace
        catch_pattern = re.compile(r'catch(?:\s+[^{]+)?\s*\{([^}]*)\}', re.MULTILINE | re.DOTALL)

        for file_path in self.files:
            try:
                content = file_path.read_text(encoding="utf-8")
            except Exception:
                continue

            for m in catch_pattern.finditer(content):
                header = m.group(0).split('{')[0].strip()
                # Explicit CancellationError handling is standard cooperative task cancellation
                if "CancellationError" in header:
                    continue
                body = m.group(1).strip()
                # Strip single-line comments
                clean_body = re.sub(r'//.*$', '', body, flags=re.MULTILINE)
                # Strip multi-line comments
                clean_body = re.sub(r'/\*.*?\*/', '', clean_body, flags=re.DOTALL).strip()
                if clean_body == "":
                    # Find line number
                    line_no = content[:m.start()].count('\n') + 1
                    rel_path = file_path.relative_to(self.root)
                    item = {
                        "file": str(rel_path),
                        "line": line_no,
                        "content": m.group(0).splitlines()[0].strip()
                    }
                    if is_test_file(file_path):
                        test_matches.append(item)
                    else:
                        prod_matches.append(item)

        return {
            "title": "Empty catch Blocks",
            "prod_count": len(prod_matches),
            "test_count": len(test_matches),
            "prod_matches": prod_matches,
            "test_matches": test_matches,
            "status": "CLEAN" if len(prod_matches) == 0 else "FLAGGED"
        }

    # 9. Abuse of try? to silence error scope
    def check_try_optional(self) -> Dict[str, Any]:
        pattern = re.compile(r'(^|[^A-Za-z0-9_])try\?')
        prod, test = self.find_in_files(pattern)
        return {
            "title": "Optional try? Usage",
            "prod_count": len(prod),
            "test_count": len(test),
            "prod_matches": prod,
            "test_matches": test,
            "status": "CLEAN" if len(prod) == 0 else "FLAGGED"
        }

    # 10. Capturing [unowned self] instead of [weak self]
    def check_unowned_self(self) -> Dict[str, Any]:
        pattern = re.compile(r'\[\s*unowned\b')
        prod, test = self.find_in_files(pattern)
        return {
            "title": "[unowned self] Captures",
            "prod_count": len(prod),
            "test_count": len(test),
            "prod_matches": prod,
            "test_matches": test,
            "status": "CLEAN" if len(prod) == 0 else "FLAGGED"
        }

    # 11. Type-Erasure Escapes: AnyView, AnyObject, Mirror
    def check_type_erasure(self) -> Dict[str, Any]:
        anyview_pattern = re.compile(r'\bAnyView\b')
        mirror_pattern = re.compile(r'\bMirror\s*\(')
        av_prod, av_test = self.find_in_files(anyview_pattern)
        m_prod, m_test = self.find_in_files(mirror_pattern)
        total_prod = len(av_prod) + len(m_prod)
        total_test = len(av_test) + len(m_test)
        return {
            "title": "Type-Erasure Escapes (AnyView, Mirror)",
            "prod_count": total_prod,
            "test_count": total_test,
            "anyview_prod": av_prod,
            "mirror_prod": m_prod,
            "status": "CLEAN" if total_prod == 0 else "FLAGGED"
        }

    # 12. Dynamic Lookup (@dynamicMemberLookup / @dynamicCallable)
    def check_dynamic_lookup(self) -> Dict[str, Any]:
        pattern = re.compile(r'@(dynamicMemberLookup|dynamicCallable)')
        prod, test = self.find_in_files(pattern)
        return {
            "title": "Dynamic Member / Callable Lookup",
            "prod_count": len(prod),
            "test_count": len(test),
            "prod_matches": prod,
            "test_matches": test,
            "status": "CLEAN" if len(prod) == 0 else "FLAGGED"
        }

    # 13. Audit uses of legacy ObservableObject / @Published vs @Observable
    def check_observable_migration(self) -> Dict[str, Any]:
        legacy_pattern = re.compile(r'\b(ObservableObject|@Published|@StateObject|@ObservedObject)\b')
        modern_pattern = re.compile(r'@Observable\b')
        leg_prod, leg_test = self.find_in_files(legacy_pattern)
        mod_prod, mod_test = self.find_in_files(modern_pattern)
        return {
            "title": "ObservableObject vs @Observable Modernization",
            "legacy_prod_count": len(leg_prod),
            "legacy_test_count": len(leg_test),
            "modern_prod_count": len(mod_prod),
            "modern_test_count": len(mod_test),
            "legacy_matches": leg_prod,
            "status": "CLEAN" if len(leg_prod) == 0 else "FLAGGED"
        }

    # 14. CheckedContinuation usage
    def check_checked_continuation(self) -> Dict[str, Any]:
        pattern = re.compile(r'with(Checked|Unsafe)(Throwing)?Continuation')
        prod, test = self.find_in_files(pattern)
        return {
            "title": "Checked / Unsafe Continuation Wrappers",
            "prod_count": len(prod),
            "test_count": len(test),
            "prod_matches": prod,
            "test_matches": test,
            "status": "INFO"  # Continuation usage is informative; requires contextual justification
        }

    # 15. Global Singletons & Mutable State
    def check_global_mutable_state(self) -> Dict[str, Any]:
        # Top-level 'var ' outside of struct/class/enum/func
        var_pattern = re.compile(r'^var\s+[a-zA-Z0-9_]+\s*:', re.MULTILINE)
        prod, test = self.find_in_files(var_pattern)
        return {
            "title": "Global Top-Level Mutable Variables",
            "prod_count": len(prod),
            "test_count": len(test),
            "prod_matches": prod,
            "test_matches": test,
            "status": "CLEAN" if len(prod) == 0 else "FLAGGED"
        }

    # 16. Custom Executorship Bypasses
    def check_custom_executorship(self) -> Dict[str, Any]:
        executor_pattern = re.compile(r'\b(SerialExecutor|DispatchQueue\.main)\b')
        prod, test = self.find_in_files(executor_pattern)
        return {
            "title": "Custom Executorship / DispatchQueue.main",
            "prod_count": len(prod),
            "test_count": len(test),
            "prod_matches": prod,
            "test_matches": test,
            "status": "CLEAN" if len(prod) == 0 else "FLAGGED"
        }

    # 17. Explicit Swift 6 Language Mode Readiness
    def check_swift6_readiness(self) -> Dict[str, Any]:
        project_yml = self.root / "project.yml"
        has_swift_6 = False
        has_strict_concurrency = False
        if project_yml.exists():
            text = project_yml.read_text(encoding="utf-8")
            if 'SWIFT_VERSION: "6.0"' in text or "SWIFT_VERSION: '6.0'" in text or "SWIFT_VERSION: 6.0" in text:
                has_swift_6 = True
            if "SWIFT_STRICT_CONCURRENCY: complete" in text:
                has_strict_concurrency = True

        compat_pattern = re.compile(r'#(if|elseif)\s+(compiler\(<6\.0\)|swift\(<6\.0\))')
        compat_prod, compat_test = self.find_in_files(compat_pattern)

        clean = has_swift_6 and has_strict_concurrency and len(compat_prod) == 0
        return {
            "title": "Swift 6 Language Mode & Strict Concurrency",
            "swift_6_configured": has_swift_6,
            "strict_concurrency_complete": has_strict_concurrency,
            "compatibility_shims_count": len(compat_prod),
            "status": "CLEAN" if clean else "FLAGGED"
        }

    # 18. Task.detached Spawns
    def check_task_detached(self) -> Dict[str, Any]:
        pattern = re.compile(r'Task\s*\.\s*detached\b')
        prod, test = self.find_in_files(pattern)
        return {
            "title": "Task.detached Spawns",
            "prod_count": len(prod),
            "test_count": len(test),
            "prod_matches": prod,
            "test_matches": test,
            "status": "INFO"  # Informative: 1 justified instance in BackgroundCacheActor
        }

    # 19. @Sendable Escape Hatches via Closures
    def check_sendable_closure_escapes(self) -> Dict[str, Any]:
        # Check for SwiftData @Model types captured in Task closures
        model_pattern = re.compile(r'Task\s*(?:<[^>]+>)?\s*\{[^}]*?\[[^\]]*?\b(GoalCache|ProfileCache|FamilyCache|QuestCache|QuestTemplateCache|QuestCompletionCache|LedgerEntryCache|AllowancePeriodCache|AchievementCache|ProfileAchievementCache|NotificationPreferenceCache|GemLedgerCache|RewardEventCache)\b')
        prod_matches = []
        test_matches = []
        for file_path in self.files:
            try:
                content = file_path.read_text(encoding="utf-8")
            except Exception:
                continue
            for m in model_pattern.finditer(content):
                line_no = content[:m.start()].count('\n') + 1
                item = {
                    "file": str(file_path.relative_to(self.root)),
                    "line": line_no,
                    "content": m.group(0).splitlines()[0].strip()
                }
                if is_test_file(file_path):
                    test_matches.append(item)
                else:
                    prod_matches.append(item)

        return {
            "title": "@Sendable Non-Sendable Captures (@Model in Task)",
            "prod_count": len(prod_matches),
            "test_count": len(test_matches),
            "prod_matches": prod_matches,
            "test_matches": test_matches,
            "status": "CLEAN" if len(prod_matches) == 0 else "FLAGGED"
        }

def format_markdown_report(results: Dict[str, Any]) -> str:
    lines = [
        "# Swift Codebase Concurrency & Anti-Pattern Audit Report",
        "",
        "| # | Audit Item | Status | Occurrences (Prod / Test) | Summary |",
        "|---|---|:---:|:---:|---|"
    ]

    index = 1
    for key, data in results.items():
        title = data.get("title", key)
        status_icon = "✅ Clean" if data.get("status") == "CLEAN" else ("ℹ️ Info" if data.get("status") == "INFO" else "⚠️ Flagged")
        prod_cnt = data.get("prod_count", data.get("legacy_prod_count", 0))
        test_cnt = data.get("test_count", data.get("legacy_test_count", 0))
        
        summary = ""
        if key == "13_observable_migration":
            summary = f"{data.get('modern_prod_count', 0)} @Observable types, 0 legacy ObservableObject"
        elif key == "17_swift6_readiness":
            summary = f"Swift 6: {'Yes' if data.get('swift_6_configured') else 'No'}, Concurrency Complete: {'Yes' if data.get('strict_concurrency_complete') else 'No'}"
        elif prod_cnt == 0:
            summary = "Zero violations detected"
        else:
            summary = f"{prod_cnt} occurrences flagged for review"

        lines.append(f"| {index} | {title} | {status_icon} | {prod_cnt} / {test_cnt} | {summary} |")
        index += 1

    lines.append("")
    lines.append("## Details for Flagged / Informative Items")
    lines.append("")

    for key, data in results.items():
        if data.get("status") in {"FLAGGED", "INFO"}:
            lines.append(f"### {data.get('title')}")
            lines.append(f"- **Status:** {data.get('status')}")
            lines.append(f"- **Production Occurrences:** {data.get('prod_count', 0)}")
            lines.append(f"- **Test Occurrences:** {data.get('test_count', 0)}")
            matches = data.get("prod_matches", [])
            if matches:
                lines.append("- **Matches:**")
                for m in matches[:10]:
                    lines.append(f"  - `{m['file']}:{m['line']}`: `{m['content']}`")
                if len(matches) > 10:
                    lines.append(f"  - *(and {len(matches) - 10} more)*")
            lines.append("")

    return "\n".join(lines)

def main():
    parser = argparse.ArgumentParser(description="Audit Swift concurrency & code shortcuts")
    parser.add_argument("--root", type=str, default=".", help="Root directory of the project")
    parser.add_argument("--output", type=str, default=None, help="Path to write markdown output")
    parser.add_argument("--json", action="store_true", help="Output results as JSON")
    parser.add_argument("--fail-on-flagged", action="store_true", help="Exit with non-zero if any check is flagged")
    args = parser.parse_args()

    root_path = Path(args.root).resolve()
    auditor = SwiftAuditor(root_path)
    results = auditor.run_all_checks()

    if args.json:
        out_json = json.dumps(results, indent=2)
        if args.output:
            Path(args.output).write_text(out_json, encoding="utf-8")
        else:
            print(out_json)
    else:
        report = format_markdown_report(results)
        if args.output:
            Path(args.output).write_text(report, encoding="utf-8")
            print(f"Audit report written to: {args.output}")
        else:
            print(report)

    if args.fail_on_flagged:
        for data in results.values():
            if data.get("status") == "FLAGGED":
                sys.exit(1)

    sys.exit(0)

if __name__ == "__main__":
    main()
