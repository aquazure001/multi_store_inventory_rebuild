import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

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
    final c = a.code.compareTo(b.code);
    return c != 0 ? c : a.name.compareTo(b.name);
  });
  return items;
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

class StoreListPage extends StatelessWidget {
  const StoreListPage({super.key});

  Future<List<LegacyStore>> _loadStores() async {
    final doc = await FirebaseFirestore.instance
        .collection('inventory_shared_v1')
        .doc('org_legacy__stores')
        .get();

    final data = doc.data();
    if (data == null) return [];

    final raw = data['items'];
    if (raw is! List) return [];

    final stores = raw.whereType<Map>().map((item) {
      final map = item.map((key, value) => MapEntry(key.toString(), value));
      return LegacyStore.fromMap(map);
    }).toList();

    stores.sort((a, b) => a.code.compareTo(b.code));
    return stores;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('店舗一覧'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '修正・追加履歴',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HistoryPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.table_chart),
            tooltip: '全店舗在庫確認',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AllStoresInventoryPage()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<List<LegacyStore>>(
          future: _loadStores(),
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

            final stores = snapshot.data ?? [];

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '多店舗在庫管理システム',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
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
                  color: Colors.deepPurple.shade50,
                  child: ListTile(
                    leading:
                        const Icon(Icons.table_chart, color: Colors.deepPurple),
                    title: const Text(
                      '全店舗在庫確認',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: const Text('商品ごとに全店舗の在庫を一覧表示'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const AllStoresInventoryPage()),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  color: Colors.teal.shade50,
                  child: ListTile(
                    leading: const Icon(Icons.history, color: Colors.teal),
                    title: const Text(
                      '修正・追加履歴',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: const Text('在庫変更の記録を確認'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const HistoryPage()),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    title: const Text('店舗数'),
                    trailing: Text(
                      '${stores.length} 件',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (final store in stores)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        child: Text(store.code.isEmpty ? '-' : store.code),
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
                            builder: (_) => StoreInventoryPage(store: store)),
                      ),
                    ),
                  ),
              ],
            );
          },
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

    return snap.docs
        .map((doc) => HistoryEntry.fromDoc(doc))
        .toList();
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
    final bgColor =
        delta > 0 ? Colors.green.shade50 : Colors.red.shade50;

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
    ]);

    final storesRaw = results[0].data()?['items'];
    final stores = <LegacyStore>[];
    if (storesRaw is List) {
      for (final item in storesRaw.whereType<Map>()) {
        final map = item.map((k, v) => MapEntry(k.toString(), v));
        final store = LegacyStore.fromMap(map);
        if (store.id.isNotEmpty) stores.add(store);
      }
      stores.sort((a, b) => a.code.compareTo(b.code));
    }

    final stocksData = results[4].data() ?? {};
    final stocksByStore = <String, Map<String, int>>{};
    for (final store in stores) {
      stocksByStore[store.id] = _parseStocksForStore(stocksData, store.id);
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
    ]);

    final stocksData = results[3].data() ?? {};

    return _InventoryData(
      products: _parseItemsFromDoc(results[0]),
      testers: _parseItemsFromDoc(results[1]),
      equipments: _parseItemsFromDoc(results[2]),
      stocks: _parseStocksForStore(stocksData, store.id),
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
                    stocks: {},
                  );

              return TabBarView(
                children: [
                  _InventoryList(
                    title: '商品',
                    items: data.products,
                    stocks: data.stocks,
                    storeId: store.id,
                    storeName: store.name,
                  ),
                  _InventoryList(
                    title: 'テスター',
                    items: data.testers,
                    stocks: data.stocks,
                    storeId: store.id,
                    storeName: store.name,
                  ),
                  _InventoryList(
                    title: '備品',
                    items: data.equipments,
                    stocks: data.stocks,
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
    required this.storeId,
    required this.storeName,
  });

  final String title;
  final List<LegacyItem> items;
  final Map<String, int> stocks;
  final String storeId;
  final String storeName;

  @override
  State<_InventoryList> createState() => _InventoryListState();
}

class _InventoryListState extends State<_InventoryList> {
  String _query = '';
  late Map<String, int> _localStocks;
  final Set<String> _changedIds = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _localStocks = Map.from(widget.stocks);
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
                  child: Text('• ${c.item.name}: ${c.oldCount} → ${c.newCount}'),
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
      // 在庫更新
      final Map<String, dynamic> stockUpdates = {};
      for (final id in _changedIds) {
        stockUpdates['${widget.storeId}.$id'] = _localStocks[id] ?? 0;
      }
      await FirebaseFirestore.instance
          .collection('inventory_shared_v1')
          .doc('org_legacy__stocks')
          .update(stockUpdates);

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
                                color: _changedIds.contains(item.id)
                                    ? Colors.orange
                                    : null,
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
// データクラス
// ─────────────────────────────────────────────

class _InventoryData {
  const _InventoryData({
    required this.products,
    required this.testers,
    required this.equipments,
    required this.stocks,
  });

  final List<LegacyItem> products;
  final List<LegacyItem> testers;
  final List<LegacyItem> equipments;
  final Map<String, int> stocks;
}
