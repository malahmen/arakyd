#!/usr/bin/env python3
"""Refuse a workflow job whose name is not a valid DNS label (Kamino item 286).

The Gitea runner on meksha gives each job's container the job's display name
as a DNS alias, unchanged (gitea/runner act/runner/run_context.go,
NetworkAliases: []string{rc.Name}, as of v6.0.0). podman's DNS server there,
aardvark-dns 1.4.0, dies on an alias that is not a DNS name - a matrix job's
default name such as "test (22.13)" - and every podman container on meksha
loses name resolution until it restarts: the job's own lookups, and Gitea's,
the mail stack's and the databases'.

The display name is the job's `name:`, or its id when it has none; a matrix
job without `name:` gets "<id> (<values>)", which is never safe. Each name
must be a single DNS label: letters, digits and hyphens, at most 63, not
starting or ending with a hyphen. In a `name:`, `${{ matrix.KEY }}` is checked
with every value KEY can take; any other expression cannot be checked here
and is refused.

Usage: check-job-names.py [workflow files...]   (default: .github/workflows/*.y*ml)
"""
import glob
import itertools
import re
import sys

try:
    import yaml
except ImportError:
    sys.exit("check-job-names: needs PyYAML (pip install pyyaml)")

LABEL = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
EXPR = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")
MATRIX_REF = re.compile(r"^matrix\.([A-Za-z_][A-Za-z0-9_-]*)$")


def matrix_values(matrix):
    """Every value each matrix key can take, "" where a combination lacks it.

    GitHub evaluates a key a combination does not have to "". An include
    entry that matches no axis value is a combination of its own, without the
    axes it does not name; a key only some include entries set is missing
    from the other combinations.
    """
    axes = {k: list(v) for k, v in matrix.items() if k not in ("include", "exclude") and isinstance(v, list)}
    values = {k: list(v) for k, v in axes.items()}
    includes = [e for e in (matrix.get("include") or []) if isinstance(e, dict)]
    for e in includes:
        standalone = not axes or any(k in axes and v not in axes[k] for k, v in e.items())
        for k, v in e.items():
            values.setdefault(k, []).append(v)
        if standalone:
            for k in axes:
                if k not in e:
                    values[k].append("")
    extra = {k for e in includes for k in e if k not in axes}
    for k in extra:
        if axes or any(k not in e for e in includes):
            values[k].append("")
    return values


def names_for(job_id, job):
    """The display names this job can have, or a reason it cannot be checked."""
    strategy = job.get("strategy") or {}
    matrix = strategy.get("matrix")
    name = job.get("name")
    if name is None:
        if matrix:
            return None, f'a matrix job without `name:` is shown as "{job_id} (<values>)"'
        return [str(job_id)], None
    name = str(name)
    refs = EXPR.findall(name)
    if not refs:
        return [name], None
    if not isinstance(matrix, dict):
        return None, f"`name: {name}` uses an expression and the job has no literal matrix to check it against"
    values = matrix_values(matrix)
    keys = []
    for ref in refs:
        m = MATRIX_REF.match(ref)
        if not m:
            return None, f"`${{{{ {ref} }}}}` in `name:` cannot be checked here; use a literal or ${{{{ matrix.KEY }}}}"
        if m.group(1) not in values:
            return None, f"`name:` uses matrix.{m.group(1)}, which the matrix does not define"
        keys.append(m.group(1))
    names = []
    for combo in itertools.product(*(values[k] for k in dict.fromkeys(keys))):
        chosen = dict(zip(dict.fromkeys(keys), combo))
        names.append(EXPR.sub(lambda e: str(chosen[MATRIX_REF.match(e.group(1)).group(1)]), name))
    return names, None


def check(path):
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    problems = []
    for job_id, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        names, reason = names_for(job_id, job)
        if reason:
            problems.append(f"{path}: job `{job_id}`: {reason}")
            continue
        for n in names:
            if not LABEL.match(n):
                problems.append(f'{path}: job `{job_id}`: "{n}" is not a DNS label')
    return problems


def main(argv):
    files = argv or sorted(glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml"))
    if not files:
        sys.exit("check-job-names: no workflow files found")
    problems = [p for f in files for p in check(f)]
    for p in problems:
        print(p)
    if problems:
        print("\nGive each job a `name:` that is a DNS label (letters, digits, hyphens), "
              "e.g. `name: test-node-${{ matrix.label }}` with label: \"22-13\" in the matrix. "
              "Why: Kamino item 286.")
        return 1
    print(f"check-job-names: {len(files)} workflow file(s), every job name is a DNS label")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
