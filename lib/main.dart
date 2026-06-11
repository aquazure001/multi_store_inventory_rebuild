import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
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
  });

  final String id;
  final String code;
  final String name;

  factory LegacyItem.fromMap(Map<String, dynamic> map) {
    return LegacyItem(
      id: (map['id'] ?? '').toString(),
      code: (map['code'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
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
      home: const StoreListPage(),
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
      final doc = await FirebaseFirestore.instance
          .collection('inventory_shared_v1')
          .doc('org_legacy__stores')
          .get();

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
        title: const Text('店舗一覧'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
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
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const OrderListPage()));
              } else if (value == 'reorder') {
                _goToReorder();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'all_stores',
                child: Row(
                  children: [
                    Icon(Icons.table_chart),
                    SizedBox(width: 12),
                    Text('全店舗在庫確認'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'history',
                child: Row(
                  children: [
                    Icon(Icons.history),
                    SizedBox(width: 12),
                    Text('修正・追加履歴'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'items',
                child: Row(
                  children: [
                    Icon(Icons.inventory_2),
                    SizedBox(width: 12),
                    Text('商品マスタ管理'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'order',
                child: Row(
                  children: [
                    Icon(Icons.shopping_cart),
                    SizedBox(width: 12),
                    Text('発注リスト'),
                  ],
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'reorder',
                child: Row(
                  children: [
                    Icon(Icons.reorder),
                    SizedBox(width: 12),
                    Text('店舗の並び替え'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
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
                      const SizedBox(height: 8),
                      const Text(
                        '復旧開発版：本番未反映',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontWeight: FontWeight.bold,
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
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) =>
                                      StoreInventoryPage(store: store)),
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
      final doc = await FirebaseFirestore.instance
          .collection('inventory_shared_v1')
          .doc('org_legacy__stores')
          .get();

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
      await FirebaseFirestore.instance
          .collection('inventory_shared_v1')
          .doc('org_legacy__stores')
          .update({'items': _rawMaps});

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
    final snap = await FirebaseFirestore.instance
        .collection('inventory_shared_v1')
        .doc('org_legacy__history')
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
            Text(
              _formatDateTime(entry.at),
              style: const TextStyle(color: Colors.grey, fontSize: 12),
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
    final base = FirebaseFirestore.instance.collection('inventory_shared_v1');

    final results = await Future.wait([
      base.doc('org_legacy__stores').get(),
      base.doc('org_legacy__products').get(),
      base.doc('org_legacy__testers').get(),
      base.doc('org_legacy__equipments').get(),
      base.doc('org_legacy__stocks').get(),
      base.doc('org_legacy__stocks_v2').get(),
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
    final base = FirebaseFirestore.instance.collection('inventory_shared_v1');

    final results = await Future.wait([
      base.doc('org_legacy__products').get(),
      base.doc('org_legacy__testers').get(),
      base.doc('org_legacy__equipments').get(),
      base.doc('org_legacy__stocks').get(),
      base.doc('org_legacy__baseline').get(),
      base.doc('org_legacy__stocks_v2').get(),
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

    final docRef = FirebaseFirestore.instance
        .collection('inventory_shared_v1')
        .doc('org_legacy__baseline');
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
        await FirebaseFirestore.instance
            .collection('inventory_shared_v1')
            .doc('org_legacy__stocks')
            .update(stockUpdates);
      } else {
        final typeKey = widget.title == 'テスター' ? 'testers' : 'equipments';
        for (final id in _changedIds) {
          stockUpdates['$typeKey.${widget.storeId}.$id'] = _localStocks[id] ?? 0;
        }
        final v2Ref = FirebaseFirestore.instance
            .collection('inventory_shared_v1')
            .doc('org_legacy__stocks_v2');
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
      final historyRef = FirebaseFirestore.instance
          .collection('inventory_shared_v1')
          .doc('org_legacy__history')
          .collection('entries');

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
                  child: ListTile(
                    title: Text(
                      item.name,
                      style: const TextStyle(fontWeight: FontWeight.bold),
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
                              color: Colors.blue.shade50,
                              border: Border.all(color: Colors.blue.shade200),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '基準',
                                  style: TextStyle(fontSize: 9, color: Colors.blue.shade600),
                                ),
                                Text(
                                  '${_localBaseStocks[item.id] ?? 0}',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          color: Colors.redAccent,
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
                          color: Colors.green,
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
        body: const SafeArea(
          child: TabBarView(
            children: [
              _ItemMasterTab(docId: 'org_legacy__products', label: '商品'),
              _ItemMasterTab(docId: 'org_legacy__testers', label: 'テスター'),
              _ItemMasterTab(docId: 'org_legacy__equipments', label: '備品'),
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
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        item.code.isEmpty ? '-' : item.code,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    title: Text(
                      item.name,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text('コード: ${item.code}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
    final base = FirebaseFirestore.instance.collection('inventory_shared_v1');
    final results = await Future.wait([
      base.doc('org_legacy__stores').get(),
      base.doc('org_legacy__products').get(),
      base.doc('org_legacy__testers').get(),
      base.doc('org_legacy__equipments').get(),
      base.doc('org_legacy__stocks').get(),
      base.doc('org_legacy__baseline').get(),
      base.doc('org_legacy__stocks_v2').get(),
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

  Future<void> _exportPdf(
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
          '発注リスト',
          style: pw.TextStyle(font: font, fontSize: 18, fontWeight: pw.FontWeight.bold),
        ),
        build: (ctx) {
          final widgets = <pw.Widget>[];
          byStore.forEach((store, storeEntries) {
            widgets.add(pw.SizedBox(height: 12));
            widgets.add(pw.Text(
              '■ ${store.name}',
              style: pw.TextStyle(font: font, fontSize: 13, fontWeight: pw.FontWeight.bold),
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
      filename: '発注リスト.pdf',
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

  // タブ①：店舗ごと → 商品/テスター/備品セクション
  Widget _buildByStore(List<_OrderEntry> entries) {
    final byStore = <LegacyStore, Map<String, List<_OrderEntry>>>{};
    for (final e in entries) {
      byStore.putIfAbsent(e.store, () => {});
      byStore[e.store]!.putIfAbsent(e.itemType, () => []).add(e);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final store in byStore.keys) ...[
          _sectionHeader('■ ${store.name}', color: Colors.indigo.shade700),
          for (final type in _types)
            if (byStore[store]!.containsKey(type)) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 0, 2),
                child: Text(type,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              ),
              Card(
                margin: const EdgeInsets.only(bottom: 4),
                child: Column(children: [
                  _tableHeader(),
                  for (final e in byStore[store]![type]!) _tableRow(e),
                ]),
              ),
            ],
        ],
      ],
    );
  }

  // タブ②：商品/テスター/備品ごと → 店舗別
  Widget _buildByType(List<_OrderEntry> entries) {
    final byType = <String, Map<LegacyStore, List<_OrderEntry>>>{};
    for (final e in entries) {
      byType.putIfAbsent(e.itemType, () => {});
      byType[e.itemType]!.putIfAbsent(e.store, () => []).add(e);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final type in _types)
          if (byType.containsKey(type)) ...[
            _sectionHeader('■ $type', color: Colors.teal.shade700),
            for (final store in byType[type]!.keys) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 0, 2),
                child: Text(store.name,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              ),
              Card(
                margin: const EdgeInsets.only(bottom: 4),
                child: Column(children: [
                  _tableHeader(),
                  for (final e in byType[type]![store]!) _tableRow(e),
                ]),
              ),
            ],
          ],
      ],
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
            FutureBuilder<List<_OrderEntry>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.data == null || snapshot.data!.isEmpty) {
                  return const SizedBox.shrink();
                }
                return IconButton(
                  icon: const Icon(Icons.picture_as_pdf),
                  tooltip: 'PDFで出力',
                  onPressed: () => _exportPdf(context, snapshot.data!),
                );
              },
            ),
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
                _buildByStore(entries),
                _buildByType(entries),
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
