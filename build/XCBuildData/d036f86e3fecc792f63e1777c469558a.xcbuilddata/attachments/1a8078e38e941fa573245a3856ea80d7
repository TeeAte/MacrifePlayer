#!/bin/sh
SRC_APP="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
DEST_APP="${PROJECT_DIR}/${FULL_PRODUCT_NAME}"
if [ -d "${SRC_APP}" ]; then
    echo "[BuildPhase] Copying ${FULL_PRODUCT_NAME} to ${PROJECT_DIR}..."
    rm -rf "${DEST_APP}"
    cp -R "${SRC_APP}" "${DEST_APP}"
    codesign --force --deep --sign - "${DEST_APP}" 2>/dev/null || true
    touch "${DEST_APP}"
fi

