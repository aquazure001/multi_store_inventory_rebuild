part of '../main.dart';

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
  int _maxItems = 10;

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
      final results = await Future.wait([
        FirebaseFirestore.instance
            .collection('inventory_shared_v1')
            .doc(widget.docId)
            .get(),
        FirebaseFirestore.instance
            .collection('orgs')
            .doc(AppSession.orgId)
            .get(),
      ]);
      final doc = results[0];
      final orgDoc = results[1];
      final orgData = orgDoc.data() ?? <String, dynamic>{};
      final maxItems = switch (widget.label) {
        '商品' => inventoryIntValue(orgData['maxProducts']),
        'テスター' => inventoryIntValue(orgData['maxTesters']),
        '備品' => inventoryIntValue(orgData['maxEquipments']),
        _ => 10,
      };
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
        _maxItems = maxItems > 0 ? maxItems : 10;
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
      if (a.code.isEmpty && b.code.isEmpty) {
        return _naturalCompare(a.name, b.name);
      }
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
    _clearMasterDataCache();
  }

  Future<Map<String, dynamic>?> _showItemDialog({
    String? initialCode,
    String? initialName,
    int initialTaxExcludedPrice = 0,
    bool initialReducedTax = false,
  }) async {
    final codeCtrl = TextEditingController(text: initialCode ?? '');
    final nameCtrl = TextEditingController(text: initialName ?? '');
    final priceCtrl = TextEditingController(
      text: initialTaxExcludedPrice > 0
          ? initialTaxExcludedPrice.toString()
          : '',
    );
    var reducedTax = initialReducedTax;
    final isProduct = widget.label == '商品';
    final isNew = initialName == null;
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isNew ? '${widget.label}を追加' : '${widget.label}を編集'),
          content: SingleChildScrollView(
            child: Column(
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
                if (isProduct) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: priceCtrl,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(
                      labelText: '税抜価格',
                      prefixText: '￥',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Builder(
                    builder: (_) {
                      final price = inventoryIntValue(priceCtrl.text);
                      final taxRate = reducedTax ? 8 : 10;
                      final included = (price * (100 + taxRate) / 100).round();
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          price > 0
                              ? '税込価格：￥${included.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',')}（$taxRate%）'
                              : '税込価格：未設定',
                          style: TextStyle(
                            color: Colors.grey.shade700,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      );
                    },
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: reducedTax,
                    onChanged: (value) {
                      setDialogState(() {
                        reducedTax = value == true;
                      });
                    },
                    title: const Text('軽減税率（8%）'),
                    subtitle: const Text('チェックなしは10%で計算'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ],
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
                  'code': codeCtrl.text.trim(),
                  'name': name,
                  'taxExcludedPrice': inventoryIntValue(priceCtrl.text),
                  'reducedTax': reducedTax,
                });
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addItem() async {
    if (_rawItems.length >= _maxItems) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${widget.label}マスタの上限（$_maxItems件）に達しています'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final result = await _showItemDialog();
    if (result == null) return;

    final newId = FirebaseFirestore.instance.collection('_').doc().id;
    setState(() {
      _rawItems.add({
        'id': newId,
        'code': result['code']!,
        'name': result['name']!,
        if (widget.label == '商品')
          'taxExcludedPrice': inventoryIntValue(result['taxExcludedPrice']),
        if (widget.label == '商品') 'reducedTax': result['reducedTax'] == true,
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
      initialTaxExcludedPrice: item.taxExcludedPrice,
      initialReducedTax: item.reducedTax,
    );
    if (result == null) return;

    final idx = _rawItems.indexWhere((m) => m['id'] == item.id);
    if (idx < 0) return;

    final oldMap = Map<String, dynamic>.from(_rawItems[idx]);
    setState(() {
      _rawItems[idx] = Map<String, dynamic>.from(_rawItems[idx])
        ..['code'] = result['code']!
        ..['name'] = result['name']!
        ..['taxExcludedPrice'] = inventoryIntValue(result['taxExcludedPrice'])
        ..['reducedTax'] = result['reducedTax'] == true
        ..['taxRate'] = result['reducedTax'] == true ? 8 : 10;
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

  String _csvCell(Object? value) {
    final text = (value ?? '').toString();
    final escaped = text.replaceAll('"', '""');
    return '"$escaped"';
  }

  Future<void> _exportCsv() async {
    final rows = <List<Object?>>[
      [
        '種別',
        '商品ID',
        '商品コード',
        '商品名',
        '税抜価格',
        '税率',
        '税込価格',
        '販売終了',
        'TANOMU取込メモ',
      ],
    ];

    for (final item in _items) {
      rows.add([
        widget.label,
        item.id,
        item.code,
        item.name,
        widget.label == '商品' && item.taxExcludedPrice > 0
            ? item.taxExcludedPrice
            : '',
        widget.label == '商品' ? (item.reducedTax ? '8%' : '10%') : '',
        widget.label == '商品' && item.taxExcludedPrice > 0
            ? (item.taxExcludedPrice * (100 + (item.reducedTax ? 8 : 10)) / 100)
                  .round()
            : '',
        item.discontinued ? 'TRUE' : 'FALSE',
        item.discontinued ? '販売終了商品のため取込対象外または無効化候補' : '',
      ]);
    }

    final csv = rows.map((row) => row.map(_csvCell).join(',')).join('\r\n');
    final bytes = utf8.encode('\ufeff$csv');
    final blob = html.Blob([bytes], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final safeLabel = widget.label.replaceAll(
      RegExp(r'[^\w\u3040-\u30ff\u3400-\u9fff]+'),
      '_',
    );
    html.AnchorElement(href: url)
      ..download = '商品マスタ_${safeLabel}_$stamp.csv'
      ..click();
    html.Url.revokeObjectUrl(url);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${widget.label}マスタCSVを出力しました'),
        backgroundColor: Colors.green,
      ),
    );
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
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: 3 + filtered.length,
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
              if (index == 2) {
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${widget.label}数',
                                style: const TextStyle(fontSize: 16),
                              ),
                            ),
                            Text(
                              '${_items.length} / $_maxItems 件',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _items.isEmpty ? null : _exportCsv,
                          icon: const Icon(Icons.download),
                          label: Text('${widget.label}マスタCSV出力'),
                        ),
                      ],
                    ),
                  ),
                );
              }

              final item = filtered[index - 3];
              return Card(
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
                            style: TextStyle(fontSize: 10, color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                  subtitle: Text(
                    widget.label == '商品'
                        ? 'コード: ${item.code} / 税抜: ${item.taxExcludedPrice > 0 ? '￥${item.taxExcludedPrice}' : '未設定'} / 税率: ${item.reducedTax ? '8%' : '10%'}'
                        : 'コード: ${item.code}',
                  ),
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
              onPressed: _rawItems.length >= _maxItems ? null : _addItem,
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
