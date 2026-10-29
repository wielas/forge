# shellcheck shell=bash
# =============================================================================
# claude-token — a `claude` that carries its own credential. SOURCED, never executed.
#
# THE DEFECT (rehearsal 5 of run A, 2026-10-29, docs/run-a.md amendment 5). The verifier's
# judge call `claude -p` came back `is_error: true, "Failed to authenticate: OAuth session
# expired and could not be refreshed"`: with CLAUDE_CODE_OAUTH_TOKEN absent from its
# environment the CLI falls back to the login keychain, and that login had expired.
#
# WHY IT WAS ABSENT. When the Hermes dispatcher spawns a ROUTED worker it calls
# `strip_launch_profile_env(env, profile_home)` (tools/environments/local.py), which deletes
# every name the LAUNCH `~/.hermes/.env` defines unless the name is on the global allow-lists
# in agent/secret_scope.py — and CLAUDE_CODE_OAUTH_TOKEN is not on them. The worker then
# reloads only ITS profile's `.env`, which carries no token line (and must not: that was the
# 2026-10-26 dead-copy trap). So the root `.env` is where the one live token is, and a routed
# worker is exactly the process that cannot inherit it. Measured with Hermes' own code for
# forge-verifier, forge-prejudge and forge-codex-lane: token present before the strip, absent
# after. `make preflight` section 12 runs that same code on every run now.
#
# THE REPAIR is Forge's, not Hermes': a script that is about to call `claude` reads the token
# itself when the environment lacks one. This file defines a shell function named `claude`, so
# a caller's `claude -p ...` line needs no edit — which matters, because the one call site
# that exists, in scripts/prejudge-review.sh, is the S5 control arm and is pinned byte for byte
# (verify: prejudge/scorer-is-the-control-arm).
#
# RULES, each one executed by verify (verifier/claude-token-*):
#   * An environment token that is set and non-empty WINS. The file is read only when it is not.
#   * The file is NEVER sourced. One line is parsed with bash builtins: an optional `export `,
#     the name, `=`, then a double-quoted, single-quoted or bare value — the forms Hermes' own
#     tokenizer (agent/secret_scope.py: load_env_file) accepts. The LAST such line wins.
#   * The token goes to the `claude` child only: it is exported inside a subshell that then
#     `exec`s the real binary. The caller's environment is not touched, no other child of
#     the caller sees it, and it never appears in argv (where `ps` would show it).
#   * Nothing here can print it. xtrace is switched off before the token is read, in the subshell
#     that reads it and again in the one that carries it, and no code path echoes a value.
#   * A missing or unreadable file, or no such line, is not an error: no token is set and the
#     real `claude` runs exactly as it would have, to fail or succeed on its own login.
#
# WHERE THE ROOT `.env` IS. A routed worker's HERMES_HOME is its PROFILE home
# (`<root>/profiles/<name>`), whose `.env` is the file with no token in it. Reading
# `$HERMES_HOME/.env` would silently do nothing in production, so a HERMES_HOME that sits
# directly under a `profiles` directory resolves to that directory's parent — the same rule as
# hermes_constants.get_default_hermes_root. Any other HERMES_HOME is itself the root, and an
# unset one is `$HOME/.hermes`. There is deliberately no second fallback: an isolated
# HERMES_HOME in a test must not reach a real token in the operator's real home.
# =============================================================================

# The path of the root .env, derived from HERMES_HOME / HOME. Prints a path; reads nothing.
forge_claude_root_env() {
  local h="${HERMES_HOME:-}" parent
  if [ -z "$h" ]; then
    printf '%s' "${HOME:-}/.hermes/.env"
    return 0
  fi
  while [ "${#h}" -gt 1 ] && [ "${h%/}" != "$h" ]; do h="${h%/}"; done
  parent="${h%/*}"
  case "$parent" in
    */profiles) h="${parent%/profiles}";;
  esac
  printf '%s' "$h/.env"
}

# Prints the value of the LAST CLAUDE_CODE_OAUTH_TOKEN line of the file named by $1, or nothing.
# Runs in a subshell with xtrace off; the value reaches only stdout (a command substitution).
forge_claude_token_read() {
  (
    set +x
    f="${1:-}"
    [ -n "$f" ] && [ -r "$f" ] || exit 0
    last=""
    first=1
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      if [ "$first" = 1 ]; then line="${line#$'\xef\xbb\xbf'}"; first=0; fi
      line="${line#"${line%%[![:space:]]*}"}"
      case "$line" in
        export[[:space:]]*) line="${line#export}"; line="${line#"${line%%[![:space:]]*}"}";;
      esac
      case "$line" in
        CLAUDE_CODE_OAUTH_TOKEN*) rest="${line#CLAUDE_CODE_OAUTH_TOKEN}";;
        *) continue;;
      esac
      rest="${rest#"${rest%%[![:space:]]*}"}"
      case "$rest" in
        =*) rest="${rest#=}";;
        *) continue;;
      esac
      rest="${rest#"${rest%%[![:space:]]*}"}"
      case "$rest" in
        \"*) rest="${rest#\"}"; val="${rest%%\"*}";;
        \'*) rest="${rest#\'}"; val="${rest%%\'*}";;
        *)   val="${rest%%[[:space:]]#*}"
             val="${val%"${val##*[![:space:]]}"}";;
      esac
      last="$val"
    done < "$f"
    printf '%s' "$last"
  )
}

# `claude`, with the token supplied when the environment has none. Arguments and stdin pass
# through untouched; the exit status is the CLI's own.
claude() {
  (
    set +x
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      forge_claude_t="$(forge_claude_token_read "$(forge_claude_root_env)")"
      if [ -n "$forge_claude_t" ]; then
        CLAUDE_CODE_OAUTH_TOKEN="$forge_claude_t"
        export CLAUDE_CODE_OAUTH_TOKEN
      fi
      unset forge_claude_t
    fi
    exec claude "$@"
  )
}
