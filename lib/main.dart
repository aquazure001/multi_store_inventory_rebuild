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
      appBar: AppBar(title: const Text('店舗一覧')),
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
                const SizedBox(height: 16),
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
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => StoreInventoryPage(store: store),
                          ),
                        );
                      },
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

class StoreInventoryPage extends StatelessWidget {
  const StoreInventoryPage({
    super.key,
    required this.store,
  });

  final LegacyStore store;

  Future<_InventoryData> _loadInventory() async {
    final base = FirebaseFirestore.instance.collection('inventory_shared_v1');

    final productsDoc = await base.doc('org_legacy__products').get();
    final testersDoc = await base.doc('org_legacy__testers').get();
    final equipmentsDoc = await base.doc('org_legacy__equipments').get();
    final stocksDoc = await base.doc('org_legacy__stocks').get();

    final products = _readItems(productsDoc);
    final testers = _readItems(testersDoc);
    final equipments = _readItems(equipmentsDoc);

    final stocksData = stocksDoc.data() ?? {};
    final storeStockRaw = stocksData[store.id];

    final Map<String, int> stocks = {};
    if (storeStockRaw is Map) {
      for (final entry in storeStockRaw.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is int) {
          stocks[key] = value;
        } else if (value is num) {
          stocks[key] = value.toInt();
        }
      }
    }

    return _InventoryData(
      products: products,
      testers: testers,
      equipments: equipments,
      stocks: stocks,
    );
  }

  List<LegacyItem> _readItems(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) return [];

    final raw = data['items'];
    if (raw is! List) return [];

    final items = raw.whereType<Map>().map((item) {
      final map = item.map((key, value) => MapEntry(key.toString(), value));
      return LegacyItem.fromMap(map);
    }).where((item) => item.id.isNotEmpty).toList();

    items.sort((a, b) {
      final codeCompare = a.code.compareTo(b.code);
      if (codeCompare != 0) return codeCompare;
      return a.name.compareTo(b.name);
    });

    return items;
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
                  ),
                  _InventoryList(
                    title: 'テスター',
                    items: data.testers,
                    stocks: data.stocks,
                  ),
                  _InventoryList(
                    title: '備品',
                    items: data.equipments,
                    stocks: data.stocks,
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

class _InventoryList extends StatefulWidget {
  const _InventoryList({
    required this.title,
    required this.items,
    required this.stocks,
  });

  final String title;
  final List<LegacyItem> items;
  final Map<String, int> stocks;

  @override
  State<_InventoryList> createState() => _InventoryListState();
}

class _InventoryListState extends State<_InventoryList> {
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
          onChanged: (value) {
            setState(() {
              _query = value;
            });
          },
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            title: Text('${widget.title}数'),
            trailing: Text(
              '${filtered.length} 件',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
              subtitle: Text('コード: ${item.code}\nID: ${item.id}'),
              trailing: Text(
                '${widget.stocks[item.id] ?? 0}',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

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