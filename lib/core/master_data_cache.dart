part of '../main.dart';

// ─────────────────────────────────────────────
// マスタデータ短時間キャッシュ
// 店舗・商品・テスター・備品だけを保持する。
// 在庫数・発注数・納品予定は常に最新を読むため、数のズレは起こさない。
// ─────────────────────────────────────────────

class _MasterDataSnapshot {
  const _MasterDataSnapshot({
    required this.orgId,
    required this.loadedAt,
    required this.stores,
    required this.products,
    required this.testers,
    required this.equipments,
  });

  final String orgId;
  final DateTime loadedAt;
  final List<LegacyStore> stores;
  final List<LegacyItem> products;
  final List<LegacyItem> testers;
  final List<LegacyItem> equipments;

  bool get isFresh {
    if (orgId != AppSession.orgId) return false;
    return DateTime.now().difference(loadedAt) < const Duration(minutes: 2);
  }
}

_MasterDataSnapshot? _masterDataCache;
Future<_MasterDataSnapshot>? _masterDataLoading;

Future<_MasterDataSnapshot> _loadMasterData({bool forceRefresh = false}) async {
  final cached = _masterDataCache;
  if (!forceRefresh && cached != null && cached.isFresh) {
    return cached;
  }

  final loading = _masterDataLoading;
  if (!forceRefresh && loading != null) {
    return loading;
  }

  final future = Future<_MasterDataSnapshot>(() async {
    final results = await Future.wait([
      AppSession.doc('stores').get(),
      AppSession.doc('products').get(),
      AppSession.doc('testers').get(),
      AppSession.doc('equipments').get(),
    ]);

    final snapshot = _MasterDataSnapshot(
      orgId: AppSession.orgId,
      loadedAt: DateTime.now(),
      stores: _parseStores(results[0].data() ?? <String, dynamic>{}),
      products: _parseItemsFromDoc(results[1]),
      testers: _parseItemsFromDoc(results[2]),
      equipments: _parseItemsFromDoc(results[3]),
    );
    _masterDataCache = snapshot;
    return snapshot;
  });

  _masterDataLoading = future;
  try {
    return await future;
  } finally {
    if (identical(_masterDataLoading, future)) {
      _masterDataLoading = null;
    }
  }
}

void _clearMasterDataCache() {
  _masterDataCache = null;
  _masterDataLoading = null;
}
