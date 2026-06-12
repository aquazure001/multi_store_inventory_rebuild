import 'dart:async';
import 'dart:convert';
import 'dart:math';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MultiStoreInventoryApp());
}

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
  static String adMode = '';    // '' | 'custom' | 'distributed'
  static String adImage = '';
  static String adMessage = '';
  // 配信広告リスト（配信許可された全組織の広告）
  static List<_AdEntry> distributedAds = [];

  static bool get isAdmin => role == 'admin';
  static bool get hasOrg => orgId.isNotEmpty;
  static bool get isSuperAdmin => email == 're.start.niigata@gmail.com';

  static void clear() {
    uid = '';
    orgId = '';
    role = '';
    email = '';
    orgName = '';
    logoUrl = '';
    nickname = '';
    adMode = '';
    adImage = '';
    adMessage = '';
    distributedAds = [];
  }

  static DocumentReference<Map<String, dynamic>> doc(String suffix) =>
      FirebaseFirestore.instance
          .collection('inventory_shared_v1')
          .doc('org_${orgId}__$suffix');
}

// 配信広告エントリ
class _AdEntry {
  final String orgId;
  final String orgName;
  final String image;   // base64
  final String message;
  const _AdEntry({required this.orgId, required this.orgName,
      required this.image, required this.message});
}

// ─────────────────────────────────────────────
// モデル
// ─────────────────────────────────────────────

class LegacyStore {
  const LegacyStore({
    required this.id,
    required this.code,
    required this.name,
  });

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
// 共通ヘルパー
// ─────────────────────────────────────────────

List<LegacyItem> _parseItemsFromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc) {
  final raw = doc.data()?['items'];
  if (raw is! List) return [];

  final items = raw.whereType<Map>().map((item) {
    final map = item.map((k, v) => MapEntry(k.toString(), v));
    return LegacyItem.fromMap(map);
  }).where((item) => item.id.isNotEmpty).toList();

  items.sort((a, b) {
    if (a.code.isEmpty && b.code.isEmpty) return _naturalCompare(a.name, b.name);
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
      final map =
          Map<String, dynamic>.from(item.map((k, v) => MapEntry(k.toString(), v)));
      final store = LegacyStore.fromMap(map);
      if (store.id.isNotEmpty) stores.add(store);
    }
  }
  return stores;
}

Map<String, int> _parseStocksForStore(
    Map<String, dynamic> stocksData, String storeId) {
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

// v1(商品) + v2(テスター・備品) を1つのマップにマージ
Map<String, int> _parseMergedStocksForStore(
    Map<String, dynamic> v1Data, Map v2TMap, Map v2EMap, String storeId) {
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

class MultiStoreInventoryApp extends StatelessWidget {
  const MultiStoreInventoryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '多店舗在庫管理システム',
      debugShowCheckedModeBanner: false,
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

  @override
  void initState() {
    super.initState();
    _loadStores();
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
              item.map((k, v) => MapEntry(k.toString(), v)));
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

  static Future<void> _showFullScreenAd(BuildContext context) async {
    _AdEntry? ad;
    if (AppSession.adMode == 'custom' &&
        (AppSession.adImage.isNotEmpty || AppSession.adMessage.isNotEmpty)) {
      ad = _AdEntry(
        orgId: AppSession.orgId,
        orgName: AppSession.orgName,
        image: AppSession.adImage,
        message: AppSession.adMessage,
      );
    } else if (AppSession.adMode == 'distributed' &&
        AppSession.distributedAds.isNotEmpty) {
      final ads = AppSession.distributedAds;
      ad = ads[Random().nextInt(ads.length)];
    }
    if (ad == null) return;
    if (!context.mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black87,
      builder: (_) => _FullScreenAdDialog(ad: ad!),
    );
  }

  Future<void> _addStore() async {
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
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('追加')),
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
          {'id': id, 'code': code, 'name': name}
        ])
      });
      _loadStores();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red));
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
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('保存')),
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
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('ニックネームを変更しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red));
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
                    labelText: '現在のパスワード', border: OutlineInputBorder()),
                obscureText: true,
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: newCtrl,
                decoration: const InputDecoration(
                    labelText: '新しいパスワード（6文字以上）',
                    border: OutlineInputBorder()),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmCtrl,
                decoration: const InputDecoration(
                    labelText: '新しいパスワード（確認）',
                    border: OutlineInputBorder()),
                obscureText: true,
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              if (dialogError != null) ...[
                const SizedBox(height: 8),
                Text(dialogError!,
                    style:
                        const TextStyle(color: Colors.red, fontSize: 13)),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('キャンセル')),
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
          email: user.email!, password: current);
      await user.reauthenticateWithCredential(cred);
      await user.updatePassword(newPass);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('パスワードを変更しました')));
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        final msg = (e.code == 'wrong-password' ||
                e.code == 'invalid-credential')
            ? '現在のパスワードが正しくありません'
            : 'エラー: ${e.code}';
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), backgroundColor: Colors.red));
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
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('脱退', style: TextStyle(color: Colors.red))),
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
            SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red));
      }
    }
  }

  void _goToReorder() {
    Navigator.of(context)
        .push<List<LegacyStore>>(
            MaterialPageRoute(builder: (_) => const StoreReorderPage()))
        .then((result) {
      if (!mounted) return;
      if (result != null && result.isNotEmpty) {
        setState(() => _stores = result);
      } else {
        _loadStores();
      }
    });
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
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.business),
                  ),
                ),
              )
            : null,
        title: Text(AppSession.orgName.isNotEmpty
            ? AppSession.orgName
            : '店舗一覧'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              if (value == 'all_stores') {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const AllStoresInventoryPage()));
              } else if (value == 'history') {
                Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HistoryPage()));
              } else if (value == 'items') {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ItemMasterPage()));
              } else if (value == 'order') {
                await _showFullScreenAd(context);
                if (!context.mounted) return;
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const OrderListPage()));
              } else if (value == 'reorder') {
                _goToReorder();
              } else if (value == 'org') {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const OrgManagementPage()));
                if (mounted) setState(() {});
              } else if (value == 'ad') {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const AdManagementPage()));
                if (mounted) setState(() {});
              } else if (value == 'superadmin') {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SuperAdminPage()));
              } else if (value == 'nickname') {
                _changeNickname();
              } else if (value == 'password') {
                _changePassword();
              } else if (value == 'leave') {
                _leaveOrg();
              } else if (value == 'logout') {
                FirebaseAuth.instance.signOut();
                AppSession.clear();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'all_stores',
                child: Row(children: [
                  Icon(Icons.table_chart), SizedBox(width: 12), Text('全店舗在庫確認'),
                ]),
              ),
              const PopupMenuItem(
                value: 'history',
                child: Row(children: [
                  Icon(Icons.history), SizedBox(width: 12), Text('修正・追加履歴'),
                ]),
              ),
              const PopupMenuItem(
                value: 'items',
                child: Row(children: [
                  Icon(Icons.inventory_2), SizedBox(width: 12), Text('商品マスタ管理'),
                ]),
              ),
              const PopupMenuItem(
                value: 'order',
                child: Row(children: [
                  Icon(Icons.shopping_cart), SizedBox(width: 12), Text('発注リスト'),
                ]),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'reorder',
                child: Row(children: [
                  Icon(Icons.reorder), SizedBox(width: 12), Text('店舗の並び替え'),
                ]),
              ),
              const PopupMenuDivider(),
              if (AppSession.isAdmin)
                const PopupMenuItem(
                  value: 'org',
                  child: Row(children: [
                    Icon(Icons.manage_accounts), SizedBox(width: 12), Text('組織管理'),
                  ]),
                ),
              if (AppSession.isAdmin)
                const PopupMenuItem(
                  value: 'ad',
                  child: Row(children: [
                    Icon(Icons.campaign), SizedBox(width: 12), Text('広告スペース管理'),
                  ]),
                ),
              if (AppSession.isSuperAdmin)
                const PopupMenuItem(
                  value: 'superadmin',
                  child: Row(children: [
                    Icon(Icons.admin_panel_settings, color: Colors.deepPurple),
                    SizedBox(width: 12),
                    Text('統括管理', style: TextStyle(color: Colors.deepPurple)),
                  ]),
                ),
              if (!AppSession.isAdmin)
                const PopupMenuItem(
                  value: 'leave',
                  child: Row(children: [
                    Icon(Icons.exit_to_app, color: Colors.orange), SizedBox(width: 12),
                    Text('組織を脱退', style: TextStyle(color: Colors.orange)),
                  ]),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'nickname',
                child: Row(children: [
                  Icon(Icons.badge_outlined), SizedBox(width: 12), Text('ニックネーム変更'),
                ]),
              ),
              const PopupMenuItem(
                value: 'password',
                child: Row(children: [
                  Icon(Icons.lock_outline), SizedBox(width: 12), Text('パスワード変更'),
                ]),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: Row(children: [
                  Icon(Icons.logout, color: Colors.red), SizedBox(width: 12),
                  Text('ログアウト', style: TextStyle(color: Colors.red)),
                ]),
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
                                  fontSize: 28, fontWeight: FontWeight.bold),
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
                                        store.code.isEmpty ? '-' : store.code),
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
                                              StoreInventoryPage(store: store)),
                                    );
                                  },
                                ),
                              ),
                          ],
                        ),
            ),
            const AdBannerWidget(),
          ],
        ),
      ),
      floatingActionButton: AppSession.isAdmin
          ? FloatingActionButton(
              onPressed: _addStore,
              tooltip: '店舗を追加',
              child: const Icon(Icons.add),
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
              item.map((k, v) => MapEntry(k.toString(), v)));
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
          SnackBar(
            content: Text('保存失敗: $e'),
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
        title: const Text('店舗の並び替え'),
      ),
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
                                      fontWeight: FontWeight.bold),
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
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.save),
                            label: Text(
                              _saving ? '保存中...' : 'この順番で保存する',
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold),
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
    final snap = await AppSession.doc('history')
        .collection('entries')
        .orderBy('at', descending: true)
        .limit(100)
        .get();

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
    final deltaColor =
        delta > 0 ? Colors.green.shade700 : Colors.red.shade700;
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
                        fontWeight: FontWeight.bold),
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
    final v2EMap = (v2Raw['equipments'] is Map) ? v2Raw['equipments'] as Map : {};

    final stocksByStore = <String, Map<String, int>>{};
    for (final store in stores) {
      stocksByStore[store.id] = _parseMergedStocksForStore(
          stocksData, v2TMap, v2EMap, store.id);
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
                        horizontal: 8, vertical: 3),
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

class StoreInventoryPage extends StatelessWidget {
  const StoreInventoryPage({
    super.key,
    required this.store,
  });

  final LegacyStore store;

  Future<_InventoryData> _loadInventory() async {
    final results = await Future.wait([
      AppSession.doc('products').get(),
      AppSession.doc('testers').get(),
      AppSession.doc('equipments').get(),
      AppSession.doc('stocks').get(),
      AppSession.doc('baseline').get(),
      AppSession.doc('stocks_v2').get(),
    ]);

    final stocksData = results[3].data() ?? {};
    final baseStocksData = results[4].exists
        ? (results[4].data() ?? <String, dynamic>{})
        : <String, dynamic>{};
    final v2Raw = results[5].data() ?? {};

    final v2TMap = (v2Raw['testers'] is Map)
        ? Map<String, dynamic>.from(
            (v2Raw['testers'] as Map).map((k, v) => MapEntry(k.toString(), v)))
        : <String, dynamic>{};
    final v2EMap = (v2Raw['equipments'] is Map)
        ? Map<String, dynamic>.from(
            (v2Raw['equipments'] as Map).map((k, v) => MapEntry(k.toString(), v)))
        : <String, dynamic>{};

    return _InventoryData(
      products: _parseItemsFromDoc(results[0]),
      testers: _parseItemsFromDoc(results[1]),
      equipments: _parseItemsFromDoc(results[2]),
      productStocks: _parseStocksForStore(stocksData, store.id),
      testerStocks: _parseStocksForStore(v2TMap, store.id),
      equipmentStocks: _parseStocksForStore(v2EMap, store.id),
      baseStocks: _parseStocksForStore(baseStocksData, store.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: const Color(0xFFFFF7FF),
        appBar: AppBar(
          title: Text(store.name),
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
            future: _loadInventory(),
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

              final data = snapshot.data ??
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
                    storeId: store.id,
                    storeName: store.name,
                  ),
                  _InventoryList(
                    title: 'テスター',
                    items: data.testers,
                    stocks: data.testerStocks,
                    baseStocks: data.baseStocks,
                    storeId: store.id,
                    storeName: store.name,
                  ),
                  _InventoryList(
                    title: '備品',
                    items: data.equipments,
                    stocks: data.equipmentStocks,
                    baseStocks: data.baseStocks,
                    storeId: store.id,
                    storeName: store.name,
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
  });

  final String title;
  final List<LegacyItem> items;
  final Map<String, int> stocks;
  final Map<String, int> baseStocks;
  final String storeId;
  final String storeName;

  @override
  State<_InventoryList> createState() => _InventoryListState();
}

class _InventoryListState extends State<_InventoryList> {
  String _query = '';
  late Map<String, int> _localStocks;
  late Map<String, int> _localBaseStocks;
  final Set<String> _changedIds = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _localStocks = Map.from(widget.stocks);
    _localBaseStocks = Map.from(widget.baseStocks);
  }

  Future<void> _showBaseStockInput(BuildContext context, LegacyItem item) async {
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
        await docRef.set({widget.storeId: {item.id: result}});
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
                  child:
                      Text('• ${c.item.name}: ${c.oldCount} → ${c.newCount}'),
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
          stockUpdates['$typeKey.${widget.storeId}.$id'] = _localStocks[id] ?? 0;
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
                }
              }
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
          SnackBar(
            content: Text('保存失敗: $e'),
            backgroundColor: Colors.red,
          ),
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
              const SizedBox(height: 12),
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
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('販売終了',
                                style: TextStyle(
                                    fontSize: 10, color: Colors.grey)),
                          ),
                      ],
                    ),
                    subtitle: Text('コード: ${item.code}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: () => _showBaseStockInput(context, item),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: item.discontinued
                                  ? Colors.grey.shade100
                                  : Colors.blue.shade50,
                              border: Border.all(
                                  color: item.discontinued
                                      ? Colors.grey.shade300
                                      : Colors.blue.shade200),
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
                                          : Colors.blue.shade600),
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
                                  if (_changedIds.contains(item.id)) return Colors.orange;
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
              _ItemMasterTab(docId: 'org_${AppSession.orgId}__products', label: '商品'),
              _ItemMasterTab(docId: 'org_${AppSession.orgId}__testers', label: 'テスター'),
              _ItemMasterTab(docId: 'org_${AppSession.orgId}__equipments', label: '備品'),
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
              item.map((k, v) => MapEntry(k.toString(), v)));
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
      if (a.code.isEmpty && b.code.isEmpty) return _naturalCompare(a.name, b.name);
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
              Navigator.of(ctx).pop({
                'code': codeCtrl.text.trim(),
                'name': name,
              });
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
      _rawItems.add({'id': newId, 'code': result['code']!, 'name': result['name']!});
      _items = _sorted(_rawItems);
    });

    try {
      await _persist();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${result['name']} を追加しました'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      setState(() {
        _rawItems.removeWhere((m) => m['id'] == newId);
        _items = _sorted(_rawItems);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('追加失敗: $e'),
          backgroundColor: Colors.red,
        ));
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${result['name']} を更新しました'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      setState(() {
        _rawItems[idx] = oldMap;
        _items = _sorted(_rawItems);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('更新失敗: $e'),
          backgroundColor: Colors.red,
        ));
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(newVal
              ? '「${item.name}」を販売終了にしました'
              : '「${item.name}」の販売終了を解除しました'),
        ));
      }
    } catch (e) {
      setState(() {
        _rawItems[idx] = oldMap;
        _items = _sorted(_rawItems);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('更新失敗: $e'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  Future<void> _deleteItem(LegacyItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除しますか？'),
        content: Text(
            '「${item.name}」を削除します。\n各店舗の在庫データはそのまま残ります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${item.name} を削除しました'),
          backgroundColor: Colors.orange,
        ));
      }
    } catch (e) {
      setState(() {
        _rawItems.insert(removedIdx, removedMap);
        _items = _sorted(_rawItems);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('削除失敗: $e'),
          backgroundColor: Colors.red,
        ));
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
                        fontSize: 20, fontWeight: FontWeight.bold),
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
                            color: item.discontinued ? Colors.grey : null),
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
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade400,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('販売終了',
                                style: TextStyle(
                                    fontSize: 10, color: Colors.white)),
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
                            item.discontinued
                                ? Icons.replay
                                : Icons.block,
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
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.red),
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
                    fontSize: 16, fontWeight: FontWeight.bold),
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

class _OrderEntry {
  const _OrderEntry({
    required this.store,
    required this.item,
    required this.itemType,
    required this.current,
    required this.base,
  });
  final LegacyStore store;
  final LegacyItem item;
  final String itemType;
  final int current;
  final int base;
  int get shortage => base - current;
}

class OrderListPage extends StatefulWidget {
  const OrderListPage({super.key});

  @override
  State<OrderListPage> createState() => _OrderListPageState();
}

class _OrderListPageState extends State<OrderListPage> {
  late Future<List<_OrderEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<_OrderEntry>> _load() async {
    final results = await Future.wait([
      AppSession.doc('stores').get(),
      AppSession.doc('products').get(),
      AppSession.doc('testers').get(),
      AppSession.doc('equipments').get(),
      AppSession.doc('stocks').get(),
      AppSession.doc('baseline').get(),
      AppSession.doc('stocks_v2').get(),
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
    final v2EMap = (v2Raw['equipments'] is Map) ? v2Raw['equipments'] as Map : {};

    final entries = <_OrderEntry>[];
    for (final store in stores) {
      final stocks = _parseMergedStocksForStore(stocksData, v2TMap, v2EMap, store.id);
      final bases = _parseStocksForStore(baseData, store.id);

      for (final typeEntry in <(String, List<LegacyItem>)>[
        ('商品', products),
        ('テスター', testers),
        ('備品', equipments),
      ]) {
        final typeName = typeEntry.$1;
        final items = typeEntry.$2;
        for (final item in items) {
          if (item.discontinued) continue;
          final b = bases[item.id] ?? 0;
          if (b <= 0) continue;
          final c = stocks[item.id] ?? 0;
          if (c < b) {
            entries.add(_OrderEntry(
              store: store,
              item: item,
              itemType: typeName,
              current: c,
              base: b,
            ));
          }
        }
      }
    }
    return entries;
  }

  Future<void> _exportPdfByStore(
      BuildContext context, List<_OrderEntry> entries) async {
    final font = await PdfGoogleFonts.notoSansJPRegular();
    final doc = pw.Document();

    final byStore = <LegacyStore, List<_OrderEntry>>{};
    for (final e in entries) {
      byStore.putIfAbsent(e.store, () => []).add(e);
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        theme: pw.ThemeData.withFont(base: font),
        header: (ctx) => pw.Text(
          '発注リスト（店舗別）',
          style: pw.TextStyle(
              font: font, fontSize: 18, fontWeight: pw.FontWeight.bold),
        ),
        build: (ctx) {
          final widgets = <pw.Widget>[];
          byStore.forEach((store, storeEntries) {
            widgets.add(pw.SizedBox(height: 12));
            widgets.add(pw.Text(
              '■ ${store.name}',
              style: pw.TextStyle(
                  font: font, fontSize: 13, fontWeight: pw.FontWeight.bold),
            ));
            widgets.add(pw.SizedBox(height: 4));
            widgets.add(pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey400),
              columnWidths: {
                0: const pw.FlexColumnWidth(3),
                1: const pw.FlexColumnWidth(1),
                2: const pw.FlexColumnWidth(1),
                3: const pw.FlexColumnWidth(1),
                4: const pw.FlexColumnWidth(1),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                  children: [
                    _pdfCell('商品名', font, bold: true),
                    _pdfCell('種別', font, bold: true),
                    _pdfCell('基準', font, bold: true),
                    _pdfCell('現在', font, bold: true),
                    _pdfCell('不足', font, bold: true),
                  ],
                ),
                for (final e in storeEntries)
                  pw.TableRow(children: [
                    _pdfCell(e.item.name, font),
                    _pdfCell(e.itemType, font),
                    _pdfCell('${e.base}', font),
                    _pdfCell('${e.current}', font),
                    _pdfCell('${e.shortage}', font, color: PdfColors.red700),
                  ]),
              ],
            ));
          });
          return widgets;
        },
      ),
    );

    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: '発注リスト_店舗別.pdf',
    );
  }

  Future<void> _exportPdfByItem(
      BuildContext context, List<_OrderEntry> entries) async {
    final font = await PdfGoogleFonts.notoSansJPRegular();
    final doc = pw.Document();

    final byTypeByItem = <String, Map<String, List<_OrderEntry>>>{};
    for (final e in entries) {
      byTypeByItem.putIfAbsent(e.itemType, () => {});
      byTypeByItem[e.itemType]!.putIfAbsent(e.item.id, () => []).add(e);
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        theme: pw.ThemeData.withFont(base: font),
        header: (ctx) => pw.Text(
          '発注リスト（商品別）',
          style: pw.TextStyle(
              font: font, fontSize: 18, fontWeight: pw.FontWeight.bold),
        ),
        build: (ctx) {
          final widgets = <pw.Widget>[];
          for (final type in _types) {
            if (!byTypeByItem.containsKey(type)) continue;
            widgets.add(pw.SizedBox(height: 12));
            widgets.add(pw.Text(
              '■ $type',
              style: pw.TextStyle(
                  font: font, fontSize: 13, fontWeight: pw.FontWeight.bold),
            ));
            widgets.add(pw.SizedBox(height: 4));
            widgets.add(pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey400),
              columnWidths: {
                0: const pw.FlexColumnWidth(3),
                1: const pw.FlexColumnWidth(2),
                2: const pw.FlexColumnWidth(1),
                3: const pw.FlexColumnWidth(1),
                4: const pw.FlexColumnWidth(1),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                  children: [
                    _pdfCell('商品名', font, bold: true),
                    _pdfCell('店舗', font, bold: true),
                    _pdfCell('基準', font, bold: true),
                    _pdfCell('現在', font, bold: true),
                    _pdfCell('不足', font, bold: true),
                  ],
                ),
                for (final itemId in byTypeByItem[type]!.keys)
                  for (int i = 0;
                      i < byTypeByItem[type]![itemId]!.length;
                      i++)
                    pw.TableRow(children: [
                      _pdfCell(
                          i == 0
                              ? byTypeByItem[type]![itemId]!.first.item.name
                              : '',
                          font),
                      _pdfCell(
                          byTypeByItem[type]![itemId]![i].store.name, font),
                      _pdfCell(
                          '${byTypeByItem[type]![itemId]![i].base}', font),
                      _pdfCell(
                          '${byTypeByItem[type]![itemId]![i].current}', font),
                      _pdfCell(
                          '${byTypeByItem[type]![itemId]![i].shortage}', font,
                          color: PdfColors.red700),
                    ]),
              ],
            ));
          }
          return widgets;
        },
      ),
    );

    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: '発注リスト_商品別.pdf',
    );
  }

  pw.Widget _pdfCell(String text, pw.Font font,
      {bool bold = false, PdfColor? color}) {
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

  static const _types = ['商品', 'テスター', '備品'];

  Widget _tableHeader() => Container(
        color: Colors.grey.shade200,
        child: const Row(
          children: [
            Expanded(flex: 3, child: Padding(padding: EdgeInsets.all(8), child: Text('商品名', style: TextStyle(fontWeight: FontWeight.bold)))),
            SizedBox(width: 48, child: Center(child: Text('基準', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)))),
            SizedBox(width: 48, child: Center(child: Text('現在', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)))),
            SizedBox(width: 48, child: Center(child: Text('不足', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.red)))),
          ],
        ),
      );

  Widget _tableRow(_OrderEntry e) => Row(
        children: [
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(e.item.name),
            ),
          ),
          SizedBox(width: 48, child: Center(child: Text('${e.base}'))),
          SizedBox(width: 48, child: Center(child: Text('${e.current}'))),
          SizedBox(
            width: 48,
            child: Center(
              child: Text('${e.shortage}',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
            ),
          ),
        ],
      );

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

  // タブ①：店舗選択 → 発注品一覧（ExpansionTile）
  Widget _buildByStore(BuildContext context, List<_OrderEntry> entries) {
    final byStore = <LegacyStore, List<_OrderEntry>>{};
    for (final e in entries) {
      byStore.putIfAbsent(e.store, () => []).add(e);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _exportPdfByStore(context, entries),
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('店舗別PDFで出力'),
            ),
          ),
        ),
        for (final store in byStore.keys)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ExpansionTile(
              title: Text(store.name,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${byStore[store]!.length}品目'),
              children: [
                _tableHeader(),
                const Divider(height: 1),
                for (final e in byStore[store]!) _tableRow(e),
                const SizedBox(height: 8),
              ],
            ),
          ),
      ],
    );
  }

  // タブ②：商品ごと → 発注が必要な店舗のみ表示
  Widget _buildByItem(BuildContext context, List<_OrderEntry> entries) {
    final byTypeByItem = <String, Map<String, List<_OrderEntry>>>{};
    for (final e in entries) {
      byTypeByItem.putIfAbsent(e.itemType, () => {});
      byTypeByItem[e.itemType]!.putIfAbsent(e.item.id, () => []).add(e);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _exportPdfByItem(context, entries),
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('商品別PDFで出力'),
            ),
          ),
        ),
        for (final type in _types)
          if (byTypeByItem.containsKey(type)) ...[
            _sectionHeader('■ $type', color: Colors.teal.shade700),
            for (final itemId in byTypeByItem[type]!.keys)
              _buildItemStoreCard(byTypeByItem[type]![itemId]!),
          ],
      ],
    );
  }

  Widget _buildItemStoreCard(List<_OrderEntry> storeEntries) {
    final item = storeEntries.first.item;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.name,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14)),
            Text('コード: ${item.code}',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                  child: Text('店舗',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                          fontWeight: FontWeight.bold))),
              SizedBox(
                  width: 44,
                  child: Center(
                      child: Text('基準',
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                              fontWeight: FontWeight.bold)))),
              SizedBox(
                  width: 44,
                  child: Center(
                      child: Text('現在',
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                              fontWeight: FontWeight.bold)))),
              const SizedBox(
                  width: 44,
                  child: Center(
                      child: Text('不足',
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.red,
                              fontWeight: FontWeight.bold)))),
            ]),
            const Divider(height: 8),
            for (final e in storeEntries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(
                      child: Text(e.store.name,
                          style: const TextStyle(fontSize: 13))),
                  SizedBox(
                      width: 44,
                      child: Center(
                          child: Text('${e.base}',
                              style: const TextStyle(fontSize: 13)))),
                  SizedBox(
                      width: 44,
                      child: Center(
                          child: Text('${e.current}',
                              style: const TextStyle(fontSize: 13)))),
                  SizedBox(
                      width: 44,
                      child: Center(
                          child: Text('${e.shortage}',
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.red)))),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
              onPressed: () => setState(() => _future = _load()),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '店舗別'),
              Tab(text: '商品別'),
            ],
          ),
        ),
        body: FutureBuilder<List<_OrderEntry>>(
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline, size: 64, color: Colors.green),
                    SizedBox(height: 16),
                    Text('発注が必要な商品はありません', style: TextStyle(fontSize: 16)),
                  ],
                ),
              );
            }
            return TabBarView(
              children: [
                _buildByStore(context, entries),
                _buildByItem(context, entries),
              ],
            );
          },
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
  });

  final List<LegacyItem> products;
  final List<LegacyItem> testers;
  final List<LegacyItem> equipments;
  final Map<String, int> productStocks;
  final Map<String, int> testerStocks;
  final Map<String, int> equipmentStocks;
  final Map<String, int> baseStocks;
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
              body: Center(child: CircularProgressIndicator()));
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
        AppSession.adMode = od['adMode']?.toString() ?? '';
        AppSession.adImage = od['adImage']?.toString() ?? '';
        AppSession.adMessage = od['adMessage']?.toString() ?? '';
        // 配信許可された全組織の広告を読み込む
        await _loadDistributedAds(fs);
      }

      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  static Future<void> _loadDistributedAds(FirebaseFirestore fs) async {
    try {
      final snap = await fs.collection('orgs')
          .where('adDistribEnabled', isEqualTo: true)
          .get();
      AppSession.distributedAds = snap.docs
          .where((d) =>
              ((d.data()['adImage'] as String?) ?? '').isNotEmpty ||
              ((d.data()['adMessage'] as String?) ?? '').isNotEmpty)
          .map((d) => _AdEntry(
                orgId: d.id,
                orgName: (d.data()['name'] as String?) ?? d.id,
                image: (d.data()['adImage'] as String?) ?? '',
                message: (d.data()['adMessage'] as String?) ?? '',
              ))
          .toList();
    } catch (_) {}
  }

  Future<void> _tryMigrateFromOrganizations(
      String uid, FirebaseFirestore fs) async {
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
                  child: Text('読み込みエラー: $_error'))));
    }
    if (!AppSession.hasOrg) {
      return const OrgSetupPage();
    }
    if (AppSession.nickname.isEmpty) {
      return const NicknameSetupPage();
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
    setState(() { _loading = true; _error = null; });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
      );
    } on FirebaseAuthException catch (e) {
      setState(() { _error = _errMsg(e.code); _loading = false; });
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
            const Text('登録済みのメールアドレスに再設定用のリンクを送信します。',
                style: TextStyle(fontSize: 13)),
            const SizedBox(height: 16),
            TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(
                  labelText: 'メールアドレス', border: OutlineInputBorder()),
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('送信')),
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
            const SnackBar(content: Text('再設定メールを送信しました。メールをご確認ください。')));
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_errMsg(e.code)), backgroundColor: Colors.red));
      }
    }
  }

  String _errMsg(String code) {
    switch (code) {
      case 'user-not-found': return 'メールアドレスが登録されていません';
      case 'wrong-password':
      case 'invalid-credential': return 'メールアドレスまたはパスワードが正しくありません';
      case 'invalid-email': return 'メールアドレスの形式が正しくありません';
      case 'too-many-requests': return 'しばらくしてから再試行してください';
      default: return 'ログインに失敗しました ($code)';
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
                const Text('多店舗在庫管理',
                    style: TextStyle(
                        fontSize: 28, fontWeight: FontWeight.bold)),
                const SizedBox(height: 48),
                TextField(
                  controller: _emailCtrl,
                  decoration: const InputDecoration(
                      labelText: 'メールアドレス',
                      border: OutlineInputBorder()),
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordCtrl,
                  decoration: const InputDecoration(
                      labelText: 'パスワード', border: OutlineInputBorder()),
                  obscureText: true,
                  onSubmitted: (_) => _login(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: const TextStyle(color: Colors.red, fontSize: 13)),
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
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Text('ログイン'),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SignupPage())),
                  child: const Text('新規登録はこちら'),
                ),
                TextButton(
                  onPressed: _loading ? null : _sendResetEmail,
                  child: const Text('パスワードをお忘れの方',
                      style: TextStyle(color: Colors.grey)),
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
    setState(() { _loading = true; _error = null; });
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
      setState(() { _error = _errMsg(e.code); _loading = false; });
    }
  }

  String _errMsg(String code) {
    switch (code) {
      case 'email-already-in-use': return 'このメールアドレスは既に登録されています';
      case 'invalid-email': return 'メールアドレスの形式が正しくありません';
      case 'weak-password': return 'パスワードが弱すぎます（6文字以上）';
      default: return '登録に失敗しました ($code)';
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
                    border: OutlineInputBorder()),
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passCtrl,
                decoration: const InputDecoration(
                    labelText: 'パスワード（6文字以上）',
                    border: OutlineInputBorder()),
                obscureText: true,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _confirmCtrl,
                decoration: const InputDecoration(
                    labelText: 'パスワード（確認）',
                    border: OutlineInputBorder()),
                obscureText: true,
                onSubmitted: (_) => _signup(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: const TextStyle(color: Colors.red, fontSize: 13)),
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
                          child: CircularProgressIndicator(strokeWidth: 2))
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
      setState(() =>
          _error = 'コードは英小文字・数字・アンダースコアのみ使用できます');
      return;
    }
    if (nickname.isEmpty) {
      setState(() => _error = 'ニックネームを入力してください');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final fs = FirebaseFirestore.instance;
      final orgDoc = await fs.collection('orgs').doc(code).get();
      if (orgDoc.exists) {
        setState(() { _error = 'このコードは既に使用されています'; _loading = false; });
        return;
      }
      await fs.collection('orgs').doc(code).set({
        'name': name,
        'inviteCode': code,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': AppSession.uid,
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
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const StoreListPage()),
          (_) => false,
        );
      }
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
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
    setState(() { _loading = true; _error = null; });
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
        final snap = await fs.collection('orgs')
            .where('inviteCode', isEqualTo: code)
            .limit(1)
            .get();
        if (snap.docs.isNotEmpty) {
          orgDoc = snap.docs.first;
          resolvedOrgId = snap.docs.first.id;
        }
      }
      if (orgDoc == null || resolvedOrgId == null) {
        setState(() { _error = '組織が見つかりません'; _loading = false; });
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
      setState(() { _error = e.toString(); _loading = false; });
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
            child: const Text('ログアウト',
                style: TextStyle(color: Colors.red)),
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
    setState(() { _loading = true; _error = null; });
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
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Widget _buildSelectMode() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('組織の設定',
                style:
                    TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('ログイン中: ${AppSession.email}',
                style: const TextStyle(color: Colors.grey, fontSize: 13)),
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
                  const Text('以前から使用していた方',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.deepOrange,
                          fontSize: 13)),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _loading ? null : _connectToLegacy,
                      icon: _loading
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white))
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
            const Text('新しく始める方',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                    fontSize: 13)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _loading
                    ? null
                    : () => setState(() { _mode = 'create'; _error = null; }),
                icon: const Icon(Icons.add_business),
                label: const Text('新しい組織を作成する'),
                style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(14)),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _loading
                    ? null
                    : () => setState(() { _mode = 'join'; _error = null; }),
                icon: const Icon(Icons.group_add),
                label: const Text('既存の組織に参加する'),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.all(14)),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13)),
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
          const Text('新しい組織を作成',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 24),
          TextField(
            controller: _orgNameCtrl,
            decoration: const InputDecoration(
                labelText: '組織名', border: OutlineInputBorder()),
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
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () =>
                    setState(() { _mode = null; _error = null; }),
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
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('作成'),
              ),
            ),
          ]),
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
          const Text('既存の組織に参加',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () =>
                    setState(() { _mode = null; _error = null; }),
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
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('参加'),
              ),
            ),
          ]),
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
    setState(() { _saving = true; _error = null; });
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
      setState(() { _saving = false; _error = e.toString(); });
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
            child: const Text('ログアウト',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('ニックネームを設定してください',
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold)),
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
                Text(_error!,
                    style:
                        const TextStyle(color: Colors.red, fontSize: 13)),
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
                          child: CircularProgressIndicator(strokeWidth: 2))
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
    setState(() { _loading = true; _error = null; });
    try {
      final fs = FirebaseFirestore.instance;
      final orgDoc =
          await fs.collection('orgs').doc(AppSession.orgId).get();
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
        _members = membersSnap.docs.map((d) {
          final data = Map<String, dynamic>.from(d.data());
          data['uid'] = d.id;
          return data;
        }).toList()
          ..sort((a, b) {
            if (a['role'] == 'admin' && b['role'] != 'admin') return -1;
            if (a['role'] != 'admin' && b['role'] == 'admin') return 1;
            return (a['email'] ?? '').compareTo(b['email'] ?? '');
          });
        _loading = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
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
              labelText: '新しい組織名', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('保存')),
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
            SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red));
      }
    }
  }

  // ロゴ画像をアップロード
  Future<void> _uploadLogo() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 75,
        maxWidth: 256,
        maxHeight: 256);
    if (picked == null) return;

    setState(() => _logoUploading = true);
    try {
      final bytes = await picked.readAsBytes();
      final b64 = base64Encode(bytes);
      await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .update({'logoBase64': b64});
      AppSession.logoUrl = b64;
      setState(() { _logoUrl = b64; _logoUploading = false; });
    } catch (e) {
      setState(() => _logoUploading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('アップロードエラー: $e'), backgroundColor: Colors.red));
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
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('削除', style: TextStyle(color: Colors.red))),
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
            SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red));
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
        child: Icon(Icons.add_photo_alternate,
            size: 40, color: Colors.deepPurple.shade200),
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
    setState(() { _loading = true; _error = null; });

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
                  border: OutlineInputBorder()),
              obscureText: true,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('削除する',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true || passCtrl.text.isEmpty) return;

    setState(() { _loading = true; _error = null; });
    try {
      // パスワードで再認証
      final user = FirebaseAuth.instance.currentUser!;
      final credential = EmailAuthProvider.credential(
        email: AppSession.email,
        password: passCtrl.text,
      );
      await user.reauthenticateWithCredential(credential);

      final fs = FirebaseFirestore.instance;

      // 全メンバーを組織から外す
      final membersSnap = await fs
          .collection('users')
          .where('orgId', isEqualTo: AppSession.orgId)
          .get();
      final batch = fs.batch();
      for (final doc in membersSnap.docs) {
        batch.update(doc.reference, {'orgId': '', 'role': 'admin'});
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
        _error = (e.code == 'wrong-password' ||
                e.code == 'invalid-credential')
            ? 'パスワードが正しくありません'
            : '認証エラー: ${e.code}';
        _loading = false;
      });
    } catch (e) {
      debugPrint('_deleteOrg error: $e');
      setState(() { _error = e.toString(); _loading = false; });
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
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('削除',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({'orgId': '', 'role': 'admin'});
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('エラー: $e'),
                backgroundColor: Colors.red));
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
              const Text('メンバーが参加時に入力するコードです。\n英小文字・数字・_のみ使用できます。',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                    labelText: '新しい招待コード', border: OutlineInputBorder()),
                autocorrect: false,
                autofocus: true,
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              if (dialogError != null) ...[
                const SizedBox(height: 6),
                Text(dialogError!,
                    style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('キャンセル')),
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
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('招待コードを変更しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red));
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
          IconButton(
              icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!))
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
                                  child: Center(
                                      child: CircularProgressIndicator()))
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
                                icon: const Icon(Icons.delete,
                                    color: Colors.red, size: 20),
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
                        label: Text(_logoUrl.isNotEmpty
                            ? 'ロゴを変更'
                            : 'ロゴをアップロード'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // ── 組織名 ──
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.business),
                        title: Text(_orgName,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                        subtitle: Text('招待コード: $_inviteCode'),
                        trailing: PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert),
                          onSelected: (v) async {
                            if (v == 'rename') {
                              _renameOrg();
                            } else if (v == 'copy') {
                              final messenger = ScaffoldMessenger.of(context);
                              await Clipboard.setData(
                                  ClipboardData(text: _inviteCode));
                              messenger.showSnackBar(const SnackBar(
                                  content: Text('招待コードをコピーしました')));
                            } else if (v == 'change_code') {
                              _changeInviteCode();
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'rename',
                              child: Row(children: [
                                Icon(Icons.edit, size: 18),
                                SizedBox(width: 8),
                                Text('組織名を変更'),
                              ]),
                            ),
                            PopupMenuItem(
                              value: 'copy',
                              child: Row(children: [
                                Icon(Icons.copy, size: 18),
                                SizedBox(width: 8),
                                Text('招待コードをコピー'),
                              ]),
                            ),
                            PopupMenuItem(
                              value: 'change_code',
                              child: Row(children: [
                                Icon(Icons.key, size: 18),
                                SizedBox(width: 8),
                                Text('招待コードを変更'),
                              ]),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('メンバー (${_members.length}名)',
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
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
                                      : Colors.grey.shade700),
                            ),
                          ),
                          title: Text(
                              m['nickname']?.toString().isNotEmpty == true
                                  ? m['nickname'].toString()
                                  : m['email']?.toString() ?? m['uid'].toString(),
                              style: const TextStyle(fontSize: 14)),
                          subtitle: Text(
                              '${m['role'] == 'admin' ? '管理者' : 'メンバー'}　${m['email'] ?? ''}',
                              style: const TextStyle(fontSize: 12)),
                          trailing: m['uid'] == AppSession.uid
                              ? const Chip(label: Text('自分'))
                              : IconButton(
                                  icon: const Icon(
                                      Icons.person_remove,
                                      color: Colors.red),
                                  tooltip: 'メンバーを削除',
                                  onPressed: () => _removeMember(
                                      m['uid'].toString(),
                                      m['email']?.toString() ?? ''),
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
                        icon: const Icon(Icons.delete_forever,
                            color: Colors.red),
                        label: const Text('組織を削除する',
                            style: TextStyle(color: Colors.red)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.red),
                          padding: const EdgeInsets.all(14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '※ すべての在庫を0にしてから削除できます',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey),
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
            // 広告コンテンツ
            Center(
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
                            color: Colors.white, fontSize: 16),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // カウントダウン
            Positioned(
              top: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _remaining > 0 ? '$_remaining 秒' : '閉じる',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13),
                ),
              ),
            ),
            // 広告主名
            Positioned(
              bottom: 16,
              right: 16,
              child: Text(
                '提供: ${ad.orgName}',
                style: TextStyle(
                    color: Colors.white54, fontSize: 11),
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
    if (AppSession.adMode == 'distributed' &&
        AppSession.distributedAds.isNotEmpty) {
      _timer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (!mounted) return;
        final ads = AppSession.distributedAds;
        if (ads.isEmpty) return;
        setState(() {
          _index = (_index + 1) % ads.length;
          _tick++;
        });
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = AppSession.adMode;
    if (mode.isEmpty) return const SizedBox.shrink();

    if (mode == 'custom') {
      final hasImage = AppSession.adImage.isNotEmpty;
      final hasMsg = AppSession.adMessage.isNotEmpty;
      if (!hasImage && !hasMsg) return const SizedBox.shrink();
      return Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 80, maxHeight: 160),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Colors.grey.shade300)),
        ),
        child: Row(
          children: [
            if (hasImage)
              Padding(
                padding: const EdgeInsets.all(8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    base64Decode(AppSession.adImage),
                    height: 100,
                    width: 100,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            if (hasMsg)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  child: Text(
                    AppSession.adMessage,
                    style: const TextStyle(fontSize: 13),
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    if (mode == 'distributed') {
      final ads = AppSession.distributedAds;
      if (ads.isEmpty) return const SizedBox.shrink();
      final ad = ads[_index % ads.length];
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 600),
        child: Container(
          key: ValueKey(_tick),
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
                            horizontal: 12, vertical: 8),
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
                child: Text(
                  '提供: ${ad.orgName}',
                  style: TextStyle(
                      fontSize: 10, color: Colors.grey.shade500),
                ),
              ),
            ],
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
  String _mode = '';
  String _image = '';
  final _msgCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _imgUploading = false;

  @override
  void initState() {
    super.initState();
    _mode = AppSession.adMode;
    _image = AppSession.adImage;
    _msgCtrl.text = AppSession.adMessage;
    _loading = false;
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 75,
        maxWidth: 400,
        maxHeight: 300);
    if (picked == null) return;
    setState(() => _imgUploading = true);
    try {
      final bytes = await picked.readAsBytes();
      setState(() { _image = base64Encode(bytes); _imgUploading = false; });
    } catch (_) {
      setState(() => _imgUploading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .update({
        'adMode': _mode,
        'adImage': _mode == 'custom' ? _image : '',
        'adMessage': _mode == 'custom' ? _msgCtrl.text.trim() : '',
      });
      AppSession.adMode = _mode;
      AppSession.adImage = _mode == 'custom' ? _image : '';
      AppSession.adMessage = _mode == 'custom' ? _msgCtrl.text.trim() : '';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('保存しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('エラー: $e'),
                backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('広告スペース管理'),
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : TextButton(
                  onPressed: _save,
                  child: const Text('保存',
                      style: TextStyle(fontWeight: FontWeight.bold))),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── 表示モード ──
                const Text('表示モード',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      _modeOption('', '非表示', 'バナーを表示しない'),
                      _modeOption('custom', '自社メッセージ', '画像・テキストを自由に設定'),
                      _modeOption('distributed', '配信広告を受信', '他組織からの広告を1分毎にローテーション表示'),
                    ],
                  ),
                ),

                if (_mode == 'custom') ...[
                  const SizedBox(height: 20),
                  const Text('バナー画像（任意）',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Center(
                    child: GestureDetector(
                      onTap: _pickImage,
                      child: _imgUploading
                          ? const SizedBox(
                              width: 180,
                              height: 100,
                              child: Center(
                                  child: CircularProgressIndicator()))
                          : _image.isNotEmpty
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(
                                    base64Decode(_image),
                                    height: 120,
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : Container(
                                  width: 180,
                                  height: 100,
                                  decoration: BoxDecoration(
                                    color: Colors.deepPurple.shade50,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: Colors.deepPurple.shade100),
                                  ),
                                  child: Icon(Icons.add_photo_alternate,
                                      size: 40,
                                      color: Colors.deepPurple.shade200),
                                ),
                    ),
                  ),
                  Center(
                    child: TextButton.icon(
                      onPressed: _pickImage,
                      icon: const Icon(Icons.upload_file, size: 16),
                      label: Text(
                          _image.isNotEmpty ? '画像を変更' : '画像をアップロード'),
                    ),
                  ),
                  if (_image.isNotEmpty)
                    Center(
                      child: TextButton(
                        onPressed: () => setState(() => _image = ''),
                        child: const Text('画像を削除',
                            style: TextStyle(color: Colors.red)),
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Text('メッセージテキスト（任意）',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _msgCtrl,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: '表示したいメッセージを入力',
                      border: OutlineInputBorder(),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                ],

                // ── プレビュー ──
                const SizedBox(height: 24),
                const Text('プレビュー',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _buildPreview(),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _modeOption(String value, String title, String subtitle) {
    final selected = _mode == value;
    return InkWell(
      onTap: () => setState(() => _mode = value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: selected ? Colors.deepPurple : Colors.grey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontWeight: selected
                              ? FontWeight.bold
                              : FontWeight.normal)),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    if (_mode.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
            child: Text('非表示',
                style: TextStyle(color: Colors.grey))),
      );
    }
    if (_mode == 'distributed') {
      return Container(
        width: double.infinity,
        height: 80,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.teal.shade50, Colors.teal.shade100],
          ),
        ),
        child: const Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('配信広告バナー',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.teal)),
                SizedBox(height: 4),
                Text('他組織の広告が1分ごとに表示されます',
                    style: TextStyle(
                        fontSize: 11, color: Colors.teal)),
              ],
            ),
          ],
        ),
      );
    }
    // custom
    final hasImage = _image.isNotEmpty;
    final hasMsg = _msgCtrl.text.isNotEmpty;
    if (!hasImage && !hasMsg) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
            child: Text('画像またはメッセージを設定してください',
                style: TextStyle(color: Colors.grey))),
      );
    }
    return Container(
      constraints:
          const BoxConstraints(minHeight: 80, maxHeight: 160),
      color: Colors.white,
      child: Row(
        children: [
          if (hasImage)
            Padding(
              padding: const EdgeInsets.all(8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  base64Decode(_image),
                  height: 100,
                  width: 100,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          if (hasMsg)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                child: Text(
                  _msgCtrl.text,
                  style: const TextStyle(fontSize: 13),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
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
        _orgs = snap.docs
            .map((d) => {'id': d.id, ...d.data()})
            .toList();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  Future<void> _toggleAdDistrib(String orgId, bool current) async {
    final newVal = !current;
    await FirebaseFirestore.instance
        .collection('orgs')
        .doc(orgId)
        .update({'adDistribEnabled': newVal});
    setState(() {
      final idx = _orgs.indexWhere((o) => o['id'] == orgId);
      if (idx != -1) _orgs[idx]['adDistribEnabled'] = newVal;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('統括管理'),
        actions: [
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
          : _orgs.isEmpty
              ? const Center(child: Text('組織が見つかりません'))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _orgs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final org = _orgs[i];
                    final orgId = org['id'] as String;
                    final name = (org['name'] as String?) ?? orgId;
                    final enabled =
                        (org['adDistribEnabled'] as bool?) ?? false;
                    final adMode = (org['adMode'] as String?) ?? '';
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.deepPurple.shade100,
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.deepPurple),
                        ),
                      ),
                      title: Text(name,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold)),
                      subtitle: Text(
                        '広告モード: ${adMode.isEmpty ? '非表示' : adMode}',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            enabled ? '配信可' : '配信不可',
                            style: TextStyle(
                              fontSize: 12,
                              color: enabled ? Colors.teal : Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Switch(
                            value: enabled,
                            activeThumbColor: Colors.teal,
                            onChanged: (_) =>
                                _toggleAdDistrib(orgId, enabled),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
