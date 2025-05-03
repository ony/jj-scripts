#!/usr/bin/env bash
msg() {
  echo "$@" >&2
}

set -exo pipefail

readonly hook_path="$(dirname "$(realpath "$0")")/post-rewrite"

tmpdirs=()

cleanup() {
  local tmpdir
  for tmpdir in "${tmpdirs[@]}"; do
    case "$tmpdir" in
    *.jj-post-rewrite-test.*)
      rm -rf "$tmpdir"
      ;;
    *) msg "Refusing to remove $tmpdir" ;;
    esac
  done
}

trap cleanup EXIT

cd-tmpdir() {
  cd "$(mktemp -d --tmpdir .jj-post-rewrite-test.XXXXXXX)"
  tmpdirs+=("$PWD")
}

run-tests() {
  local test_func
  local passed_tests=() failed_tests=() all_tests=()
  for test_func in $(compgen -A function test-); do
    [[ -z "$FOCUS_TEST" ]] || [[ "$FOCUS_TEST" == "$test_func" ]] || continue
    all_tests+=("$test_func")
    msg ">> $test_func - start"
    if "$test_func"; then
      msg ">> $test_func - success"
      passed_tests+=("$test_func")
    else
      msg ">> $test_func - fail! ($?)"
      failed_tests+=("$test_func")
      [[ "$test_func" == "$DEBUG_TEST" ]] || [[ "$DEBUG_TEST" == "all" ]] && "${SHELL:-bash}"
    fi
  done
  (
    set +x
    echo
    echo "Total ${#passed_tests[@]} out of ${#all_tests[@]} passed."
    [[ "$VERBOSE_TEST" == [1y] ]] && {
      echo "Passed tests are:"
      for test_func in "${passed_tests[@]}"; do
        echo "  - ${test_func}"
      done
    }
    echo "Failed tests are:"
    for test_func in "${failed_tests[@]}"; do
      echo "  - ${test_func}"
    done
  )
}

cd-tmp-git-repo() {
  cd-tmpdir
  git init
  ln -s "$hook_path" .git/hooks/
  jj git init --colocate
}

grep-output() {
  tee >(cat >&2) | grep --quiet "$@"
}

test-git-amend-msg() {
  cd-tmp-git-repo
  jj describe -m 'Hi old'
  echo 'Hi file.' > hi.txt
  jj new
  git commit --amend -m 'Hi new'
  git log
  jj --no-pager log --patch | grep-output ' Hi file.' || return 1
  jj --no-pager log | grep-output 'Hi new' || return 1
  jj --no-pager log | { ! grep-output 'Hi old'; } || return 1
}

test-git-amend-file() {
  cd-tmp-git-repo
  jj describe -m 'Hi'
  echo 'Hi file old.' > hi.txt
  jj new
  echo 'Hi file new.' > hi.txt
  git commit --amend --all --no-edit
  git log
  jj --no-pager log --patch | grep-output 'Hi file new.' || return 1
  jj --no-pager log --patch | { ! grep-output 'Hi file old.'; } || return 1
}

test-git-amend-middle() {
  cd-tmp-git-repo
  jj describe -m 'First'
  echo 'Hi file old.' > hi.txt
  jj new -m 'Second'
  echo 'Hi file new.' > hi.txt
  jj co @-
  echo 'Hi file amended.' > hi.txt
  jj --no-pager log
  git commit --amend --all --no-edit -m 'First amended'
  git log
  jj --no-pager log --patch | grep-output ': Hi file amended.' || return 1
  jj --no-pager log --patch | { ! grep-output ': Hi file old.'; } || return 1
}

test-git-amend-middle_out_of_jj() {
  cd-tmp-git-repo
  jj describe -m 'First'
  echo 'Hi file old.' > hi.txt
  jj new -m 'Second'
  echo 'Hi file new.' > hi.txt
  jj new
  git log --oneline
  git checkout --detach 'HEAD^'
  grep-output 'Hi file old.' < hi.txt || return 1
  echo 'Hi file amended.' > hi.txt
  git commit --amend --all --no-edit -m 'First amended'
  jj --no-pager log --patch | grep-output ': Hi file amended.' || return 1
  jj --no-pager log --patch | { ! grep-output ': Hi file old.'; } || return 1
}

test-git-amend-message-only() {
  cd-tmp-git-repo
  jj describe -m 'Change without amend'
  jj new
  git commit --amend --allow-empty --only --message 'Change amended message only' || return 1
  jj --no-pager log | grep-output 'Change amended message only' || return 1
  jj --no-pager log | { ! grep-output 'Change without amend'; } || return 1
}

test-git-amend-message-only-with-explicit-work-tree() {
  cd-tmp-git-repo
  jj describe -m 'Change without amend'
  jj new
  local work_tree="$PWD"
  cd-tmpdir
  git --git-dir="$work_tree/.git" --work-tree="$work_tree" commit --amend --allow-empty --only --message 'Change amended message only' || return 1
  cd "$work_tree"
  jj --no-pager log | grep-output 'Change amended message only' || return 1
  jj --no-pager log | { ! grep-output 'Change without amend'; } || return 1
}

test-git-rebase-fixup-reword() {
  cd-tmp-git-repo
  jj describe -m 'First'
  echo 'Hi file old.' > hi.txt
  jj new -m 'Second'
  echo 'Hi file middle.' > hi.txt
  jj new -m 'Third'
  echo 'Hi file new.' > hi.txt
  jj new
  GIT_EDITOR="sed -i '2,\$s/^[^#]/Updated &/'" git commit --fixup=reword:'HEAD^'
  git rebase --autosquash 'HEAD^^^'
  git log | grep-output 'Updated Second' || return 1
  git show | grep-output Third || return 1
  # Until we support rebases jj log will show split history
}

run-tests
