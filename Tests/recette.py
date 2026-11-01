#!/usr/bin/env python3
"""Acceptance run of the dashboard window, after a release: every project of the sidebar, every period of the toolbar.

Drives the running PulseMRR through the macOS accessibility tree with agent-desktop (npm i -g agent-desktop), in the
background: no pointer moves, no focus taken. Each view must show its project's name, finish reading Stripe, show its MRR,
have the 30-day bridge end on that same MRR, and no NaN or error text. The project and period picked before are put back.

Run: Tests/recette.sh            (opens the dashboard if no window is open)
     Tests/recette.sh --quick    (the 1 month period only)
"""
import json, re, subprocess, sys, time

MRR = ("MRR",)
BRIDGE_START = ("Il y a 30 jours", "30 days ago")
BRIDGE_END = ("Aujourd'hui", "Today")
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
    # The MRR at the top, and the bridge under it ending on that same MRR
    values = []
    try:
        # After the header ("Updated …"), so the sidebar's own "MRR" column title is skipped
        h = next(k for k, x in enumerate(t) if x.startswith(("Mis à jour", "Updated")))
        i = next(k for k in range(h, len(t)) if t[k] in MRR)
        # The accessibility tree reads row by row: the first amount after the title is the MRR
        hero = next(x for x in t[i + 1:] if re.search(r"\d", x))
        values.append(hero)
        j = next(k for k, x in enumerate(t) if x in BRIDGE_START)
        start = next(x for x in t[j + 1:] if re.search(r"\d", x))
        e = next(k for k in range(j, len(t)) if t[k] in BRIDGE_END)
        end = t[e + 1]
        values += [start, end]
        if end != hero:
            problems.append(f"bridge ends on {end!r}, MRR says {hero!r}")
    except StopIteration:
        problems.append("no MRR or no bridge")
    return problems, values


def has_window():
    try:
        return any(n.get("role") == "outline" for n in snapshot())
    except RuntimeError:
        return False


def wait_window(seconds):
    end = time.time() + seconds
    while time.time() < end:
        if has_window():
            return True
        time.sleep(2)
    return False


def open_dashboard():
    """The dashboard window, opened if needed. Right after an install the first launch can come up without its window
    (macOS still checking the new app): quit it and launch it again once."""
    if has_window():
        return True
    subprocess.run(["open", "-a", "PulseMRR", "--args", "--dashboard"])
    if wait_window(60):
        return True
    subprocess.run(["osascript", "-e", 'tell application id "app.pulsemrr" to quit'])
    time.sleep(3)
    subprocess.run(["open", "-a", "PulseMRR", "--args", "--dashboard"])
    return wait_window(60)


def main():
    quick = "--quick" in sys.argv
    if not open_dashboard():
        print("FAIL: the dashboard window did not open"); return 1
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
    first_project = next((nm for _, nm, n in rows if "selected" in n.get("states", [])), rows[0][1])
    first_period = next((n["name"] for n in periods if "checked" in n.get("states", [])), None)
    if not rows or not period_names:
        print("FAIL: sidebar or period picker not found"); return 1

    failures, done = [], 0
    print(f"{len(rows)} projects × {len(period_names)} periods\n")
    for _, name, _ in rows:
        row = next(n for _, nm, n in sidebar(snapshot()) if nm == name)
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
        row = next(n for _, nm, n in sidebar(snapshot()) if nm == first_project)
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
