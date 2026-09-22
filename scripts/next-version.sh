#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf 'Usage: %s [--rc | --stable vX.Y.Z-rc.N]\n' "$0" >&2
}

mode=stable
stable_tag=
case "${1:-}" in
  '') ;;
  --rc)
    mode=rc
    ;;
  --stable)
    mode=stable-tag
    stable_tag=${2:-}
    if [[ ! "$stable_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]]; then
      usage
      exit 2
    fi
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ "$mode" == stable-tag ]]; then
  printf '%s\n' "${stable_tag#v}" | sed 's/-rc\.[0-9]*$//'
  exit 0
fi

stable_tags=$(git tag --list | while IFS= read -r tag; do
  if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$tag"
  fi
  true
done | sort -V)
base_tag=$(printf '%s\n' "$stable_tags" | tail -n 1)

base_version=0.0.0
range=HEAD
if [[ -n "$base_tag" ]]; then
  base_version=${base_tag#v}
  range="$base_tag..HEAD"
fi

major=0
minor=0
patch=0
feat_subject_re='^feat(\(|:|$)'
while IFS= read -r message; do
  [[ -z "$message" ]] && continue
  subject=${message%%$'\n'*}
  if [[ "$subject" =~ ^[^:]*!:.+$ || "$message" == *"BREAKING CHANGE"* ]]; then
    major=1
  elif [[ "$subject" =~ $feat_subject_re ]]; then
    minor=1
  else
    patch=1
  fi
done < <(git log "$range" --format=%B)

if (( !major && !minor && !patch )); then
  printf '%s\n' 'no release'
  exit 0
fi

IFS=. read -r major_version minor_version patch_version <<<"$base_version"
if (( major )); then
  ((major_version += 1))
  minor_version=0
  patch_version=0
elif (( minor )); then
  ((minor_version += 1))
  patch_version=0
else
  ((patch_version += 1))
fi

version="$major_version.$minor_version.$patch_version"
if [[ "$mode" == rc ]]; then
  rc_tag_re="^v${version//./\\.}-rc\\.[0-9]+$"
  rc_count=0
  while IFS= read -r tag; do
    if [[ "$tag" =~ $rc_tag_re ]]; then
      ((rc_count += 1))
    fi
  done < <(git tag --list) || :
  printf '%s\n' "$version-rc.$((rc_count + 1))"
else
  printf '%s\n' "$version"
fi
