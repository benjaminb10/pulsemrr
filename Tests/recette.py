#!/usr/bin/env python3
"""Acceptance run of the dashboard window, after a release: every project of the sidebar, every period of the toolbar.

Drives the running PulseMRR through the macOS accessibility tree with agent-desktop (npm i -g agent-desktop), in the
background: no pointer moves, no focus taken. Each view must show its project's name, finish reading Stripe, have the
four headline figures with digits in them, and no NaN or error text. The project and period picked before are put back.

Run: Tests/recette.sh            (opens the dashboard if no window is open)
     Tests/recette.sh --quick    (the 1 month period only)
"""
import json, re, subprocess, sys, time

HEADLINE = [["MRR réel", "Real MRR"], ["MRR net gagné", "Net new MRR"], ["Clients payants", "Paying customers"],
            ["Revenu par client", "Revenue per customer"]]
LOADING = ("Lecture de Stripe", "Reading Stripe")
BAD = re.compile(r"\bNaN\b|\bnan\b|\binf\b|Erreur|Error|\(null\)|Optional\(", re.I)
PERIOD = re.compile(r"^(1|3|6|12) (mois|months?)$")


def ad(*args):
    out = subprocess.run(["agent-desktop", *args], capture_output=True, text=True).stdout
    d = json.loads(out or "{}")
    if not d.get("ok"):
        raise RuntimeError(f"agent-desktop {' '.join(args)}: {d.get('error', out[:300])}")
    return d["data"]


def click(ref):
    """A click whose effect agent-desktop could not confirm (the row moved, as a quiet project picked leaves its group)
    goes on: the view check that follows says whether it worked."""
    try:
        ad("click", ref)
    except RuntimeError as e:
        if "delivered_unverified" not in str(e):
            raise
    time.sleep(0.5)


def walk(n, out):
    out.append(n)
    for c in n.get("children", []):
        walk(c, out)
    return out


def snapshot():
    return walk(ad("snapshot", "--app", "PulseMRR", "--compact")["tree"], [])


def texts(nodes):
    return [n["name"] for n in nodes if n.get("role") == "statictext" and n.get("name")
            and "offscreen" not in n.get("states", [])]


def wait_loaded(timeout=180):
    end = time.time() + timeout
    while True:
        nodes = snapshot()
        if not any(t.startswith(LOADING) for t in texts(nodes)):
            return nodes
        if time.time() > end:
            raise RuntimeError("still reading Stripe after %d s" % timeout)
        time.sleep(2)


def sidebar(nodes):
    """Project rows of the sidebar, in order: (label, name shown in the header, node)."""
    rows = []
    for n in nodes:
        if n.get("role") != "treeitem" or not n.get("name"):
            continue
        label = n["name"]
        # "Viewlify 142 €" → "Viewlify"; "📱 Cadencer –" → "Cadencer"
        name = re.sub(r"\s+(–|[\d\s,. \xa0]+\s?k?\s?[€$£¥]|[€$£¥]\s?[\d,.]+k?)$", "", label)
        name = re.sub(r"^📱\s*", "", name).strip()
        rows.append((label, name, n))
    return rows


def check_view(nodes, expected):
    t = texts(nodes)
    problems = []
    if expected not in t:
        problems.append(f"header is not {expected!r}")
    bad = [x for x in t if BAD.search(x)]
    if bad:
        problems.append(f"bad text: {bad[:3]}")
    # The four headline labels follow each other, then their four values
    try:
        i = next(k for k, x in enumerate(t) if x in HEADLINE[0])
        labels, values = t[i:i + 4], t[i + 4:i + 8]
        if [any(l == x for x in names) for l, names in zip(labels, HEADLINE)] != [True] * 4:
            problems.append(f"headline labels {labels}")
        elif not all(re.search(r"\d", v) for v in values):
            problems.append(f"headline values {values}")
    except StopIteration:
        problems.append("no headline cards")
        values = []
    return problems, values


def main():
    quick = "--quick" in sys.argv
    try:
        ad("list-windows", "--app", "PulseMRR")
        nodes = snapshot()
    except Exception:
        nodes = []
    if not any(n.get("role") == "outline" for n in nodes):
        subprocess.run(["open", "-a", "PulseMRR", "--args", "--dashboard"])
        time.sleep(6)
    nodes = wait_loaded()

    # Quiet projects folded away: unfold them for the run
    for n in nodes:
        if n.get("role") == "disclosure" and n.get("value") == "0":
            click(n["ref_id"])
            nodes = wait_loaded()

    rows = sidebar(nodes)
    periods = [n for n in nodes if n.get("role") == "radiobutton" and PERIOD.match(n.get("name", ""))]
    period_names = [n["name"] for n in periods]
    if quick:
        period_names = period_names[:1]
    first_project = next((label for label, _, n in rows if "selected" in n.get("states", [])), rows[0][0])
    first_period = next((n["name"] for n in periods if "checked" in n.get("states", [])), None)
    if not rows or not period_names:
        print("FAIL: sidebar or period picker not found"); return 1

    failures, done = [], 0
    print(f"{len(rows)} projects × {len(period_names)} periods\n")
    for label, name, _ in rows:
        row = next(n for l, _, n in sidebar(snapshot()) if l == label)
        click(row["ref_id"])
        for p in period_names:
            radio = next(n for n in snapshot() if n.get("role") == "radiobutton" and n.get("name") == p)
            if "checked" not in radio.get("states", []):
                click(radio["ref_id"])
            nodes = wait_loaded()
            radio = next(n for n in nodes if n.get("role") == "radiobutton" and n.get("name") == p)
            problems, values = check_view(nodes, name)
            if "checked" not in radio.get("states", []):
                problems.append(f"period {p} not picked")
            done += 1
            status = "ok  " if not problems else "FAIL"
            print(f"{status} {name:<24} {p:<9} {' · '.join(values)}" + ("" if not problems else "  ← " + "; ".join(problems)))
            if problems:
                failures.append((name, p, problems))

    # Back to what was picked before the run
    try:
        row = next(n for l, _, n in sidebar(snapshot()) if l == first_project)
        click(row["ref_id"])
        if first_period:
            radio = next(n for n in snapshot() if n.get("role") == "radiobutton" and n.get("name") == first_period)
            click(radio["ref_id"])
    except (StopIteration, RuntimeError):
        pass

    print(f"\n{done - len(failures)}/{done} views ok")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
