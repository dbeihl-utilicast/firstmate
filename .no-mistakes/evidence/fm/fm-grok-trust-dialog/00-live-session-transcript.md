# Grok folder trust — live session transcript

Driven 2026-09-15 against real `grok 1.0.30 (stable)` in a private tmux server (`tmux -L fmgroklive`),
with an isolated Grok home under /tmp. The user's real `~/.grok/trusted_folders.toml` was never written
(mtime unchanged). Grok authenticated through a symlink to its own credential file; no credential was
read, copied, printed, or transmitted, and no keystroke was ever sent to a trust dialog — every session
was killed from outside with `tmux kill-session`.

## 1. Defect reproduces (fresh repo, nothing in the store)

    $ grok            # cwd = /tmp/fm-grok-live/proj, GROK_HOME empty
    Do you trust the contents of this directory?
           /private/tmp/fm-grok-live/proj
    Grok Build may run or modify contents in this directory, posing security risks.
           Yes, proceed        y
           No, quit            n

    (full screen: 01-untrusted-primary-dialog-fires.txt)

## 2. One registration, called with the TASK WORKTREE path (the fleet's dispatch shape)

    $ bin/fm-grok-trust.sh /tmp/fm-grok-live/wt
    trusted: /private/tmp/fm-grok-live/proj

    $ cat $GROK_HOME/trusted_folders.toml
    [folders."/private/tmp/fm-grok-live/proj"]
    trusted = true
    decided_at = 1789496194

## 3. Relaunch in the fresh worktree — no dialog, straight into the session

    $ grok            # cwd = /tmp/fm-grok-live/wt
       task worktree /private/tmp/fm-grok-live/wt (worktree of /private/tmp/fm-grok-live/proj)
       Grok Build 1.0.30 ... New worktree / Resume session / Changelog / Quit

    (full screen: 02-fresh-worktree-after-registration.txt; primary: 03-primary-after-registration.txt)

## 4. Adversarial — an unregistered sibling repository still gates

    dialog fires (04-unregistered-sibling-still-gates.txt)

## 5. Adversarial — an explicit `trusted = false` is never overridden

    $ bin/fm-grok-trust.sh /tmp/fm-grok-live/other
    error: /private/tmp/fm-grok-live/other already has an explicit untrust decision in
      .../trusted_folders.toml; refusing to override it
    error: refusing to pre-register Grok trust: could not record trust for ...
    exit=1
    store byte-identical before/after; relaunch still shows the dialog
    (06-explicit-untrust-still-gates.txt)

## 6. Write scope inside the Grok home — one file, the trust store

    546 files in the Grok home; a registration changed exactly one:

    < 1789496241 143 .../grokhome/trusted_folders.toml
    > 1789496260 227 .../grokhome/trusted_folders.toml

    auth.json unchanged (07-grok-home-write-scope.txt)
