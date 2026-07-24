part of '../main.dart';

// ─────────────────────────────────────────────
// モデル
// ─────────────────────────────────────────────

class LegacyStore {
  const LegacyStore({required this.id, required this.code, required this.name});

  final String id;
  final String code;
  final String name;

  factory LegacyStore.fromMap(Map<String, dynamic> map) {
    return LegacyStore(
      id: (map['id'] ?? '').toString(),
      code: (map['code'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
    );
  }
}

class LegacyItem {
  const LegacyItem({
    required this.id,
    required this.code,
    required this.name,
    this.discontinued = false,
  });

  final String id;
  final String code;
  final String name;
  final bool discontinued;

  factory LegacyItem.fromMap(Map<String, dynamic> map) {
    return LegacyItem(
      id: (map['id'] ?? '').toString(),
      code: (map['code'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      discontinued: map['discontinued'] == true,
    );
  }
}

class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.at,
    required this.storeId,
    required this.storeName,
    required this.itemId,
    required this.itemName,
    required this.itemType,
    required this.oldCount,
    required this.newCount,
    required this.nickName,
  });

  final String id;
  final DateTime at;
  final String storeId;
  final String storeName;
  final String itemId;
  final String itemName;
  final String itemType;
  final int oldCount;
  final int newCount;
  final String nickName;

  factory HistoryEntry.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    final ts = data['at'];
    final at = ts is Timestamp ? ts.toDate() : DateTime.now();
    return HistoryEntry(
      id: doc.id,
      at: at,
      storeId: (data['storeId'] ?? '').toString(),
      storeName: (data['storeName'] ?? '').toString(),
      itemId: (data['itemId'] ?? '').toString(),
      itemName: (data['itemName'] ?? '').toString(),
      itemType: (data['itemType'] ?? '').toString(),
      oldCount: (data['oldCount'] as num?)?.toInt() ?? 0,
      newCount: (data['newCount'] as num?)?.toInt() ?? 0,
      nickName: (data['nickName'] ?? '').toString(),
    );
  }
}

// ─────────────────────────────────────────────
// 特別発注アイテム
// ─────────────────────────────────────────────

class SpecialOrderItem {
  const SpecialOrderItem({
    required this.id,
    required this.type,
    required this.name,
    required this.code,
    required this.salesStart,
    required this.salesEnd,
    required this.arrival,
    required this.createdAt,
  });

  final String id;
  final String type; // '特別発注' | '新規発注' | 'その他'
  final String name;
  final String code;
  final DateTime salesStart;
  final DateTime salesEnd;
  final DateTime arrival;
  final DateTime createdAt;

  DateTime get _todayOnly {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  DateTime get _salesStartOnly =>
      DateTime(salesStart.year, salesStart.month, salesStart.day);

  DateTime get _salesEndOnly =>
      DateTime(salesEnd.year, salesEnd.month, salesEnd.day);

  bool get isBeforeSales => _todayOnly.isBefore(_salesStartOnly);

  bool get isExpired => _salesEndOnly.isBefore(_todayOnly);

  bool get isInSalesPeriod => !isBeforeSales && !isExpired;

  static String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> toMap() => {
    'id': id,
    'type': type,
    'name': name,
    'code': code,
    'salesStart': _fmt(salesStart),
    'salesEnd': _fmt(salesEnd),
    'arrival': _fmt(arrival),
    'createdAt': Timestamp.fromDate(createdAt),
  };

  factory SpecialOrderItem.fromMap(Map<String, dynamic> map) {
    DateTime parseDate(dynamic v, [DateTime? fallback]) {
      if (v is Timestamp) return v.toDate();
      if (v is String && v.length >= 10) {
        try {
          final p = v.substring(0, 10).split('-');
          if (p.length == 3) {
            return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
          }
        } catch (_) {}
      }
      return fallback ?? DateTime.now();
    }

    return SpecialOrderItem(
      id: (map['id'] ?? '').toString(),
      type: (map['type'] ?? 'その他').toString(),
      name: (map['name'] ?? '').toString(),
      code: (map['code'] ?? '').toString(),
      salesStart: parseDate(map['salesStart'], DateTime.now()),
      salesEnd: parseDate(
        map['salesEnd'],
        DateTime.now().add(const Duration(days: 30)),
      ),
      arrival: parseDate(map['arrival'], DateTime.now()),
      createdAt: map['createdAt'] is Timestamp
          ? (map['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }
}

// ─────────────────────────────────────────────
// 共通ヘルパー
// ─────────────────────────────────────────────

List<LegacyItem> _parseItemsFromDoc(
  DocumentSnapshot<Map<String, dynamic>> doc,
) {
  final raw = doc.data()?['items'];
  if (raw is! List) return [];

  final items = raw
      .whereType<Map>()
      .map((item) {
        final map = item.map((k, v) => MapEntry(k.toString(), v));
        return LegacyItem.fromMap(map);
      })
      .where((item) => item.id.isNotEmpty)
      .toList();

  items.sort((a, b) {
    if (a.code.isEmpty && b.code.isEmpty)
      return _naturalCompare(a.name, b.name);
    if (a.code.isEmpty) return 1;
    if (b.code.isEmpty) return -1;
    final c = _naturalCompare(a.code, b.code);
    return c != 0 ? c : _naturalCompare(a.name, b.name);
  });
  return items;
}

List<LegacyStore> _parseStores(Map<String, dynamic> data) {
  final raw = data['items'];
  final stores = <LegacyStore>[];
  if (raw is List) {
    for (final item in raw.whereType<Map>()) {
      final map = Map<String, dynamic>.from(
        item.map((k, v) => MapEntry(k.toString(), v)),
      );
      final store = LegacyStore.fromMap(map);
      if (store.id.isNotEmpty) stores.add(store);
    }
  }
  return stores;
}

Map<String, int> _parseStocksForStore(
  Map<String, dynamic> stocksData,
  String storeId,
) {
  final raw = stocksData[storeId];
  final result = <String, int>{};
  if (raw is Map) {
    for (final entry in raw.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (value is int) {
        result[key] = value;
      } else if (value is num) {
        result[key] = value.toInt();
      }
    }
  }
  return result;
}

Map<String, _OrderMeta> _parseOrderMetasForStore(
  Map<String, dynamic> ordersRaw,
  String typeKey,
  String storeId,
) {
  final result = <String, _OrderMeta>{};
  final metaRaw = (ordersRaw['_meta'] is Map)
      ? ordersRaw['_meta'] as Map
      : <dynamic, dynamic>{};
  final prefix = '${typeKey}__${storeId}__';
  for (final entry in metaRaw.entries) {
    final key = entry.key.toString();
    if (!key.startsWith(prefix) || entry.value is! Map) continue;
    final itemId = key.substring(prefix.length);
    result[itemId] = _OrderMeta.fromMap(entry.value as Map);
  }
  return result;
}

// v1(商品) + v2(テスター・備品) を1つのマップにマージ
Map<String, int> _parseMergedStocksForStore(
  Map<String, dynamic> v1Data,
  Map v2TMap,
  Map v2EMap,
  String storeId,
) {
  final merged = <String, int>{};
  merged.addAll(_parseStocksForStore(v1Data, storeId));
  for (final sub in [v2TMap, v2EMap]) {
    final storeData = sub[storeId];
    if (storeData is Map) {
      for (final e in storeData.entries) {
        final v = e.value;
        if (v is int) {
          merged[e.key.toString()] = v;
        } else if (v is num) {
          merged[e.key.toString()] = v.toInt();
        }
      }
    }
  }
  return merged;
}

// コード・名前のナチュラルソート（T1<T2<T10、あ<い<う）
int _naturalCompare(String a, String b) {
  final re = RegExp(r'\d+|\D+');
  final ap = re.allMatches(a).map((m) => m.group(0)!).toList();
  final bp = re.allMatches(b).map((m) => m.group(0)!).toList();
  for (int i = 0; i < ap.length && i < bp.length; i++) {
    final an = int.tryParse(ap[i]);
    final bn = int.tryParse(bp[i]);
    final cmp = (an != null && bn != null)
        ? an.compareTo(bn)
        : ap[i].compareTo(bp[i]);
    if (cmp != 0) return cmp;
  }
  return ap.length.compareTo(bp.length);
}

String _shortStoreName(String name) {
  if (name.length <= 4) return name;
  return name.substring(0, 4);
}

String _formatDateTime(DateTime dt) {
  final y = dt.year;
  final mo = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final h = dt.hour.toString().padLeft(2, '0');
  final mi = dt.minute.toString().padLeft(2, '0');
  return '$y/$mo/$d $h:$mi';
}
