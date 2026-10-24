#!/bin/sh
set -eu
# Remove only toolchains embedded by earlier RxCode builds before app signing.
: "${TARGET_BUILD_DIR:?}"
: "${CONTENTS_FOLDER_PATH:?}"
rm -rf "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/SwiftFilter" "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/SwiftFilter"
