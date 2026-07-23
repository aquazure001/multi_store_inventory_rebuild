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
part 'pages/auth_pages.dart';
part 'pages/org_management_page.dart';
part 'pages/ad_pages.dart';
part 'pages/admin_review_pages.dart';
part 'pages/item_master_page.dart';

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
// セッション（グローバル状態）
// ─────────────────────────────────────────────

class AppSession {
  static String uid = '';
  static String orgId = '';
  static String role = '';
  static String email = '';
  static String orgName = '';
  static String logoUrl = '';
  static String nickname = '';
  static int adSlotBase = -1;
  static List<_AdEntry> distributedAds = [];
  static bool approved = true; // 既存組織はデフォルト承認済み
  static bool adViewEnabled = true; // 広告表示（デフォルトON）

  static bool get isAdmin => role == 'admin';
  static bool get hasOrg => orgId.isNotEmpty;
  static bool get isSuperAdmin => email == 're.start.niigata@gmail.com';

  static void clear() {
    uid = orgId = role = email = orgName = logoUrl = nickname = '';
    adSlotBase = -1;
    distributedAds = [];
    approved = true;
    adViewEnabled = true;
  }

  static DocumentReference<Map<String, dynamic>> doc(String suffix) =>
      FirebaseFirestore.instance
          .collection('inventory_shared_v1')
          .doc('org_${orgId}__$suffix');
}

// 広告エントリ（スロット番号付き）
class _AdEntry {
  final String orgId;
  final String orgName;
  final String image;
  final String message;
  final String url;
  final int slotNumber;
  const _AdEntry({
    required this.orgId,
    required this.orgName,
    required this.image,
    required this.message,
    required this.url,
    required this.slotNumber,
  });
}

// ─────────────────────────────────────────────
// 広告ユーティリティ（グローバル）
// ─────────────────────────────────────────────

bool _orgHasAdContent(Map<String, dynamic> data) {
  final rawSlots = data['adSlots'];
  if (rawSlots is List) {
    return rawSlots.any(
      (s) =>
          s is Map &&
          (((s['image'] as String?) ?? '').isNotEmpty ||
              ((s['message'] as String?) ?? '').isNotEmpty),
    );
  }
  return ((data['adImage'] as String?) ?? '').isNotEmpty ||
      ((data['adMessage'] as String?) ?? '').isNotEmpty;
}

// ownOrgData: _UserLoader._load で既に読み込んだ自組織データ（再読み取り不要）
Future<void> _loadAllAdsImpl(
  FirebaseFirestore fs, {
  Map<String, dynamic>? ownOrgData,
}) async {
  final entries = <_AdEntry>[];
  int fallbackSlot = 10000;

  void addFromDoc(String docId, Map<String, dynamic> data) {
    final slotBase = (data['adSlotBase'] as int?) ?? -1;
    final orgName = (data['name'] as String?) ?? docId;
    bool addedAny = false;

    // 新形式: adSlots
    final rawSlots = data['adSlots'];
    if (rawSlots is List) {
      for (int i = 0; i < rawSlots.length; i++) {
        final slot = rawSlots[i];
        if (slot is! Map) continue;
        final image = (slot['image'] as String?) ?? '';
        final message = (slot['message'] as String?) ?? '';
        final url = (slot['url'] as String?) ?? '';
        if (image.isEmpty && message.isEmpty) continue;
        final base = slotBase >= 0 ? slotBase : fallbackSlot++;
        entries.add(
          _AdEntry(
            orgId: docId,
            orgName: orgName,
            image: image,
            message: message,
            url: url,
            slotNumber: base + i,
          ),
        );
        addedAny = true;
      }
    }

    // レガシー互換: adSlots に有効なエントリがない場合は adImage/adMessage を使用
    if (!addedAny) {
      final image = (data['adImage'] as String?) ?? '';
      final message = (data['adMessage'] as String?) ?? '';
      if (image.isNotEmpty || message.isNotEmpty) {
        final base = slotBase >= 0 ? slotBase : fallbackSlot++;
        entries.add(
          _AdEntry(
            orgId: docId,
            orgName: orgName,
            image: image,
            message: message,
            url: '',
            slotNumber: base,
          ),
        );
      }
    }
  }

  // ① 自組織（_load で読み込み済みのデータを使用 → Firestore 再読み取り不要）
  if (AppSession.orgId.isNotEmpty && ownOrgData != null) {
    addFromDoc(AppSession.orgId, ownOrgData);
  }

  // ② 他組織の広告を取得（全件スキャン → 権限なければ配信許可済みのみ）
  try {
    final snap = await fs.collection('orgs').get();
    for (final doc in snap.docs) {
      if (doc.id == AppSession.orgId) continue;
      if (entries.any((e) => e.orgId == doc.id)) continue;
      addFromDoc(doc.id, doc.data());
    }
  } catch (_) {
    try {
      final snap = await fs
          .collection('orgs')
          .where('adDistribEnabled', isEqualTo: true)
          .get();
      for (final doc in snap.docs) {
        if (doc.id == AppSession.orgId) continue;
        if (entries.any((e) => e.orgId == doc.id)) continue;
        addFromDoc(doc.id, doc.data());
      }
    } catch (_) {}
  }

  entries.sort((a, b) => a.slotNumber.compareTo(b.slotNumber));
  AppSession.distributedAds = entries;
}

Future<int> _assignAdSlotBase(
  FirebaseFirestore fs,
  String orgId,
  bool isSuperAdmin,
) async {
  if (isSuperAdmin) {
    await fs.collection('orgs').doc(orgId).update({
      'adSlotBase': 0,
      'adDistribEnabled': true,
    });
    return 0;
  }
  try {
    final snap = await fs
        .collection('orgs')
        .where('adSlotBase', isGreaterThanOrEqualTo: 5)
        .get();
    int maxBase = 2; // 初回割り当ては5になるよう
    for (final doc in snap.docs) {
      if (doc.id == orgId) continue;
      final base = (doc.data()['adSlotBase'] as int?) ?? 0;
      if (base > maxBase) maxBase = base;
    }
    final newBase = maxBase >= 5 ? maxBase + 3 : 5;
    await fs.collection('orgs').doc(orgId).update({'adSlotBase': newBase});
    return newBase;
  } catch (_) {
    return -1;
  }
}

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
// ─────────────────────────────────────────────

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.onManualUpdate,
    required this.onChangeNickname,
    required this.onChangePassword,
    required this.onLeaveOrg,
    required this.onDeleteAccount,
  });

  final Future<void> Function() onManualUpdate;
  final Future<void> Function() onChangeNickname;
  final Future<void> Function() onChangePassword;
  final Future<void> Function() onLeaveOrg;
  final Future<void> Function() onDeleteAccount;

  Future<void> _logout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ログアウト'),
        content: const Text('ログアウトしますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('ログアウト'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await FirebaseAuth.instance.signOut();
    AppSession.clear();
    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(title: const Text('設定')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.system_update_alt),
                    title: const Text('アプリを最新にする'),
                    subtitle: const Text('最新の画面を手動で読み直します'),
                    onTap: onManualUpdate,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: const Text('ニックネーム変更'),
                    onTap: onChangeNickname,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: const Text('パスワード変更'),
                    onTap: onChangePassword,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: const Text('利用規約'),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const LegalPage(
                            title: '利用規約',
                            content: _kTermsOfService,
                          ),
                        ),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.privacy_tip_outlined),
                    title: const Text('プライバシーポリシー'),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const LegalPage(
                            title: 'プライバシーポリシー',
                            content: _kPrivacyPolicy,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: const Text('ログアウト'),
                    onTap: () => _logout(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.group_remove_outlined),
                    title: const Text('組織から退出'),
                    onTap: onLeaveOrg,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(
                      Icons.delete_forever,
                      color: Colors.red,
                    ),
                    title: const Text(
                      'アカウント削除',
                      style: TextStyle(color: Colors.red),
                    ),
                    onTap: onDeleteAccount,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 店舗並び替えページ（独立ページ）
// ─────────────────────────────────────────────

class StoreReorderPage extends StatefulWidget {
  const StoreReorderPage({super.key});

  @override
  State<StoreReorderPage> createState() => _StoreReorderPageState();
}

class _StoreReorderPageState extends State<StoreReorderPage> {
  List<LegacyStore> _stores = [];
  List<Map<String, dynamic>> _rawMaps = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final doc = await AppSession.doc('stores').get();

      final data = doc.data();
      final raw = data?['items'];
      final stores = <LegacyStore>[];
      final rawMaps = <Map<String, dynamic>>[];

      if (raw is List) {
        for (final item in raw.whereType<Map>()) {
          final map = Map<String, dynamic>.from(
            item.map((k, v) => MapEntry(k.toString(), v)),
          );
          final store = LegacyStore.fromMap(map);
          if (store.id.isNotEmpty) {
            stores.add(store);
            rawMaps.add(map);
          }
        }
      }

      setState(() {
        _stores = stores;
        _rawMaps = rawMaps;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _move(int from, int to) {
    setState(() {
      final store = _stores.removeAt(from);
      _stores.insert(to, store);
      final raw = _rawMaps.removeAt(from);
      _rawMaps.insert(to, raw);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await AppSession.doc('stores').update({'items': _rawMaps});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('並び順を保存しました'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.of(context).pop(List<LegacyStore>.from(_stores));
      }
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(title: const Text('店舗の並び替え')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: SelectableText('読み取りエラー\n\n$_error'),
              )
            : Column(
                children: [
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      itemCount: _stores.length,
                      itemBuilder: (context, i) {
                        return Card(
                          child: ListTile(
                            leading: Text(
                              '${i + 1}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey,
                              ),
                            ),
                            title: Text(
                              _stores[i].name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(_stores[i].id),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.arrow_upward),
                                  color: i > 0 ? Colors.blue : Colors.grey,
                                  onPressed: i > 0
                                      ? () => _move(i, i - 1)
                                      : null,
                                ),
                                IconButton(
                                  icon: const Icon(Icons.arrow_downward),
                                  color: i < _stores.length - 1
                                      ? Colors.blue
                                      : Colors.grey,
                                  onPressed: i < _stores.length - 1
                                      ? () => _move(i, i + 1)
                                      : null,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save),
                        label: Text(
                          _saving ? '保存中...' : 'この順番で保存する',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 履歴ページ
// ─────────────────────────────────────────────

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  Future<List<HistoryEntry>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<HistoryEntry>> _load() async {
    final snap = await AppSession.doc(
      'history',
    ).collection('entries').orderBy('at', descending: true).limit(100).get();

    return snap.docs.map((doc) => HistoryEntry.fromDoc(doc)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('修正・追加履歴'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '更新',
            onPressed: () => setState(() => _future = _load()),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<List<HistoryEntry>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: SelectableText('読み取りエラー\n\n${snapshot.error}'),
              );
            }

            final entries = snapshot.data ?? [];

            if (entries.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    '履歴がありません\n在庫を変更すると記録されます',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: entries.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      child: ListTile(
                        title: const Text('件数（直近100件）'),
                        trailing: Text(
                          '${entries.length} 件',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  );
                }
                return _buildEntryCard(entries[index - 1]);
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildEntryCard(HistoryEntry entry) {
    final delta = entry.newCount - entry.oldCount;
    final deltaStr = delta > 0 ? '+$delta' : '$delta';
    final deltaColor = delta > 0 ? Colors.green.shade700 : Colors.red.shade700;
    final bgColor = delta > 0 ? Colors.green.shade50 : Colors.red.shade50;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: bgColor,
          child: Text(
            deltaStr,
            style: TextStyle(
              color: deltaColor,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        title: Text(
          entry.itemName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${entry.storeName}  ・  ${entry.itemType}'),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _formatDateTime(entry.at),
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
                if (entry.nickName.isNotEmpty)
                  Text(
                    entry.nickName,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.deepPurple.shade400,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ],
        ),
        trailing: RichText(
          text: TextSpan(
            style: DefaultTextStyle.of(context).style,
            children: [
              TextSpan(text: '${entry.oldCount}'),
              const TextSpan(text: ' → '),
              TextSpan(
                text: '${entry.newCount}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: deltaColor,
                ),
              ),
            ],
          ),
        ),
        isThreeLine: true,
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 全店舗在庫確認ページ
// ─────────────────────────────────────────────

class _AllStoresData {
  const _AllStoresData({
    required this.stores,
    required this.products,
    required this.testers,
    required this.equipments,
    required this.stocksByStore,
  });

  final List<LegacyStore> stores;
  final List<LegacyItem> products;
  final List<LegacyItem> testers;
  final List<LegacyItem> equipments;
  final Map<String, Map<String, int>> stocksByStore;
}

class AllStoresInventoryPage extends StatelessWidget {
  const AllStoresInventoryPage({super.key});

  Future<_AllStoresData> _load() async {
    final results = await Future.wait([
      AppSession.doc('stores').get(),
      AppSession.doc('products').get(),
      AppSession.doc('testers').get(),
      AppSession.doc('equipments').get(),
      AppSession.doc('stocks').get(),
      AppSession.doc('stocks_v2').get(),
    ]);

    // Firestore配列順のまま（ソートなし）
    final storesRaw = results[0].data()?['items'];
    final stores = <LegacyStore>[];
    if (storesRaw is List) {
      for (final item in storesRaw.whereType<Map>()) {
        final map = item.map((k, v) => MapEntry(k.toString(), v));
        final store = LegacyStore.fromMap(map);
        if (store.id.isNotEmpty) stores.add(store);
      }
    }

    final stocksData = results[4].data() ?? {};
    final v2Raw = results[5].data() ?? {};
    final v2TMap = (v2Raw['testers'] is Map) ? v2Raw['testers'] as Map : {};
    final v2EMap = (v2Raw['equipments'] is Map)
        ? v2Raw['equipments'] as Map
        : {};

    final stocksByStore = <String, Map<String, int>>{};
    for (final store in stores) {
      stocksByStore[store.id] = _parseMergedStocksForStore(
        stocksData,
        v2TMap,
        v2EMap,
        store.id,
      );
    }

    return _AllStoresData(
      stores: stores,
      products: _parseItemsFromDoc(results[1]),
      testers: _parseItemsFromDoc(results[2]),
      equipments: _parseItemsFromDoc(results[3]),
      stocksByStore: stocksByStore,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: const Color(0xFFFFF7FF),
        appBar: AppBar(
          title: const Text('全店舗在庫確認'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '商品'),
              Tab(text: 'テスター'),
              Tab(text: '備品'),
            ],
          ),
        ),
        body: SafeArea(
          child: FutureBuilder<_AllStoresData>(
            future: _load(),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: SelectableText('読み取りエラー\n\n${snapshot.error}'),
                );
              }

              final data = snapshot.data;
              if (data == null) {
                return const Center(child: Text('データなし'));
              }

              return TabBarView(
                children: [
                  _AllStoresItemList(
                    items: data.products,
                    stores: data.stores,
                    stocksByStore: data.stocksByStore,
                  ),
                  _AllStoresItemList(
                    items: data.testers,
                    stores: data.stores,
                    stocksByStore: data.stocksByStore,
                  ),
                  _AllStoresItemList(
                    items: data.equipments,
                    stores: data.stores,
                    stocksByStore: data.stocksByStore,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AllStoresItemList extends StatefulWidget {
  const _AllStoresItemList({
    required this.items,
    required this.stores,
    required this.stocksByStore,
  });

  final List<LegacyItem> items;
  final List<LegacyStore> stores;
  final Map<String, Map<String, int>> stocksByStore;

  @override
  State<_AllStoresItemList> createState() => _AllStoresItemListState();
}

class _AllStoresItemListState extends State<_AllStoresItemList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.items.where((item) {
      final q = _query.trim().toLowerCase();
      if (q.isEmpty) return true;
      return item.name.toLowerCase().contains(q) ||
          item.code.toLowerCase().contains(q);
    }).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: '検索...',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            title: const Text('件数'),
            trailing: Text(
              '${filtered.length} 件',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final item in filtered) _buildItemCard(item),
      ],
    );
  }

  Widget _buildItemCard(LegacyItem item) {
    final storeCounts = widget.stores.map((store) {
      final count = widget.stocksByStore[store.id]?[item.id] ?? 0;
      return (store: store, count: count);
    }).toList();

    final total = storeCounts.fold(0, (acc, e) => acc + e.count);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '合計: $total',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            Text(
              'コード: ${item.code}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final sc in storeCounts)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: sc.count > 0
                          ? Colors.deepPurple.shade50
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: sc.count > 0
                            ? Colors.deepPurple.shade200
                            : Colors.grey.shade300,
                      ),
                    ),
                    child: Text(
                      '${_shortStoreName(sc.store.name)}: ${sc.count}',
                      style: TextStyle(
                        fontSize: 13,
                        color: sc.count > 0
                            ? Colors.deepPurple.shade700
                            : Colors.grey,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

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

const String _kTermsOfService = '''利用規約

制定日：2026年6月13日

本利用規約（以下「本規約」といいます）は、株式会社Re,stArt（以下「当社」といいます）が提供する多店舗在庫管理システム（以下「本サービス」といいます）の利用条件を定めるものです。ユーザーの皆さまは、本規約に同意のうえ、本サービスをご利用ください。

第1条（適用）
本規約は、ユーザーと当社との間の本サービスの利用に関わる一切の関係に適用されます。
当社は本規約のほか、本サービスに関するルール・諸規定等（以下「個別規定」といいます）を定めることがあります。個別規定は、その名称のいかんにかかわらず、本規約の一部を構成するものとします。本規約の規定が個別規定と矛盾する場合には、個別規定の規定が優先されるものとします。

第2条（定義）
本規約において使用する用語の定義は以下のとおりです。
・「ユーザー」とは、本規約に同意のうえ、本サービスに登録した個人または法人をいいます。
・「本サービス」とは、当社が提供する多店舗在庫管理システムおよびこれに付随するサービスをいいます。
・「コンテンツ」とは、ユーザーが本サービスに登録・入力した在庫データ、商品情報その他一切の情報をいいます。

第3条（利用登録）
本サービスへの登録を希望する方は、本規約に同意のうえ、当社の定める方法によって利用登録を申請するものとします。
当社は、利用登録の申請者に以下の事由があると判断した場合、利用登録の申請を承認しないことがあります。
・虚偽の事項を届け出た場合
・本規約に違反したことがある者からの申請である場合
・その他当社が利用登録を相当でないと判断した場合

第4条（料金プランおよび有料サービス）
本サービスは以下の料金プランを提供します。
・無料プラン：店舗数5店舗・ユーザー数5名までを無料でご利用いただけます。
・有料プラン：上記上限を超えてご利用の場合、または広告出稿をご希望の場合は、別途当社が定める料金が発生します。
有料サービスの料金・支払条件等については、当社が別途定め、本サービス上または個別契約書等において提示するものとします。

第5条（禁止事項）
ユーザーは、本サービスの利用にあたり、以下の行為をしてはなりません。
・法令または公序良俗に違反する行為
・犯罪行為に関連する行為
・当社または第三者の知的財産権、肖像権、プライバシー、名誉その他の権利または利益を侵害する行為
・当社のサーバーまたはネットワークの機能を破壊したり、妨害したりする行為
・本サービスの運営を妨害するおそれのある行為（大量アクセス・自動送信等を含む）
・他のユーザーの情報を収集すること
・不正アクセスをし、またはこれを試みる行為
・本サービスを競合他社への情報提供、再販売または転売を目的として利用する行為
・本サービスを逆コンパイル、リバースエンジニアリング、逆アセンブルする行為
・その他当社が不適切と判断する行為

第6条（損害賠償）
ユーザーが本規約に違反した行為または不正もしくは違法な行為によって当社に損害を与えた場合、当社はユーザーに対して損害賠償を請求できるものとします。悪意ある行為による損害については、実損害の全額を請求できるものとします。

第7条（本サービスの提供の停止等）
当社は、以下のいずれかの事由があると判断した場合、ユーザーに事前に通知することなく本サービスの全部または一部の提供を停止または中断することができるものとします。
・本サービスにかかるコンピュータシステムの保守点検または更新を行う場合
・地震、落雷、火災、停電または天災などの不可抗力により、本サービスの提供が困難となった場合
・コンピュータまたは通信回線等が事故により停止した場合
・その他当社が本サービスの提供が困難と判断した場合
当社は、本サービスの提供の停止または中断により、ユーザーまたは第三者が被ったいかなる不利益または損害についても、一切の責任を負わないものとします。

第8条（利用制限および登録抹消）
当社は、ユーザーが以下のいずれかに該当する場合には、事前の通知なく、ユーザーに対して本サービスの全部もしくは一部の利用を制限し、またはユーザーとしての登録を抹消することができるものとします。
・本規約のいずれかの条項に違反した場合
・登録事項に虚偽の事実があることが判明した場合
・有料サービスの料金等の支払債務の不履行があった場合
・長期間本サービスの利用がない場合
・その他当社が本サービスの利用を適当でないと判断した場合
当社は、本条に基づき当社が行った行為によりユーザーに生じた損害について、一切の責任を負いません。

第9条（退会）
ユーザーは、当社の定める退会手続きにより、本サービスから退会できるものとします。退会時、ユーザーのコンテンツ（在庫データ・商品情報等）は即時削除され、復旧はできませんのでご注意ください。

第10条（保証の否認および免責事項）
当社は、本サービスに事実上または法律上の瑕疵（安全性、信頼性、正確性、完全性、有効性、特定の目的への適合性、セキュリティなどに関する欠陥、エラーやバグ、権利侵害などを含みます）がないことを明示的にも黙示的にも保証しておりません。
当社は、本サービスに起因してユーザーに生じたあらゆる損害（システム障害によるデータ消失を含む）について、一切の責任を負いません。ただし、当社の故意または重過失による場合はこの限りではありません。

第11条（サービス内容の変更等）
当社は、ユーザーへの事前の告知をもって、本サービスの内容を変更、追加または廃止することがあり、ユーザーはこれを承諾するものとします。

第12条（利用規約の変更）
当社は以下の場合には、ユーザーの個別の同意を要せず、本規約を変更することができるものとします。
・本規約の変更がユーザーの一般の利益に適合するとき。
・本規約の変更が本サービス利用契約の目的に反せず、かつ変更の必要性、変更後の内容の相当性その他の変更に係る事情に照らして合理的なものであるとき。
当社はユーザーに対し、前項による本規約の変更にあたり、事前に、本規約を変更する旨および変更後の本規約の内容並びにその効力発生時期を通知します。

第13条（個人情報の取扱い）
当社による本サービスの利用に際して取得する個人情報の取扱いについては、別途当社が定めるプライバシーポリシーに従うものとします。

第14条（準拠法・裁判管轄）
本規約の解釈にあたっては、日本法を準拠法とします。
本サービスに関して紛争が生じた場合には、当社の本店所在地を管轄する新潟地方裁判所を専属的合意管轄とします。

以上

株式会社Re,stArt
〒942-0061 新潟県上越市春日新田２−２−２
info@happy-bluebird.co.jp''';

const String _kPrivacyPolicy = '''プライバシーポリシー

制定日：2026年6月13日

株式会社Re,stArt（以下「当社」といいます）は、本ウェブサービス「多店舗在庫管理システム」（以下「本サービス」といいます）における個人情報の取扱いについて、以下のとおりプライバシーポリシー（以下「本ポリシー」といいます）を定めます。

第1条（個人情報の定義）
本ポリシーにおいて「個人情報」とは、個人情報の保護に関する法律（個人情報保護法）に定める「個人情報」を指し、生存する個人に関する情報であって、当該情報に含まれる氏名、メールアドレス等によって特定の個人を識別できるものをいいます。

第2条（収集する情報）
当社は、本サービスの利用にあたり、以下の情報を収集する場合があります。
・メールアドレス（アカウント登録時）
・本サービスへの入力情報（在庫データ、商品情報、店舗情報等の業務データ）
・ログイン日時、アクセスログ等の利用履歴情報
本サービスは業務用途を前提としており、氏名・住所・電話番号等の個人を直接特定する情報の収集は原則として行いません。

第3条（個人情報の利用目的）
当社は、収集した個人情報を以下の目的で利用します。
・本サービスの提供・運営のため
・ユーザーからのお問い合わせに対応するため
・メンテナンス・障害情報等の重要なお知らせを送付するため
・利用規約に違反したユーザーの特定および対応のため
・本サービスの改善・新機能開発のため
・その他上記の利用目的に付随する目的のため

第4条（第三者提供の制限）
当社は、次に掲げる場合を除いて、あらかじめユーザーの同意を得ることなく、第三者に個人情報を提供することはありません。
・法令に基づく場合
・人の生命、身体または財産の保護のために必要がある場合であって、本人の同意を得ることが困難であるとき
・公衆衛生の向上または児童の健全な育成の推進のために特に必要がある場合であって、本人の同意を得ることが困難であるとき
・国の機関もしくは地方公共団体またはその委託を受けた者が法令の定める事務を遂行することに対して協力する必要がある場合

第5条（個人情報の管理）
当社は、個人情報の正確性を保ち、これを安全に管理します。当社は、個人情報への不正アクセス・紛失・破損・改ざん・漏洩などを防止するため、適切な安全管理措置を講じます。
本サービスはFirebase（Google LLC提供）を利用しており、収集した情報はFirebaseのサーバーに保存されます。Googleのプライバシーポリシーについては、Google社のウェブサイトをご参照ください。

第6条（データの削除）
ユーザーが本サービスを退会した場合、当該ユーザーのアカウント情報および業務データ（在庫データ・商品情報等）は即時に削除されます。削除されたデータの復旧はいたしかねますので、あらかじめご了承ください。

第7条（個人情報の開示・訂正・削除）
ユーザーは当社に対して、自己の個人情報の開示・訂正・追加・削除・利用停止を請求することができます。ご請求の際は、下記お問い合わせ先までご連絡ください。当社は、合理的な期間内に対応します。

第8条（Cookieの使用）
本サービスでは、ユーザー認証および利便性向上のためにCookieを使用する場合があります。ブラウザの設定によりCookieを無効にすることができますが、その場合、本サービスの一部機能が利用できなくなる場合があります。

第9条（プライバシーポリシーの変更）
当社は、必要に応じて本ポリシーの内容を変更することができるものとします。変更後の本ポリシーは、本サービス上に掲載した時点から効力を生じるものとします。重要な変更については、本サービス上での通知またはメールにてお知らせします。

第10条（お問い合わせ窓口）
本ポリシーに関するお問い合わせは、下記までお願いいたします。

株式会社Re,stArt
代表取締役　清水広美
〒942-0061 新潟県上越市春日新田２−２−２
メールアドレス：info@happy-bluebird.co.jp

以上''';

class LegalPage extends StatelessWidget {
  final String title;
  final String content;
  const LegalPage({super.key, required this.title, required this.content});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(title: Text(title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: SelectableText(
          content,
          style: const TextStyle(fontSize: 13, height: 1.8),
        ),
      ),
    );
  }
}
