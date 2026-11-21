# Source from the repository root.

sign_app() {
    /usr/bin/codesign --force --sign - "$1"
    verify_app "$1"
}

verify_app() {
    /usr/bin/codesign --verify --strict "$1"
}

publish_app() {
    local app="$1" destination="$2"
    local publisher="${app%/*}/publish-app"
    /usr/bin/clang -Wall -Wextra -Werror script/publish-app.c -o "$publisher"
    "$publisher" "$app" "$destination"
}
