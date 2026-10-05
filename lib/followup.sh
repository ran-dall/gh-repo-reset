# Open only settings pages that correspond to detected manual follow-up.

manual_followup ()
{
    local dir="$1" base="https://github.com/$REPO/settings";
    (( DRY_RUN || NO_OPEN )) && return 0;
    [[ -s "$dir/manual-items.tsv" ]] || return 0;

    if grep -q '^secrets[[:space:]]' "$dir/manual-items.tsv"; then
        open_url "$base/secrets/actions";
    fi;
    if grep -q '^webhooks[[:space:]]' "$dir/manual-items.tsv"; then
        open_url "$base/hooks";
    fi;
    if grep -q '^runners[[:space:]]' "$dir/manual-items.tsv"; then
        open_url "$base/actions/runners";
    fi;
    if grep -q '^pages[[:space:]]' "$dir/manual-items.tsv"; then
        open_url "$base/pages";
    fi;
    if grep -q '^deploy_keys[[:space:]]' "$dir/manual-items.tsv"; then
        open_url "$base/keys";
    fi
    if grep -q '^package_actions_access[[:space:]]' "$dir/manual-items.tsv"; then
        open_url "https://github.com/orgs/${REPO%%/*}/packages";
    fi
}
