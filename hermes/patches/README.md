# Hermes carried patches

`0.23.2-respawn-guard-unblock.patch` applies to stable Hermes v0.23.2
(`ae2a81ccc00e9b7c06301523e5bb09608397149c`). It ports the existing Forge fix:
an explicit `unblocked` or `promoted_manual` event strictly after the newest PR
comment permits a retry. Automatic promotion/reclaim and same-second ties remain
guarded. Upstream v0.23.2 still fails that continuation contract without the patch.

Keep this copy outside the Hermes checkout: older `hermes update` implementations
discard locally committed divergence, and the local version banner is insufficient
evidence that the fix survived.

With the gateway stopped and the release checked out, apply and test before restart:

```bash
git -C "$HOME/.hermes/hermes-agent" apply --check \
  "$HOME/.forge/repo/hermes/patches/0.23.2-respawn-guard-unblock.patch"
git -C "$HOME/.hermes/hermes-agent" apply \
  "$HOME/.forge/repo/hermes/patches/0.23.2-respawn-guard-unblock.patch"
PY="$(python3 "$HOME/.forge/repo/scripts/hermes-python.py")"
"$PY" "$HOME/.forge/repo/scripts/respawn-guard-probe.py"
```

A future release may contain the fix already. Run the behavioral probe against
it first; do not blindly apply an old patch or interpret an import failure as a
failed contract. PM releases own their dependencies; use `hermes pm install` or
`hermes pm repair`, rather than pip against the legacy `venv/`.

Before cutover, retain the old source revision, carried diff, configuration,
credentials, board/session databases including WAL sidecars, cron definitions,
launchers and service definitions in a private backup. Stop every process using
those stores before taking the final backup. Preserve the old environment until
the upgraded gateway, scheduler, full Forge suite and preflight have passed.
