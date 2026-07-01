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

const String _appVersion = '1.2.0';

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

  bool get isExpired {
    final today = DateTime.now();
    return salesEnd.isBefore(DateTime(today.year, today.month, today.day));
  }

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
              js.context.callMethod('applyUpdate');
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
// ─────────────────────────────────────────────

class StoreListPage extends StatefulWidget {
  const StoreListPage({super.key});

  @override
  State<StoreListPage> createState() => _StoreListPageState();
}

class _StoreListPageState extends State<StoreListPage> {
  List<LegacyStore> _stores = [];
  bool _loading = true;
  String? _error;
  Timer? _adReloadTimer;

  @override
  void initState() {
    super.initState();
    _loadStores();
    // 10分ごとに広告を再読み込み（削除済み組織の広告を除外するため）
    _adReloadTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      _reloadAds();
    });
  }

  @override
  void dispose() {
    _adReloadTimer?.cancel();
    super.dispose();
  }

  Future<void> _reloadAds() async {
    if (!AppSession.adViewEnabled || AppSession.orgId.isEmpty) return;
    try {
      final fs = FirebaseFirestore.instance;
      final orgDoc = await fs.collection('orgs').doc(AppSession.orgId).get();
      if (orgDoc.exists) {
        await _loadAllAdsImpl(fs, ownOrgData: orgDoc.data());
      }
    } catch (_) {}
  }

  Future<void> _loadStores() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final doc = await AppSession.doc('stores').get();

      final data = doc.data();
      final raw = data?['items'];
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

      setState(() {
        _stores = stores;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  static int _lastFullScreenIdx = -1;

  static Future<void> _showFullScreenAd(BuildContext context) async {
    if (!AppSession.adViewEnabled) return;
    final ads = AppSession.distributedAds;
    if (ads.isEmpty) return;
    int idx;
    if (ads.length == 1) {
      idx = 0;
    } else {
      do {
        idx = Random().nextInt(ads.length);
      } while (idx == _lastFullScreenIdx);
    }
    _lastFullScreenIdx = idx;
    final ad = ads[idx];
    if (!context.mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black87,
      builder: (_) => _FullScreenAdDialog(ad: ad),
    );
  }

  Future<void> _addStore() async {
    final orgDoc = await FirebaseFirestore.instance
        .collection('orgs')
        .doc(AppSession.orgId)
        .get();
    final maxStores = (orgDoc.data()?['maxStores'] as int?) ?? 5;
    if (_stores.length >= maxStores) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('店舗数の上限（$maxStores店舗）に達しています'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final nameCtrl = TextEditingController();
    final codeCtrl = TextEditingController();
    final idCtrl = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('店舗を追加'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: '店舗名'),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: codeCtrl,
              decoration: const InputDecoration(labelText: 'コード（表示用）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: idCtrl,
              decoration: const InputDecoration(labelText: '店舗ID（英数字）'),
              autocorrect: false,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('追加'),
          ),
        ],
      ),
    );
    if (result != true) return;

    final name = nameCtrl.text.trim();
    final code = codeCtrl.text.trim();
    final id = idCtrl.text.trim();
    if (name.isEmpty || id.isEmpty) return;

    try {
      await AppSession.doc('stores').update({
        'items': FieldValue.arrayUnion([
          {'id': id, 'code': code, 'name': name},
        ]),
      });
      _loadStores();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _changeNickname() async {
    final ctrl = TextEditingController(text: AppSession.nickname);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ニックネームを変更'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'ニックネーム',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(AppSession.uid)
          .update({'nickname': result});
      AppSession.nickname = result;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('ニックネームを変更しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _changePassword() async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? dialogError;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('パスワードを変更'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: currentCtrl,
                decoration: const InputDecoration(
                  labelText: '現在のパスワード',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: newCtrl,
                decoration: const InputDecoration(
                  labelText: '新しいパスワード（6文字以上）',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmCtrl,
                decoration: const InputDecoration(
                  labelText: '新しいパスワード（確認）',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              if (dialogError != null) ...[
                const SizedBox(height: 8),
                Text(
                  dialogError!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () {
                if (newCtrl.text != confirmCtrl.text) {
                  setS(() => dialogError = '新しいパスワードが一致しません');
                  return;
                }
                if (newCtrl.text.length < 6) {
                  setS(() => dialogError = 'パスワードは6文字以上で入力してください');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('変更'),
            ),
          ],
        ),
      ),
    );
    if (result != true) return;
    final current = currentCtrl.text;
    final newPass = newCtrl.text;
    try {
      final user = FirebaseAuth.instance.currentUser!;
      final cred = EmailAuthProvider.credential(
        email: user.email!,
        password: current,
      );
      await user.reauthenticateWithCredential(cred);
      await user.updatePassword(newPass);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('パスワードを変更しました')));
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        final msg =
            (e.code == 'wrong-password' || e.code == 'invalid-credential')
            ? '現在のパスワードが正しくありません'
            : 'エラー: ${e.code}';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _leaveOrg() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('組織を脱退'),
        content: const Text('この組織から脱退しますか？\n脱退後は新しい組織を作成または別の組織に参加できます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('脱退', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(AppSession.uid)
          .update({'orgId': '', 'role': 'admin'});
      AppSession.orgId = '';
      AppSession.role = 'admin';
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const OrgSetupPage()),
          (_) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _goToReorder() {
    Navigator.of(context)
        .push<List<LegacyStore>>(
          MaterialPageRoute(builder: (_) => const StoreReorderPage()),
        )
        .then((result) {
          if (!mounted) return;
          if (result != null && result.isNotEmpty) {
            setState(() => _stores = result);
          } else {
            _loadStores();
          }
        });
  }

  Future<void> _openFeedback(String type) async {
    final labels = {
      'feature': ('機能追加依頼', Colors.blue, Icons.add_circle_outline),
      'fix': ('修正依頼', Colors.orange, Icons.build_outlined),
      'bug': ('バグ報告', Colors.red, Icons.bug_report_outlined),
    };
    final (label, color, icon) = labels[type]!;
    final contentCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (type == 'feature')
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: const Text(
                    '機能追加は無料で受け付けておりますが、確実に対応することをお約束するものではありません。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              Text(
                '送信者: ${AppSession.nickname.isNotEmpty ? AppSession.nickname : "（未設定）"}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              Text(
                'メール: ${FirebaseAuth.instance.currentUser?.email ?? ""}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentCtrl,
                maxLines: 5,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '内容',
                  hintText: type == 'bug'
                      ? 'どのような操作をしたときに、何が起きましたか？'
                      : '詳細を入力してください',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.send, size: 16),
            label: const Text('メールで送信'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    contentCtrl.dispose();
    if (confirmed != true || !mounted) return;

    final nick = AppSession.nickname.isNotEmpty ? AppSession.nickname : '未設定';
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    final body = Uri.encodeComponent(
      'ニックネーム: $nick\nメールアドレス: $email\n\n--- 内容 ---\n${contentCtrl.text.trim()}',
    );
    final subject = Uri.encodeComponent('【$label】多店舗在庫管理システム');
    final uri = Uri.parse(
      'mailto:info@happy-bluebird.co.jp?subject=$subject&body=$body',
    );
    try {
      await launchUrl(uri);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'メールアプリが見つかりませんでした。info@happy-bluebird.co.jp までご連絡ください。',
            ),
          ),
        );
      }
    }
  }

  Future<void> _deleteAccount() async {
    final passCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('アカウントを削除'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'この操作は元に戻せません。\nアカウントを完全に削除します。',
              style: TextStyle(color: Colors.red, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passCtrl,
              decoration: const InputDecoration(
                labelText: 'パスワードを入力して確認',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除する', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || passCtrl.text.isEmpty) return;

    try {
      final user = FirebaseAuth.instance.currentUser!;
      final credential = EmailAuthProvider.credential(
        email: AppSession.email,
        password: passCtrl.text,
      );
      await user.reauthenticateWithCredential(credential);

      final fs = FirebaseFirestore.instance;
      await fs.collection('users').doc(AppSession.uid).delete();
      AppSession.clear();

      try {
        await user.delete();
      } catch (_) {
        await FirebaseAuth.instance.signOut();
      }

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AuthGate()),
          (_) => false,
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              (e.code == 'wrong-password' || e.code == 'invalid-credential')
                  ? 'パスワードが正しくありません'
                  : '認証エラー: ${e.code}',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        leading: AppSession.logoUrl.isNotEmpty
            ? Padding(
                padding: const EdgeInsets.all(8),
                child: ClipOval(
                  child: Image.memory(
                    base64Decode(AppSession.logoUrl),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.business),
                  ),
                ),
              )
            : null,
        title: Text(
          AppSession.orgName.isNotEmpty ? AppSession.orgName : '店舗一覧',
        ),
        actions: [
          if (AppSession.isSuperAdmin)
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('orgs')
                  .where('approved', isEqualTo: false)
                  .snapshots(),
              builder: (context, snap) {
                final count = snap.data?.docs.length ?? 0;
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.notifications_outlined),
                      tooltip: '承認待ち管理者',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SuperAdminPage(),
                        ),
                      ),
                    ),
                    if (count > 0)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 16,
                            minHeight: 16,
                          ),
                          child: Text(
                            '$count',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              if (value == 'all_stores') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AllStoresInventoryPage(),
                  ),
                );
              } else if (value == 'history') {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const HistoryPage()));
              } else if (value == 'items') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ItemMasterPage()),
                );
              } else if (value == 'special_order') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SpecialOrderPage()),
                );
              } else if (value == 'order') {
                await _showFullScreenAd(context);
                if (!context.mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const OrderListPage()),
                );
              } else if (value == 'reorder') {
                _goToReorder();
              } else if (value == 'org') {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const OrgManagementPage()),
                );
                if (mounted) {
                  await _reloadAds();
                  setState(() {});
                }
              } else if (value == 'ad') {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AdManagementPage()),
                );
                if (mounted) {
                  await _reloadAds();
                  setState(() {});
                }
              } else if (value == 'superadmin') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SuperAdminPage()),
                );
              } else if (value == 'nickname') {
                _changeNickname();
              } else if (value == 'password') {
                _changePassword();
              } else if (value == 'leave') {
                _leaveOrg();
              } else if (value == 'terms') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const LegalPage(
                      title: '利用規約',
                      content: _kTermsOfService,
                    ),
                  ),
                );
              } else if (value == 'privacy') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const LegalPage(
                      title: 'プライバシーポリシー',
                      content: _kPrivacyPolicy,
                    ),
                  ),
                );
              } else if (value == 'feedback_feature') {
                _openFeedback('feature');
              } else if (value == 'feedback_fix') {
                _openFeedback('fix');
              } else if (value == 'feedback_bug') {
                _openFeedback('bug');
              } else if (value == 'logout') {
                FirebaseAuth.instance.signOut();
                AppSession.clear();
              } else if (value == 'delete_account') {
                _deleteAccount();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'all_stores',
                child: Row(
                  children: [
                    Icon(Icons.table_chart),
                    SizedBox(width: 12),
                    Text('全店舗在庫確認'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'history',
                child: Row(
                  children: [
                    Icon(Icons.history),
                    SizedBox(width: 12),
                    Text('修正・追加履歴'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'items',
                child: Row(
                  children: [
                    Icon(Icons.inventory_2),
                    SizedBox(width: 12),
                    Text('商品マスタ管理'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'order',
                child: Row(
                  children: [
                    Icon(Icons.shopping_cart),
                    SizedBox(width: 12),
                    Text('発注リスト'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'special_order',
                child: Row(
                  children: [
                    Icon(Icons.star_border),
                    SizedBox(width: 12),
                    Text('特別発注・新規発注'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'reorder',
                child: Row(
                  children: [
                    Icon(Icons.reorder),
                    SizedBox(width: 12),
                    Text('店舗の並び替え'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              if (AppSession.isAdmin)
                const PopupMenuItem(
                  value: 'org',
                  child: Row(
                    children: [
                      Icon(Icons.manage_accounts),
                      SizedBox(width: 12),
                      Text('組織管理'),
                    ],
                  ),
                ),
              if (AppSession.isAdmin)
                const PopupMenuItem(
                  value: 'ad',
                  child: Row(
                    children: [
                      Icon(Icons.campaign),
                      SizedBox(width: 12),
                      Text('広告スペース管理'),
                    ],
                  ),
                ),
              if (AppSession.isSuperAdmin)
                const PopupMenuItem(
                  value: 'superadmin',
                  child: Row(
                    children: [
                      Icon(
                        Icons.admin_panel_settings,
                        color: Colors.deepPurple,
                      ),
                      SizedBox(width: 12),
                      Text('統括管理', style: TextStyle(color: Colors.deepPurple)),
                    ],
                  ),
                ),
              if (!AppSession.isAdmin)
                const PopupMenuItem(
                  value: 'leave',
                  child: Row(
                    children: [
                      Icon(Icons.exit_to_app, color: Colors.orange),
                      SizedBox(width: 12),
                      Text('組織を脱退', style: TextStyle(color: Colors.orange)),
                    ],
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'nickname',
                child: Row(
                  children: [
                    Icon(Icons.badge_outlined),
                    SizedBox(width: 12),
                    Text('ニックネーム変更'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'password',
                child: Row(
                  children: [
                    Icon(Icons.lock_outline),
                    SizedBox(width: 12),
                    Text('パスワード変更'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'terms',
                child: Row(
                  children: [
                    Icon(Icons.article_outlined),
                    SizedBox(width: 12),
                    Text('利用規約'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'privacy',
                child: Row(
                  children: [
                    Icon(Icons.privacy_tip_outlined),
                    SizedBox(width: 12),
                    Text('プライバシーポリシー'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'feedback_feature',
                child: Row(
                  children: [
                    Icon(Icons.add_circle_outline, color: Colors.blue),
                    SizedBox(width: 12),
                    Text('機能追加依頼'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'feedback_fix',
                child: Row(
                  children: [
                    Icon(Icons.build_outlined, color: Colors.orange),
                    SizedBox(width: 12),
                    Text('修正依頼'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'feedback_bug',
                child: Row(
                  children: [
                    Icon(Icons.bug_report_outlined, color: Colors.red),
                    SizedBox(width: 12),
                    Text('バグ報告'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, color: Colors.red),
                    SizedBox(width: 12),
                    Text('ログアウト', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete_account',
                child: Row(
                  children: [
                    Icon(Icons.delete_forever, color: Colors.red),
                    SizedBox(width: 12),
                    Text('アカウント削除', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                enabled: false,
                child: Text(
                  'v$_appVersion',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: SelectableText('読み取りエラー\n\n$_error'),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        const Text(
                          '多店舗在庫管理システム',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '組織: ${AppSession.orgId.isEmpty ? "（未設定）" : AppSession.orgId}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppSession.orgId == 'legacy'
                                ? Colors.green.shade700
                                : Colors.orange.shade700,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Card(
                          child: ListTile(
                            title: const Text('店舗数'),
                            trailing: Text(
                              '${_stores.length} 件',
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        for (final store in _stores)
                          Card(
                            child: ListTile(
                              leading: CircleAvatar(
                                child: Text(
                                  store.code.isEmpty ? '-' : store.code,
                                ),
                              ),
                              title: Text(
                                store.name,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(store.id),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () async {
                                await _showFullScreenAd(context);
                                if (!context.mounted) return;
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        StoreInventoryPage(store: store),
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const AdBannerWidget(),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: AppSession.isAdmin
          ? Padding(
              padding: const EdgeInsets.only(bottom: 88),
              child: FloatingActionButton(
                onPressed: _addStore,
                tooltip: '店舗を追加',
                child: const Icon(Icons.add),
              ),
            )
          : null,
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
// ─────────────────────────────────────────────

class StoreInventoryPage extends StatefulWidget {
  const StoreInventoryPage({super.key, required this.store});

  final LegacyStore store;

  @override
  State<StoreInventoryPage> createState() => _StoreInventoryPageState();
}

class _StoreInventoryPageState extends State<StoreInventoryPage>
    with RouteAware {
  late Future<_InventoryData> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadInventory();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    appRouteObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    // 上に重なっていたページがポップされ、このページが再表示されたとき自動リフレッシュ
    _refresh();
  }

  Future<_InventoryData> _loadInventory() async {
    final results = await Future.wait([
      AppSession.doc('products').get(),
      AppSession.doc('testers').get(),
      AppSession.doc('equipments').get(),
      AppSession.doc('stocks').get(),
      AppSession.doc('baseline').get(),
      AppSession.doc('stocks_v2').get(),
      AppSession.doc('orders').get(),
    ]);

    final stocksData = results[3].data() ?? {};
    final baseStocksData = results[4].exists
        ? (results[4].data() ?? <String, dynamic>{})
        : <String, dynamic>{};
    final v2Raw = results[5].data() ?? {};

    final v2TMap = (v2Raw['testers'] is Map)
        ? Map<String, dynamic>.from(
            (v2Raw['testers'] as Map).map((k, v) => MapEntry(k.toString(), v)),
          )
        : <String, dynamic>{};
    final v2EMap = (v2Raw['equipments'] is Map)
        ? Map<String, dynamic>.from(
            (v2Raw['equipments'] as Map).map(
              (k, v) => MapEntry(k.toString(), v),
            ),
          )
        : <String, dynamic>{};

    final ordersRaw = results[6].exists
        ? (results[6].data() ?? <String, dynamic>{})
        : <String, dynamic>{};
    final ordersPMap = (ordersRaw['products'] is Map)
        ? Map<String, dynamic>.from(
            (ordersRaw['products'] as Map).map(
              (k, v) => MapEntry(k.toString(), v),
            ),
          )
        : <String, dynamic>{};
    final ordersTMap = (ordersRaw['testers'] is Map)
        ? Map<String, dynamic>.from(
            (ordersRaw['testers'] as Map).map(
              (k, v) => MapEntry(k.toString(), v),
            ),
          )
        : <String, dynamic>{};
    final ordersEMap = (ordersRaw['equipments'] is Map)
        ? Map<String, dynamic>.from(
            (ordersRaw['equipments'] as Map).map(
              (k, v) => MapEntry(k.toString(), v),
            ),
          )
        : <String, dynamic>{};

    return _InventoryData(
      products: _parseItemsFromDoc(results[0]),
      testers: _parseItemsFromDoc(results[1]),
      equipments: _parseItemsFromDoc(results[2]),
      productStocks: _parseStocksForStore(stocksData, widget.store.id),
      testerStocks: _parseStocksForStore(v2TMap, widget.store.id),
      equipmentStocks: _parseStocksForStore(v2EMap, widget.store.id),
      baseStocks: _parseStocksForStore(baseStocksData, widget.store.id),
      orderedProductStocks: _parseStocksForStore(ordersPMap, widget.store.id),
      orderedTesterStocks: _parseStocksForStore(ordersTMap, widget.store.id),
      orderedEquipmentStocks: _parseStocksForStore(ordersEMap, widget.store.id),
      productOrderMetas: _parseOrderMetasForStore(
        ordersRaw,
        'products',
        widget.store.id,
      ),
      testerOrderMetas: _parseOrderMetasForStore(
        ordersRaw,
        'testers',
        widget.store.id,
      ),
      equipmentOrderMetas: _parseOrderMetasForStore(
        ordersRaw,
        'equipments',
        widget.store.id,
      ),
    );
  }

  void _refresh() => setState(() => _future = _loadInventory());

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: const Color(0xFFFFF7FF),
        appBar: AppBar(
          title: Text(widget.store.name),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '再読み込み',
              onPressed: _refresh,
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '商品'),
              Tab(text: 'テスター'),
              Tab(text: '備品'),
            ],
          ),
        ),
        body: SafeArea(
          child: FutureBuilder<_InventoryData>(
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

              final data =
                  snapshot.data ??
                  const _InventoryData(
                    products: [],
                    testers: [],
                    equipments: [],
                    productStocks: {},
                    testerStocks: {},
                    equipmentStocks: {},
                    baseStocks: {},
                  );

              return TabBarView(
                children: [
                  _InventoryList(
                    title: '商品',
                    items: data.products,
                    stocks: data.productStocks,
                    baseStocks: data.baseStocks,
                    orderedStocks: data.orderedProductStocks,
                    orderMetas: data.productOrderMetas,
                    storeId: widget.store.id,
                    storeName: widget.store.name,
                    onDelivered: _refresh,
                  ),
                  _InventoryList(
                    title: 'テスター',
                    items: data.testers,
                    stocks: data.testerStocks,
                    baseStocks: data.baseStocks,
                    orderedStocks: data.orderedTesterStocks,
                    orderMetas: data.testerOrderMetas,
                    storeId: widget.store.id,
                    storeName: widget.store.name,
                    onDelivered: _refresh,
                  ),
                  _InventoryList(
                    title: '備品',
                    items: data.equipments,
                    stocks: data.equipmentStocks,
                    baseStocks: data.baseStocks,
                    orderedStocks: data.orderedEquipmentStocks,
                    orderMetas: data.equipmentOrderMetas,
                    storeId: widget.store.id,
                    storeName: widget.store.name,
                    onDelivered: _refresh,
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

// ─────────────────────────────────────────────
// 店舗別在庫リスト（編集・履歴記録あり）
// ─────────────────────────────────────────────

class _InventoryList extends StatefulWidget {
  const _InventoryList({
    required this.title,
    required this.items,
    required this.stocks,
    required this.baseStocks,
    required this.storeId,
    required this.storeName,
    this.orderedStocks = const {},
    this.orderMetas = const {},
    this.onDelivered,
  });

  final String title;
  final List<LegacyItem> items;
  final Map<String, int> stocks;
  final Map<String, int> baseStocks;
  final String storeId;
  final String storeName;
  final Map<String, int> orderedStocks;
  final Map<String, _OrderMeta> orderMetas;
  final VoidCallback? onDelivered;

  @override
  State<_InventoryList> createState() => _InventoryListState();
}

class _InventoryListState extends State<_InventoryList> {
  String _query = '';
  late Map<String, int> _localStocks;
  late Map<String, int> _localBaseStocks;
  Map<String, int> _localOrderedStocks = {};
  Map<String, _OrderMeta> _localOrderMetas = {};
  final Set<String> _changedIds = {};
  bool _saving = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _ordersSub;

  @override
  void initState() {
    super.initState();
    _localStocks = Map.from(widget.stocks);
    _localBaseStocks = Map.from(widget.baseStocks);
    _localOrderedStocks = Map.from(widget.orderedStocks);
    _localOrderMetas = Map.from(widget.orderMetas);
    _subscribeOrders();
  }

  void _subscribeOrders() {
    final typeKey = widget.title == '商品'
        ? 'products'
        : (widget.title == 'テスター' ? 'testers' : 'equipments');
    _ordersSub = AppSession.doc('orders').snapshots().listen((snap) {
      if (!mounted) return;
      final raw = snap.exists
          ? (snap.data() ?? <String, dynamic>{})
          : <String, dynamic>{};
      final typeMap = (raw[typeKey] is Map)
          ? raw[typeKey] as Map
          : <dynamic, dynamic>{};
      final storeData = (typeMap[widget.storeId] is Map)
          ? typeMap[widget.storeId] as Map
          : <dynamic, dynamic>{};
      final newQtys = <String, int>{};
      for (final e in storeData.entries) {
        final v = e.value;
        final qty = v is int
            ? v
            : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
        if (qty > 0) newQtys[e.key.toString()] = qty;
      }
      final newMetas = _parseOrderMetasForStore(
        Map<String, dynamic>.from(raw),
        typeKey,
        widget.storeId,
      );
      setState(() {
        _localOrderedStocks = newQtys;
        _localOrderMetas = newMetas;
      });
    });
  }

  @override
  void dispose() {
    _ordersSub?.cancel();
    super.dispose();
  }

  String get _typeKey => widget.title == '商品'
      ? 'products'
      : (widget.title == 'テスター' ? 'testers' : 'equipments');

  String _orderMetaField(String itemId) =>
      '_meta.${_typeKey}__${widget.storeId}__$itemId';

  List<MapEntry<String, _OrderMeta>> get _unacknowledgedOrders =>
      _localOrderMetas.entries
          .where(
            (entry) =>
                (_localOrderedStocks[entry.key] ?? 0) > 0 &&
                entry.value.needsAcknowledgement,
          )
          .toList();

  Future<void> _acknowledgeOrders(BuildContext context) async {
    final targets = _unacknowledgedOrders;
    if (targets.isEmpty) return;
    final updates = <String, dynamic>{};
    for (final entry in targets) {
      updates['${_orderMetaField(entry.key)}.acknowledgedAt'] =
          FieldValue.serverTimestamp();
      updates['${_orderMetaField(entry.key)}.acknowledgedBy'] =
          AppSession.nickname;
    }
    try {
      await AppSession.doc('orders').update(updates);
      setState(() {
        for (final entry in targets) {
          final old = entry.value;
          _localOrderMetas[entry.key] = _OrderMeta(
            requestedAt: old.requestedAt,
            orderedAt: old.orderedAt,
            acknowledgedAt: DateTime.now(),
            requestedBy: old.requestedBy,
            orderedBy: old.orderedBy,
            acknowledgedBy: AppSession.nickname,
          );
        }
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('発注通知を確認済みにしました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('確認済み更新失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deliver(BuildContext context, LegacyItem item) async {
    final orderedQty = _localOrderedStocks[item.id] ?? 0;
    if (orderedQty <= 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('納品確認'),
        content: Text('${item.name}\n${orderedQty}個を納品し、在庫数に加算します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('納品する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final newStock = (_localStocks[item.id] ?? 0) + orderedQty;
    final typeKey = widget.title == '商品'
        ? 'products'
        : (widget.title == 'テスター' ? 'testers' : 'equipments');

    try {
      // 発注済数をクリア
      final ordersRef = AppSession.doc('orders');
      try {
        await ordersRef.update({
          '$typeKey.${widget.storeId}.${item.id}': FieldValue.delete(),
          '${_orderMetaField(item.id)}': FieldValue.delete(),
        });
      } on FirebaseException catch (e) {
        if (e.code != 'not-found') rethrow;
      }

      // 在庫数更新
      if (widget.title == '商品') {
        try {
          await AppSession.doc(
            'stocks',
          ).update({'${widget.storeId}.${item.id}': newStock});
        } on FirebaseException catch (e) {
          if (e.code == 'not-found') {
            await AppSession.doc('stocks').set({
              widget.storeId: {item.id: newStock},
            });
          } else {
            rethrow;
          }
        }
      } else {
        final stockTypeKey = widget.title == 'テスター' ? 'testers' : 'equipments';
        try {
          await AppSession.doc(
            'stocks_v2',
          ).update({'$stockTypeKey.${widget.storeId}.${item.id}': newStock});
        } on FirebaseException catch (e) {
          if (e.code == 'not-found') {
            await AppSession.doc('stocks_v2').set({
              stockTypeKey: {
                widget.storeId: {item.id: newStock},
              },
            });
          } else {
            rethrow;
          }
        }
      }

      // 履歴記録
      await AppSession.doc('history').collection('entries').add({
        'at': FieldValue.serverTimestamp(),
        'storeId': widget.storeId,
        'storeName': widget.storeName,
        'itemId': item.id,
        'itemName': item.name,
        'itemType': widget.title,
        'oldCount': _localStocks[item.id] ?? 0,
        'newCount': newStock,
        'nickName': AppSession.nickname,
      });

      setState(() {
        _localStocks[item.id] = newStock;
        _localOrderedStocks[item.id] = 0;
        _localOrderMetas.remove(item.id);
      });

      widget.onDelivered?.call();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${item.name}: ${orderedQty}個納品しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('納品失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showBaseStockInput(
    BuildContext context,
    LegacyItem item,
  ) async {
    final controller = TextEditingController(
      text: '${_localBaseStocks[item.id] ?? 0}',
    );
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('基準在庫: ${item.name}'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '基準在庫数',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              Navigator.of(ctx).pop(value);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || result < 0) return;

    setState(() => _localBaseStocks[item.id] = result);

    final docRef = AppSession.doc('baseline');
    final updates = <String, dynamic>{'${widget.storeId}.${item.id}': result};
    try {
      await docRef.update(updates);
    } on FirebaseException catch (e) {
      if (e.code == 'not-found') {
        await docRef.set({
          widget.storeId: {item.id: result},
        });
      } else {
        rethrow;
      }
    }
  }

  void _increment(String id) {
    setState(() {
      _localStocks[id] = (_localStocks[id] ?? 0) + 1;
      _changedIds.add(id);
    });
  }

  void _decrement(String id) {
    final current = _localStocks[id] ?? 0;
    if (current <= 0) return;
    setState(() {
      _localStocks[id] = current - 1;
      _changedIds.add(id);
    });
  }

  Future<void> _showDirectInput(BuildContext context, LegacyItem item) async {
    final controller = TextEditingController(
      text: '${_localStocks[item.id] ?? 0}',
    );
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.name),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '在庫数',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              Navigator.of(ctx).pop(value);
            },
            child: const Text('セット'),
          ),
        ],
      ),
    );
    if (result != null && result >= 0) {
      setState(() {
        _localStocks[item.id] = result;
        _changedIds.add(item.id);
      });
    }
  }

  Future<void> _save(BuildContext context) async {
    if (_changedIds.isEmpty || _saving) return;

    final changes = _changedIds.map((id) {
      final item = widget.items.firstWhere(
        (i) => i.id == id,
        orElse: () => LegacyItem(id: id, code: '', name: id),
      );
      final oldCount = widget.stocks[id] ?? 0;
      final newCount = _localStocks[id] ?? 0;
      return (item: item, oldCount: oldCount, newCount: newCount);
    }).toList();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('在庫を更新しますか？'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in changes)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '• ${c.item.name}: ${c.oldCount} → ${c.newCount}',
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存する'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _saving = true);

    try {
      // 在庫更新（商品はv1、テスター・備品はv2）
      final Map<String, dynamic> stockUpdates = {};
      if (widget.title == '商品') {
        for (final id in _changedIds) {
          stockUpdates['${widget.storeId}.$id'] = _localStocks[id] ?? 0;
        }
        await AppSession.doc('stocks').update(stockUpdates);
      } else {
        final typeKey = widget.title == 'テスター' ? 'testers' : 'equipments';
        for (final id in _changedIds) {
          stockUpdates['$typeKey.${widget.storeId}.$id'] =
              _localStocks[id] ?? 0;
        }
        final v2Ref = AppSession.doc('stocks_v2');
        try {
          await v2Ref.update(stockUpdates);
        } on FirebaseException catch (e) {
          if (e.code == 'not-found') {
            await v2Ref.set(<String, dynamic>{
              typeKey: {
                widget.storeId: {
                  for (final id in _changedIds) id: _localStocks[id] ?? 0,
                },
              },
            });
          } else {
            rethrow;
          }
        }
      }

      // 履歴書き込み
      final historyRef = AppSession.doc('history').collection('entries');

      final batch = FirebaseFirestore.instance.batch();
      for (final c in changes) {
        batch.set(historyRef.doc(), {
          'at': FieldValue.serverTimestamp(),
          'storeId': widget.storeId,
          'storeName': widget.storeName,
          'itemId': c.item.id,
          'itemName': c.item.name,
          'itemType': widget.title,
          'oldCount': c.oldCount,
          'newCount': c.newCount,
          'nickName': AppSession.nickname,
          'uid': AppSession.uid,
        });
      }
      await batch.commit();

      setState(() {
        _changedIds.clear();
        _saving = false;
      });

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('保存しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() => _saving = false);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.items.where((item) {
      final q = _query.trim().toLowerCase();
      if (q.isEmpty) return true;
      return item.name.toLowerCase().contains(q) ||
          item.code.toLowerCase().contains(q);
    }).toList();

    // 発注済アイテムを先頭に表示
    filtered.sort((a, b) {
      final aOrdered = (_localOrderedStocks[a.id] ?? 0) > 0 ? 0 : 1;
      final bOrdered = (_localOrderedStocks[b.id] ?? 0) > 0 ? 0 : 1;
      return aOrdered.compareTo(bOrdered);
    });

    final orderedCount = _localOrderedStocks.values.where((v) => v > 0).length;
    final unacknowledgedOrders = _unacknowledgedOrders;
    final latestOrderDate = unacknowledgedOrders
        .map((entry) => entry.value.orderedAt)
        .whereType<DateTime>()
        .fold<DateTime?>(
          null,
          (latest, date) =>
              latest == null || date.isAfter(latest) ? date : latest,
        );

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '検索...',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 8),
              if (unacknowledgedOrders.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    border: Border.all(color: Colors.red.shade200),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.notifications_active_outlined,
                        color: Colors.red.shade700,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          latestOrderDate == null
                              ? 'PDF発行済み・未確認の${widget.title}があります'
                              : 'PDF発行済み・未確認: ${unacknowledgedOrders.length}品目\n発注日: ${_formatDateTime(latestOrderDate)}',
                          style: TextStyle(
                            color: Colors.red.shade800,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => _acknowledgeOrders(context),
                        child: const Text('確認済み'),
                      ),
                    ],
                  ),
                ),
              if (orderedCount > 0)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    border: Border.all(color: Colors.orange.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.local_shipping_outlined,
                        color: Colors.orange.shade700,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '発注済 $orderedCount 品目（リスト先頭に表示中）',
                        style: TextStyle(
                          color: Colors.orange.shade800,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              Card(
                child: ListTile(
                  title: Text('${widget.title}数'),
                  trailing: Text(
                    '${filtered.length} 件',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final item in filtered)
                Card(
                  color: item.discontinued ? Colors.grey.shade100 : null,
                  child: ListTile(
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.name,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: item.discontinued ? Colors.grey : null,
                              decoration: item.discontinued
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                        if (item.discontinued)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '販売終了',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('コード: ${item.code}'),
                        if ((_localOrderedStocks[item.id] ?? 0) > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.shade100,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    _localOrderMetas[item.id]?.orderedAt == null
                                        ? '発注済: ${_localOrderedStocks[item.id]}'
                                        : '発注済: ${_localOrderedStocks[item.id]} / ${_formatDateTime(_localOrderMetas[item.id]!.orderedAt!)}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.orange.shade800,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                InkWell(
                                  onTap: () => _deliver(context, item),
                                  borderRadius: BorderRadius.circular(4),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.green.shade100,
                                      border: Border.all(
                                        color: Colors.green.shade400,
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '納品',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.green.shade800,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: () => _showBaseStockInput(context, item),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: item.discontinued
                                  ? Colors.grey.shade100
                                  : Colors.blue.shade50,
                              border: Border.all(
                                color: item.discontinued
                                    ? Colors.grey.shade300
                                    : Colors.blue.shade200,
                              ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '基準',
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: item.discontinued
                                        ? Colors.grey
                                        : Colors.blue.shade600,
                                  ),
                                ),
                                Text(
                                  '${_localBaseStocks[item.id] ?? 0}',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: item.discontinued
                                        ? Colors.grey
                                        : Colors.blue.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          color: item.discontinued
                              ? Colors.grey
                              : Colors.redAccent,
                          onPressed: () => _decrement(item.id),
                        ),
                        GestureDetector(
                          onLongPress: () => _showDirectInput(context, item),
                          child: Container(
                            constraints: const BoxConstraints(minWidth: 48),
                            alignment: Alignment.center,
                            child: Text(
                              '${_localStocks[item.id] ?? 0}',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: () {
                                  if (item.discontinued) return Colors.grey;
                                  final cur = _localStocks[item.id] ?? 0;
                                  final base = _localBaseStocks[item.id] ?? 0;
                                  if (base > 0 && cur < base) return Colors.red;
                                  if (_changedIds.contains(item.id))
                                    return Colors.orange;
                                  return null;
                                }(),
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          color: item.discontinued ? Colors.grey : Colors.green,
                          onPressed: () => _increment(item.id),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_changedIds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ElevatedButton.icon(
              onPressed: _saving ? null : () => _save(context),
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(
                _saving ? '保存中...' : '${_changedIds.length}件の変更を保存する',
              ),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// 商品マスタ管理ページ
// ─────────────────────────────────────────────

class ItemMasterPage extends StatelessWidget {
  const ItemMasterPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: const Color(0xFFFFF7FF),
        appBar: AppBar(
          title: const Text('商品マスタ管理'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '商品'),
              Tab(text: 'テスター'),
              Tab(text: '備品'),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              _ItemMasterTab(
                docId: 'org_${AppSession.orgId}__products',
                label: '商品',
              ),
              _ItemMasterTab(
                docId: 'org_${AppSession.orgId}__testers',
                label: 'テスター',
              ),
              _ItemMasterTab(
                docId: 'org_${AppSession.orgId}__equipments',
                label: '備品',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemMasterTab extends StatefulWidget {
  const _ItemMasterTab({required this.docId, required this.label});

  final String docId;
  final String label;

  @override
  State<_ItemMasterTab> createState() => _ItemMasterTabState();
}

class _ItemMasterTabState extends State<_ItemMasterTab> {
  List<Map<String, dynamic>> _rawItems = [];
  List<LegacyItem> _items = [];
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final doc = await FirebaseFirestore.instance
          .collection('inventory_shared_v1')
          .doc(widget.docId)
          .get();
      final raw = doc.data()?['items'];
      final rawItems = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final item in raw.whereType<Map>()) {
          final map = Map<String, dynamic>.from(
            item.map((k, v) => MapEntry(k.toString(), v)),
          );
          if ((map['id'] ?? '').toString().isNotEmpty) rawItems.add(map);
        }
      }
      setState(() {
        _rawItems = rawItems;
        _items = _sorted(rawItems);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<LegacyItem> _sorted(List<Map<String, dynamic>> raw) {
    final items = raw
        .map((m) => LegacyItem.fromMap(m))
        .where((i) => i.id.isNotEmpty)
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

  Future<void> _persist() async {
    await FirebaseFirestore.instance
        .collection('inventory_shared_v1')
        .doc(widget.docId)
        .update({'items': _rawItems});
  }

  Future<Map<String, String>?> _showItemDialog({
    String? initialCode,
    String? initialName,
  }) async {
    final codeCtrl = TextEditingController(text: initialCode ?? '');
    final nameCtrl = TextEditingController(text: initialName ?? '');
    final isNew = initialName == null;
    return showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isNew ? '${widget.label}を追加' : '${widget.label}を編集'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: codeCtrl,
              decoration: const InputDecoration(
                labelText: 'コード',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '名前 *',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              Navigator.of(
                ctx,
              ).pop({'code': codeCtrl.text.trim(), 'name': name});
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _addItem() async {
    final result = await _showItemDialog();
    if (result == null) return;

    final newId = FirebaseFirestore.instance.collection('_').doc().id;
    setState(() {
      _rawItems.add({
        'id': newId,
        'code': result['code']!,
        'name': result['name']!,
      });
      _items = _sorted(_rawItems);
    });

    try {
      await _persist();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${result['name']} を追加しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _rawItems.removeWhere((m) => m['id'] == newId);
        _items = _sorted(_rawItems);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('追加失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _editItem(LegacyItem item) async {
    final result = await _showItemDialog(
      initialCode: item.code,
      initialName: item.name,
    );
    if (result == null) return;

    final idx = _rawItems.indexWhere((m) => m['id'] == item.id);
    if (idx < 0) return;

    final oldMap = Map<String, dynamic>.from(_rawItems[idx]);
    setState(() {
      _rawItems[idx] = Map<String, dynamic>.from(_rawItems[idx])
        ..['code'] = result['code']!
        ..['name'] = result['name']!;
      _items = _sorted(_rawItems);
    });

    try {
      await _persist();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${result['name']} を更新しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _rawItems[idx] = oldMap;
        _items = _sorted(_rawItems);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _toggleDiscontinued(LegacyItem item) async {
    final idx = _rawItems.indexWhere((m) => m['id'] == item.id);
    if (idx < 0) return;
    final newVal = !item.discontinued;
    final oldMap = Map<String, dynamic>.from(_rawItems[idx]);
    setState(() {
      _rawItems[idx] = Map<String, dynamic>.from(_rawItems[idx])
        ..['discontinued'] = newVal;
      _items = _sorted(_rawItems);
    });
    try {
      await _persist();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              newVal
                  ? '「${item.name}」を販売終了にしました'
                  : '「${item.name}」の販売終了を解除しました',
            ),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _rawItems[idx] = oldMap;
        _items = _sorted(_rawItems);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteItem(LegacyItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除しますか？'),
        content: Text('「${item.name}」を削除します。\n各店舗の在庫データはそのまま残ります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final removedIdx = _rawItems.indexWhere((m) => m['id'] == item.id);
    if (removedIdx < 0) return;
    final removedMap = Map<String, dynamic>.from(_rawItems[removedIdx]);

    setState(() {
      _rawItems.removeAt(removedIdx);
      _items = _sorted(_rawItems);
    });

    try {
      await _persist();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${item.name} を削除しました'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _rawItems.insert(removedIdx, removedMap);
        _items = _sorted(_rawItems);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('削除失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            SelectableText('読み取りエラー\n\n$_error'),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _load, child: const Text('再読み込み')),
          ],
        ),
      );
    }

    final filtered = _items.where((item) {
      final q = _query.trim().toLowerCase();
      if (q.isEmpty) return true;
      return item.name.toLowerCase().contains(q) ||
          item.code.toLowerCase().contains(q);
    }).toList();

    return Column(
      children: [
        Expanded(
          child: ListView(
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
                  title: Text('${widget.label}数'),
                  trailing: Text(
                    '${_items.length} 件',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final item in filtered)
                Card(
                  color: item.discontinued ? Colors.grey.shade100 : null,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: item.discontinued
                          ? Colors.grey.shade300
                          : null,
                      child: Text(
                        item.code.isEmpty ? '-' : item.code,
                        style: TextStyle(
                          fontSize: 12,
                          color: item.discontinued ? Colors.grey : null,
                        ),
                      ),
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.name,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: item.discontinued ? Colors.grey : null,
                              decoration: item.discontinued
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                        if (item.discontinued)
                          Container(
                            margin: const EdgeInsets.only(left: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade400,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '販売終了',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                    subtitle: Text('コード: ${item.code}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: item.discontinued ? '販売終了を解除' : '販売終了にする',
                          icon: Icon(
                            item.discontinued ? Icons.replay : Icons.block,
                            color: item.discontinued
                                ? Colors.green
                                : Colors.orange,
                          ),
                          onPressed: () => _toggleDiscontinued(item),
                        ),
                        if (AppSession.isAdmin) ...[
                          IconButton(
                            icon: const Icon(Icons.edit),
                            onPressed: () => _editItem(item),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                            ),
                            onPressed: () => _deleteItem(item),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _addItem,
              icon: const Icon(Icons.add),
              label: Text(
                '${widget.label}を追加',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

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
  });

  final DateTime? requestedAt;
  final DateTime? orderedAt;
  final DateTime? acknowledgedAt;
  final String requestedBy;
  final String orderedBy;
  final String acknowledgedBy;

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

class OrderListPage extends StatefulWidget {
  const OrderListPage({super.key});

  @override
  State<OrderListPage> createState() => _OrderListPageState();
}

class _OrderListPageState extends State<OrderListPage> {
  List<_OrderEntry> _entries = [];
  bool _loading = true;
  String? _error;
  final Set<String> _selectedTypes = {'商品', 'テスター', '備品'};
  // key: "${storeId}_${itemType}_${itemId}"
  final Map<String, int> _orderedQtys = {};
  final Map<String, _OrderMeta> _orderMetas = {};
  final Map<String, TextEditingController> _qtyControllers = {};

  static const _types = ['商品', 'テスター', '備品'];

  String _typeKeyForType(String itemType) => itemType == '商品'
      ? 'products'
      : (itemType == 'テスター' ? 'testers' : 'equipments');

  String _orderMetaKey(String typeKey, String storeId, String itemId) =>
      '${typeKey}__${storeId}__${itemId}';

  String _orderMetaField(_OrderEntry entry) =>
      '_meta.${_orderMetaKey(_typeKeyForType(entry.itemType), entry.store.id, entry.item.id)}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _qtyControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _orderKey(_OrderEntry e) => '${e.store.id}_${e.itemType}_${e.item.id}';

  TextEditingController _controllerFor(_OrderEntry e) {
    final key = _orderKey(e);
    return _qtyControllers.putIfAbsent(
      key,
      () => TextEditingController(
        text: '${e.effectiveShortage > 0 ? e.effectiveShortage : 1}',
      ),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        AppSession.doc('stores').get(),
        AppSession.doc('products').get(),
        AppSession.doc('testers').get(),
        AppSession.doc('equipments').get(),
        AppSession.doc('stocks').get(),
        AppSession.doc('baseline').get(),
        AppSession.doc('stocks_v2').get(),
        AppSession.doc('orders').get(),
      ]);

      final storesRaw = results[0].data() ?? {};
      final stores = _parseStores(storesRaw);
      final products = _parseItemsFromDoc(results[1]);
      final testers = _parseItemsFromDoc(results[2]);
      final equipments = _parseItemsFromDoc(results[3]);
      final stocksData = results[4].data() ?? {};
      final baseDoc = results[5];
      final baseData = baseDoc.exists
          ? (baseDoc.data() ?? <String, dynamic>{})
          : <String, dynamic>{};
      final v2Raw = results[6].data() ?? {};
      final v2TMap = (v2Raw['testers'] is Map) ? v2Raw['testers'] as Map : {};
      final v2EMap = (v2Raw['equipments'] is Map)
          ? v2Raw['equipments'] as Map
          : {};

      final ordersRaw = results[7].exists
          ? (results[7].data() ?? <String, dynamic>{})
          : <String, dynamic>{};
      final Map<String, int> orderedQtys = {};
      final Map<String, _OrderMeta> orderMetas = {};
      final metaRaw = (ordersRaw['_meta'] is Map)
          ? ordersRaw['_meta'] as Map
          : <dynamic, dynamic>{};
      for (final metaEntry in metaRaw.entries) {
        if (metaEntry.value is Map) {
          orderMetas[metaEntry.key.toString()] = _OrderMeta.fromMap(
            metaEntry.value as Map,
          );
        }
      }

      for (final typeKey in ['products', 'testers', 'equipments']) {
        final typeName = typeKey == 'products'
            ? '商品'
            : (typeKey == 'testers' ? 'テスター' : '備品');
        final typeMap = (ordersRaw[typeKey] is Map)
            ? ordersRaw[typeKey] as Map
            : {};
        for (final storeEntry in typeMap.entries) {
          final storeId = storeEntry.key.toString();
          final storeData = storeEntry.value is Map
              ? storeEntry.value as Map
              : {};
          for (final itemEntry in storeData.entries) {
            final itemId = itemEntry.key.toString();
            final qty = itemEntry.value is int
                ? itemEntry.value as int
                : int.tryParse('${itemEntry.value}') ?? 0;
            if (qty > 0) {
              orderedQtys['${storeId}_${typeName}_$itemId'] = qty;
            }
          }
        }
      }

      final entries = <_OrderEntry>[];
      for (final store in stores) {
        final stocks = _parseMergedStocksForStore(
          stocksData,
          v2TMap,
          v2EMap,
          store.id,
        );
        final bases = _parseStocksForStore(baseData, store.id);

        for (final typeEntry in <(String, List<LegacyItem>)>[
          ('商品', products),
          ('テスター', testers),
          ('備品', equipments),
        ]) {
          final typeName = typeEntry.$1;
          final typeKey = _typeKeyForType(typeName);
          final items = typeEntry.$2;
          for (final item in items) {
            if (item.discontinued) continue;
            final b = bases[item.id] ?? 0;
            if (b <= 0) continue;
            final c = stocks[item.id] ?? 0;
            final orderedQty =
                orderedQtys['${store.id}_${typeName}_${item.id}'] ?? 0;
            final metaKey = _orderMetaKey(typeKey, store.id, item.id);
            final effectiveShortage = max(0, b - c - orderedQty);
            if (effectiveShortage > 0 || orderedQty > 0) {
              final entry = _OrderEntry(
                store: store,
                item: item,
                itemType: typeName,
                current: c,
                base: b,
                orderedQty: orderedQty,
                orderMeta: orderMetas[metaKey] ?? const _OrderMeta(),
              );
              entries.add(entry);
              final key = '${store.id}_${typeName}_${item.id}';
              _qtyControllers.putIfAbsent(
                key,
                () => TextEditingController(
                  text:
                      '${entry.effectiveShortage > 0 ? entry.effectiveShortage : 1}',
                ),
              );
            }
          }
        }
      }

      setState(() {
        _entries = entries;
        _orderedQtys
          ..clear()
          ..addAll(orderedQtys);
        _orderMetas
          ..clear()
          ..addAll(orderMetas);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _placeOrder(
    BuildContext context,
    _OrderEntry entry,
    int qty,
  ) async {
    if (qty <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('発注数は1以上を入力してください')));
      return;
    }
    final typeKey = _typeKeyForType(entry.itemType);
    final existingQty = _orderedQtys[_orderKey(entry)] ?? 0;
    final totalQty = existingQty + qty;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('発注リスト追加確認'),
        content: Text(
          existingQty > 0
              ? '${entry.store.name}\n${entry.item.name}\n既存の未納品: $existingQty個\n追加: $qty個\n合計: $totalQty個で発注リストに登録します。'
              : '${entry.store.name}\n${entry.item.name}\nを ${qty}個、発注リストに登録します。\n\n※正式な発注日はPDF発行時に記録されます。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('登録する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final ordersRef = AppSession.doc('orders');
      final update = {
        '$typeKey.${entry.store.id}.${entry.item.id}': totalQty,
        '${_orderMetaField(entry)}.requestedAt': FieldValue.serverTimestamp(),
        '${_orderMetaField(entry)}.requestedBy': AppSession.nickname,
        '${_orderMetaField(entry)}.storeName': entry.store.name,
        '${_orderMetaField(entry)}.itemName': entry.item.name,
        '${_orderMetaField(entry)}.itemType': entry.itemType,
      };
      try {
        await ordersRef.update(update);
      } on FirebaseException catch (e) {
        if (e.code == 'not-found') {
          await ordersRef.set({
            typeKey: {
              entry.store.id: {entry.item.id: totalQty},
            },
            '_meta': {
              _orderMetaKey(typeKey, entry.store.id, entry.item.id): {
                'requestedAt': FieldValue.serverTimestamp(),
                'requestedBy': AppSession.nickname,
                'storeName': entry.store.name,
                'itemName': entry.item.name,
                'itemType': entry.itemType,
              },
            },
          });
        } else {
          rethrow;
        }
      }

      setState(() => _orderedQtys[_orderKey(entry)] = totalQty);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${entry.store.name}：${entry.item.name} を発注リストに登録しました',
            ),
            backgroundColor: Colors.blue,
          ),
        );
      }
      await _load();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('発注登録失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _placeBulkOrder(
    BuildContext context,
    LegacyStore store,
    String typeName,
    List<_OrderEntry> entries,
  ) async {
    final targetEntries = entries
        .where((e) => e.effectiveShortage > 0)
        .toList();
    if (targetEntries.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${store.name}  $typeName 一括登録'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '未納品の発注済み数を差し引いた不足分だけ登録します。',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                for (final e in targetEntries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${e.item.name}',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        Text(
                          '${e.effectiveShortage}個',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.red,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('一括登録する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final typeKey = _typeKeyForType(typeName);

    try {
      final Map<String, dynamic> updates = {};
      for (final e in targetEntries) {
        final existing = _orderedQtys[_orderKey(e)] ?? 0;
        final total = existing + e.effectiveShortage;
        updates['$typeKey.${store.id}.${e.item.id}'] = total;
        updates['${_orderMetaField(e)}.requestedAt'] =
            FieldValue.serverTimestamp();
        updates['${_orderMetaField(e)}.requestedBy'] = AppSession.nickname;
        updates['${_orderMetaField(e)}.storeName'] = e.store.name;
        updates['${_orderMetaField(e)}.itemName'] = e.item.name;
        updates['${_orderMetaField(e)}.itemType'] = e.itemType;
      }
      final ordersRef = AppSession.doc('orders');
      try {
        await ordersRef.update(updates);
      } on FirebaseException catch (ex) {
        if (ex.code == 'not-found') {
          await ordersRef.set({
            typeKey: {
              store.id: {
                for (final e in targetEntries) e.item.id: e.effectiveShortage,
              },
            },
            '_meta': {
              for (final e in targetEntries)
                _orderMetaKey(typeKey, store.id, e.item.id): {
                  'requestedAt': FieldValue.serverTimestamp(),
                  'requestedBy': AppSession.nickname,
                  'storeName': e.store.name,
                  'itemName': e.item.name,
                  'itemType': e.itemType,
                },
            },
          });
        } else {
          rethrow;
        }
      }

      setState(() {
        for (final e in targetEntries) {
          final existing = _orderedQtys[_orderKey(e)] ?? 0;
          _orderedQtys[_orderKey(e)] = existing + e.effectiveShortage;
        }
      });

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${store.name} $typeName ${targetEntries.length}品目を発注リストに登録しました',
            ),
            backgroundColor: Colors.blue,
          ),
        );
      }
      await _load();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('一括登録失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deliverFromOrderList(
    BuildContext context,
    _OrderEntry entry,
  ) async {
    final key = _orderKey(entry);
    final orderedQty = _orderedQtys[key] ?? 0;
    if (orderedQty <= 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('納品確認'),
        content: Text(
          '${entry.store.name}\n${entry.item.name}\n${orderedQty}個を納品し、在庫数に加算します。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('納品する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final newStock = entry.current + orderedQty;
    final typeKey = entry.itemType == '商品'
        ? 'products'
        : (entry.itemType == 'テスター' ? 'testers' : 'equipments');

    try {
      // 発注済数クリア
      final ordersRef = AppSession.doc('orders');
      try {
        await ordersRef.update({
          '$typeKey.${entry.store.id}.${entry.item.id}': FieldValue.delete(),
          '${_orderMetaField(entry)}': FieldValue.delete(),
        });
      } on FirebaseException catch (e) {
        if (e.code != 'not-found') rethrow;
      }

      // 在庫数更新
      if (entry.itemType == '商品') {
        try {
          await AppSession.doc(
            'stocks',
          ).update({'${entry.store.id}.${entry.item.id}': newStock});
        } on FirebaseException catch (e) {
          if (e.code == 'not-found') {
            await AppSession.doc('stocks').set({
              entry.store.id: {entry.item.id: newStock},
            });
          } else {
            rethrow;
          }
        }
      } else {
        final stockTypeKey = entry.itemType == 'テスター'
            ? 'testers'
            : 'equipments';
        try {
          await AppSession.doc('stocks_v2').update({
            '$stockTypeKey.${entry.store.id}.${entry.item.id}': newStock,
          });
        } on FirebaseException catch (e) {
          if (e.code == 'not-found') {
            await AppSession.doc('stocks_v2').set({
              stockTypeKey: {
                entry.store.id: {entry.item.id: newStock},
              },
            });
          } else {
            rethrow;
          }
        }
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${entry.store.name}：${entry.item.name} ${orderedQty}個納品完了',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
      await _load();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('納品失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<List<_OrderEntry>> _orderedEntriesForPdf(
    BuildContext context,
    List<_OrderEntry> entries,
  ) async {
    final ordered = entries
        .where((e) => (_orderedQtys[_orderKey(e)] ?? e.orderedQty) > 0)
        .toList();
    if (ordered.isEmpty && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('PDFに出力する発注済み商品がありません'),
          backgroundColor: Colors.orange,
        ),
      );
    }
    return ordered;
  }

  Future<void> _markPdfIssued(List<_OrderEntry> entries) async {
    if (entries.isEmpty) return;
    final updates = <String, dynamic>{};
    for (final e in entries) {
      updates['${_orderMetaField(e)}.orderedAt'] = FieldValue.serverTimestamp();
      updates['${_orderMetaField(e)}.orderedBy'] = AppSession.nickname;
      updates['${_orderMetaField(e)}.acknowledgedAt'] = FieldValue.delete();
      updates['${_orderMetaField(e)}.acknowledgedBy'] = FieldValue.delete();
    }
    await AppSession.doc('orders').update(updates);
  }

  Future<void> _exportPdfByStore(
    BuildContext context,
    List<_OrderEntry> entries,
  ) async {
    final pdfEntries = await _orderedEntriesForPdf(context, entries);
    if (pdfEntries.isEmpty) return;

    final font = await PdfGoogleFonts.notoSansJPRegular();
    final doc = pw.Document();

    final byStore = <LegacyStore, List<_OrderEntry>>{};
    for (final e in pdfEntries) {
      byStore.putIfAbsent(e.store, () => []).add(e);
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        theme: pw.ThemeData.withFont(base: font),
        header: (ctx) => pw.Text(
          '発注済みリスト（店舗別）',
          style: pw.TextStyle(
            font: font,
            fontSize: 18,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        build: (ctx) {
          final widgets = <pw.Widget>[];
          widgets.add(
            pw.Text(
              'PDF発行日時: ${_formatDateTime(DateTime.now())}',
              style: pw.TextStyle(font: font, fontSize: 10),
            ),
          );
          byStore.forEach((store, storeEntries) {
            widgets.add(pw.SizedBox(height: 12));
            widgets.add(
              pw.Text(
                '■ ${store.name}',
                style: pw.TextStyle(
                  font: font,
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            );
            widgets.add(pw.SizedBox(height: 4));
            widgets.add(
              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey400),
                columnWidths: {
                  0: const pw.FlexColumnWidth(1.2),
                  1: const pw.FlexColumnWidth(2.7),
                  2: const pw.FlexColumnWidth(1),
                  3: const pw.FlexColumnWidth(0.8),
                  4: const pw.FlexColumnWidth(0.8),
                  5: const pw.FlexColumnWidth(0.9),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(
                      color: PdfColors.grey200,
                    ),
                    children: [
                      _pdfCell('コード', font, bold: true),
                      _pdfCell('商品名', font, bold: true),
                      _pdfCell('種別', font, bold: true),
                      _pdfCell('基準', font, bold: true),
                      _pdfCell('現在', font, bold: true),
                      _pdfCell('発注数', font, bold: true),
                    ],
                  ),
                  for (final e in storeEntries)
                    pw.TableRow(
                      children: [
                        _pdfCell(e.item.code, font),
                        _pdfCell(e.item.name, font),
                        _pdfCell(e.itemType, font),
                        _pdfCell('${e.base}', font),
                        _pdfCell('${e.current}', font),
                        _pdfCell(
                          '${_orderedQtys[_orderKey(e)] ?? e.orderedQty}',
                          font,
                          color: PdfColors.blue700,
                        ),
                      ],
                    ),
                ],
              ),
            );
          });
          return widgets;
        },
      ),
    );

    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: '発注済みリスト_店舗別.pdf',
    );
    await _markPdfIssued(pdfEntries);
    await _load();
  }

  Future<void> _exportPdfByItem(
    BuildContext context,
    List<_OrderEntry> entries,
  ) async {
    final pdfEntries = await _orderedEntriesForPdf(context, entries);
    if (pdfEntries.isEmpty) return;

    final font = await PdfGoogleFonts.notoSansJPRegular();
    final doc = pw.Document();

    final byTypeByItem = <String, Map<String, List<_OrderEntry>>>{};
    for (final e in pdfEntries) {
      byTypeByItem.putIfAbsent(e.itemType, () => {});
      byTypeByItem[e.itemType]!.putIfAbsent(e.item.id, () => []).add(e);
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        theme: pw.ThemeData.withFont(base: font),
        header: (ctx) => pw.Text(
          '発注済みリスト（商品別）',
          style: pw.TextStyle(
            font: font,
            fontSize: 18,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        build: (ctx) {
          final widgets = <pw.Widget>[];
          widgets.add(
            pw.Text(
              'PDF発行日時: ${_formatDateTime(DateTime.now())}',
              style: pw.TextStyle(font: font, fontSize: 10),
            ),
          );
          for (final type in _types) {
            if (!byTypeByItem.containsKey(type)) continue;
            widgets.add(pw.SizedBox(height: 12));
            widgets.add(
              pw.Text(
                '■ $type',
                style: pw.TextStyle(
                  font: font,
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            );
            widgets.add(pw.SizedBox(height: 4));
            widgets.add(
              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey400),
                columnWidths: {
                  0: const pw.FlexColumnWidth(1.2),
                  1: const pw.FlexColumnWidth(2.5),
                  2: const pw.FlexColumnWidth(1.5),
                  3: const pw.FlexColumnWidth(0.8),
                  4: const pw.FlexColumnWidth(0.8),
                  5: const pw.FlexColumnWidth(0.9),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(
                      color: PdfColors.grey200,
                    ),
                    children: [
                      _pdfCell('コード', font, bold: true),
                      _pdfCell('商品名', font, bold: true),
                      _pdfCell('店舗', font, bold: true),
                      _pdfCell('基準', font, bold: true),
                      _pdfCell('現在', font, bold: true),
                      _pdfCell('発注数', font, bold: true),
                    ],
                  ),
                  for (final itemId in byTypeByItem[type]!.keys)
                    for (
                      int i = 0;
                      i < byTypeByItem[type]![itemId]!.length;
                      i++
                    )
                      pw.TableRow(
                        children: [
                          _pdfCell(
                            i == 0
                                ? byTypeByItem[type]![itemId]!.first.item.code
                                : '',
                            font,
                          ),
                          _pdfCell(
                            i == 0
                                ? byTypeByItem[type]![itemId]!.first.item.name
                                : '',
                            font,
                          ),
                          _pdfCell(
                            byTypeByItem[type]![itemId]![i].store.name,
                            font,
                          ),
                          _pdfCell(
                            '${byTypeByItem[type]![itemId]![i].base}',
                            font,
                          ),
                          _pdfCell(
                            '${byTypeByItem[type]![itemId]![i].current}',
                            font,
                          ),
                          _pdfCell(
                            '${_orderedQtys[_orderKey(byTypeByItem[type]![itemId]![i])] ?? byTypeByItem[type]![itemId]![i].orderedQty}',
                            font,
                            color: PdfColors.blue700,
                          ),
                        ],
                      ),
                ],
              ),
            );
          }
          return widgets;
        },
      ),
    );

    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: '発注済みリスト_商品別.pdf',
    );
    await _markPdfIssued(pdfEntries);
    await _load();
  }

  pw.Widget _pdfCell(
    String text,
    pw.Font font, {
    bool bold = false,
    PdfColor? color,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          font: font,
          fontSize: 10,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          color: color,
        ),
      ),
    );
  }

  Widget _sectionHeader(String label, {Color? color}) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.bold,
        color: color ?? Colors.black87,
      ),
    ),
  );

  Widget _stockLabel(String label, String value, Color valueColor) => SizedBox(
    width: 38,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: valueColor,
          ),
        ),
      ],
    ),
  );

  Widget _buildFilterChips() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Row(
      children: [
        Text(
          '種別:',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
        ),
        const SizedBox(width: 8),
        for (final type in _types)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              label: Text(type, style: const TextStyle(fontSize: 12)),
              selected: _selectedTypes.contains(type),
              onSelected: (selected) {
                setState(() {
                  if (selected) {
                    _selectedTypes.add(type);
                  } else {
                    if (_selectedTypes.length > 1) {
                      _selectedTypes.remove(type);
                    }
                  }
                });
              },
              visualDensity: VisualDensity.compact,
            ),
          ),
      ],
    ),
  );

  Widget _buildOrderItemRow(BuildContext context, _OrderEntry e) {
    final key = _orderKey(e);
    final controller = _controllerFor(e);
    final orderedQty = _orderedQtys[key] ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.item.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      '${e.item.code}  [${e.itemType}]',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              _stockLabel('基準', '${e.base}', Colors.grey.shade600),
              const SizedBox(width: 2),
              _stockLabel('現在', '${e.current}', Colors.grey.shade800),
              const SizedBox(width: 2),
              _stockLabel('不足', '${e.effectiveShortage}', Colors.red),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              SizedBox(
                width: 58,
                height: 30,
                child: TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 0,
                    ),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                height: 30,
                child: ElevatedButton(
                  onPressed: () {
                    final qty = int.tryParse(controller.text.trim()) ?? 0;
                    _placeOrder(context, e, qty);
                  },
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('発注', style: TextStyle(fontSize: 12)),
                ),
              ),
              if (orderedQty > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    border: Border.all(color: Colors.orange.shade300),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '発注済:$orderedQty',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  height: 30,
                  child: ElevatedButton(
                    onPressed: () => _deliverFromOrderList(context, e),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('納品', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ],
          ),
          const Divider(height: 10),
        ],
      ),
    );
  }

  Widget _buildItemStoreRow(BuildContext context, _OrderEntry e) {
    final key = _orderKey(e);
    final controller = _controllerFor(e);
    final orderedQty = _orderedQtys[key] ?? 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(e.store.name, style: const TextStyle(fontSize: 13)),
              ),
              _stockLabel('基準', '${e.base}', Colors.grey.shade600),
              const SizedBox(width: 2),
              _stockLabel('現在', '${e.current}', Colors.grey.shade800),
              const SizedBox(width: 2),
              _stockLabel('不足', '${e.effectiveShortage}', Colors.red),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              SizedBox(
                width: 52,
                height: 28,
                child: TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 0,
                    ),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                height: 28,
                child: ElevatedButton(
                  onPressed: () {
                    final qty = int.tryParse(controller.text.trim()) ?? 0;
                    _placeOrder(context, e, qty);
                  },
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                  child: const Text('発注'),
                ),
              ),
              if (orderedQty > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    border: Border.all(color: Colors.orange.shade300),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '発注済:$orderedQty',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  height: 28,
                  child: ElevatedButton(
                    onPressed: () => _deliverFromOrderList(context, e),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                    child: const Text('納品'),
                  ),
                ),
              ],
            ],
          ),
          const Divider(height: 8),
        ],
      ),
    );
  }

  Widget _buildBulkOrderBar(
    BuildContext context,
    LegacyStore store,
    List<_OrderEntry> storeEntries,
  ) {
    final byType = <String, List<_OrderEntry>>{};
    for (final e in storeEntries) {
      byType.putIfAbsent(e.itemType, () => []).add(e);
    }

    final buttons = <Widget>[];
    for (final type in _types) {
      if (!byType.containsKey(type)) continue;
      final typeEntries = byType[type]!
          .where((e) => e.effectiveShortage > 0)
          .toList();
      if (typeEntries.isEmpty) continue;
      buttons.add(
        SizedBox(
          height: 30,
          child: ElevatedButton(
            onPressed: () => _placeBulkOrder(context, store, type, typeEntries),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              backgroundColor: Colors.indigo.shade600,
              foregroundColor: Colors.white,
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: Text('$type 一括登録'),
          ),
        ),
      );
    }

    if (buttons.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      color: Colors.indigo.shade50,
      child: Row(
        children: [
          const Icon(Icons.shopping_cart, size: 16, color: Colors.indigo),
          const SizedBox(width: 6),
          Wrap(spacing: 6, children: buttons),
        ],
      ),
    );
  }

  Widget _buildByStore(BuildContext context, List<_OrderEntry> allEntries) {
    final filtered = allEntries
        .where((e) => _selectedTypes.contains(e.itemType))
        .toList();
    final byStore = <LegacyStore, List<_OrderEntry>>{};
    for (final e in filtered) {
      byStore.putIfAbsent(e.store, () => []).add(e);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _exportPdfByStore(context, filtered),
                icon: const Icon(Icons.picture_as_pdf, size: 18),
                label: const Text('店舗別PDF'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('戻る'),
            ),
          ],
        ),
        _buildFilterChips(),
        const SizedBox(height: 8),
        if (filtered.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '選択された種別の発注品はありません',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ),
        for (final store in byStore.keys)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ExpansionTile(
              initiallyExpanded: true,
              title: Text(
                store.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text('${byStore[store]!.length}品目'),
              children: [
                _buildBulkOrderBar(context, store, byStore[store]!),
                for (final e in byStore[store]!) _buildOrderItemRow(context, e),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildByItem(BuildContext context, List<_OrderEntry> allEntries) {
    final filtered = allEntries
        .where((e) => _selectedTypes.contains(e.itemType))
        .toList();
    final byTypeByItem = <String, Map<String, List<_OrderEntry>>>{};
    for (final e in filtered) {
      byTypeByItem.putIfAbsent(e.itemType, () => {});
      byTypeByItem[e.itemType]!.putIfAbsent(e.item.id, () => []).add(e);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _exportPdfByItem(context, filtered),
                icon: const Icon(Icons.picture_as_pdf, size: 18),
                label: const Text('商品別PDF'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('戻る'),
            ),
          ],
        ),
        _buildFilterChips(),
        const SizedBox(height: 8),
        if (filtered.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '選択された種別の発注品はありません',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ),
        for (final type in _types)
          if (byTypeByItem.containsKey(type)) ...[
            _sectionHeader('■ $type', color: Colors.teal.shade700),
            for (final itemId in byTypeByItem[type]!.keys)
              _buildItemStoreCard(context, byTypeByItem[type]![itemId]!),
          ],
      ],
    );
  }

  Widget _buildItemStoreCard(
    BuildContext context,
    List<_OrderEntry> storeEntries,
  ) {
    final item = storeEntries.first.item;
    final itemType = storeEntries.first.itemType;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.name,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            Text(
              'コード: ${item.code}  [$itemType]',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
            const SizedBox(height: 6),
            for (final e in storeEntries) _buildItemStoreRow(context, e),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('発注リスト')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText('読み取りエラー\n\n$_error'),
        ),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFFFFF7FF),
        appBar: AppBar(
          title: const Text('発注リスト'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '再読み込み',
              onPressed: _load,
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '店舗別'),
              Tab(text: '商品別'),
            ],
          ),
        ),
        body: _entries.isEmpty
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 64,
                      color: Colors.green,
                    ),
                    SizedBox(height: 16),
                    Text('発注が必要な商品はありません', style: TextStyle(fontSize: 16)),
                  ],
                ),
              )
            : TabBarView(
                children: [
                  _buildByStore(context, _entries),
                  _buildByItem(context, _entries),
                ],
              ),
      ),
    );
  }
}

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
// 認証ゲート
// ─────────────────────────────────────────────

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data == null) {
          return const LoginPage();
        }
        return const _UserLoader();
      },
    );
  }
}

class _UserLoader extends StatefulWidget {
  const _UserLoader();

  @override
  State<_UserLoader> createState() => _UserLoaderState();
}

class _UserLoaderState extends State<_UserLoader> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final fs = FirebaseFirestore.instance;
      AppSession.uid = user.uid;
      AppSession.email = user.email ?? '';

      // 新システムの users/{uid} を確認
      final userDoc = await fs.collection('users').doc(user.uid).get();
      if (userDoc.exists) {
        final data = userDoc.data()!;
        AppSession.orgId = (data['orgId'] ?? '').toString();
        AppSession.role = (data['role'] ?? '').toString();
        AppSession.nickname = (data['nickname'] ?? '').toString();
      } else {
        // 旧システムの organizations コレクションから自動移行
        await _tryMigrateFromOrganizations(user.uid, fs);
      }

      // 組織名・ロゴURLを読み込む
      if (AppSession.orgId.isNotEmpty) {
        final orgDoc = await fs.collection('orgs').doc(AppSession.orgId).get();
        final od = orgDoc.data() ?? {};
        AppSession.orgName = od['name']?.toString() ?? AppSession.orgId;
        AppSession.logoUrl = od['logoBase64']?.toString() ?? '';
        AppSession.adSlotBase = (od['adSlotBase'] as int?) ?? -1;
        // 既存組織（approved フィールドなし）は承認済みとみなす
        AppSession.approved = (od['approved'] as bool?) ?? true;
        AppSession.adViewEnabled = (od['adViewEnabled'] as bool?) ?? true;
        // 管理者でadSlotBase未割り当ての場合は割り当てる
        if (AppSession.isAdmin && AppSession.adSlotBase == -1) {
          AppSession.adSlotBase = await _assignAdSlotBase(
            fs,
            AppSession.orgId,
            AppSession.isSuperAdmin,
          );
        }
        // 旧形式(adImage/adMessage)の広告があるがadDistribEnabledが未設定の場合は自動設定
        if (AppSession.isAdmin) {
          final hasAdContent = _orgHasAdContent(od);
          final distribEnabled = (od['adDistribEnabled'] as bool?) ?? false;
          if (hasAdContent && !distribEnabled) {
            try {
              await fs.collection('orgs').doc(AppSession.orgId).update({
                'adDistribEnabled': true,
              });
            } catch (_) {}
          }
        }
        // 全組織の広告を読み込む（adViewEnabled=false の組織はスキップ）
        if (AppSession.adViewEnabled) {
          await _loadAllAdsImpl(fs, ownOrgData: od);
        }
      }

      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted)
        setState(() {
          _error = e.toString();
          _loading = false;
        });
    }
  }

  Future<void> _tryMigrateFromOrganizations(
    String uid,
    FirebaseFirestore fs,
  ) async {
    try {
      // ownerUid が自分のUIDと一致する組織のみ自動移行
      final orgsSnap = await fs.collection('organizations').get();
      String? orgId;
      for (final doc in orgsSnap.docs) {
        final data = doc.data();
        final owner = (data['ownerUid'] ?? '').toString();
        if (owner != uid) continue;
        final storesDoc = await fs
            .collection('inventory_shared_v1')
            .doc('${doc.id}__stores')
            .get();
        if (storesDoc.exists) {
          orgId = doc.id;
          break;
        }
      }
      if (orgId == null) return;

      // orgs コレクションに登録（なければ作成）
      final orgsDoc = await fs.collection('orgs').doc(orgId).get();
      if (!orgsDoc.exists) {
        await fs.collection('orgs').doc(orgId).set({
          'name': orgId,
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': uid,
        });
      }

      // users コレクションに保存
      await fs.collection('users').doc(uid).set({
        'email': AppSession.email,
        'orgId': orgId,
        'role': 'admin',
        'createdAt': FieldValue.serverTimestamp(),
      });

      AppSession.orgId = orgId;
      AppSession.role = 'admin';
    } catch (_) {
      // 自動移行失敗時は OrgSetupPage で手動設定
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('読み込みエラー: $_error'),
          ),
        ),
      );
    }
    if (!AppSession.hasOrg) {
      return const OrgSetupPage();
    }
    if (AppSession.nickname.isEmpty) {
      return const NicknameSetupPage();
    }
    // 管理者が未承認の場合は承認待ち画面（統括管理者は除く）
    if (AppSession.isAdmin &&
        !AppSession.isSuperAdmin &&
        !AppSession.approved) {
      return const PendingApprovalPage();
    }
    return const StoreListPage();
  }
}

// ─────────────────────────────────────────────
// ログインページ
// ─────────────────────────────────────────────

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
      );
    } on FirebaseAuthException catch (e) {
      setState(() {
        _error = _errMsg(e.code);
        _loading = false;
      });
    }
  }

  Future<void> _sendResetEmail() async {
    final emailCtrl = TextEditingController(text: _emailCtrl.text.trim());
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('パスワードの再設定'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '登録済みのメールアドレスに再設定用のリンクを送信します。',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(
                labelText: 'メールアドレス',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('送信'),
          ),
        ],
      ),
    );
    if (result != true) return;
    final email = emailCtrl.text.trim();
    if (email.isEmpty) return;
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('再設定メールを送信しました。メールをご確認ください。')),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errMsg(e.code)), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _errMsg(String code) {
    switch (code) {
      case 'user-not-found':
        return 'メールアドレスが登録されていません';
      case 'wrong-password':
      case 'invalid-credential':
        return 'メールアドレスまたはパスワードが正しくありません';
      case 'invalid-email':
        return 'メールアドレスの形式が正しくありません';
      case 'too-many-requests':
        return 'しばらくしてから再試行してください';
      default:
        return 'ログインに失敗しました ($code)';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '多店舗在庫管理',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 48),
                TextField(
                  controller: _emailCtrl,
                  decoration: const InputDecoration(
                    labelText: 'メールアドレス',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordCtrl,
                  decoration: const InputDecoration(
                    labelText: 'パスワード',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                  onSubmitted: (_) => _login(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _login,
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('ログイン'),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const SignupPage())),
                  child: const Text('新規登録はこちら'),
                ),
                TextButton(
                  onPressed: _loading ? null : _sendResetEmail,
                  child: const Text(
                    'パスワードをお忘れの方',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 新規登録ページ
// ─────────────────────────────────────────────

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _signup() async {
    if (_passCtrl.text != _confirmCtrl.text) {
      setState(() => _error = 'パスワードが一致しません');
      return;
    }
    if (_passCtrl.text.length < 6) {
      setState(() => _error = 'パスワードは6文字以上で設定してください');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text,
      );
      AppSession.uid = cred.user!.uid;
      AppSession.email = cred.user!.email ?? '';
      if (!mounted) return;
      // スタックを完全クリアして OrgSetupPage へ
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const OrgSetupPage()),
        (_) => false,
      );
    } on FirebaseAuthException catch (e) {
      setState(() {
        _error = _errMsg(e.code);
        _loading = false;
      });
    }
  }

  String _errMsg(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'このメールアドレスは既に登録されています';
      case 'invalid-email':
        return 'メールアドレスの形式が正しくありません';
      case 'weak-password':
        return 'パスワードが弱すぎます（6文字以上）';
      default:
        return '登録に失敗しました ($code)';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(title: const Text('新規登録')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              TextField(
                controller: _emailCtrl,
                decoration: const InputDecoration(
                  labelText: 'メールアドレス',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passCtrl,
                decoration: const InputDecoration(
                  labelText: 'パスワード（6文字以上）',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _confirmCtrl,
                decoration: const InputDecoration(
                  labelText: 'パスワード（確認）',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
                onSubmitted: (_) => _signup(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _signup,
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('次へ（組織設定）'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 組織設定ページ（新規登録後 / 脱退後）
// ─────────────────────────────────────────────

class OrgSetupPage extends StatefulWidget {
  const OrgSetupPage({super.key});

  @override
  State<OrgSetupPage> createState() => _OrgSetupPageState();
}

class _OrgSetupPageState extends State<OrgSetupPage> {
  String? _mode; // null=選択, 'create', 'join'
  final _orgNameCtrl = TextEditingController();
  final _orgCodeCtrl = TextEditingController();
  final _joinCodeCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController();
  bool _loading = false;
  bool _agreedToTerms = false;
  String? _error;

  @override
  void dispose() {
    _orgNameCtrl.dispose();
    _orgCodeCtrl.dispose();
    _joinCodeCtrl.dispose();
    _nicknameCtrl.dispose();
    super.dispose();
  }

  Future<void> _createOrg() async {
    final name = _orgNameCtrl.text.trim();
    final code = _orgCodeCtrl.text.trim().toLowerCase();
    final nickname = _nicknameCtrl.text.trim();
    if (name.isEmpty || code.isEmpty) {
      setState(() => _error = '組織名とコードを入力してください');
      return;
    }
    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(code)) {
      setState(() => _error = 'コードは英小文字・数字・アンダースコアのみ使用できます');
      return;
    }
    if (nickname.isEmpty) {
      setState(() => _error = 'ニックネームを入力してください');
      return;
    }
    if (!_agreedToTerms) {
      setState(() => _error = '利用規約とプライバシーポリシーへの同意が必要です');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fs = FirebaseFirestore.instance;
      final orgDoc = await fs.collection('orgs').doc(code).get();
      if (orgDoc.exists) {
        setState(() {
          _error = 'このコードは既に使用されています';
          _loading = false;
        });
        return;
      }
      await fs.collection('orgs').doc(code).set({
        'name': name,
        'inviteCode': code,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': AppSession.uid,
        'maxStores': 5,
        'maxUsers': 5,
        'approved': false,
        'adminEmail': AppSession.email,
        'adminNickname': nickname,
      });
      await fs.collection('users').doc(AppSession.uid).set({
        'email': AppSession.email,
        'orgId': code,
        'role': 'admin',
        'nickname': nickname,
        'createdAt': FieldValue.serverTimestamp(),
      });
      AppSession.orgId = code;
      AppSession.role = 'admin';
      AppSession.nickname = nickname;
      AppSession.approved = false;
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const PendingApprovalPage()),
          (_) => false,
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _joinOrg() async {
    final code = _joinCodeCtrl.text.trim().toLowerCase();
    final nickname = _nicknameCtrl.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'コードを入力してください');
      return;
    }
    if (nickname.isEmpty) {
      setState(() => _error = 'ニックネームを入力してください');
      return;
    }
    if (!_agreedToTerms) {
      setState(() => _error = '利用規約とプライバシーポリシーへの同意が必要です');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fs = FirebaseFirestore.instance;
      // まず orgId で直接検索、なければ inviteCode フィールドで検索
      DocumentSnapshot<Map<String, dynamic>>? orgDoc;
      String? resolvedOrgId;
      final direct = await fs.collection('orgs').doc(code).get();
      if (direct.exists) {
        orgDoc = direct;
        resolvedOrgId = code;
      } else {
        final snap = await fs
            .collection('orgs')
            .where('inviteCode', isEqualTo: code)
            .limit(1)
            .get();
        if (snap.docs.isNotEmpty) {
          orgDoc = snap.docs.first;
          resolvedOrgId = snap.docs.first.id;
        }
      }
      if (orgDoc == null || resolvedOrgId == null) {
        setState(() {
          _error = '組織が見つかりません';
          _loading = false;
        });
        return;
      }
      final maxUsers = (orgDoc.data()?['maxUsers'] as int?) ?? 5;
      final userSnap = await fs
          .collection('users')
          .where('orgId', isEqualTo: resolvedOrgId)
          .get();
      if (userSnap.docs.length >= maxUsers) {
        setState(() {
          _error = 'この組織のユーザー数が上限（$maxUsers人）に達しています';
          _loading = false;
        });
        return;
      }
      await fs.collection('users').doc(AppSession.uid).set({
        'email': AppSession.email,
        'orgId': resolvedOrgId,
        'role': 'member',
        'nickname': nickname,
        'createdAt': FieldValue.serverTimestamp(),
      });
      AppSession.orgId = resolvedOrgId;
      AppSession.role = 'member';
      AppSession.nickname = nickname;
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const StoreListPage()),
          (_) => false,
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('組織の設定'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              AppSession.clear();
            },
            child: const Text('ログアウト', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
      body: SafeArea(
        child: _mode == null
            ? _buildSelectMode()
            : _mode == 'create'
            ? _buildCreateMode()
            : _buildJoinMode(),
      ),
    );
  }

  Future<void> _connectToLegacy() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fs = FirebaseFirestore.instance;

      // ownerUid が自分のUIDと一致する組織のみ移行可能
      final orgsSnap = await fs.collection('organizations').get();
      String? orgId;
      for (final doc in orgsSnap.docs) {
        final data = doc.data();
        final owner = (data['ownerUid'] ?? '').toString();
        if (owner != AppSession.uid) continue; // 自分が所有者の組織のみ
        final storesDoc = await fs
            .collection('inventory_shared_v1')
            .doc('${doc.id}__stores')
            .get();
        if (storesDoc.exists) {
          orgId = doc.id;
          break;
        }
      }
      if (orgId == null) {
        setState(() {
          _error = 'あなたのアカウントに対応する既存データが見つかりませんでした。\n組織コードを入力して参加してください。';
          _loading = false;
        });
        return;
      }

      // orgs コレクションに登録（なければ作成）
      final orgDoc = await fs.collection('orgs').doc(orgId).get();
      if (!orgDoc.exists) {
        await fs.collection('orgs').doc(orgId).set({
          'name': orgId,
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': AppSession.uid,
        });
      }
      await fs.collection('users').doc(AppSession.uid).set({
        'email': AppSession.email,
        'orgId': orgId,
        'role': 'admin',
        'createdAt': FieldValue.serverTimestamp(),
      });
      AppSession.orgId = orgId;
      AppSession.role = 'admin';
      AppSession.nickname = '';
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const NicknameSetupPage()),
          (_) => false,
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Widget _buildAgreementRow(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Checkbox(
          value: _agreedToTerms,
          onChanged: (v) => setState(() => _agreedToTerms = v ?? false),
        ),
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const LegalPage(
                      title: '利用規約',
                      content: _kTermsOfService,
                    ),
                  ),
                ),
                child: const Text(
                  '利用規約',
                  style: TextStyle(
                    color: Colors.blue,
                    decoration: TextDecoration.underline,
                    fontSize: 13,
                  ),
                ),
              ),
              const Text('と', style: TextStyle(fontSize: 13)),
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const LegalPage(
                      title: 'プライバシーポリシー',
                      content: _kPrivacyPolicy,
                    ),
                  ),
                ),
                child: const Text(
                  'プライバシーポリシー',
                  style: TextStyle(
                    color: Colors.blue,
                    decoration: TextDecoration.underline,
                    fontSize: 13,
                  ),
                ),
              ),
              const Text('に同意する', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSelectMode() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '組織の設定',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'ログイン中: ${AppSession.email}',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 32),
            // 既存データ引き継ぎ（移行ユーザー向け）
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.deepOrange.shade200),
                borderRadius: BorderRadius.circular(8),
                color: Colors.deepOrange.shade50,
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '以前から使用していた方',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.deepOrange,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: (_loading || !_agreedToTerms)
                          ? null
                          : _connectToLegacy,
                      icon: _loading
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.restore),
                      label: const Text('既存データを引き継ぐ'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepOrange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              '新しく始める方',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: (_loading || !_agreedToTerms)
                    ? null
                    : () => setState(() {
                        _mode = 'create';
                        _error = null;
                      }),
                icon: const Icon(Icons.add_business),
                label: const Text('新しい組織を作成する'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(14),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: (_loading || !_agreedToTerms)
                    ? null
                    : () => setState(() {
                        _mode = 'join';
                        _error = null;
                      }),
                icon: const Icon(Icons.group_add),
                label: const Text('既存の組織に参加する'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.all(14),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildAgreementRow(context),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCreateMode() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '新しい組織を作成',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _orgNameCtrl,
            decoration: const InputDecoration(
              labelText: '組織名',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _orgCodeCtrl,
            decoration: const InputDecoration(
              labelText: '組織コード（参加用）',
              helperText: '英小文字・数字・_のみ。例: myshop\n※既存データを引き継ぐ場合は legacy と入力',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
            ),
            autocorrect: false,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nicknameCtrl,
            decoration: const InputDecoration(
              labelText: 'ニックネーム（必須）',
              helperText: '履歴に表示される名前です',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          _buildAgreementRow(context),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    _mode = null;
                    _error = null;
                  }),
                  child: const Text('戻る'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _loading ? null : _createOrg,
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('作成'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildJoinMode() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '既存の組織に参加',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _joinCodeCtrl,
            decoration: const InputDecoration(
              labelText: '組織コード',
              helperText: '管理者から教えてもらったコードを入力してください',
              border: OutlineInputBorder(),
            ),
            autocorrect: false,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nicknameCtrl,
            decoration: const InputDecoration(
              labelText: 'ニックネーム（必須）',
              helperText: '履歴に表示される名前です',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _joinOrg(),
          ),
          const SizedBox(height: 12),
          _buildAgreementRow(context),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    _mode = null;
                    _error = null;
                  }),
                  child: const Text('戻る'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _loading ? null : _joinOrg,
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('参加'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// ニックネーム設定ページ（既存ユーザー向け）
// ─────────────────────────────────────────────

class NicknameSetupPage extends StatefulWidget {
  const NicknameSetupPage({super.key});

  @override
  State<NicknameSetupPage> createState() => _NicknameSetupPageState();
}

class _NicknameSetupPageState extends State<NicknameSetupPage> {
  final _ctrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final nick = _ctrl.text.trim();
    if (nick.isEmpty) {
      setState(() => _error = 'ニックネームを入力してください');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(AppSession.uid)
          .update({'nickname': nick});
      AppSession.nickname = nick;
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const StoreListPage()),
          (_) => false,
        );
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('ニックネームの設定'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              AppSession.clear();
            },
            child: const Text('ログアウト', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ニックネームを設定してください',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '在庫の修正・追加履歴に表示される名前です。',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _ctrl,
                decoration: const InputDecoration(
                  labelText: 'ニックネーム',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
                onSubmitted: (_) => _save(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('設定して続ける'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 組織管理ページ（管理者専用）
// ─────────────────────────────────────────────

class OrgManagementPage extends StatefulWidget {
  const OrgManagementPage({super.key});

  @override
  State<OrgManagementPage> createState() => _OrgManagementPageState();
}

class _OrgManagementPageState extends State<OrgManagementPage> {
  List<Map<String, dynamic>> _members = [];
  String _orgName = '';
  String _logoUrl = '';
  String _inviteCode = '';
  bool _loading = true;
  bool _logoUploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fs = FirebaseFirestore.instance;
      final orgDoc = await fs.collection('orgs').doc(AppSession.orgId).get();
      final od = orgDoc.data() ?? {};
      _orgName = od['name']?.toString() ?? AppSession.orgId;
      _logoUrl = od['logoBase64']?.toString() ?? '';
      _inviteCode = od['inviteCode']?.toString().isNotEmpty == true
          ? od['inviteCode'].toString()
          : AppSession.orgId;

      final membersSnap = await fs
          .collection('users')
          .where('orgId', isEqualTo: AppSession.orgId)
          .get();

      setState(() {
        _members =
            membersSnap.docs.map((d) {
              final data = Map<String, dynamic>.from(d.data());
              data['uid'] = d.id;
              return data;
            }).toList()..sort((a, b) {
              if (a['role'] == 'admin' && b['role'] != 'admin') return -1;
              if (a['role'] != 'admin' && b['role'] == 'admin') return 1;
              return (a['email'] ?? '').compareTo(b['email'] ?? '');
            });
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // 組織名変更
  Future<void> _renameOrg() async {
    final ctrl = TextEditingController(text: _orgName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('組織名を変更'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新しい組織名',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == _orgName) return;
    try {
      await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .update({'name': newName});
      AppSession.orgName = newName;
      setState(() => _orgName = newName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ロゴ画像をアップロード
  Future<void> _uploadLogo() async {
    final picker = ImagePicker();
    XFile? picked;
    try {
      picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 75,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('画像の選択に失敗しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    if (picked == null) return;

    setState(() => _logoUploading = true);
    Uint8List bytes;
    try {
      bytes = await picked.readAsBytes();
    } catch (e) {
      setState(() => _logoUploading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('この画像は読み込めません。別の画像を選んでください。'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('画像のデコードに失敗しました');
      final resized = img.copyResize(decoded, width: 400, height: -1);
      final compressed = img.encodeJpg(resized, quality: 70);
      final b64 = base64Encode(compressed);
      await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .update({'logoBase64': b64});
      AppSession.logoUrl = b64;
      setState(() {
        _logoUrl = b64;
        _logoUploading = false;
      });
    } catch (e) {
      setState(() => _logoUploading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ロゴ削除
  Future<void> _deleteLogo() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ロゴを削除'),
        content: const Text('ロゴ画像を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .update({'logoBase64': ''});
      AppSession.logoUrl = '';
      setState(() => _logoUrl = '');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _logoPlaceholder() => Container(
    width: 100,
    height: 100,
    decoration: BoxDecoration(
      color: Colors.deepPurple.shade50,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.deepPurple.shade100, width: 1.5),
    ),
    child: Icon(
      Icons.add_photo_alternate,
      size: 40,
      color: Colors.deepPurple.shade200,
    ),
  );

  // 全在庫が0かチェック（0以外があれば false）
  Future<bool> _checkAllStocksZero() async {
    final stocksDoc = await AppSession.doc('stocks').get();
    if (stocksDoc.exists) {
      for (final storeData in (stocksDoc.data() ?? {}).values) {
        if (storeData is Map) {
          for (final v in storeData.values) {
            final n = v is num ? v.toInt() : 0;
            if (n > 0) return false;
          }
        }
      }
    }
    final v2Doc = await AppSession.doc('stocks_v2').get();
    if (v2Doc.exists) {
      for (final typeData in (v2Doc.data() ?? {}).values) {
        if (typeData is Map) {
          for (final storeData in typeData.values) {
            if (storeData is Map) {
              for (final v in storeData.values) {
                final n = v is num ? v.toInt() : 0;
                if (n > 0) return false;
              }
            }
          }
        }
      }
    }
    return true;
  }

  Future<void> _deleteOrg() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    // 在庫チェック
    final allZero = await _checkAllStocksZero();
    if (!allZero) {
      setState(() {
        _error = '在庫が残っている商品があります。\nすべての在庫を0にしてから組織を削除してください。';
        _loading = false;
      });
      return;
    }
    setState(() => _loading = false);

    // パスワード確認ダイアログ
    final passCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('組織を削除'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'この操作は元に戻せません。\n組織・メンバー情報とあなたのアカウントをすべて削除します。',
              style: TextStyle(color: Colors.red, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passCtrl,
              decoration: const InputDecoration(
                labelText: 'パスワードを入力して確認',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除する', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || passCtrl.text.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // パスワードで再認証
      final user = FirebaseAuth.instance.currentUser!;
      final credential = EmailAuthProvider.credential(
        email: AppSession.email,
        password: passCtrl.text,
      );
      await user.reauthenticateWithCredential(credential);

      final fs = FirebaseFirestore.instance;

      // 全メンバーの users ドキュメントを削除（自分以外）
      final membersSnap = await fs
          .collection('users')
          .where('orgId', isEqualTo: AppSession.orgId)
          .get();
      final batch = fs.batch();
      for (final doc in membersSnap.docs) {
        if (doc.id != AppSession.uid) batch.delete(doc.reference);
      }
      // orgs ドキュメントを削除
      batch.delete(fs.collection('orgs').doc(AppSession.orgId));
      await batch.commit();

      // 自分の users ドキュメントを削除
      await fs.collection('users').doc(AppSession.uid).delete();

      AppSession.clear();

      // Firebase Authアカウント削除（失敗してもサインアウトで確実にログアウト）
      try {
        await user.delete();
      } catch (deleteErr) {
        debugPrint('user.delete() failed: $deleteErr');
        await FirebaseAuth.instance.signOut();
      }

      // AuthGate を維持したまま最初のルートへ戻る
      // （AuthGate の StreamBuilder がログアウト状態を検知して LoginPage を表示する）
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } on FirebaseAuthException catch (e) {
      setState(() {
        _error = (e.code == 'wrong-password' || e.code == 'invalid-credential')
            ? 'パスワードが正しくありません'
            : '認証エラー: ${e.code}';
        _loading = false;
      });
    } catch (e) {
      debugPrint('_deleteOrg error: $e');
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _removeMember(String uid, String email) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('メンバーを削除'),
        content: Text('$email をメンバーから削除しますか？\n削除後、そのユーザーは組織設定画面へ移動します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'orgId': '',
        'role': 'admin',
      });
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _changeInviteCode() async {
    final ctrl = TextEditingController(text: _inviteCode);
    String? dialogError;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('招待コードを変更'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'メンバーが参加時に入力するコードです。\n英小文字・数字・_のみ使用できます。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                  labelText: '新しい招待コード',
                  border: OutlineInputBorder(),
                ),
                autocorrect: false,
                autofocus: true,
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              if (dialogError != null) ...[
                const SizedBox(height: 6),
                Text(
                  dialogError!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () {
                final v = ctrl.text.trim();
                if (!RegExp(r'^[a-z0-9_]+$').hasMatch(v)) {
                  setS(() => dialogError = '英小文字・数字・_のみ使用できます');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('変更'),
            ),
          ],
        ),
      ),
    );
    if (result != true) return;
    final newCode = ctrl.text.trim();
    if (newCode.isEmpty || newCode == _inviteCode) return;
    try {
      await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .update({'inviteCode': newCode});
      setState(() => _inviteCode = newCode);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('招待コードを変更しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('組織管理'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── ロゴ ──
                Center(
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      _logoUploading
                          ? const SizedBox(
                              width: 100,
                              height: 100,
                              child: Center(child: CircularProgressIndicator()),
                            )
                          : GestureDetector(
                              onTap: _uploadLogo,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: _logoUrl.isNotEmpty
                                    ? Image.memory(
                                        base64Decode(_logoUrl),
                                        width: 100,
                                        height: 100,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            _logoPlaceholder(),
                                      )
                                    : _logoPlaceholder(),
                              ),
                            ),
                      if (_logoUrl.isNotEmpty && !_logoUploading)
                        Positioned(
                          right: -4,
                          bottom: -4,
                          child: IconButton(
                            icon: const Icon(
                              Icons.delete,
                              color: Colors.red,
                              size: 20,
                            ),
                            tooltip: 'ロゴを削除',
                            onPressed: _deleteLogo,
                          ),
                        ),
                    ],
                  ),
                ),
                Center(
                  child: TextButton.icon(
                    onPressed: _uploadLogo,
                    icon: const Icon(Icons.upload_file, size: 16),
                    label: Text(_logoUrl.isNotEmpty ? 'ロゴを変更' : 'ロゴをアップロード'),
                  ),
                ),
                const SizedBox(height: 8),
                // ── 組織名 ──
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.business),
                    title: Text(
                      _orgName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text('招待コード: $_inviteCode'),
                    trailing: PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert),
                      onSelected: (v) async {
                        if (v == 'rename') {
                          _renameOrg();
                        } else if (v == 'copy') {
                          final messenger = ScaffoldMessenger.of(context);
                          await Clipboard.setData(
                            ClipboardData(text: _inviteCode),
                          );
                          messenger.showSnackBar(
                            const SnackBar(content: Text('招待コードをコピーしました')),
                          );
                        } else if (v == 'change_code') {
                          _changeInviteCode();
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'rename',
                          child: Row(
                            children: [
                              Icon(Icons.edit, size: 18),
                              SizedBox(width: 8),
                              Text('組織名を変更'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'copy',
                          child: Row(
                            children: [
                              Icon(Icons.copy, size: 18),
                              SizedBox(width: 8),
                              Text('招待コードをコピー'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'change_code',
                          child: Row(
                            children: [
                              Icon(Icons.key, size: 18),
                              SizedBox(width: 8),
                              Text('招待コードを変更'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'メンバー (${_members.length}名)',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                for (final m in _members)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: m['role'] == 'admin'
                            ? Colors.deepPurple.shade100
                            : Colors.grey.shade200,
                        child: Text(
                          m['role'] == 'admin' ? '管' : '員',
                          style: TextStyle(
                            fontSize: 12,
                            color: m['role'] == 'admin'
                                ? Colors.deepPurple
                                : Colors.grey.shade700,
                          ),
                        ),
                      ),
                      title: Text(
                        m['nickname']?.toString().isNotEmpty == true
                            ? m['nickname'].toString()
                            : m['email']?.toString() ?? m['uid'].toString(),
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        '${m['role'] == 'admin' ? '管理者' : 'メンバー'}　${m['email'] ?? ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: m['uid'] == AppSession.uid
                          ? const Chip(label: Text('自分'))
                          : IconButton(
                              icon: const Icon(
                                Icons.person_remove,
                                color: Colors.red,
                              ),
                              tooltip: 'メンバーを削除',
                              onPressed: () => _removeMember(
                                m['uid'].toString(),
                                m['email']?.toString() ?? '',
                              ),
                            ),
                    ),
                  ),
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _deleteOrg,
                    icon: const Icon(Icons.delete_forever, color: Colors.red),
                    label: const Text(
                      '組織を削除する',
                      style: TextStyle(color: Colors.red),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.all(14),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '※ すべての在庫を0にしてから削除できます',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────
// 全画面広告ダイアログ（3秒で自動クローズ）
// ─────────────────────────────────────────────

class _FullScreenAdDialog extends StatefulWidget {
  final _AdEntry ad;
  const _FullScreenAdDialog({required this.ad});

  @override
  State<_FullScreenAdDialog> createState() => _FullScreenAdDialogState();
}

class _FullScreenAdDialogState extends State<_FullScreenAdDialog> {
  int _remaining = 3;

  @override
  void initState() {
    super.initState();
    _tick();
  }

  void _tick() async {
    for (int i = 3; i > 0; i--) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      setState(() => _remaining = i - 1);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ad = widget.ad;
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.black,
      child: SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: Stack(
          children: [
            // 広告コンテンツ（URLがあればタップで遷移）
            GestureDetector(
              onTap: ad.url.isNotEmpty ? () => _openLink(ad.url) : null,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (ad.image.isNotEmpty)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.85,
                          maxHeight: MediaQuery.of(context).size.height * 0.6,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(
                            base64Decode(ad.image),
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    if (ad.message.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          ad.message,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                    if (ad.url.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.open_in_new,
                            size: 13,
                            color: Colors.white54,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'タップして詳細を見る',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.6),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // カウントダウン
            Positioned(
              top: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _remaining > 0 ? '$_remaining 秒' : '閉じる',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
            // 広告主名
            Positioned(
              bottom: 16,
              right: 16,
              child: Text(
                '提供: ${ad.orgName}',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 広告バナーウィジェット
// ─────────────────────────────────────────────

class AdBannerWidget extends StatefulWidget {
  const AdBannerWidget({super.key});

  @override
  State<AdBannerWidget> createState() => _AdBannerWidgetState();
}

class _AdBannerWidgetState extends State<AdBannerWidget> {
  Timer? _timer;
  int _index = 0;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    // 初期表示もランダム
    final initAds = AppSession.distributedAds;
    if (initAds.isNotEmpty) _index = Random().nextInt(initAds.length);
    // 広告がなくてもタイマーは常に起動（後からロードされた場合も対応）
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      final ads = AppSession.distributedAds;
      if (ads.isEmpty) return;
      int next;
      if (ads.length == 1) {
        next = 0;
      } else {
        do {
          next = Random().nextInt(ads.length);
        } while (next == _index);
      }
      setState(() {
        _index = next;
        _tick++;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AppSession.adViewEnabled) return const SizedBox.shrink();
    final ads = AppSession.distributedAds;
    if (ads.isNotEmpty) {
      final ad = ads[_index % ads.length];
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 600),
        child: GestureDetector(
          key: ValueKey(_tick),
          onTap: ad.url.isNotEmpty ? () => _openLink(ad.url) : null,
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 80, maxHeight: 160),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Colors.grey.shade300)),
            ),
            child: Stack(
              children: [
                Row(
                  children: [
                    if (ad.image.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            base64Decode(ad.image),
                            height: 100,
                            width: 100,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    if (ad.message.isNotEmpty)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Text(
                            ad.message,
                            style: const TextStyle(fontSize: 13),
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ],
                ),
                Positioned(
                  bottom: 4,
                  right: 8,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (ad.url.isNotEmpty)
                        Icon(
                          Icons.open_in_new,
                          size: 11,
                          color: Colors.grey.shade400,
                        ),
                      if (ad.url.isNotEmpty) const SizedBox(width: 3),
                      Text(
                        '提供: ${ad.orgName}  [${_index + 1}/${ads.length}]',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}

// ─────────────────────────────────────────────
// 広告スペース管理ページ（管理者専用）
// ─────────────────────────────────────────────

class AdManagementPage extends StatefulWidget {
  const AdManagementPage({super.key});

  @override
  State<AdManagementPage> createState() => _AdManagementPageState();
}

class _AdManagementPageState extends State<AdManagementPage> {
  // 各スロットの状態: {image, message, url}
  List<Map<String, String>> _slots = [];
  // メッセージ用コントローラ（最大5個）
  final List<TextEditingController> _msgCtrls = List.generate(
    5,
    (_) => TextEditingController(),
  );
  // URL用コントローラ（最大5個）
  final List<TextEditingController> _urlCtrls = List.generate(
    5,
    (_) => TextEditingController(),
  );
  bool _loading = true;
  bool _saving = false;

  int get _maxSlots => AppSession.isSuperAdmin ? 5 : 3;

  @override
  void initState() {
    super.initState();
    _loadSlots();
  }

  @override
  void dispose() {
    for (final c in _msgCtrls) c.dispose();
    for (final c in _urlCtrls) c.dispose();
    super.dispose();
  }

  Future<void> _loadSlots() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .get();
      final data = doc.data();
      final raw = data?['adSlots'];
      List<Map<String, String>> loaded = [];
      if (raw is List && raw.isNotEmpty) {
        loaded = raw.map<Map<String, String>>((e) {
          if (e is Map) {
            return {
              'image': (e['image'] as String?) ?? '',
              'message': (e['message'] as String?) ?? '',
              'url': (e['url'] as String?) ?? '',
            };
          }
          return {'image': '', 'message': '', 'url': ''};
        }).toList();
      } else {
        // レガシー移行: adImage/adMessageをスロット0に
        final img = (data?['adImage'] as String?) ?? '';
        final msg = (data?['adMessage'] as String?) ?? '';
        if (img.isNotEmpty || msg.isNotEmpty) {
          loaded = [
            {'image': img, 'message': msg, 'url': ''},
          ];
        }
      }
      setState(() {
        _slots = loaded;
        for (int i = 0; i < _slots.length && i < _msgCtrls.length; i++) {
          _msgCtrls[i].text = _slots[i]['message'] ?? '';
          _urlCtrls[i].text = _slots[i]['url'] ?? '';
        }
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _pickImage(int i) async {
    final picker = ImagePicker();
    XFile? picked;
    try {
      picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 60,
        maxWidth: 600,
        maxHeight: 600,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('画像の選択に失敗しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    if (picked == null) return;
    try {
      final bytes = await picked.readAsBytes();
      // Web では image_picker のサイズ制限が効かないため Dart 側でリサイズ・圧縮
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('画像のデコードに失敗しました');
      final resized = img.copyResize(decoded, width: 300, height: -1);
      final compressed = img.encodeJpg(resized, quality: 55);
      setState(() {
        _slots[i] = {..._slots[i], 'image': base64Encode(compressed)};
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('画像の読み込みに失敗しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    // コントローラの内容をスロットに反映
    for (int i = 0; i < _slots.length && i < _msgCtrls.length; i++) {
      _slots[i] = {
        ..._slots[i],
        'message': _msgCtrls[i].text.trim(),
        'url': _urlCtrls[i].text.trim(),
      };
    }
    try {
      // 空のスロットは保存しない
      final slotsData = _slots
          .where(
            (s) =>
                (s['image'] ?? '').isNotEmpty ||
                (s['message'] ?? '').isNotEmpty,
          )
          .map(
            (s) => <String, dynamic>{
              'image': s['image'] ?? '',
              'message': s['message'] ?? '',
              'url': s['url'] ?? '',
            },
          )
          .toList();
      final orgRef = FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId);
      // 有効な広告があれば配信ON、なければOFF（adDistribEnabled を自動管理）
      // adImage/adMessage はレガシーフィールドのため同時に削除
      await orgRef.update({
        'adSlots': slotsData,
        'adDistribEnabled': slotsData.isNotEmpty,
        'adImage': FieldValue.delete(),
        'adMessage': FieldValue.delete(),
      });
      // 保存後に自組織データを再取得して広告リストを更新
      final updatedDoc = await orgRef.get();
      if (updatedDoc.exists) {
        await _loadAllAdsImpl(
          FirebaseFirestore.instance,
          ownOrgData: updatedDoc.data()!,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = AppSession.adSlotBase;
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: Text('広告管理（最大$_maxSlots枠）'),
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : TextButton(
                  onPressed: _save,
                  child: const Text(
                    '保存',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (base >= 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '割り当てスロット番号: ${base}〜${base + _maxSlots - 1}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                for (int i = 0; i < _slots.length; i++) _buildSlotCard(i),
                if (_slots.length < _maxSlots)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _slots.add({'image': '', 'message': '', 'url': ''});
                        });
                      },
                      icon: const Icon(Icons.add),
                      label: Text('スロットを追加（${_slots.length}/$_maxSlots）'),
                    ),
                  ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _buildSlotCard(int i) {
    final slot = _slots[i];
    final image = slot['image'] ?? '';
    final base = AppSession.adSlotBase;
    final globalNum = base >= 0 ? base + i : i;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'スロット $globalNum',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => setState(() {
                    _slots.removeAt(i);
                    _msgCtrls[i].text = '';
                    _urlCtrls[i].text = '';
                    // コントローラをシフト
                    for (
                      int j = i;
                      j < _slots.length && j + 1 < _msgCtrls.length;
                      j++
                    ) {
                      _msgCtrls[j].text = _msgCtrls[j + 1].text;
                      _urlCtrls[j].text = _urlCtrls[j + 1].text;
                    }
                    if (_slots.length < _msgCtrls.length) {
                      _msgCtrls[_slots.length].text = '';
                      _urlCtrls[_slots.length].text = '';
                    }
                  }),
                  tooltip: 'このスロットを削除',
                ),
              ],
            ),
            Center(
              child: GestureDetector(
                onTap: () => _pickImage(i),
                child: image.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          base64Decode(image),
                          height: 100,
                          fit: BoxFit.cover,
                        ),
                      )
                    : Container(
                        width: 160,
                        height: 80,
                        decoration: BoxDecoration(
                          color: Colors.deepPurple.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.deepPurple.shade100),
                        ),
                        child: Icon(
                          Icons.add_photo_alternate,
                          color: Colors.deepPurple.shade300,
                        ),
                      ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () => _pickImage(i),
                  icon: const Icon(Icons.upload_file, size: 16),
                  label: Text(image.isNotEmpty ? '画像を変更' : '画像をアップロード'),
                ),
                if (image.isNotEmpty)
                  TextButton(
                    onPressed: () =>
                        setState(() => _slots[i] = {...slot, 'image': ''}),
                    child: const Text(
                      '削除',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _msgCtrls[i],
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'メッセージテキスト（任意）',
                border: OutlineInputBorder(),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlCtrls[i],
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'リンクURL（任意）',
                hintText: 'https://example.com',
                prefixIcon: Icon(Icons.link, size: 18),
                border: OutlineInputBorder(),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 承認待ちページ
// ─────────────────────────────────────────────

class PendingApprovalPage extends StatefulWidget {
  const PendingApprovalPage({super.key});
  @override
  State<PendingApprovalPage> createState() => _PendingApprovalPageState();
}

class _PendingApprovalPageState extends State<PendingApprovalPage> {
  bool _checking = false;

  Future<void> _refresh() async {
    setState(() => _checking = true);
    try {
      final doc = await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .get();
      final approved = (doc.data()?['approved'] as bool?) ?? false;
      AppSession.approved = approved;
      if (approved && mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const StoreListPage()),
          (_) => false,
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('まだ承認されていません。しばらくお待ちください。')),
        );
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.hourglass_top_rounded,
                size: 72,
                color: Colors.deepPurple.shade300,
              ),
              const SizedBox(height: 24),
              const Text(
                '承認待ち',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Text(
                '組織「${AppSession.orgName.isNotEmpty ? AppSession.orgName : AppSession.orgId}」の管理者承認を申請中です。\n統括管理者の承認をお待ちください。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 8),
              Text(
                AppSession.email,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 32),
              _checking
                  ? const CircularProgressIndicator()
                  : ElevatedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('承認状況を確認'),
                      onPressed: _refresh,
                    ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () async {
                  await FirebaseAuth.instance.signOut();
                  AppSession.clear();
                  if (mounted) {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const AuthGate()),
                      (_) => false,
                    );
                  }
                },
                child: const Text(
                  'ログアウト',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 統括管理ページ（re.start.niigata@gmail.com 専用）
// ─────────────────────────────────────────────

class SuperAdminPage extends StatefulWidget {
  const SuperAdminPage({super.key});

  @override
  State<SuperAdminPage> createState() => _SuperAdminPageState();
}

class _SuperAdminPageState extends State<SuperAdminPage> {
  List<Map<String, dynamic>> _orgs = [];
  bool _loading = true;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('orgs')
          .orderBy('name')
          .get();
      setState(() {
        _orgs = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_search.isEmpty) return _orgs;
    final q = _search.toLowerCase();
    return _orgs.where((o) {
      final name = (o['name'] as String? ?? '').toLowerCase();
      final nick = (o['adminNickname'] as String? ?? '').toLowerCase();
      final mail = (o['adminEmail'] as String? ?? '').toLowerCase();
      final id = (o['id'] as String? ?? '').toLowerCase();
      return name.contains(q) ||
          nick.contains(q) ||
          mail.contains(q) ||
          id.contains(q);
    }).toList();
  }

  Future<void> _toggleApproval(String orgId, bool current) async {
    final newVal = !current;
    await FirebaseFirestore.instance.collection('orgs').doc(orgId).update({
      'approved': newVal,
    });
    setState(() {
      final idx = _orgs.indexWhere((o) => o['id'] == orgId);
      if (idx != -1) _orgs[idx]['approved'] = newVal;
    });
  }

  Future<void> _toggleAdView(String orgId, bool current) async {
    final newVal = !current;
    await FirebaseFirestore.instance.collection('orgs').doc(orgId).update({
      'adViewEnabled': newVal,
    });
    setState(() {
      final idx = _orgs.indexWhere((o) => o['id'] == orgId);
      if (idx != -1) _orgs[idx]['adViewEnabled'] = newVal;
    });
  }

  Future<void> _editLimits(
    String orgId,
    int currentMaxStores,
    int currentMaxUsers,
  ) async {
    final storesCtrl = TextEditingController(text: currentMaxStores.toString());
    final usersCtrl = TextEditingController(text: currentMaxUsers.toString());

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('店舗数・ユーザー数の上限変更'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: storesCtrl,
              decoration: const InputDecoration(labelText: '最大店舗数'),
              keyboardType: TextInputType.number,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: usersCtrl,
              decoration: const InputDecoration(labelText: '最大ユーザー数'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result != true) return;
    final newMaxStores =
        int.tryParse(storesCtrl.text.trim()) ?? currentMaxStores;
    final newMaxUsers = int.tryParse(usersCtrl.text.trim()) ?? currentMaxUsers;
    if (newMaxStores == currentMaxStores && newMaxUsers == currentMaxUsers) {
      return;
    }
    await FirebaseFirestore.instance.collection('orgs').doc(orgId).update({
      'maxStores': newMaxStores,
      'maxUsers': newMaxUsers,
    });
    setState(() {
      final idx = _orgs.indexWhere((o) => o['id'] == orgId);
      if (idx != -1) {
        _orgs[idx]['maxStores'] = newMaxStores;
        _orgs[idx]['maxUsers'] = newMaxUsers;
      }
    });
  }

  Future<void> _toggleAdDistrib(String orgId, bool current) async {
    final newVal = !current;
    await FirebaseFirestore.instance.collection('orgs').doc(orgId).update({
      'adDistribEnabled': newVal,
    });
    setState(() {
      final idx = _orgs.indexWhere((o) => o['id'] == orgId);
      if (idx != -1) _orgs[idx]['adDistribEnabled'] = newVal;
    });
  }

  Future<void> _syncAllAds() async {
    setState(() => _loading = true);
    try {
      final fs = FirebaseFirestore.instance;
      final snap = await fs.collection('orgs').get();
      final batch = fs.batch();
      for (final doc in snap.docs) {
        final data = doc.data();
        final hasAd = _orgHasAdContent(data);
        // 広告あり → 配信ON、なし → 配信OFFに統一
        batch.update(doc.reference, {'adDistribEnabled': hasAd});
      }
      await batch.commit();
      // 広告リストを再構築
      await _load();
      // AppSession の distributedAds も更新
      final orgDoc = await fs.collection('orgs').doc(AppSession.orgId).get();
      if (orgDoc.exists) {
        await _loadAllAdsImpl(fs, ownOrgData: orgDoc.data()!);
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('全組織の広告配信状態を更新しました')));
      }
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _toggleChip(
    String label,
    bool value,
    Color activeColor,
    VoidCallback onTap, {
    Color? offColor,
  }) {
    final color = value ? activeColor : (offColor ?? Colors.grey);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.toggle_on : Icons.toggle_off,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrgTile(Map<String, dynamic> org) {
    final orgId = org['id'] as String;
    final name = (org['name'] as String?) ?? orgId;
    final adminNick = (org['adminNickname'] as String?) ?? '';
    final adminEmail = (org['adminEmail'] as String?) ?? '';
    final enabled = (org['adDistribEnabled'] as bool?) ?? false;
    final adView = (org['adViewEnabled'] as bool?) ?? true;
    final approved = (org['approved'] as bool?) ?? true;
    final maxStores = (org['maxStores'] as int?) ?? 5;
    final maxUsers = (org['maxUsers'] as int?) ?? 5;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 組織名 + 承認状態バッジ
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: approved
                      ? Colors.deepPurple.shade100
                      : Colors.orange.shade100,
                  radius: 18,
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: approved
                          ? Colors.deepPurple
                          : Colors.orange.shade800,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        'ID: $orgId',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: approved
                        ? Colors.green.shade50
                        : Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: approved
                          ? Colors.green.shade300
                          : Colors.orange.shade300,
                    ),
                  ),
                  child: Text(
                    approved ? '承認済み' : '承認待ち',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: approved
                          ? Colors.green.shade700
                          : Colors.orange.shade700,
                    ),
                  ),
                ),
              ],
            ),
            // 管理者情報
            if (adminNick.isNotEmpty || adminEmail.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (adminNick.isNotEmpty)
                      Row(
                        children: [
                          Icon(
                            Icons.badge_outlined,
                            size: 13,
                            color: Colors.grey.shade600,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            adminNick,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                    if (adminEmail.isNotEmpty)
                      Row(
                        children: [
                          Icon(
                            Icons.email_outlined,
                            size: 13,
                            color: Colors.grey.shade600,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            adminEmail,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            // 上限情報
            Text(
              '上限: 店舗 $maxStores / ユーザー $maxUsers',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            // トグル行
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                // 広告配信トグル
                _toggleChip(
                  '広告配信',
                  enabled,
                  Colors.teal,
                  () => _toggleAdDistrib(orgId, enabled),
                ),
                // 広告表示トグル
                _toggleChip(
                  '広告表示',
                  adView,
                  Colors.indigo,
                  () => _toggleAdView(orgId, adView),
                ),
                // 承認トグル
                _toggleChip(
                  '承認',
                  approved,
                  Colors.green,
                  () => _toggleApproval(orgId, approved),
                  offColor: Colors.orange,
                ),
                // 上限編集ボタン
                IconButton(
                  icon: const Icon(Icons.tune, size: 20),
                  tooltip: '上限を変更',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => _editLimits(orgId, maxStores, maxUsers),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _filtered
        .where((o) => (o['approved'] as bool?) == false)
        .toList();
    final approved = _filtered
        .where((o) => (o['approved'] as bool?) != false)
        .toList();

    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('統括管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.campaign),
            tooltip: '全組織の広告配信を同期',
            onPressed: _loading ? null : _syncAllAds,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() => _loading = true);
              _load();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 検索バー
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: TextField(
                    onChanged: (v) => setState(() => _search = v),
                    decoration: InputDecoration(
                      hintText: '組織名・管理者名・メールで検索',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                ),
                Expanded(
                  child: _orgs.isEmpty
                      ? const Center(child: Text('組織が見つかりません'))
                      : ListView(
                          children: [
                            // 承認待ちセクション
                            if (pending.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  4,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.hourglass_top,
                                      size: 16,
                                      color: Colors.orange.shade700,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      '承認待ち (${pending.length}件)',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.orange.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              ...pending.map(_buildOrgTile),
                              const Divider(height: 24),
                            ],
                            // 承認済みセクション
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.check_circle_outline,
                                    size: 16,
                                    color: Colors.green.shade700,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '承認済み (${approved.length}件)',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            ...approved.map(_buildOrgTile),
                            const SizedBox(height: 16),
                          ],
                        ),
                ),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────
// 特別発注・新規発注ページ
// ─────────────────────────────────────────────

class SpecialOrderPage extends StatefulWidget {
  const SpecialOrderPage({super.key});

  @override
  State<SpecialOrderPage> createState() => _SpecialOrderPageState();
}

class _SpecialOrderPageState extends State<SpecialOrderPage> {
  List<SpecialOrderItem> _items = [];
  List<LegacyStore> _stores = [];
  Map<String, Map<String, int>> _orders = {};
  Map<String, Map<String, int>> _deliveries = {};
  bool _loading = true;
  String? _error;
  final Map<String, TextEditingController> _controllers = {};

  static const _kTypes = ['特別発注', '新規発注', 'その他'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        AppSession.doc('stores').get(),
        AppSession.doc('special_orders').get(),
      ]);
      final stores = _parseStores(results[0].data() ?? {});

      final doc = results[1];
      final raw = doc.exists
          ? (doc.data() ?? <String, dynamic>{})
          : <String, dynamic>{};

      final rawItems = raw['items'];
      final items = <SpecialOrderItem>[];
      if (rawItems is List) {
        for (final e in rawItems) {
          if (e is Map) {
            final m = e.map((k, v) => MapEntry(k.toString(), v));
            final item = SpecialOrderItem.fromMap(m);
            if (item.id.isNotEmpty) items.add(item);
          }
        }
      }
      items.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      Map<String, Map<String, int>> parseNestedQty(dynamic src) {
        final result = <String, Map<String, int>>{};
        if (src is! Map) return result;
        for (final e in src.entries) {
          final itemId = e.key.toString();
          if (e.value is! Map) continue;
          final storeMap = <String, int>{};
          for (final s in (e.value as Map).entries) {
            final v = s.value;
            final qty = v is int
                ? v
                : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
            if (qty > 0) storeMap[s.key.toString()] = qty;
          }
          if (storeMap.isNotEmpty) result[itemId] = storeMap;
        }
        return result;
      }

      setState(() {
        _items = items;
        _stores = stores;
        _orders = parseNestedQty(raw['orders']);
        _deliveries = parseNestedQty(raw['deliveries']);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  TextEditingController _ctrl(String itemId, String storeId) {
    final key = '${itemId}_$storeId';
    final ordered = (_orders[itemId] ?? {})[storeId] ?? 0;
    return _controllers.putIfAbsent(
      key,
      () => TextEditingController(text: ordered > 0 ? '$ordered' : ''),
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.year}年${d.month.toString().padLeft(2, '0')}月'
      '${d.day.toString().padLeft(2, '0')}日';

  Future<void> _placeOrder(
    SpecialOrderItem item,
    String storeId,
    int qty,
  ) async {
    final storeName = _stores
        .firstWhere(
          (s) => s.id == storeId,
          orElse: () => LegacyStore(id: storeId, code: '', name: storeId),
        )
        .name;

    if (qty <= 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('発注キャンセル確認'),
          content: Text('$storeName の ${item.name} の発注をキャンセルしますか？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('いいえ'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('キャンセルする'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      try {
        await AppSession.doc(
          'special_orders',
        ).update({'orders.${item.id}.$storeId': FieldValue.delete()});
      } on FirebaseException catch (e) {
        if (e.code != 'not-found') rethrow;
      }
      setState(() {
        _orders[item.id]?.remove(storeId);
        if (_orders[item.id]?.isEmpty ?? false) _orders.remove(item.id);
      });
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('仮発注確認'),
        content: Text('${item.name}\n$storeName: $qty 個を仮発注します'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('仮発注する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await AppSession.doc('special_orders').set({
        'orders': {
          item.id: {storeId: qty},
        },
      }, SetOptions(merge: true));
      setState(() {
        _orders.putIfAbsent(item.id, () => {})[storeId] = qty;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('仮発注しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deliver(SpecialOrderItem item, LegacyStore store) async {
    final orderedQty = (_orders[item.id] ?? {})[store.id] ?? 0;
    if (orderedQty <= 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('納品確認'),
        content: Text('${item.name}\n${store.name}: ${orderedQty}個を納品済みにします'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('納品する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await AppSession.doc('special_orders').set({
        'orders': {
          item.id: {store.id: FieldValue.delete()},
        },
        'deliveries': {
          item.id: {store.id: orderedQty},
        },
      }, SetOptions(merge: true));
      setState(() {
        _orders[item.id]?.remove(store.id);
        if (_orders[item.id]?.isEmpty ?? false) _orders.remove(item.id);
        _deliveries.putIfAbsent(item.id, () => {})[store.id] = orderedQty;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('納品しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _normalizeCode(String s) => String.fromCharCodes(
    s.runes.map((r) {
      if (r >= 0xFF01 && r <= 0xFF5E) return r - 0xFEE0;
      if (r == 0x3000) return 0x20;
      return r;
    }),
  ).toLowerCase().trim();

  Future<void> _addItem() async {
    final result = await _showRegistrationDialog();
    if (result == null) return;

    final newCode = _normalizeCode(result['code'] as String);
    final duplicate = _items.any((i) => _normalizeCode(i.code) == newCode);
    if (duplicate) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('商品コード「${result['code']}」は既に登録されています'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    final newId = FirebaseFirestore.instance.collection('_').doc().id;
    final newItem = SpecialOrderItem(
      id: newId,
      type: result['type'] as String,
      name: result['name'] as String,
      code: result['code'] as String,
      salesStart: result['salesStart'] as DateTime,
      salesEnd: result['salesEnd'] as DateTime,
      arrival: result['arrival'] as DateTime,
      createdAt: DateTime.now(),
    );

    try {
      await AppSession.doc('special_orders').set({
        'items': FieldValue.arrayUnion([newItem.toMap()]),
      }, SetOptions(merge: true));

      if (result['type'] == '新規発注') {
        final masterItem = {
          'id': newId,
          'code': result['code'],
          'name': result['name'],
        };
        await Future.wait([
          AppSession.doc('products').set({
            'items': FieldValue.arrayUnion([masterItem]),
          }, SetOptions(merge: true)),
          AppSession.doc('testers').set({
            'items': FieldValue.arrayUnion([masterItem]),
          }, SetOptions(merge: true)),
        ]);
      }

      setState(() => _items.insert(0, newItem));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${newItem.name} を登録しました'
              '${result['type'] == '新規発注' ? '（商品・テスターマスタに追加済み）' : ''}',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('登録失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _editItem(SpecialOrderItem item) async {
    final result = await _showRegistrationDialog(initial: item);
    if (result == null) return;

    final newCode = _normalizeCode(result['code'] as String);
    final duplicate = _items.any(
      (i) => i.id != item.id && _normalizeCode(i.code) == newCode,
    );
    if (duplicate) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('商品コード「${result['code']}」は既に登録されています'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    final updated = SpecialOrderItem(
      id: item.id,
      type: result['type'] as String,
      name: result['name'] as String,
      code: result['code'] as String,
      salesStart: result['salesStart'] as DateTime,
      salesEnd: result['salesEnd'] as DateTime,
      arrival: result['arrival'] as DateTime,
      createdAt: item.createdAt,
    );

    try {
      final doc = await AppSession.doc('special_orders').get();
      final raw = doc.data() ?? {};
      final rawItems = (raw['items'] as List? ?? []).map((e) {
        if (e is Map && (e['id'] ?? '').toString() == item.id) {
          return updated.toMap();
        }
        return e;
      }).toList();
      await AppSession.doc('special_orders').update({'items': rawItems});

      setState(() {
        final idx = _items.indexWhere((i) => i.id == item.id);
        if (idx >= 0) _items[idx] = updated;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('編集しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('編集失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteItem(SpecialOrderItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('${item.name} を削除しますか？\n発注データもすべて削除されます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final doc = await AppSession.doc('special_orders').get();
      final raw = doc.data() ?? {};
      final rawItems = (raw['items'] as List? ?? [])
          .where((e) => !(e is Map && (e['id'] ?? '').toString() == item.id))
          .toList();
      final updates = <String, dynamic>{'items': rawItems};
      if ((raw['orders'] as Map?)?.containsKey(item.id) == true) {
        updates['orders.${item.id}'] = FieldValue.delete();
      }
      if ((raw['deliveries'] as Map?)?.containsKey(item.id) == true) {
        updates['deliveries.${item.id}'] = FieldValue.delete();
      }
      await AppSession.doc('special_orders').update(updates);

      setState(() {
        _items.removeWhere((i) => i.id == item.id);
        _orders.remove(item.id);
        _deliveries.remove(item.id);
        _controllers.removeWhere((k, _) => k.startsWith('${item.id}_'));
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('削除しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('削除失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<Map<String, dynamic>?> _showRegistrationDialog({
    SpecialOrderItem? initial,
  }) async {
    String selectedType = initial?.type ?? '特別発注';
    final nameCtrl = TextEditingController(text: initial?.name ?? '');
    final codeCtrl = TextEditingController(text: initial?.code ?? '');
    DateTime salesStart = initial?.salesStart ?? DateTime.now();
    DateTime salesEnd =
        initial?.salesEnd ?? DateTime.now().add(const Duration(days: 90));
    DateTime arrival =
        initial?.arrival ?? DateTime.now().add(const Duration(days: 14));
    final isEdit = initial != null;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          Future<void> pickDate(String field) async {
            final init = field == 'start'
                ? salesStart
                : (field == 'end' ? salesEnd : arrival);
            final picked = await showDatePicker(
              context: ctx,
              initialDate: init,
              firstDate: DateTime(2020),
              lastDate: DateTime(2035),
            );
            if (picked == null) return;
            setS(() {
              if (field == 'start')
                salesStart = picked;
              else if (field == 'end')
                salesEnd = picked;
              else
                arrival = picked;
            });
          }

          String fmtD(DateTime d) =>
              '${d.year}/${d.month.toString().padLeft(2, '0')}/'
              '${d.day.toString().padLeft(2, '0')}';

          return AlertDialog(
            title: Text(isEdit ? '発注情報を編集' : '特別発注・新規発注 登録'),
            content: SizedBox(
              width: 340,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '種別',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      children: _kTypes
                          .map(
                            (t) => ChoiceChip(
                              label: Text(t),
                              selected: selectedType == t,
                              onSelected: (_) => setS(() => selectedType = t),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: '商品名',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: codeCtrl,
                      decoration: const InputDecoration(
                        labelText: '商品コード',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '販売期間',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => pickDate('start'),
                            child: Text(
                              fmtD(salesStart),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Text('〜'),
                        ),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => pickDate('end'),
                            child: Text(
                              fmtD(salesEnd),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '本店到着予定日',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    OutlinedButton(
                      onPressed: () => pickDate('arrival'),
                      child: Text(fmtD(arrival)),
                    ),
                    if (selectedType == '新規発注')
                      Container(
                        margin: const EdgeInsets.only(top: 12),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.blue.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 14,
                              color: Colors.blue.shade700,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '登録と同時に商品マスタ・テスターマスタに追加されます',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.blue.shade700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('キャンセル'),
              ),
              ElevatedButton(
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) return;
                  Navigator.of(ctx).pop({
                    'type': selectedType,
                    'name': name,
                    'code': codeCtrl.text.trim(),
                    'salesStart': salesStart,
                    'salesEnd': salesEnd,
                    'arrival': arrival,
                  });
                },
                child: Text(isEdit ? '保存' : '登録'),
              ),
            ],
          );
        },
      ),
    );
    nameCtrl.dispose();
    codeCtrl.dispose();
    return result;
  }

  Color _typeColor(String type) {
    switch (type) {
      case '新規発注':
        return Colors.blue;
      case '特別発注':
        return Colors.purple;
      default:
        return Colors.grey.shade600;
    }
  }

  Widget _buildStoreRow(SpecialOrderItem item, LegacyStore store) {
    final ordered = (_orders[item.id] ?? {})[store.id] ?? 0;
    final delivered = (_deliveries[item.id] ?? {})[store.id] ?? 0;
    final ctrl = _ctrl(item.id, store.id);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 76,
                child: Text(
                  store.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              SizedBox(
                width: 64,
                child: TextField(
                  controller: ctrl,
                  enabled: !item.isExpired,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    border: OutlineInputBorder(),
                    hintText: '0',
                    suffixText: '個',
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              if (!item.isExpired) ...[
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    final qty = int.tryParse(ctrl.text.trim()) ?? 0;
                    _placeOrder(item, store.id, qty);
                  },
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('仮発注', style: TextStyle(fontSize: 13)),
                ),
              ],
            ],
          ),
          if (ordered > 0 || delivered > 0)
            Padding(
              padding: const EdgeInsets.only(left: 76, top: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (ordered > 0) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '発注済: $ordered 個',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade800,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: () => _deliver(item, store),
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green.shade100,
                          border: Border.all(color: Colors.green.shade400),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '納品',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.green.shade800,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (delivered > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade100,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '納品済: $delivered 個',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.blue.shade800,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          const Divider(height: 12),
        ],
      ),
    );
  }

  Widget _buildItemCard(SpecialOrderItem item) {
    final c = _typeColor(item.type);
    final totalOrdered = (_orders[item.id] ?? {}).values.fold(
      0,
      (a, b) => a + b,
    );

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: 20),
          onSelected: (v) {
            if (v == 'edit')
              _editItem(item);
            else if (v == 'delete')
              _deleteItem(item);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'edit',
              child: Row(
                children: [
                  Icon(Icons.edit, size: 16),
                  SizedBox(width: 8),
                  Text('編集'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete, size: 16, color: Colors.red),
                  SizedBox(width: 8),
                  Text('削除', style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: c.withOpacity(0.15),
                border: Border.all(color: c.withOpacity(0.4)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                item.type,
                style: TextStyle(
                  fontSize: 10,
                  color: c,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.name,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: item.isExpired ? Colors.grey : null,
                  decoration: item.isExpired
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
            ),
            if (item.isExpired)
              Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '期間終了',
                  style: TextStyle(fontSize: 10, color: Colors.grey),
                ),
              )
            else if (totalOrdered > 0)
              Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '合計 $totalOrdered 個',
                  style: TextStyle(fontSize: 10, color: Colors.orange.shade700),
                ),
              ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('コード: ${item.code}', style: const TextStyle(fontSize: 12)),
              Text(
                '販売期間: ${_fmtDate(item.salesStart)} 〜 ${_fmtDate(item.salesEnd)}',
                style: const TextStyle(fontSize: 12),
              ),
              Text(
                '本店到着予定: ${_fmtDate(item.arrival)}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        children: [
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '各店舗 仮発注数',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          for (final store in _stores) _buildStoreRow(item, store),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('特別発注・新規発注'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '再読み込み',
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Text('読み込みエラー: $_error'),
            )
          : _items.isEmpty
          ? const Center(
              child: Text(
                '登録された発注はありません\n＋ボタンから登録してください',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _items.length,
              itemBuilder: (_, i) => _buildItemCard(_items[i]),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addItem,
        tooltip: '新規登録',
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 利用規約・プライバシーポリシー
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
