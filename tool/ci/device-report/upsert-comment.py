#!/usr/bin/env python3
"""Posts or updates the device report comment on a pull request.

A complete report replaces the existing comment (or is posted as a new one)
and is marked complete. An incomplete report never replaces a complete one:
that comment keeps its report and gets a warning that the latest run did not
finish. Otherwise (no comment yet, or one that was never complete) the
incomplete report is posted as is.

Usage:
  upsert-comment.py --repo OWNER/NAME --pr N --report report.md \
      --complete true|false --run-url URL
"""

import argparse
import json
import re
import subprocess
import tempfile

MARKER = "<!-- tugboat-device-report -->"
STALE_START = "<!-- tugboat-device-report:stale -->"
STALE_END = "<!-- /tugboat-device-report:stale -->"
COMPLETE = "<!-- tugboat-device-report:complete -->"
BOT = "github-actions[bot]"


def gh(*args, body=None):
    if body is None:
        return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as handle:
        handle.write(body)
    return subprocess.run(
        ["gh", *args, "-F", f"body=@{handle.name}"], check=True, capture_output=True, text=True
    ).stdout


def find_comment(repo, pr):
    out = gh("api", "--paginate", f"repos/{repo}/issues/{pr}/comments", "--jq", ".[]")
    # Not splitlines(): it also splits on U+0085 and similar, which the JSON
    # encoder leaves unescaped inside comment bodies.
    for line in out.split("\n"):
        if not line.strip():
            continue
        comment = json.loads(line)
        if comment["user"]["login"] == BOT and comment["body"].startswith(MARKER):
            return comment
    return None


def marked_complete(report):
    first, _, rest = report.partition("\n")
    return f"{first}\n{COMPLETE}\n{rest}"


def without_stale_note(body):
    return re.sub(re.escape(STALE_START) + r".*?" + re.escape(STALE_END) + r"\n*", "", body, flags=re.S)


def with_stale_note(body, run_url):
    note = (
        f"{STALE_START}\n"
        "> [!WARNING]\n"
        f"> The latest device suite run ([run]({run_url})) did not record a full report. "
        "The report below is from the last run that did; check that run's logs.\n"
        f"{STALE_END}\n\n"
    )
    body = without_stale_note(body)
    first, _, rest = body.partition("\n")
    return f"{first}\n{note}{rest}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--pr", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--complete", required=True)
    parser.add_argument("--run-url", required=True)
    args = parser.parse_args()

    report = open(args.report).read()
    existing = find_comment(args.repo, args.pr)
    complete = args.complete == "true"

    if complete:
        body = marked_complete(report)
    elif existing and COMPLETE in existing["body"]:
        body = with_stale_note(existing["body"], args.run_url)
    else:
        body = report
    if existing:
        print(gh("api", "-X", "PATCH", f"repos/{args.repo}/issues/comments/{existing['id']}",
                 "--jq", ".html_url", body=body).strip())
    else:
        print(gh("api", "-X", "POST", f"repos/{args.repo}/issues/{args.pr}/comments",
                 "--jq", ".html_url", body=body).strip())
    if not complete:
        print("::warning::The device suite did not record a full report; see the job logs.")


if __name__ == "__main__":
    main()
