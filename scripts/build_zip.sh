#!/bin/bash
set -e

# ─────────────────────────────────────────────
# RxCode ZIP 배포 빌드 스크립트 (노터라이제이션 포함)
#
# 사용법: ./scripts/build_zip.sh [버전]
# 예시:   ./scripts/build_zip.sh 1.2.0
#
# 인증 정보: scripts/.env 파일에 설정
#   APPLE_ID=you@example.com
#   APP_PASSWORD=xxxx-xxxx-xxxx-xxxx  (appleid.apple.com에서 생성)
#   TEAM_ID=XXXXXXXXXX
# ─────────────────────────────────────────────

# .env 로드
ENV_FILE="$(dirname "$0")/.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "⚠️  scripts/.env 파일이 없습니다."
    echo "   scripts/.env.example을 복사해서 작성해주세요:"
    echo "   cp scripts/.env.example scripts/.env"
    exit 1
fi

SCHEME="RxCode"
PROJECT="RxCode.xcodeproj"
EXPORT_OPTIONS="scripts/ExportOptions.plist"
BUILD_DIR="build"
VERSION=${1:-"1.0.0"}

ARCHIVE_PATH="$BUILD_DIR/RxCode.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/RxCode.app"
ZIP_NAME="RxCode-${VERSION}.zip"

echo "▶ RxCode v${VERSION} 빌드 시작"
echo ""

# 이전 빌드 정리
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── 1. Archive ──────────────────────────────
echo "📦 아카이브 생성 중..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    2>&1 | grep -E "error:|warning:.*error|ARCHIVE SUCCEEDED|ARCHIVE FAILED" || true

if [ ! -d "$ARCHIVE_PATH" ]; then
    echo "❌ 아카이브 실패"
    exit 1
fi
echo "✓ 아카이브 완료"
echo ""

# ── 2. Export ───────────────────────────────
echo "📤 앱 내보내기 중..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_PATH" \
    2>&1 | grep -E "error:|EXPORT SUCCEEDED|EXPORT FAILED" || true

if [ ! -d "$APP_PATH" ]; then
    echo "❌ 내보내기 실패 — Developer ID Application 인증서가 있는지 확인해주세요"
    echo "   Xcode → Settings → Accounts → 팀 선택 → Manage Certificates → + → Developer ID Application"
    exit 1
fi
echo "✓ 내보내기 완료"
echo ""

# ── 3. 노터라이제이션 ────────────────────────
echo "🔐 노터라이제이션 제출 중 (수 분 소요)..."

NOTARIZE_ZIP="$BUILD_DIR/RxCode-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

xcrun notarytool submit "$NOTARIZE_ZIP" \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

echo "✓ 노터라이제이션 완료"
echo ""

# 스테이플링
echo "📎 스테이플링 중..."
xcrun stapler staple "$APP_PATH"
echo "✓ 스테이플링 완료"
echo ""

rm -f "$NOTARIZE_ZIP"

# ── 4. 최종 ZIP ──────────────────────────────
echo "🗜  ZIP 생성 중..."
ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/$ZIP_NAME"

ZIP_SIZE=$(du -sh "$BUILD_DIR/$ZIP_NAME" | cut -f1)

# ── 5. Sparkle EdDSA 서명 ────────────────────
SIGN_UPDATE="$(dirname "$0")/sparkle_tools/sign_update"
KEY_FILE="$(dirname "$0")/.sparkle_private_key"
META_FILE="$BUILD_DIR/.sparkle_meta"

if [ -f "$SIGN_UPDATE" ] && [ -f "$KEY_FILE" ]; then
    echo ""
    echo "🔐 Sparkle EdDSA 서명 중..."
    SIGNATURE=$("$SIGN_UPDATE" "$BUILD_DIR/$ZIP_NAME" --ed-key-file "$KEY_FILE" -p)
    ZIP_SIZE_BYTES=$(stat -f%z "$BUILD_DIR/$ZIP_NAME")
    {
        echo "SPARKLE_SIGNATURE=$SIGNATURE"
        echo "SPARKLE_SIZE=$ZIP_SIZE_BYTES"
        echo "SPARKLE_ZIP=$ZIP_NAME"
    } > "$META_FILE"
    echo "✓ 서명 완료 (메타데이터: $META_FILE)"
else
    if [ ! -f "$SIGN_UPDATE" ]; then
        echo ""
        echo "⚠️  Sparkle 도구 없음 — Sparkle 서명이 생략됩니다."
        echo "   최초 설정: ./scripts/setup_sparkle.sh"
    elif [ ! -f "$KEY_FILE" ]; then
        echo ""
        echo "⚠️  비밀 키 없음 — Sparkle 서명이 생략됩니다."
        echo "   최초 설정: ./scripts/setup_sparkle.sh"
    fi
fi

echo ""
echo "─────────────────────────────────────────"
echo "✅ 배포 완료"
echo "   파일: $BUILD_DIR/$ZIP_NAME"
echo "   크기: $ZIP_SIZE"
echo "─────────────────────────────────────────"
