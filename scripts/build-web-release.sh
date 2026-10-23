#!/bin/sh

set -eu

if [ -z "${RECAPTCHA_SITE_KEY:-}" ]; then
  echo "RECAPTCHA_SITE_KEY が未設定です。本番Webビルドを中止します。" >&2
  exit 1
fi

flutter build web --release \
  --dart-define=RECAPTCHA_SITE_KEY="$RECAPTCHA_SITE_KEY" \
  "$@"
