"""Golden reference model for kmeans_core.

Pure Python integers, so there is no overflow anywhere: if the hardware ever
truncates a width, the comparison against this model fails.
"""


def dist2(p, c):
    return (p[0] - c[0]) ** 2 + (p[1] - c[1]) ** 2


def assign(p, cents):
    """Nearest centroid; ties go to the lowest index (same rule as min_tree)."""
    d = [dist2(p, c) for c in cents]
    best = min(d)
    return d.index(best), best


def is_tie(p, cents):
    d = [dist2(p, c) for c in cents]
    return d.count(min(d)) > 1


def run(points, cents):
    """One pass of the core: per-point results plus the accumulator contents."""
    k = len(cents)
    results = []
    sum_x, sum_y, count = [0] * k, [0] * k, [0] * k
    sse = 0
    for p in points:
        idx, d = assign(p, cents)
        results.append((idx, d))
        sum_x[idx] += p[0]
        sum_y[idx] += p[1]
        count[idx] += 1
        sse += d
    return results, sum_x, sum_y, count, sse


def trunc_div(a, b):
    """Integer division rounding toward zero (C semantics, as in firmware)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def update(cents, sum_x, sum_y, count):
    """Centroid-update step. An empty cluster keeps its old centroid."""
    return [
        (trunc_div(sx, n), trunc_div(sy, n)) if n else c
        for c, sx, sy, n in zip(cents, sum_x, sum_y, count)
    ]


def lloyd(points, cents, max_iters=20):
    """Reference K-means: iterate until the centroids stop moving."""
    history = [list(cents)]
    for _ in range(max_iters):
        _, sx, sy, n, _ = run(points, cents)
        new = update(cents, sx, sy, n)
        history.append(new)
        if new == cents:
            break
        cents = new
    return history
