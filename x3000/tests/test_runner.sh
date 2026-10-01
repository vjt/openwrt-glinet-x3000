# x3000/tests/run.sh itself: discovery must fail closed.

# run.sh resolves X3000_REAL_ROOT from its own location, so the runner
# under test gets a private copy of the tree skeleton it needs.
runner_sandbox() {
    mkdir -p "$TEST_TMP/rt/x3000/lib" "$TEST_TMP/rt/x3000/tests"
    cp "$X3000_REAL_ROOT/x3000/lib/feed.sh" "$TEST_TMP/rt/x3000/lib/"
    cp "$X3000_REAL_ROOT/x3000/tests/run.sh" "$TEST_TMP/rt/x3000/tests/"
    cp -r "$X3000_REAL_ROOT/x3000/tests/lib" "$TEST_TMP/rt/x3000/tests/"
    RT="$TEST_TMP/rt/x3000/tests"
}

test_runner_fails_on_unloadable_test_file() {
    runner_sandbox
    printf 'test_ok() { :; }\nthis is ( broken\n' > "$RT/test_broken.sh"
    local rc=0 out
    out="$("$RT/run.sh" 2>&1)" || rc=$?
    assert_eq "$rc" 1
    assert_contains "$out" "FAIL test_broken.sh (cannot load)"
}

test_runner_fails_when_nothing_matches() {
    runner_sandbox
    printf 'test_ok() { :; }\n' > "$RT/test_a.sh"
    local rc=0 out
    out="$("$RT/run.sh" 'nope_*.sh' 2>&1)" || rc=$?
    assert_eq "$rc" 1
    assert_contains "$out" "no tests matched"
    rc=0
    out="$("$RT/run.sh" test_a.sh nomatch 2>&1)" || rc=$?
    assert_eq "$rc" 1
    assert_contains "$out" "no tests matched"
}

test_runner_passes_a_good_file() {
    runner_sandbox
    printf 'test_ok() { :; }\n' > "$RT/test_a.sh"
    local out
    out="$("$RT/run.sh" 2>&1)"
    assert_contains "$out" "1 passed, 0 failed"
}
