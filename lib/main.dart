import 'dart:async';
import 'dart:convert';
import 'dart:math';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;
import 'package:image/image.dart' as img;
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'firebase_options.dart';

part 'pages/delivery_processing_page.dart';
part 'pages/order_list_page.dart';
part 'pages/past_order_pdf_page.dart';
part 'pages/inventory_snapshot_page.dart';
part 'pages/order_request_history_page.dart';
part 'pages/special_order_page.dart';
part 'pages/store_inventory_page.dart';
part 'pages/store_list_page.dart';
part 'pages/settings_page.dart';
part 'pages/store_reorder_page.dart';
part 'pages/history_page.dart';
part 'pages/all_stores_inventory_page.dart';
part 'pages/auth_pages.dart';
part 'pages/org_management_page.dart';
part 'pages/ad_pages.dart';
part 'pages/admin_review_pages.dart';
part 'pages/legal_page.dart';
part 'pages/item_master_page.dart';
part 'core/app_session.dart';

const String _appVersion = '1.2.1-delivery-cache-reset';

// iOS Safari / Android Chrome のポップアップブロック回避:
// AnchorElement を直接クリックすることでユーザージェスチャーコンテキストを維持する
void _openLink(String url) {
  html.AnchorElement(href: url)
    ..target = '_blank'
    ..rel = 'noopener noreferrer'
    ..click();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MultiStoreInventoryApp());
}

// ページ遷移監視（StoreInventoryPageの自動リフレッシュに使用）
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

// ─────────────────────────────────────────────
// セッション・広告ユーティリティ
// 実装は lib/core/app_session.dart に分離
// ─────────────────────────────────────────────

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

// ─────────────────────────────────────────────
// 店舗一覧ページ
// 実装は lib/pages/store_list_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 設定ページ
// 実装は lib/pages/settings_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 店舗並び替えページ（独立ページ）
// 実装は lib/pages/store_reorder_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 履歴ページ
// 実装は lib/pages/history_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 全店舗在庫確認ページ
// 実装は lib/pages/all_stores_inventory_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 店舗別在庫ページ
// 実装は lib/pages/store_inventory_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 商品マスタ管理ページ
// 実装は lib/pages/item_master_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// ⑤ 発注リストページ
// ─────────────────────────────────────────────

class _OrderMeta {
  const _OrderMeta({
    this.requestedAt,
    this.orderedAt,
    this.acknowledgedAt,
    this.requestedBy = '',
    this.orderedBy = '',
    this.acknowledgedBy = '',
    this.lastRequestedQty = 0,
  });

  final DateTime? requestedAt;
  final DateTime? orderedAt;
  final DateTime? acknowledgedAt;
  final String requestedBy;
  final String orderedBy;
  final String acknowledgedBy;
  final int lastRequestedQty;

  bool get isPdfIssued => orderedAt != null;
  bool get needsAcknowledgement => orderedAt != null && acknowledgedAt == null;

  factory _OrderMeta.fromMap(Map<dynamic, dynamic> map) {
    DateTime? readTime(dynamic value) {
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is String && value.isNotEmpty) {
        return DateTime.tryParse(value);
      }
      return null;
    }

    return _OrderMeta(
      requestedAt: readTime(map['requestedAt']),
      orderedAt: readTime(map['orderedAt']),
      acknowledgedAt: readTime(map['acknowledgedAt']),
      requestedBy: (map['requestedBy'] ?? '').toString(),
      orderedBy: (map['orderedBy'] ?? '').toString(),
      acknowledgedBy: (map['acknowledgedBy'] ?? '').toString(),
      lastRequestedQty: (map['lastRequestedQty'] as num?)?.toInt() ?? 0,
    );
  }
}

class _OrderEntry {
  const _OrderEntry({
    required this.store,
    required this.item,
    required this.itemType,
    required this.current,
    required this.base,
    this.orderedQty = 0,
    this.orderMeta = const _OrderMeta(),
  });
  final LegacyStore store;
  final LegacyItem item;
  final String itemType;
  final int current;
  final int base;
  final int orderedQty;
  final _OrderMeta orderMeta;

  int get shortage => base - current;
  int get effectiveShortage => max(0, base - current - orderedQty);
  bool get hasOrderedQty => orderedQty > 0;
}

// ─────────────────────────────────────────────
// 発注リスト画面
// 実装は lib/pages/order_list_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 棚卸し一覧CSV出力
// 実装は lib/pages/inventory_snapshot_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 発注ボタン履歴
// 実装は lib/pages/order_request_history_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 過去の発注表PDF再出力
// 実装は lib/pages/past_order_pdf_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 納品処理ページ
// 実装は lib/pages/delivery_processing_page.dart に分離
// ─────────────────────────────────────────────

class _InventoryData {
  const _InventoryData({
    required this.products,
    required this.testers,
    required this.equipments,
    required this.productStocks,
    required this.testerStocks,
    required this.equipmentStocks,
    required this.baseStocks,
    this.orderedProductStocks = const {},
    this.orderedTesterStocks = const {},
    this.orderedEquipmentStocks = const {},
    this.productOrderMetas = const {},
    this.testerOrderMetas = const {},
    this.equipmentOrderMetas = const {},
  });

  final List<LegacyItem> products;
  final List<LegacyItem> testers;
  final List<LegacyItem> equipments;
  final Map<String, int> productStocks;
  final Map<String, int> testerStocks;
  final Map<String, int> equipmentStocks;
  final Map<String, int> baseStocks;
  final Map<String, int> orderedProductStocks;
  final Map<String, int> orderedTesterStocks;
  final Map<String, int> orderedEquipmentStocks;
  final Map<String, _OrderMeta> productOrderMetas;
  final Map<String, _OrderMeta> testerOrderMetas;
  final Map<String, _OrderMeta> equipmentOrderMetas;
}

// ─────────────────────────────────────────────
// 認証・ログイン・初期ユーザー読込ページ
// 実装は lib/pages/auth_pages.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 組織管理ページ（管理者専用）
// 実装は lib/pages/org_management_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 広告表示・広告管理まわり
// 実装は lib/pages/ad_pages.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 承認待ち・統括管理ページ
// 実装は lib/pages/admin_review_pages.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 利用規約・プライバシーポリシー
// 実装は lib/pages/legal_page.dart に分離
// ─────────────────────────────────────────────
