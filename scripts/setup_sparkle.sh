#!/bin/bash
set -e

# ─────────────────────────────────────────────
# Sparkle 초기 설정 스크립트 (최초 1회 실행)
#
# 역할:
#   1. Sparkle CLI 도구 다운로드 (sign_update, generate_appcast)
#   2. EdDSA 키 페어 생성
#   3. 공개 키를 Xcode 빌드 설정에 추가하는 방법 안내
#
# 사용법: ./scripts/setup_sparkle.sh
# ─────────────────────────────────────────────

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$SCRIPTS_DIR/sparkle_tools"
KEY_FILE="$SCRIPTS_DIR/.sparkle_private_key"
PBXPROJ="$(dirname "$SCRIPTS_DIR")/RxCode.xcodeproj/project.pbxproj"

SPARKLE_VERSION="2.9.1"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

echo "▶ Sparkle 초기 설정"
echo ""

# ── 1. Sparkle CLI 도구 다운로드 ─────────────
if [ -f "$TOOLS_DIR/sign_update" ]; then
    echo "✓ Sparkle 도구가 이미 설치되어 있습니다: $TOOLS_DIR"
else
    echo "📥 Sparkle ${SPARKLE_VERSION} CLI 도구 다운로드 중..."
    mkdir -p "$TOOLS_DIR"
    TEMP_DIR=$(mktemp -d)
    curl -L "$SPARKLE_URL" -o "$TEMP_DIR/sparkle.tar.xz"
    tar -xf "$TEMP_DIR/sparkle.tar.xz" -C "$TEMP_DIR"
    cp "$TEMP_DIR/bin/sign_update" "$TOOLS_DIR/"
    cp "$TEMP_DIR/bin/generate_appcast" "$TOOLS_DIR/"
    chmod +x "$TOOLS_DIR/sign_update" "$TOOLS_DIR/generate_appcast"
    rm -rf "$TEMP_DIR"
    echo "✓ 도구 설치 완료: $TOOLS_DIR"
fi
echo ""

# ── 2. EdDSA 키 페어 생성 ──────────────────
if [ -f "$KEY_FILE" ]; then
    echo "✓ 비밀 키가 이미 존재합니다: $KEY_FILE"
    echo "  (기존 키를 재사용합니다)"
else
    echo "🔑 EdDSA 키 페어 생성 중..."
    python3 -c "
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
import base64, os
key = Ed25519PrivateKey.generate()
priv = base64.b64encode(key.private_bytes_raw()).decode()
pub  = base64.b64encode(key.public_key().public_bytes_raw()).decode()
with open('$KEY_FILE', 'w') as f:
    f.write(priv + '\n')
os.chmod('$KEY_FILE', 0o600)
print('PUBLIC_KEY=' + pub)
" > /tmp/sparkle_keygen_out.txt
    chmod 600 "$KEY_FILE"
    echo "✓ 비밀 키 생성: $KEY_FILE (절대 커밋하지 마세요)"
fi
echo ""

# ── 3. 공개 키 추출 ──────────────────────────
echo "📋 공개 키 추출 중..."
PUBLIC_KEY=$(python3 -c "
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
import base64
with open('$KEY_FILE') as f:
    priv_b64 = f.read().strip()
priv_bytes = base64.b64decode(priv_b64)
key = Ed25519PrivateKey.from_private_bytes(priv_bytes)
print(base64.b64encode(key.public_key().public_bytes_raw()).decode())
")

echo ""
echo "─────────────────────────────────────────"
echo "✅ 설정 완료"
echo ""
echo "📌 다음 단계: Xcode에서 SUPublicEDKey 설정"
echo ""
echo "   1. Xcode → RxCode 타겟 → Build Settings → Info.plist Values"
echo "   2. 아래 키/값을 추가:"
echo ""
echo "      키:  SUPublicEDKey"
echo "      값:  $PUBLIC_KEY"
echo ""
echo "   또는 터미널에서 자동 패치:"
echo ""
echo "   /usr/libexec/PlistBuddy -c 'Add :SUPublicEDKey string $PUBLIC_KEY' \\"
echo "     \"\$(xcodebuild -showBuildSettings 2>/dev/null | grep 'INFOPLIST_FILE' | awk '{print \$3}')\""
echo ""

# pbxproj에 공개 키 자동 추가 시도
if grep -q "INFOPLIST_KEY_SUPublicEDKey" "$PBXPROJ" 2>/dev/null; then
    echo "✓ SUPublicEDKey가 이미 pbxproj에 있습니다."
else
    echo "🔧 pbxproj에 SUPublicEDKey 자동 추가 중..."
    sed -i '' "s|INFOPLIST_KEY_SUFeedURL = \"https://raw.githubusercontent.com/ttnear/RxCode/main/appcast.xml\";|INFOPLIST_KEY_SUFeedURL = \"https://raw.githubusercontent.com/ttnear/RxCode/main/appcast.xml\";\n\t\t\t\tINFOPLIST_KEY_SUPublicEDKey = \"${PUBLIC_KEY}\";|g" "$PBXPROJ"
    echo "✓ SUPublicEDKey가 pbxproj에 추가되었습니다."
fi

echo ""
echo "─────────────────────────────────────────"
echo "⚠️  .gitignore에 다음 항목이 있는지 확인하세요:"
echo "   scripts/.sparkle_private_key"
echo "─────────────────────────────────────────"
