# Negative control: the review fix turned three vacuous assertions load-bearing

Suite: `tests/fm-procevent-when.test.sh`, case `a group-writable state root is
refused before any files are written`.

The real filenames `arm` writes are confirmed by the CLI transcript
(`cli-arm-nonprivate-state-root.txt`, case 2): `state/when/when-<name>.spec`,
`state/when/when-<name>.trust`, `state/procevent/when-<name>.source` — the
`when-` prefix the review fix added.

## Mutation A — subtract the guard

Deleted `fm_procevent_state_root_resolve ... || die` from `cmd_arm`
(bin/fm-procevent-when.sh:174).

```
armed: when-group-writable-test
starts on the watcher's next cycle; or run: bin/fm-procevent.sh reconcile
not ok - arming against a group-writable state directory must be refused
```

RED. Pins the refusal itself.

## Mutation B — substitute: refuse LATE, after the files are published

Moved the same guard below `fm_procevent_registration_publish_locked`, so `arm`
still exits 1 with the identical message but leaves the spec, the trust record
and the registry entry on disk. This is the exact leak the three `assert_absent`
lines exist to catch, and the only mutation that can distinguish the fixed test
from the pre-fix one.

Target commit `fe7fe9b` (prefixed paths):

```
ok - mutated action bytes are refused before claiming the fire
not ok - no spec file was written
```

RED.

Pre-fix test file (`git show 06c945d:tests/fm-procevent-when.test.sh`, unprefixed
paths), same Mutation B applied to the same source:

```
ok - mutated action bytes are refused before claiming the fire
ok - a group-writable state root is refused before any files are written
all fm-procevent-when tests passed
```

GREEN — and it printed "refused before any files are written" while three files
sat on disk. That is the vacuity the review reported, and the prefix fix closes it.
