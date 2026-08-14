part of '../main.dart';

// ─────────────────────────────────────────────
// 販売終了テスター一覧ページ
// ─────────────────────────────────────────────

class DiscontinuedTestersPage extends StatefulWidget {
  const DiscontinuedTestersPage({super.key});

  @override
  State<DiscontinuedTestersPage> createState() =>
      _DiscontinuedTestersPageState();
}

class _DiscontinuedTestersPageState extends State<DiscontinuedTestersPage> {
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
          .doc('org_${AppSession.orgId}__testers')
          .get();
      final raw = doc.data()?['items'];
      final items = <LegacyItem>[];
      if (raw is List) {
        for (final item in raw.whereType<Map>()) {
          final map = Map<String, dynamic>.from(
            item.map((k, v) => MapEntry(k.toString(), v)),
          );
          final legacy = LegacyItem.fromMap(map);
          if (legacy.id.isNotEmpty && legacy.discontinued) {
            items.add(legacy);
          }
        }
      }
      items.sort((a, b) {
        if (a.code.isEmpty && b.code.isEmpty) {
          return _naturalCompare(a.name, b.name);
        }
        if (a.code.isEmpty) return 1;
        if (b.code.isEmpty) return -1;
        final c = _naturalCompare(a.code, b.code);
        return c != 0 ? c : _naturalCompare(a.name, b.name);
      });
      setState(() {
        _items = items;
        _loading = false;
      });
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
      appBar: AppBar(title: const Text('販売終了テスター一覧')),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
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

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 2 + filtered.length,
      itemBuilder: (context, index) {
        if (index == 0) {
          return TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '検索...',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v),
          );
        }
        if (index == 1) return const SizedBox(height: 12);

        final item = filtered[index - 2];
        return Card(
          color: Colors.grey.shade100,
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: Colors.grey.shade300,
              child: Text(
                item.code.isEmpty ? '-' : item.code,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    item.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
                ),
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
                    style: TextStyle(fontSize: 10, color: Colors.white),
                  ),
                ),
              ],
            ),
            subtitle: Text(
              'コード: ${item.code} / 税抜: ${item.taxExcludedPrice > 0 ? '￥${item.taxExcludedPrice}' : '未設定'} / 税率: ${item.reducedTax ? '8%' : '10%'}',
            ),
          ),
        );
      },
    );
  }
}
