#!/usr/bin/env python3
"""keel - promote, observe and roll back GitOps deployments, with timings.

A promotion is a one-line change to `gitops/environments/<env>/env.yaml`. This
tool makes that edit, waits for Argo CD to converge, and records how long it
took. The ledger it keeps is where the platform's headline numbers come from:
median time from merge to healthy, and median time to roll back.

    keel promote --app sentinel --env staging --tag sha-abc1234
    keel status
    keel wait --app sentinel --env staging
    keel rollback --app sentinel --env prod
    keel timings

Argo CD access is via its HTTP API using ARGOCD_SERVER and ARGOCD_TOKEN. Every
command that talks to a cluster supports --dry-run, and `promote` works with no
cluster at all — editing Git is the deployment.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
ENVIRONMENTS = REPO_ROOT / "gitops" / "environments"
LEDGER = REPO_ROOT / ".keel" / "ledger.jsonl"

TERMINAL_HEALTH = {"Healthy", "Degraded", "Missing", "Unknown"}
GREEN, YELLOW, RED, DIM, BOLD, RESET = (
    "\033[32m",
    "\033[33m",
    "\033[31m",
    "\033[2m",
    "\033[1m",
    "\033[0m",
)


def colour(text: str, code: str) -> str:
    return text if os.environ.get("NO_COLOR") else f"{code}{text}{RESET}"


def tone(status: str) -> str:
    if status in ("Healthy", "Synced", "Succeeded"):
        return colour(status, GREEN)
    if status in ("Progressing", "OutOfSync", "Running"):
        return colour(status, YELLOW)
    if status in ("Degraded", "Missing", "Failed", "Error"):
        return colour(status, RED)
    return colour(status, DIM)


def die(message: str) -> None:
    print(colour(f"error: {message}", RED), file=sys.stderr)
    raise SystemExit(1)


# --------------------------------------------------------------------------- #
# environment files
# --------------------------------------------------------------------------- #
def env_file(env: str) -> Path:
    path = ENVIRONMENTS / env / "env.yaml"
    if not path.exists():
        available = sorted(p.name for p in ENVIRONMENTS.iterdir() if p.is_dir())
        die(f"unknown environment '{env}'. Available: {', '.join(available)}")
    return path


def read_tag(env: str, app: str) -> str | None:
    """Read the current tag without a YAML dependency.

    The file shape is fixed and validated in CI, so a scoped scan is safer than
    adding a parser that would also happily rewrite comments and formatting.
    """
    text = env_file(env).read_text(encoding="utf-8")
    block = _app_block(text, app)
    if block is None:
        return None
    match = re.search(r"^\s{4}tag:\s*(\S+)\s*$", block, re.MULTILINE)
    return match.group(1) if match else None


def _app_block(text: str, app: str) -> str | None:
    start = re.search(rf"^  {re.escape(app)}:\s*$", text, re.MULTILINE)
    if not start:
        return None
    rest = text[start.end() :]
    end = re.search(r"^  \S", rest, re.MULTILINE)
    return rest[: end.start()] if end else rest


def write_tag(env: str, app: str, tag: str) -> tuple[str, str]:
    """Rewrite exactly one `tag:` line. Returns (previous, path-relative)."""
    path = env_file(env)
    text = path.read_text(encoding="utf-8")
    block = _app_block(text, app)
    if block is None:
        die(f"app '{app}' is not defined in {path.relative_to(REPO_ROOT)}")

    offset = text.index(block)
    match = re.search(r"^(\s{4}tag:\s*)(\S+)([^\n]*)$", block, re.MULTILINE)
    if not match:
        die(f"no `tag:` key under app '{app}' in {path.relative_to(REPO_ROOT)}")

    previous = match.group(2)
    if previous == tag:
        print(colour(f"{app}/{env} is already at {tag}; nothing to change", DIM))
        return previous, str(path.relative_to(REPO_ROOT))

    updated = (
        text[: offset + match.start()]
        + match.group(1)
        + tag
        + match.group(3)
        + text[offset + match.end() :]
    )
    path.write_text(updated, encoding="utf-8")
    return previous, str(path.relative_to(REPO_ROOT))


# --------------------------------------------------------------------------- #
# Argo CD client
# --------------------------------------------------------------------------- #
@dataclass
class AppState:
    name: str
    sync: str
    health: str
    revision: str
    images: list[str] = field(default_factory=list)
    message: str = ""
    operation: str = ""

    @property
    def converged(self) -> bool:
        return self.sync == "Synced" and self.health == "Healthy"


class Argo:
    def __init__(
        self, server: str | None = None, token: str | None = None, insecure: bool = True
    ):
        self.server = (server or os.environ.get("ARGOCD_SERVER", "")).rstrip("/")
        self.token = token or os.environ.get("ARGOCD_TOKEN", "")
        self.insecure = insecure

    @property
    def configured(self) -> bool:
        return bool(self.server and self.token)

    def _request(
        self, method: str, path: str, payload: dict[str, Any] | None = None
    ) -> Any:
        if not self.configured:
            die(
                "ARGOCD_SERVER and ARGOCD_TOKEN must be set to talk to Argo CD "
                "(or pass --dry-run)"
            )
        url = f"{self.server}{path}"
        data = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("authorization", f"Bearer {self.token}")
        request.add_header("content-type", "application/json")

        context = None
        if self.insecure and url.startswith("https"):
            import ssl

            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE

        try:
            with urllib.request.urlopen(
                request, timeout=45, context=context
            ) as response:
                body = response.read()
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")[:300]
            die(f"Argo CD {method} {path} -> {exc.code}: {detail}")
        except urllib.error.URLError as exc:
            die(f"cannot reach Argo CD at {self.server}: {exc.reason}")

    def applications(self, selector: str | None = None) -> list[AppState]:
        query = f"?selector={urllib.parse.quote(selector)}" if selector else ""
        payload = self._request("GET", f"/api/v1/applications{query}")
        return [self._state(item) for item in payload.get("items") or []]

    def application(self, name: str) -> AppState:
        return self._state(self._request("GET", f"/api/v1/applications/{name}"))

    @staticmethod
    def _state(item: dict[str, Any]) -> AppState:
        status = item.get("status") or {}
        sync = status.get("sync") or {}
        health = status.get("health") or {}
        operation = status.get("operationState") or {}
        summary = status.get("summary") or {}
        return AppState(
            name=(item.get("metadata") or {}).get("name", "?"),
            sync=sync.get("status", "Unknown"),
            health=health.get("status", "Unknown"),
            revision=(sync.get("revision") or "")[:8],
            images=sorted(summary.get("images") or []),
            message=health.get("message", "") or operation.get("message", ""),
            operation=operation.get("phase", ""),
        )

    def sync(self, name: str, prune: bool = False) -> None:
        self._request(
            "POST",
            f"/api/v1/applications/{name}/sync",
            {"prune": prune, "strategy": {"hook": {}}},
        )

    def history(self, name: str) -> list[dict[str, Any]]:
        payload = self._request("GET", f"/api/v1/applications/{name}")
        return (payload.get("status") or {}).get("history") or []

    def rollback(self, name: str, revision_id: int) -> None:
        self._request(
            "POST",
            f"/api/v1/applications/{name}/rollback",
            {"id": revision_id, "prune": False},
        )

    def wait(
        self, name: str, timeout: float, quiet: bool = False
    ) -> tuple[AppState, float]:
        started = time.monotonic()
        last = ""
        while time.monotonic() - started < timeout:
            state = self.application(name)
            line = f"{state.sync}/{state.health}"
            if line != last and not quiet:
                print(
                    f"  {tone(state.sync):<22} {tone(state.health):<22} {DIM}{state.revision}{RESET}"
                )
                last = line
            if state.converged:
                return state, time.monotonic() - started
            if state.health == "Degraded":
                return state, time.monotonic() - started
            time.sleep(3)
        return self.application(name), time.monotonic() - started


# --------------------------------------------------------------------------- #
# ledger
# --------------------------------------------------------------------------- #
def record(entry: dict[str, Any]) -> None:
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    entry = {"at": datetime.now(timezone.utc).isoformat(), **entry}
    with LEDGER.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry) + "\n")


def load_ledger() -> list[dict[str, Any]]:
    if not LEDGER.exists():
        return []
    entries = []
    for line in LEDGER.read_text(encoding="utf-8").splitlines():
        if line.strip():
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return entries


# --------------------------------------------------------------------------- #
# git
# --------------------------------------------------------------------------- #
def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args], cwd=REPO_ROOT, capture_output=True, text=True, check=False
    )
    if check and result.returncode != 0:
        die(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #
def cmd_promote(args: argparse.Namespace) -> int:
    previous, relative = write_tag(args.env, args.app, args.tag)
    print(
        f"{BOLD}{args.app}/{args.env}{RESET}: {colour(previous, DIM)} "
        f"-> {colour(args.tag, GREEN)}  ({relative})"
    )
    if previous == args.tag and not args.force:
        return 0

    if args.commit:
        message = args.message or f"promote({args.env}): {args.app} -> {args.tag}"
        git("add", relative)
        if git("diff", "--cached", "--name-only"):
            git("commit", "-m", message)
            print(f"  committed: {message}")
            if args.push:
                git("push")
                print("  pushed")
        else:
            print(colour("  nothing staged; file already matched", DIM))

    if args.dry_run:
        print(colour("  dry run: not contacting Argo CD", DIM))
        return 0

    argo = Argo(args.server, args.token)
    name = f"{args.app}-{args.env}"
    started = time.monotonic()

    if args.sync:
        print(f"  requesting sync of {name}")
        argo.sync(name, prune=args.prune)

    print(f"  waiting for {name} to converge (timeout {args.timeout:.0f}s)")
    state, elapsed = argo.wait(name, args.timeout)
    total = time.monotonic() - started

    record(
        {
            "kind": "deploy",
            "app": args.app,
            "env": args.env,
            "from": previous,
            "to": args.tag,
            "seconds": round(total, 2),
            "sync": state.sync,
            "health": state.health,
            "converged": state.converged,
            "synced_manually": args.sync,
        }
    )

    if state.converged:
        print(colour(f"  healthy in {total:.1f}s", GREEN))
        return 0
    print(
        colour(
            f"  did not converge in {elapsed:.1f}s: {state.sync}/{state.health} {state.message}",
            RED,
        )
    )
    return 1


def cmd_status(args: argparse.Namespace) -> int:
    if args.dry_run:
        print(f"{BOLD}desired state from Git{RESET}")
        for directory in sorted(p for p in ENVIRONMENTS.iterdir() if p.is_dir()):
            env = directory.name
            for app in ("flywheel", "sentinel"):
                current = read_tag(env, app)
                if current:
                    print(f"  {app + '/' + env:<22} {current}")
        return 0

    argo = Argo(args.server, args.token)
    apps = argo.applications(args.selector)
    if not apps:
        print(colour("no applications matched", DIM))
        return 0

    width = max(len(app.name) for app in apps) + 2
    print(
        f"{BOLD}{'application'.ljust(width)}{'sync'.ljust(22)}{'health'.ljust(22)}rev{RESET}"
    )
    degraded = 0
    for app in sorted(apps, key=lambda a: a.name):
        print(
            f"{app.name.ljust(width)}{tone(app.sync).ljust(31)}{tone(app.health).ljust(31)}{DIM}{app.revision}{RESET}"
        )
        if app.message and args.verbose:
            print(f"  {DIM}{app.message[:160]}{RESET}")
        if app.health == "Degraded":
            degraded += 1
    return 1 if degraded and args.fail_on_degraded else 0


def cmd_wait(args: argparse.Namespace) -> int:
    argo = Argo(args.server, args.token)
    name = args.name or f"{args.app}-{args.env}"
    print(f"waiting for {BOLD}{name}{RESET} (timeout {args.timeout:.0f}s)")
    state, elapsed = argo.wait(name, args.timeout)
    if state.converged:
        print(colour(f"converged in {elapsed:.1f}s", GREEN))
        return 0
    print(colour(f"still {state.sync}/{state.health} after {elapsed:.1f}s", RED))
    return 1


def cmd_rollback(args: argparse.Namespace) -> int:
    argo = Argo(args.server, args.token)
    name = args.name or f"{args.app}-{args.env}"
    history = argo.history(name)
    if len(history) < 2:
        die(f"{name} has no previous revision to roll back to")

    target = (
        history[-2]
        if args.to is None
        else next((h for h in history if str(h.get("id")) == str(args.to)), None)
    )
    if target is None:
        die(f"revision {args.to} not in the history of {name}")

    print(
        f"rolling {BOLD}{name}{RESET} back to revision id {target.get('id')} "
        f"({(target.get('revision') or '')[:8]}, deployed {target.get('deployedAt')})"
    )
    if args.dry_run:
        print(colour("  dry run: not contacting Argo CD", DIM))
        return 0

    started = time.monotonic()
    argo.rollback(name, int(target["id"]))
    state, _ = argo.wait(name, args.timeout)
    total = time.monotonic() - started

    record(
        {
            "kind": "rollback",
            "app": args.app,
            "env": args.env,
            "application": name,
            "to_revision": target.get("id"),
            "seconds": round(total, 2),
            "sync": state.sync,
            "health": state.health,
            "converged": state.converged,
        }
    )

    if state.converged:
        print(colour(f"  rolled back and healthy in {total:.1f}s", GREEN))
        return 0
    print(colour(f"  rollback did not converge: {state.sync}/{state.health}", RED))
    return 1


def cmd_timings(args: argparse.Namespace) -> int:
    entries = [e for e in load_ledger() if e.get("kind") in ("deploy", "rollback")]
    if not entries:
        print(colour("no timings recorded yet — run a promote or a rollback", DIM))
        return 0

    for kind in ("deploy", "rollback"):
        rows = [e for e in entries if e["kind"] == kind and e.get("converged")]
        failed = [e for e in entries if e["kind"] == kind and not e.get("converged")]
        if not rows:
            print(f"{BOLD}{kind}{RESET}: no successful runs ({len(failed)} failed)")
            continue
        seconds = sorted(e["seconds"] for e in rows)
        print(
            f"{BOLD}{kind}{RESET}: n={len(rows)}  "
            f"median={statistics.median(seconds):.1f}s  "
            f"p90={seconds[min(len(seconds) - 1, int(0.9 * (len(seconds) - 1)))]:.1f}s  "
            f"best={seconds[0]:.1f}s  worst={seconds[-1]:.1f}s"
            + (f"  failed={len(failed)}" if failed else "")
        )

    if args.verbose:
        print()
        for entry in entries[-args.limit :]:
            marker = (
                colour("ok", GREEN) if entry.get("converged") else colour("fail", RED)
            )
            print(
                f"  {entry['at'][:19]}  {entry['kind']:<9} "
                f"{entry.get('app', '?')}/{entry.get('env', '?'):<10} "
                f"{entry['seconds']:>7.1f}s  {marker}"
            )
    return 0


def cmd_diff(args: argparse.Namespace) -> int:
    """What Git wants versus what the cluster is running."""
    argo = Argo(args.server, args.token)
    drift = 0
    for directory in sorted(p for p in ENVIRONMENTS.iterdir() if p.is_dir()):
        env = directory.name
        for app in ("flywheel", "sentinel"):
            desired = read_tag(env, app)
            if not desired:
                continue
            name = f"{app}-{env}"
            if args.dry_run or not argo.configured:
                print(f"  {name:<22} git={desired}")
                continue
            state = argo.application(name)
            running = (
                ", ".join(
                    image.rsplit(":", 1)[-1] for image in state.images if ":" in image
                )
                or "unknown"
            )
            match = desired in running
            if not match:
                drift += 1
            print(
                f"  {name:<22} git={desired:<18} cluster={running:<24} "
                f"{colour('match', GREEN) if match else colour('drift', YELLOW)}"
            )
    return 1 if drift and args.fail_on_drift else 0


# --------------------------------------------------------------------------- #
# argument parsing
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="keel", description=__doc__.splitlines()[0])
    parser.add_argument("--server", help="Argo CD host (default: $ARGOCD_SERVER)")
    parser.add_argument("--token", help="Argo CD API token (default: $ARGOCD_TOKEN)")
    parser.add_argument(
        "--dry-run", action="store_true", help="never contact the cluster"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    promote = sub.add_parser(
        "promote", help="write a new image tag and wait for convergence"
    )
    promote.add_argument("--app", required=True)
    promote.add_argument("--env", required=True)
    promote.add_argument("--tag", required=True)
    promote.add_argument("--message", help="commit message override")
    promote.add_argument("--commit", action="store_true", default=True)
    promote.add_argument("--no-commit", dest="commit", action="store_false")
    promote.add_argument("--push", action="store_true", help="push after committing")
    promote.add_argument(
        "--sync",
        action="store_true",
        help="trigger a sync instead of waiting for auto-sync",
    )
    promote.add_argument("--prune", action="store_true")
    promote.add_argument(
        "--force", action="store_true", help="proceed even if the tag is unchanged"
    )
    promote.add_argument("--timeout", type=float, default=600.0)
    promote.set_defaults(func=cmd_promote)

    status = sub.add_parser("status", help="sync and health of every application")
    status.add_argument(
        "--selector", help="label selector, e.g. keel.somokolonlabs.com/env=prod"
    )
    status.add_argument("--verbose", "-v", action="store_true")
    status.add_argument("--fail-on-degraded", action="store_true")
    status.set_defaults(func=cmd_status)

    wait = sub.add_parser(
        "wait", help="block until an application is Synced and Healthy"
    )
    wait.add_argument("--app")
    wait.add_argument("--env")
    wait.add_argument("--name", help="explicit Argo application name")
    wait.add_argument("--timeout", type=float, default=600.0)
    wait.set_defaults(func=cmd_wait)

    rollback = sub.add_parser("rollback", help="revert to a previous Argo revision")
    rollback.add_argument("--app", required=True)
    rollback.add_argument("--env", required=True)
    rollback.add_argument("--name")
    rollback.add_argument("--to", help="revision id (default: the one before current)")
    rollback.add_argument("--timeout", type=float, default=600.0)
    rollback.set_defaults(func=cmd_rollback)

    timings = sub.add_parser(
        "timings", help="deploy and rollback durations from the ledger"
    )
    timings.add_argument("--verbose", "-v", action="store_true")
    timings.add_argument("--limit", type=int, default=15)
    timings.set_defaults(func=cmd_timings)

    diff = sub.add_parser(
        "diff", help="compare desired tags in Git with running images"
    )
    diff.add_argument("--fail-on-drift", action="store_true")
    diff.set_defaults(func=cmd_diff)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
