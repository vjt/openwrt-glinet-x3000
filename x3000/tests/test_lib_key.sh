# feed_check_key: the key every shipped image trusts must be there, and
# the public half must derive from it.

test_key_ok_when_public_derives_from_private() {
    fx_key "$TEST_TMP/k"
    assert_ok "feed_check_key '$TEST_TMP/k'"
}

test_key_missing_private_says_how_to_restore() {
    fx_key "$TEST_TMP/k"
    rm "$TEST_TMP/k/private-key.pem"
    assert_fails "feed_check_key '$TEST_TMP/k'" "private-key.pem is missing"
    assert_contains "$RUN_OUT" "gh repo clone vjt/x3000-feed-key"
}

test_key_missing_public() {
    fx_key "$TEST_TMP/k"
    rm "$TEST_TMP/k/public-key.pem"
    assert_fails "feed_check_key '$TEST_TMP/k'" "public-key.pem is missing"
}

test_key_rejects_public_half_of_another_key() {
    fx_key "$TEST_TMP/k"
    fx_key "$TEST_TMP/other"
    cp "$TEST_TMP/other/public-key.pem" "$TEST_TMP/k/public-key.pem"
    assert_fails "feed_check_key '$TEST_TMP/k'" "does not derive"
}

test_key_rejects_garbage_private_key() {
    fx_key "$TEST_TMP/k"
    echo junk > "$TEST_TMP/k/private-key.pem"
    assert_fails "feed_check_key '$TEST_TMP/k'" "not a readable EC private key"
}
