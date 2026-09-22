#!/usr/bin/env bats

setup() {
  repo=$(mktemp -d)
  script="$BATS_TEST_DIRNAME/../../scripts/next-version.sh"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name tester
}

teardown() {
  rm -rf "$repo"
}

commit() {
  printf '%s\n' "$1" >"$repo/message"
  git -C "$repo" add message
  if [[ -n "${2:-}" ]]; then
    git -C "$repo" commit -q -m "$1" -m "$2"
  else
    git -C "$repo" commit -q -m "$1"
  fi
}

run_version() {
  run bash -c 'cd "$1" || exit; script="$2"; shift 2; "$script" "$@"' _ "$repo" "$script" "$@"
}

@test "first release is patch rc 1" {
  commit "chore: bootstrap"

  run_version --rc

  [ "$status" -eq 0 ]
  [ "$output" = "1.0.1-rc.1" ]
}

@test "feat bumps minor" {
  commit "feat: add dashboard"

  run_version --rc

  [ "$status" -eq 0 ]
  [ "$output" = "1.1.0-rc.1" ]
}

@test "fix bumps patch from stable base" {
  commit "chore: initial"
  git -C "$repo" tag v1.2.3
  commit "fix: handle empty input"

  run_version

  [ "$status" -eq 0 ]
  [ "$output" = "1.2.4" ]
}

@test "feat bang bumps major" {
  commit "chore: initial"
  git -C "$repo" tag v1.2.3
  commit "feat!: replace API"

  run_version --rc

  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0-rc.1" ]
}

@test "breaking change footer bumps major" {
  commit "chore: initial"
  git -C "$repo" tag v1.2.3
  commit "feat: replace API" "BREAKING CHANGE: the API changed"

  run_version --rc

  [ "$status" -eq 0 ]
  [ "$output" = "2.0.0-rc.1" ]
}

@test "no commits after stable tag returns no release" {
  commit "chore: initial"
  git -C "$repo" tag v1.2.3

  run_version --rc

  [ "$status" -eq 0 ]
  [ "$output" = "no release" ]
}

@test "existing rc tags increment the candidate number" {
  commit "chore: initial"
  git -C "$repo" tag v1.2.3
  commit "feat: add dashboard"
  git -C "$repo" tag v1.3.0-rc.1
  git -C "$repo" tag v1.3.0-rc.2

  run_version --rc

  [ "$status" -eq 0 ]
  [ "$output" = "1.3.0-rc.3" ]
}

@test "rc tags are ignored as the stable base" {
  commit "chore: initial"
  git -C "$repo" tag v1.2.3
  commit "feat: add dashboard"
  git -C "$repo" tag v1.3.0-rc.1
  commit "fix: polish dashboard"

  run_version --rc

  [ "$status" -eq 0 ]
  [ "$output" = "1.3.0-rc.2" ]
}

@test "older feat is not ignored when a newer fix exists" {
  commit "chore: initial"
  git -C "$repo" tag v1.2.3
  commit "feat: add dashboard"
  commit "fix: polish dashboard"

  run_version --rc

  [ "$status" -eq 0 ]
  [ "$output" = "1.3.0-rc.1" ]
}

@test "stable mode strips an rc tag" {
  run_version --stable v1.3.0-rc.4

  [ "$status" -eq 0 ]
  [ "$output" = "1.3.0" ]
}

@test "commit body text is not classified as a subject" {
  commit "chore: documentation" "feat: illustrative text"

  run_version --rc

  [ "$status" -eq 0 ]
  [ "$output" = "1.0.1-rc.1" ]
}

@test "empty repository returns only no release" {
  run_version --rc

  [ "$status" -eq 0 ]
  [ "$output" = "no release" ]
  [ -z "$stderr" ]
}

@test "unexpected arguments are rejected" {
  run_version --rc unexpected

  [ "$status" -eq 2 ]
}
