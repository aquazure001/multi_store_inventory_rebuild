part of 'main.dart';

// ─────────────────────────────────────────────
// アプリルート
// ─────────────────────────────────────────────

final GlobalKey<ScaffoldMessengerState> _rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

class MultiStoreInventoryApp extends StatefulWidget {
  const MultiStoreInventoryApp({super.key});

  @override
  State<MultiStoreInventoryApp> createState() => _MultiStoreInventoryAppState();
}

class _MultiStoreInventoryAppState extends State<MultiStoreInventoryApp> {
  @override
  void initState() {
    super.initState();
    html.window.addEventListener('swUpdateReady', _onUpdateReady);
  }

  @override
  void dispose() {
    html.window.removeEventListener('swUpdateReady', _onUpdateReady);
    super.dispose();
  }

  void _onUpdateReady(html.Event _) {
    _rootScaffoldMessengerKey.currentState?.showMaterialBanner(
      MaterialBanner(
        backgroundColor: Colors.deepPurple,
        content: const Text(
          '新しいバージョンが利用可能です',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _rootScaffoldMessengerKey.currentState
                  ?.hideCurrentMaterialBanner();
            },
            child: const Text('後で', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () {
              js.context.callMethod('eval', [
                r"""
(function() {
  var nextUrl = window.location.origin + window.location.pathname + '?force_update=' + Date.now();
  var jobs = [];
  if ('serviceWorker' in navigator) {
    jobs.push(navigator.serviceWorker.getRegistrations().then(function(registrations) {
      return Promise.all(registrations.map(function(reg) { return reg.unregister(); }));
    }).catch(function() {}));
  }
  if ('caches' in window) {
    jobs.push(caches.keys().then(function(keys) {
      return Promise.all(keys.map(function(key) { return caches.delete(key); }));
    }).catch(function() {}));
  }
  Promise.all(jobs).finally(function() { window.location.replace(nextUrl); });
})();
""",
              ]);
            },
            child: const Text(
              '今すぐ更新',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '多店舗在庫管理システム',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _rootScaffoldMessengerKey,
      navigatorObservers: [appRouteObserver],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const AuthGate(),
    );
  }
}
