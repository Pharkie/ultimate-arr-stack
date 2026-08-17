#!/usr/bin/env bats
# Unit tests for the jq transforms in terraform/apply.sh, sourced with curl
# stubbed - no BW_SESSION, live NAS, or Terraform binary needed. Sourcing
# this script only defines functions; main() (BW/terraform/live-API calls)
# is guarded to run only when the script is executed directly.

setup() {
    load helpers/setup
    FIXTURES="$REPO_ROOT/tests/fixtures/credential-propagation"
}

# --- sync_indexer_keys: propagates Prowlarr's current key into each
# Sonarr/Radarr Indexer entry. This is the credential direction that broke
# live on 2026-08-17 - Terraform never modeled it, and `terraform apply`
# reported "No changes" while it was stale. Fixture has 2 indexers (ids 2
# and 3); asserts each PUT body carries only its own id's data with the new
# key applied, and unrelated fields (baseUrl) are left untouched. ---

@test "sync_indexer_keys updates each indexer's apiKey without touching other fields or ids" {
    run bash -c "
        source '$REPO_ROOT/terraform/apply.sh'
        tmpdir=\$(mktemp -d)
        curl() {
            local all=\"\$*\"
            if [[ \"\$all\" == *'-X PUT'* ]]; then
                local id
                id=\$(echo \"\$all\" | grep -oE '/indexer/[0-9]+' | grep -oE '[0-9]+')
                local body=\"\${!#}\"
                echo \"\$body\" > \"\$tmpdir/put-\${id}.json\"
            else
                cat '$FIXTURES/indexer-list.json'
            fi
        }
        export -f curl
        sync_indexer_keys 'Radarr' 'http://localhost:7878' 'app-key' 'new-prowlarr-key'
        echo 'id2:' \$(jq -r '.id' \"\$tmpdir/put-2.json\")
        echo 'id2 apiKey:' \$(jq -r '.fields[] | select(.name==\"apiKey\") | .value' \"\$tmpdir/put-2.json\")
        echo 'id2 baseUrl:' \$(jq -r '.fields[] | select(.name==\"baseUrl\") | .value' \"\$tmpdir/put-2.json\")
        echo 'id3:' \$(jq -r '.id' \"\$tmpdir/put-3.json\")
        echo 'id3 apiKey:' \$(jq -r '.fields[] | select(.name==\"apiKey\") | .value' \"\$tmpdir/put-3.json\")
    "
    assert_output --partial "id2: 2"
    assert_output --partial "id2 apiKey: new-prowlarr-key"
    assert_output --partial "id2 baseUrl: http://prowlarr:9696"
    assert_output --partial "id3: 3"
    assert_output --partial "id3 apiKey: new-prowlarr-key"
    refute_output --partial "stale-prowlarr-key"
}

# --- build_seerr_payload: regression for snag #5 (Seerr's settings PUT
# rejected with `400 request/body/id is read-only` until `id` was stripped
# before re-sending). ---

@test "build_seerr_payload strips the read-only id field and applies the new key" {
    run bash -c "
        source '$REPO_ROOT/terraform/apply.sh'
        settings=\$(cat '$FIXTURES/seerr-radarr-settings.json')
        build_seerr_payload \"\$settings\" 'new-radarr-key'
    "
    assert_success
    refute_output --partial '\"id\"'
    assert_output --partial "new-radarr-key"
    refute_output --partial "stale-radarr-key"
    # Untouched fields must survive the transform.
    assert_output --partial "gluetun"
}
