part of '../main.dart';

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
