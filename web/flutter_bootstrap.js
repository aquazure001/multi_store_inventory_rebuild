{{flutter_js}}
{{flutter_build_config}}

// main.dart.js にリリース識別子を付け、古いサービスワーカーのキャッシュを
// 必ず回避して最新のアプリ本体を取得する。
for (const build of _flutter.buildConfig.builds) {
  if (build.mainJsPath === 'main.dart.js') {
    build.mainJsPath = 'main.dart.js?v=20261026_134208';
  }
}

_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  }
});
