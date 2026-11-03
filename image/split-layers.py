"""Split an image closure into stable layers (ADR 0005).

Input: the closure (closureInfo registration), a group spec and optionally the reference image's
store paths. Output: nix2container's layersFile (a list of store-path lists, one per layer) and
a table. Each path goes to the first group (in spec order) whose candidates contain it; layers
are then written in `layerOrder`, stable to volatile. What no group takes is the config group,
always last: it changes on every build, hence the size ceiling.
"""
import argparse
import collections
import hashlib
import json
import sys

MiB = 1 << 20


def read_registration(f):
    """closureInfo's registration: path, hash, size, deriver, n, n references; repeated."""
    lines = f.read().split("\n")
    nodes, i = {}, 0
    while i < len(lines) and lines[i]:
        path, size, n = lines[i], int(lines[i + 2]), int(lines[i + 4])
        nodes[path] = (size, [r for r in lines[i + 5:i + 5 + n] if r != path])
        i += 5 + n
    return nodes


def closure(starts, edges):
    seen, stack = set(starts), list(starts)
    while stack:
        for y in edges[stack.pop()]:
            if y not in seen:
                seen.add(y)
                stack.append(y)
    return seen


def name(path):
    return path.split("/")[-1].split("-", 1)[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("registration")
    ap.add_argument("spec")
    ap.add_argument("outdir")
    ap.add_argument("--reference", help="store paths of the reference image; default: this closure")
    args = ap.parse_args()

    with open(args.registration) as f:
        nodes = read_registration(f)
    with open(args.spec) as f:
        spec = json.load(f)
    fwd = {p: refs for p, (_, refs) in nodes.items()}
    rev = collections.defaultdict(list)
    for p, refs in fwd.items():
        for r in refs:
            rev[r].append(p)
    size = {p: s for p, (s, _) in nodes.items()}
    if args.reference:
        with open(args.reference) as f:
            ref = set(f.read().split())
    else:
        ref = set(nodes)
    ref_names = {name(p) for p in ref}

    by_name = collections.defaultdict(list)
    for p in nodes:
        by_name[name(p)].append(p)

    def resolve(a):
        """A store path, or "name:<n>" for the closure's paths named n (a path the KWin graft rewrote
        has another hash than the system's attribute)."""
        return by_name.get(a[5:], []) if a.startswith("name:") else [a] if a in nodes else []

    errors, notes = [], []
    assigned = {}
    for g in spec["groups"]:
        present = lambda ps: [x for a in ps for x in resolve(a)]
        for key in ("anchors", "refsOf", "dependentsOf"):
            missing = [a for a in g.get(key, []) if not resolve(a)]
            if missing:
                notes.append(f"{g['name']}: {key} not in the closure: "
                             + ", ".join(a[5:] if a.startswith("name:") else name(a) for a in missing))
        cand = closure(present(g.get("anchors", [])), fwd)
        if g.get("refsOf"):
            cand |= closure([r for p in present(g["refsOf"]) for r in fwd[p]], fwd)
        if g.get("dependentsOf"):
            cand &= closure(present(g["dependentsOf"]), rev)
        if g.get("sameAsReference"):
            # Same name as a reference path but a different hash: the consumer rebuilt it.
            differ = sorted(name(p) for p in cand if p not in ref and name(p) in ref_names)
            if differ:
                errors.append(f"{g['name']}: differs from the reference image: {', '.join(differ)}")
        scope = g.get("scope", "reference")
        for p in cand:
            if p not in assigned and (p in ref) == (scope == "reference"):
                assigned[p] = g["name"]
    for p in nodes:
        assigned.setdefault(p, "config")

    members = collections.defaultdict(list)
    for p, g in assigned.items():
        members[g].append(p)
    buckets = {g["name"]: g.get("buckets", 1) for g in spec["groups"]}
    order = spec["layerOrder"] + ["config"]
    unknown = set(buckets) - set(order)
    if unknown:
        errors.append(f"groups missing from layerOrder: {', '.join(sorted(unknown))}")

    layers, table = [], []
    for g in order:
        n = buckets.get(g, 1)
        # By a hash of the path, so a path joining or leaving moves only its own chunk.
        chunks = collections.defaultdict(list)
        for p in members.get(g, []):
            chunks[int(hashlib.sha256(p.encode()).hexdigest()[:8], 16) % n].append(p)
        for k in sorted(chunks):
            ps = sorted(chunks[k])
            layers.append(ps)
            table.append((g if n == 1 else f"{g}/{k + 1}", len(ps), sum(size[p] for p in ps)))

    config_mib = sum(size[p] for p in members.get("config", [])) / MiB
    if config_mib > spec["maxConfigMiB"]:
        biggest = sorted(members["config"], key=lambda p: -size[p])[:10]
        errors.append(f"config group is {config_mib:.0f} MiB (limit {spec['maxConfigMiB']}); give these a group: "
                      + ", ".join(f"{name(p)} ({size[p] / MiB:.0f})" for p in biggest))
    foreign = sorted(name(p) for p in nodes if p not in ref and name(p) in ref_names)

    with open(f"{args.outdir}/layers.json", "w") as f:
        json.dump(layers, f)
    with open(f"{args.outdir}/groups.json", "w") as f:
        json.dump([t[0] for t in table], f)
    out = [f"{'layer':<14} {'paths':>6} {'NAR MiB':>8}"]
    out += [f"{g:<14} {n:>6} {s / MiB:>8.0f}" for g, n, s in table]
    out.append(f"{'total':<14} {len(nodes):>6} {sum(size.values()) / MiB:>8.0f}")
    out += [f"note: {m}" for m in notes]
    if foreign:
        out.append(f"note: {len(foreign)} paths differ from the reference image by hash only: {', '.join(foreign[:20])}")
    with open(f"{args.outdir}/table.txt", "w") as f:
        f.write("\n".join(out) + "\n")
    print("\n".join(out))
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
