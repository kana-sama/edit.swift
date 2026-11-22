# Source from the repository root.

sign_app() {
    /usr/bin/codesign --force --sign - "$1"
    verify_app "$1"
}

verify_app() {
    /usr/bin/codesign --verify --strict "$1"
}

publish_path() {
    local app="$1" destination="$2"
    local publisher="${app%/*}/publish-app"
    if [[ ! -x "$publisher" ]]; then
        /usr/bin/clang -Wall -Wextra -Werror script/publish-app.c -o "$publisher"
    fi
    "$publisher" "$app" "$destination"
}

publish_app() {
    local app="$1" destination="$2"
    staged_app_inode="$(/usr/bin/stat -f %i "$app")"
    publish_path "$app" "$destination"
}

finish_app_stage() {
    local stage="$1" app="$2"
    # After a swap the incoming pathname points to the previous bundle.
    # Keep that bundle available for macOS services that validate the running executable.
    if [[ -n ${staged_app_inode:-} && -d "$app" ]] &&
       [[ "$(/usr/bin/stat -f %i "$app")" != "$staged_app_inode" ]]; then
        touch "$stage/.retired-app"
    else
        rm -rf -- "$stage"
    fi
}

prune_retired_apps() {
    local directory="$1" marker stage
    for marker in "$directory"/.edit-bundle.*/.retired-app "$directory"/.edit-install.*/.retired-app; do
        [[ -f "$marker" ]] || continue
        stage="${marker%/*}"
        if [[ -O "$stage" && ! -L "$stage" && "$(/usr/bin/stat -f %Lp "$stage")" == 700 &&
              -x "$stage/publish-app" && ! -L "$stage/publish-app" ]] &&
           "$stage/publish-app" unused "$stage"; then
            rm -rf -- "$stage"
        fi
    done
}
