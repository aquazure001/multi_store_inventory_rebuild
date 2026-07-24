part of '../main.dart';

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
  bool _creatingPdf = false;

  static const _types = ['商品', 'テスター', '備品'];

  bool get _canConfirmOrders => AppSession.isAdmin || AppSession.isSuperAdmin;

  void _showOrderPermissionMessage(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('発注操作は管理者のみ行えます'),
        backgroundColor: Colors.orange,
      ),
    );
  }

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

  Map<String, dynamic> _orderRequestLogData(
    _OrderEntry entry,
    int qty,
    int totalQty,
    String source,
  ) {
    return {
      'requestedAt': FieldValue.serverTimestamp(),
      'requestedAtLocal': DateTime.now().toIso8601String(),
      'requestedBy': AppSession.nickname,
      'uid': AppSession.uid,
      'storeId': entry.store.id,
      'storeName': entry.store.name,
      'itemType': entry.itemType,
      'typeKey': _typeKeyForType(entry.itemType),
      'itemId': entry.item.id,
      'itemName': entry.item.name,
      'itemCode': entry.item.code,
      'qty': qty,
      'totalQtyAfterRequest': totalQty,
      'source': source,
    };
  }

  Future<void> _recordOrderRequestLog(
    _OrderEntry entry,
    int qty,
    int totalQty,
    String source,
  ) async {
    await AppSession.doc('order_request_history')
        .collection('entries')
        .add(_orderRequestLogData(entry, qty, totalQty, source));
  }

  Future<void> _placeOrder(
    BuildContext context,
    _OrderEntry entry,
    int qty,
  ) async {
    if (!_canConfirmOrders) {
      _showOrderPermissionMessage(context);
      return;
    }
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
              ? '${entry.store.name}\n${entry.item.name}\n$existingQty個納品予定ですが、追加で $qty個 発注しますか？\n\n合計の納品予定数は $totalQty個 になります。'
              : '${entry.store.name}\n${entry.item.name}\nを ${qty}個、発注リストに登録します。\n\n※「発注確定PDF」を出した時点で発注日として記録されます。',
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
        '${_orderMetaField(entry)}.itemCode': entry.item.code,
        '${_orderMetaField(entry)}.itemType': entry.itemType,
        '${_orderMetaField(entry)}.lastRequestedQty': qty,
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
                'itemCode': entry.item.code,
                'itemType': entry.itemType,
                'lastRequestedQty': qty,
              },
            },
          });
        } else {
          rethrow;
        }
      }

      await _recordOrderRequestLog(entry, qty, totalQty, 'single');

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
    if (!_canConfirmOrders) {
      _showOrderPermissionMessage(context);
      return;
    }
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
        updates['${_orderMetaField(e)}.itemCode'] = e.item.code;
        updates['${_orderMetaField(e)}.itemType'] = e.itemType;
        updates['${_orderMetaField(e)}.lastRequestedQty'] = e.effectiveShortage;
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
                  'itemCode': e.item.code,
                  'itemType': e.itemType,
                  'lastRequestedQty': e.effectiveShortage,
                },
            },
          });
        } else {
          rethrow;
        }
      }

      final historyBatch = FirebaseFirestore.instance.batch();
      final historyRef = AppSession.doc(
        'order_request_history',
      ).collection('entries');
      for (final e in targetEntries) {
        final existing = _orderedQtys[_orderKey(e)] ?? 0;
        final total = existing + e.effectiveShortage;
        historyBatch.set(
          historyRef.doc(),
          _orderRequestLogData(e, e.effectiveShortage, total, 'bulk'),
        );
      }
      await historyBatch.commit();

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

  Future<void> _editOrderQtyFromOrderList(
    BuildContext context,
    _OrderEntry entry,
  ) async {
    final key = _orderKey(entry);
    final orderedQty = _orderedQtys[key] ?? 0;
    if (orderedQty <= 0) return;

    final controller = TextEditingController(text: '$orderedQty');
    final newQty = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('発注数の訂正'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${entry.store.name}\n${entry.item.name}'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '訂正後の発注数',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '0にする場合は取消ボタンを使ってください。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
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
              final value = int.tryParse(controller.text.trim());
              Navigator.of(ctx).pop(value);
            },
            child: const Text('訂正する'),
          ),
        ],
      ),
    );
    if (newQty == null) return;
    if (newQty <= 0) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('発注数は1以上にしてください。取消は取消ボタンを使ってください。')),
        );
      }
      return;
    }
    if (newQty == orderedQty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('訂正確認'),
        content: Text(
          '${entry.store.name}\n${entry.item.name}\n発注数を $orderedQty 個 → $newQty 個に訂正します。\n\n在庫数は変更されません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('訂正する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final typeKey = _typeKeyForType(entry.itemType);
    try {
      await AppSession.doc('orders').update({
        '$typeKey.${entry.store.id}.${entry.item.id}': newQty,
        '${_orderMetaField(entry)}.correctedAt': FieldValue.serverTimestamp(),
        '${_orderMetaField(entry)}.correctedBy': AppSession.nickname,
        '${_orderMetaField(entry)}.acknowledgedAt': FieldValue.delete(),
        '${_orderMetaField(entry)}.acknowledgedBy': FieldValue.delete(),
      });
      setState(() => _orderedQtys[key] = newQty);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${entry.store.name}：${entry.item.name} の発注数を訂正しました'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      await _load();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('訂正失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _cancelOrderFromOrderList(
    BuildContext context,
    _OrderEntry entry,
  ) async {
    final key = _orderKey(entry);
    final orderedQty = _orderedQtys[key] ?? 0;
    if (orderedQty <= 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('発注取消確認'),
        content: Text(
          '${entry.store.name}\n${entry.item.name}\n未納品の発注 $orderedQty 個を取り消します。\n\n在庫数は変更されません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('やめる'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('取り消す'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final typeKey = _typeKeyForType(entry.itemType);
    try {
      await AppSession.doc('orders').update({
        '$typeKey.${entry.store.id}.${entry.item.id}': FieldValue.delete(),
        '${_orderMetaField(entry)}': FieldValue.delete(),
      });
      setState(() => _orderedQtys.remove(key));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${entry.store.name}：${entry.item.name} の発注を取り消しました'),
            backgroundColor: Colors.red,
          ),
        );
      }
      await _load();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('取消失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  _OrderMeta _latestOrderMeta(_OrderEntry entry) {
    return _orderMetas[_orderKey(entry)] ?? entry.orderMeta;
  }

  bool _hasUnconfirmedOrderRequest(_OrderEntry entry) {
    final meta = _latestOrderMeta(entry);
    final requestedAt = meta.requestedAt;
    if (requestedAt == null) return false;
    final orderedAt = meta.orderedAt;
    if (orderedAt == null) return true;
    return requestedAt.isAfter(orderedAt);
  }

  int _pdfOrderQty(_OrderEntry entry) {
    final meta = _latestOrderMeta(entry);
    if (meta.lastRequestedQty > 0) {
      return meta.lastRequestedQty;
    }
    return _orderedQtys[_orderKey(entry)] ?? entry.orderedQty;
  }

  Future<List<_OrderEntry>> _orderedEntriesForPdf(
    BuildContext context,
    List<_OrderEntry> entries,
  ) async {
    final ordered = entries
        .where((e) => _hasUnconfirmedOrderRequest(e) && _pdfOrderQty(e) > 0)
        .toList();
    if (ordered.isEmpty && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('発注ボタンを押した未確定の商品がありません'),
          backgroundColor: Colors.orange,
        ),
      );
    }
    return ordered;
  }

  Future<void> _markPdfIssued(
    List<_OrderEntry> entries, {
    required List<int> pdfBytes,
    required String pdfKind,
    required String pdfFileName,
  }) async {
    if (entries.isEmpty) return;
    final updates = <String, dynamic>{};
    final batchItems = <Map<String, dynamic>>[];
    final issuedAt = DateTime.now();
    for (final e in entries) {
      final qty = _pdfOrderQty(e);
      updates['${_orderMetaField(e)}.orderedAt'] = FieldValue.serverTimestamp();
      updates['${_orderMetaField(e)}.orderedBy'] = AppSession.nickname;
      updates['${_orderMetaField(e)}.acknowledgedAt'] = FieldValue.delete();
      updates['${_orderMetaField(e)}.acknowledgedBy'] = FieldValue.delete();
      batchItems.add({
        'storeId': e.store.id,
        'storeName': e.store.name,
        'itemType': e.itemType,
        'typeKey': _typeKeyForType(e.itemType),
        'itemId': e.item.id,
        'itemName': e.item.name,
        'itemCode': e.item.code,
        'base': e.base,
        'currentAtOrder': e.current,
        'qty': qty,
        'deliveredQty': 0,
        'status': 'pending',
      });
    }
    await AppSession.doc('orders').update(updates);

    final batchRef = AppSession.doc('orders').collection('batches').doc();
    await batchRef.set({
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtLocal': issuedAt.toIso8601String(),
      'createdBy': AppSession.nickname,
      'status': 'pending',
      'items': batchItems,
      // 一覧・納品処理を重くしないため、PDF本体は別ドキュメントへ保存する。
      'hasSavedPdf': true,
      'pdfKind': pdfKind,
      'pdfFileName': pdfFileName,
      'pdfSavedAtLocal': issuedAt.toIso8601String(),
    });
    await AppSession.doc(
      'order_saved_pdfs',
    ).collection('entries').doc(batchRef.id).set({
      'batchId': batchRef.id,
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtLocal': issuedAt.toIso8601String(),
      'createdBy': AppSession.nickname,
      'pdfBase64': base64Encode(pdfBytes),
      'pdfKind': pdfKind,
      'pdfFileName': pdfFileName,
    });
  }

  Future<void> _exportPdfByStore(
    BuildContext context,
    List<_OrderEntry> entries,
  ) async {
    if (!_canConfirmOrders) {
      _showOrderPermissionMessage(context);
      return;
    }
    if (_creatingPdf) return;
    setState(() => _creatingPdf = true);
    try {
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
                            '${_pdfOrderQty(e)}',
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

      const fileName = '発注済みリスト_店舗別.pdf';
      final pdfBytes = await doc.save();
      await Printing.sharePdf(bytes: pdfBytes, filename: fileName);
      await _markPdfIssued(
        pdfEntries,
        pdfBytes: pdfBytes,
        pdfKind: 'store',
        pdfFileName: fileName,
      );
      await _load();
    } finally {
      if (mounted) setState(() => _creatingPdf = false);
    }
  }

  Future<void> _exportPdfByItem(
    BuildContext context,
    List<_OrderEntry> entries,
  ) async {
    if (!_canConfirmOrders) {
      _showOrderPermissionMessage(context);
      return;
    }
    if (_creatingPdf) return;
    setState(() => _creatingPdf = true);
    try {
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
                              '${_pdfOrderQty(byTypeByItem[type]![itemId]![i])}',
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

      const fileName = '発注済みリスト_商品別.pdf';
      final pdfBytes = await doc.save();
      await Printing.sharePdf(bytes: pdfBytes, filename: fileName);
      await _markPdfIssued(
        pdfEntries,
        pdfBytes: pdfBytes,
        pdfKind: 'item',
        pdfFileName: fileName,
      );
      await _load();
    } finally {
      if (mounted) setState(() => _creatingPdf = false);
    }
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

  Widget _buildOrderedActionButtons(BuildContext context, _OrderEntry e) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _editOrderQtyFromOrderList(context, e),
              icon: const Icon(Icons.edit, size: 16),
              label: const Text('修正'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.orange.shade800,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _cancelOrderFromOrderList(context, e),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('削除'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }

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
              if (_canConfirmOrders) ...[
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
              ],
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
                    '納品予定:$orderedQty',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (orderedQty > 0 && _canConfirmOrders)
            _buildOrderedActionButtons(context, e),
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
              if (_canConfirmOrders) ...[
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
              ],
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
                    '納品予定:$orderedQty',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (orderedQty > 0) _buildOrderedActionButtons(context, e),
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
    if (!_canConfirmOrders) return const SizedBox.shrink();

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
            if (_canConfirmOrders) ...[
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _creatingPdf
                      ? null
                      : () => _exportPdfByStore(context, filtered),
                  icon: const Icon(Icons.picture_as_pdf, size: 18),
                  label: const Text('店舗別 発注確定PDF'),
                ),
              ),
              const SizedBox(width: 8),
            ],
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('戻る'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const AdInlineCardWidget(compact: true),
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
            if (_canConfirmOrders) ...[
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _creatingPdf
                      ? null
                      : () => _exportPdfByItem(context, filtered),
                  icon: const Icon(Icons.picture_as_pdf, size: 18),
                  label: const Text('商品別 発注確定PDF'),
                ),
              ),
              const SizedBox(width: 8),
            ],
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('戻る'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const AdInlineCardWidget(compact: true),
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
