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
    required this.rawProducts,
    required this.rawTesters,
    required this.rawEquipments,
  });

  final String orgId;
  final DateTime loadedAt;
  final List<LegacyStore> stores;
  final List<LegacyItem> products;
  final List<LegacyItem> testers;
  final List<LegacyItem> equipments;
  final List<Map<String, dynamic>> rawProducts;
  final List<Map<String, dynamic>> rawTesters;
  final List<Map<String, dynamic>> rawEquipments;

  bool get isFresh {
    if (orgId != AppSession.orgId) return false;
    return DateTime.now().difference(loadedAt) < const Duration(minutes: 2);
  }
}

class _OrgItemLimits {
  const _OrgItemLimits({
    required this.orgId,
    required this.loadedAt,
    required this.products,
    required this.testers,
    required this.equipments,
  });

  final String orgId;
  final DateTime loadedAt;
  final int products;
  final int testers;
  final int equipments;

  bool get isFresh =>
      orgId == AppSession.orgId &&
      DateTime.now().difference(loadedAt) < const Duration(minutes: 2);

  int forLabel(String label) => switch (label) {
    '商品' => products,
    'テスター' => testers,
    '備品' => equipments,
    _ => 10,
  };
}

class _MasterDocumentCacheEntry {
  const _MasterDocumentCacheEntry({
    required this.orgId,
    required this.loadedAt,
    required this.document,
  });

  final String orgId;
  final DateTime loadedAt;
  final DocumentSnapshot<Map<String, dynamic>> document;

  bool get isFresh =>
      orgId == AppSession.orgId &&
      DateTime.now().difference(loadedAt) < const Duration(minutes: 2);
}

_MasterDataSnapshot? _masterDataCache;
Future<_MasterDataSnapshot>? _masterDataLoading;
_OrgItemLimits? _orgItemLimitsCache;
Future<_OrgItemLimits>? _orgItemLimitsLoading;
final Map<String, _MasterDocumentCacheEntry> _masterDocumentCache = {};
final Map<String, Future<DocumentSnapshot<Map<String, dynamic>>>>
_masterDocumentLoading = {};

String _masterDocumentKey(String suffix) => '${AppSession.orgId}::$suffix';

Future<DocumentSnapshot<Map<String, dynamic>>> _loadMasterDocument(
  String suffix, {
  bool forceRefresh = false,
}) async {
  final key = _masterDocumentKey(suffix);
  final cached = _masterDocumentCache[key];
  if (!forceRefresh && cached != null && cached.isFresh) {
    return cached.document;
  }

  final loading = _masterDocumentLoading[key];
  if (!forceRefresh && loading != null) return loading;

  final orgId = AppSession.orgId;
  final future = AppSession.doc(suffix).get().then((document) {
    if (AppSession.orgId == orgId) {
      _masterDocumentCache[key] = _MasterDocumentCacheEntry(
        orgId: orgId,
        loadedAt: DateTime.now(),
        document: document,
      );
    }
    return document;
  });
  _masterDocumentLoading[key] = future;
  try {
    return await future;
  } finally {
    if (identical(_masterDocumentLoading[key], future)) {
      _masterDocumentLoading.remove(key);
    }
  }
}

List<Map<String, dynamic>> _rawMasterItems(
  DocumentSnapshot<Map<String, dynamic>> doc,
) {
  final raw = doc.data()?['items'];
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map(
        (item) => Map<String, dynamic>.from(
          item.map((key, value) => MapEntry(key.toString(), value)),
        ),
      )
      .where((item) => (item['id'] ?? '').toString().isNotEmpty)
      .toList();
}

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
      _loadMasterDocument('stores', forceRefresh: forceRefresh),
      _loadMasterDocument('products', forceRefresh: forceRefresh),
      _loadMasterDocument('testers', forceRefresh: forceRefresh),
      _loadMasterDocument('equipments', forceRefresh: forceRefresh),
    ]);
    final rawProducts = _rawMasterItems(results[1]);
    final rawTesters = _rawMasterItems(results[2]);
    final rawEquipments = _rawMasterItems(results[3]);

    final snapshot = _MasterDataSnapshot(
      orgId: AppSession.orgId,
      loadedAt: DateTime.now(),
      stores: _parseStores(results[0].data() ?? <String, dynamic>{}),
      products: _parseItemsFromDoc(results[1]),
      testers: _parseItemsFromDoc(results[2]),
      equipments: _parseItemsFromDoc(results[3]),
      rawProducts: rawProducts,
      rawTesters: rawTesters,
      rawEquipments: rawEquipments,
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

Future<_OrgItemLimits> _loadOrgItemLimits() async {
  final cached = _orgItemLimitsCache;
  if (cached != null && cached.isFresh) return cached;

  final loading = _orgItemLimitsLoading;
  if (loading != null) return loading;

  final future = Future<_OrgItemLimits>(() async {
    final doc = await FirebaseFirestore.instance
        .collection('orgs')
        .doc(AppSession.orgId)
        .get();
    final data = doc.data() ?? <String, dynamic>{};
    final limits = _OrgItemLimits(
      orgId: AppSession.orgId,
      loadedAt: DateTime.now(),
      products: inventoryIntValue(data['maxProducts']),
      testers: inventoryIntValue(data['maxTesters']),
      equipments: inventoryIntValue(data['maxEquipments']),
    );
    _orgItemLimitsCache = limits;
    return limits;
  });

  _orgItemLimitsLoading = future;
  try {
    return await future;
  } finally {
    if (identical(_orgItemLimitsLoading, future)) {
      _orgItemLimitsLoading = null;
    }
  }
}

void _clearMasterDataCache({String? suffix}) {
  _masterDataCache = null;
  _masterDataLoading = null;
  if (suffix == null) {
    _masterDocumentCache.clear();
    _masterDocumentLoading.clear();
  } else {
    final keySuffix = '::$suffix';
    _masterDocumentCache.removeWhere((key, _) => key.endsWith(keySuffix));
    _masterDocumentLoading.removeWhere((key, _) => key.endsWith(keySuffix));
  }
}
