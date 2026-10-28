#!/usr/bin/env python3
"""Per-node mean of each pipeline stage between two snapshot-stages.sh TSVs.

  python3 harness/fleet-scale/stage-means.py <first.tsv> <second.tsv>
"""
import re, sys
def load(f):
    d = {}
    for l in open(f):
        parts = l.rstrip('\n').split('\t')
        if len(parts) < 3 or parts[2] == 'UNREACHABLE':
            print('!! unreachable/short row:', l.strip()); continue
        _, m, t = parts
        nums = [int(x) for x in re.findall(r'-?\d+', t)]
        d[m] = [nums[i*5:i*5+5] for i in range(7)] + [nums[35]]
    return d
a = load(sys.argv[1]); b = load(sys.argv[2])
names = ['match_us','fanout_us','flow.queue_us','flow.service_us','flow.depth','egress.depth','egress.service_us']
print('node            ' + ' '.join(f'{n:>17}' for n in names) + '  shed  window_count(match)')
for m in sorted(b):
    if m not in a: print(m, 'missing in first snapshot'); continue
    row = []
    for i in range(7):
        dc = b[m][i][0] - a[m][i][0]; ds = b[m][i][1] - a[m][i][1]
        row.append(f'{(ds/dc if dc else 0):17.3f}')
    print(m, ' '.join(row), f'{b[m][7]-a[m][7]:5d}', b[m][0][0]-a[m][0][0])