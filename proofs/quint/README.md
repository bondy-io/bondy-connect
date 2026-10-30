# Quint models

**THIS WAS BUILT BY CLAUDE OPUS and it is not verified.**

Model-checked specifications of Bondy's replication, compaction, reclamation
and index protocols. Each spec is a purely functional layer of `pure def`s
over typed state records, and a thin state machine with one parameterised
action per process, matching on a sum-typed program counter that carries the
process's data. `MODELS.md` says what each model asks and what it answers;
`../README.md` is the index of record for every result under `proofs/`.

## Layout

| Path | Contents |
|---|---|
| `specs/<Model>.qnt` | the model, parameterised by constants and a `cfg` record of protocol variants |
| `lib/` | definitions two or more specs share |
| `configs/<Model>.configs.qnt` | one module per instance, named `<Model>_<Name>`; each sets the constants and defines `inv`, the invariant it checks |
| `configs/<Model>/<Name>.qnt` | the same, one instance per file, for a model whose instances cannot share one: `quint` sends the transpiler the name, type and effect tables of every module in the file, and Apalache 0.62.1 refuses a request over 20 MB (the `LiveRebootstrapRefold` instances in one file exceed it); `configs/<Model>.configs.qnt` then holds only the shared values |
| `tests/<Model>_test.qnt` | `run` tests that replay counterexamples step by step |
| `MODELS.md` | what each model asks, and what its instances answer |
| `verdicts.json` | the expected result of every instance |
| `symmetric.sh` | checks an instance under TLC `SYMMETRY` |

## Checking

The models are checked with Quint 0.33.0, which fetches Apalache 0.62.1 into
`~/.quint` on first use. Model checking uses TLC through Quint's TLC backend,
which needs Java 17 or later as `java` on `PATH`; under an older Java,
`quint compile` emits an empty module.

TLC keeps its state queue and fingerprints under `TMPDIR`, and the largest
instances need tens of GB there and hours of time (`verdicts.json` gives each
instance's state count). Point `TMPDIR` at a disk with room, watch its free
space, and bound the heap and workers with `--tlc-config`, a JSON file such as
`{"maxHeap": "-Xmx8G", "workers": "1"}`. Run one `quint` process at a time:
`quint` starts a shared Apalache server, and killing one run's process tree
can take it down under another run. The backend generates
its own TLC configuration: it checks neither deadlock nor `SYMMETRY` nor
`CONSTRAINT`. Where deadlock matters, an instance's `inv` includes
`noDeadlock`, which is `enabled(step)`. Fairness is the hypothesis of an
instance's temporal property: `live` is `fairness implies` the property,
checked with `--temporal live`.

```sh
quint verify --backend=tlc --main ReadCache_Ship --invariant inv \
  configs/ReadCache.configs.qnt
quint test --main ReadCache_Head_test tests/ReadCache_test.qnt
```

Every module in `tests/` is named `<Model>_<Name>_test`; to run them all:

```sh
for f in tests/*_test.qnt; do
  for m in $(sed -n 's/^module \(.*_test\) {/\1/p' "$f"); do
    quint test --main "$m" "$f" || echo "FAILED $m"
  done
done
```

A violation is recorded with one TLC worker: with several, the first
counterexample found is not always a shortest one. A violation "in N steps"
is a counterexample of N + 1 states.

### Verdicts

`verdicts.json` maps each instance to its expected result. `verdict` is
`holds`, `violated`, `holds, with live` or `violated, live` (the temporal
property `live`, checked with `--temporal live`), or `no violation, not
exhaustive` when the run stopped at a time or disk cap. The other fields are
what the run reported:

| Field | Meaning |
|---|---|
| `cex_states` | states in the counterexample, with one worker |
| `distinct`, `generated`, `depth` | TLC's distinct and generated state counts and the depth of the complete search |
| `reachable` | distinct states of the whole graph, explored with no invariant |
| `distinct_before_cap`, `queued` | distinct and queued states when a capped run stopped |
| `safety_distinct`, `safety_depth` | the same for `inv` without its convergence conjunct |
| `note` | how the result was obtained, when not by plain `quint verify` |

### Symmetry

When the processes of an instance are interchangeable, `symmetric.sh` checks
it under `SYMMETRY` over them:

```sh
./symmetric.sh configs/JoinInstall/Truncation_CompactMembers_Reap.qnt \
  JoinInstall_Truncation_CompactMembers_Reap r1 r2
```

TLC permutes only model values, and refuses a symmetry over strings. The
script compiles the instance (`quint compile --target tlaplus`), replaces each
named string literal with a model-value constant of the same name, and runs
TLC with `SYMMETRY` over them. It refuses an element that is not a literal of
the compiled module, or that already names something in it. With `NOSYM=1` it
omits `SYMMETRY`, so the rewritten module can be checked against
`quint verify`: on `JoinInstall_Truncation_CompactMembers` both reach
3,999,196 distinct states at depth 29. The reduction is sound only when the
instance treats the elements alike: no constant names one of them, and no
expression's value depends on their order. TLC stops with an error when `<`
compares two model values, but a set `fold` visits them in a fixed order
without one, so a fold over the elements must give the same result in every
order, as the minimum in `JoinInstall`'s `stableVV` does.
