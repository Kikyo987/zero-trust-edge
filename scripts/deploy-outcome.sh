#!/usr/bin/env bash
# Classify a deploy workflow run.
#
#   deploy-outcome.sh <preflight> <build> <deploy> <can_deploy>
#
# Prints one word: SUCCESS, SKIPPED, or FAILURE, then a reason.
# Exit 0 for SUCCESS and SKIPPED. Exit 1 for FAILURE.
#
#   deploy-outcome.sh --self-test
set -euo pipefail

classify() {
  local preflight="$1" build="$2" deploy="$3" can="$4"
  if [[ "${preflight}" != "success" ]]; then
    printf 'FAILURE\npreflight result=%s\n' "${preflight}"
    return 1
  fi
  if [[ "${build}" == "failure" || "${build}" == "cancelled" ]]; then
    printf 'FAILURE\nimage build or push result=%s; deploy did not run\n' "${build}"
    return 1
  fi
  if [[ "${can}" != "true" ]]; then
    printf 'SKIPPED\nremote deploy skipped (Tailscale secrets or NODE_TAILSCALE_IP unset)\n'
    return 0
  fi
  if [[ "${deploy}" == "success" ]]; then
    printf 'SUCCESS\nrollout finished; digest and probes ran in the deploy job\n'
    return 0
  fi
  if [[ "${deploy}" == "skipped" ]]; then
    printf 'SKIPPED\ndeploy job skipped\n'
    return 0
  fi
  printf 'FAILURE\ndeploy result=%s\n' "${deploy}"
  return 1
}

self_test() {
  local fail=0
  expect() {
    local want="$1" rc_want="$2"
    shift 2
    local out rc
    set +e
    out="$(classify "$@")"
    rc=$?
    set -e
    local got
    got="$(printf '%s\n' "${out}" | head -1)"
    if [[ "${got}" != "${want}" || "${rc}" -ne "${rc_want}" ]]; then
      printf 'self-test FAIL want %s rc=%s got %s rc=%s args=%s\n' \
        "${want}" "${rc_want}" "${got}" "${rc}" "$*" >&2
      fail=1
    fi
  }
  expect SUCCESS 0 success success success true
  expect SUCCESS 0 success skipped success true
  expect SKIPPED 0 success success skipped false
  expect SKIPPED 0 success skipped skipped false
  expect FAILURE 1 success failure skipped true
  expect FAILURE 1 success failure skipped false
  expect FAILURE 1 success success failure true
  expect FAILURE 1 failure skipped skipped false
  expect FAILURE 1 success cancelled skipped true
  if [[ "${fail}" -ne 0 ]]; then
    echo "deploy-outcome self-test FAILED" >&2
    return 1
  fi
  echo "deploy-outcome self-test PASS"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

if [[ "$#" -ne 4 ]]; then
  echo "usage: deploy-outcome.sh <preflight> <build> <deploy> <can_deploy>" >&2
  exit 2
fi

classify "$1" "$2" "$3" "$4"
