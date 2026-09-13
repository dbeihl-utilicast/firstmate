#!/usr/bin/env python3
"""Count live Dependabot alerts that an npm package-lock branch proves it remediates.

Usage:
  fm-alert-count.py <base-ref> <head-ref>

The command reads the live open Dependabot alert list for origin's GitHub
repository through gh-axi, then evaluates each alert's package-lock manifest at
the supplied base and head refs.
It is deliberately fail-closed: an unsupported manifest, a non-semver version,
or an advisory without a non-major patched version is reported as not checked,
never counted as remediated.
Output is silent only when the live default-branch alert list is empty.
"""

from __future__ import annotations

import base64
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import PurePosixPath


REPO_RE = re.compile(r"(?:git@github\.com:|https://github\.com/)([^/\s]+)/([^/\s]+?)(?:\.git)?$")
SEMVER_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$")


class CheckError(Exception):
    pass


def run(*args: str) -> str:
    completed = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if completed.returncode:
        detail = completed.stderr.strip() or completed.stdout.strip() or "command failed"
        raise CheckError(f"{' '.join(args[:2])}: {detail}")
    return completed.stdout


def repository() -> str:
    remote = run("git", "remote", "get-url", "origin").strip()
    match = REPO_RE.fullmatch(remote)
    if not match:
        raise CheckError("origin is not a GitHub repository, so the live alert list was not checked")
    return f"{match.group(1)}/{match.group(2)}"


def gh_axi_bodies(output: str) -> list[str]:
    """Extract gh-axi's scalar response bodies without parsing presentation YAML."""
    bodies: list[str] = []
    for line in output.splitlines():
        match = re.fullmatch(r"\s*body:\s*['\"]?([A-Za-z0-9+/=]+)['\"]?\s*", line)
        if match:
            bodies.append(match.group(1))
    if not bodies:
        raise CheckError("gh-axi returned no readable alert data")
    return bodies


def live_alerts(repo: str) -> list[dict[str, object]]:
    query = "[.[] | {number, dependency, security_vulnerability}] | @base64"
    output = run(
        "gh-axi",
        "api",
        f"/repos/{repo}/dependabot/alerts?state=open&per_page=100",
        "--paginate",
        "--jq",
        query,
        "--full",
    )
    alerts: list[dict[str, object]] = []
    for body in gh_axi_bodies(output):
        try:
            page = json.loads(base64.b64decode(body, validate=True))
        except (ValueError, json.JSONDecodeError) as exc:
            raise CheckError(f"gh-axi returned malformed alert data: {exc}") from exc
        if not isinstance(page, list) or not all(isinstance(alert, dict) for alert in page):
            raise CheckError("gh-axi returned an unexpected alert list")
        alerts.extend(page)
    return alerts


def git_file(ref: str, path: str) -> bytes:
    completed = subprocess.run(("git", "show", f"{ref}:{path}"), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if completed.returncode:
        raise CheckError(f"{path} is unavailable at {ref}")
    return completed.stdout


def package_name_from_path(path: str) -> str | None:
    parts = PurePosixPath(path).parts
    indexes = [index for index, part in enumerate(parts) if part == "node_modules"]
    if not indexes:
        return None
    start = indexes[-1] + 1
    if start >= len(parts):
        return None
    if parts[start].startswith("@") and start + 1 < len(parts):
        return f"{parts[start]}/{parts[start + 1]}"
    return parts[start]


def lock_versions(raw: bytes) -> dict[str, list[str]]:
    try:
        lock = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CheckError(f"package-lock.json is not valid JSON: {exc}") from exc
    versions: dict[str, list[str]] = defaultdict(list)
    packages = lock.get("packages")
    if isinstance(packages, dict):
        for path, item in packages.items():
            if not isinstance(path, str) or not isinstance(item, dict):
                continue
            package = package_name_from_path(path)
            version = item.get("version")
            if package and isinstance(version, str):
                versions[package].append(version)
        return versions

    def visit(dependencies: object) -> None:
        if not isinstance(dependencies, dict):
            return
        for package, item in dependencies.items():
            if not isinstance(package, str) or not isinstance(item, dict):
                continue
            version = item.get("version")
            if isinstance(version, str):
                versions[package].append(version)
            visit(item.get("dependencies"))

    visit(lock.get("dependencies"))
    return versions


def semver(version: str) -> tuple[int, int, int, int] | None:
    match = SEMVER_RE.fullmatch(version)
    if not match:
        return None
    major, minor, patch, prerelease = match.groups()
    return int(major), int(minor), int(patch), 0 if prerelease else 1


def version_state(versions: list[str], patched: str) -> str:
    patch_version = semver(patched)
    parsed = [semver(version) for version in versions]
    if patch_version is None or any(version is None for version in parsed):
        return "unknown"
    return "safe" if all(version >= patch_version for version in parsed if version is not None) else "vulnerable"


def requires_major_upgrade(versions: list[str], patched: str) -> bool:
    patch_version = semver(patched)
    parsed = [semver(version) for version in versions]
    return bool(
        patch_version
        and parsed
        and all(version is not None and version[0] < patch_version[0] for version in parsed)
    )


def alert_fields(alert: dict[str, object]) -> tuple[int, str, str, str | None] | None:
    number = alert.get("number")
    dependency = alert.get("dependency")
    vulnerability = alert.get("security_vulnerability")
    if not isinstance(number, int) or not isinstance(dependency, dict) or not isinstance(vulnerability, dict):
        return None
    package = dependency.get("package")
    manifest = dependency.get("manifest_path")
    first_patched = vulnerability.get("first_patched_version")
    if not isinstance(package, dict) or not isinstance(package.get("name"), str) or not isinstance(manifest, str):
        return None
    patched = first_patched.get("identifier") if isinstance(first_patched, dict) else None
    return number, package["name"], manifest.lstrip("/"), patched if isinstance(patched, str) else None


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] in {"-h", "--help"}:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    base, head = argv[1:]
    try:
        repo = repository()
        alerts = live_alerts(repo)
    except CheckError as exc:
        print(f"NOT CHECKED: {exc}")
        return 1
    if not alerts:
        return 0

    remediated: list[str] = []
    excluded: list[str] = []
    unchecked: list[str] = []
    by_package: dict[str, list[int]] = defaultdict(list)
    caches: dict[tuple[str, str], dict[str, list[str]]] = {}

    for raw_alert in alerts:
        fields = alert_fields(raw_alert)
        if fields is None:
            unchecked.append("malformed live alert record")
            continue
        number, package, manifest, patched = fields
        by_package[package].append(number)
        label = f"#{number} {package} ({manifest})"
        if PurePosixPath(manifest).name != "package-lock.json":
            unchecked.append(f"{label}: unsupported manifest")
            continue
        if patched is None:
            excluded.append(f"{label}: major-only advisory, no non-major patched version to verify")
            continue
        try:
            for ref in (base, head):
                key = (ref, manifest)
                if key not in caches:
                    caches[key] = lock_versions(git_file(ref, manifest))
            base_versions = caches[(base, manifest)].get(package, [])
            head_versions = caches[(head, manifest)].get(package, [])
        except CheckError as exc:
            unchecked.append(f"{label}: {exc}")
            continue
        base_state = version_state(base_versions, patched) if base_versions else "safe"
        head_state = version_state(head_versions, patched) if head_versions else "safe"
        if base_state == "unknown" or head_state == "unknown":
            unchecked.append(f"{label}: non-semver package-lock version")
        elif requires_major_upgrade(base_versions, patched):
            excluded.append(f"{label}: major-only advisory, patch requires {patched}")
        elif base_state == "safe":
            excluded.append(f"{label}: already resolved on {base}")
        elif head_state == "safe":
            remediated.append(label)
        else:
            excluded.append(f"{label}: {head} does not reach a patched version")

    print("OPEN DEFAULT-BRANCH ADVISORIES BY PACKAGE:")
    for package, numbers in sorted(by_package.items()):
        identifiers = ", ".join(f"#{number}" for number in sorted(numbers))
        print(f"- {package}: {len(numbers)} ({identifiers})")
    print("PER-ADVISORY VERDICTS:")
    for item in sorted(remediated + excluded + unchecked):
        print(f"- {item}")
    print(f"VERIFIED BRANCH REMEDIATION COUNT: {len(remediated)} ({', '.join(remediated) or 'none'})")
    print(
        f"DEFAULT-BRANCH CAVEAT: {len(remediated)} verified branch remediation(s) close none now. "
        "Dependabot advisories attach to the default branch and close only after release to it."
    )
    print("EXCLUDED FROM THE VERIFIED COUNT:")
    for item in excluded:
        print(f"- {item}")
    if unchecked:
        print("NOT CHECKED:")
        for item in unchecked:
            print(f"- {item}")
        return 1
    print("NOT CHECKED: none")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
