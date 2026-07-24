part of '../main.dart';

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
    final master = await _loadMasterData();
    final results = await Future.wait([
      AppSession.doc('stocks').get(),
      AppSession.doc('baseline').get(),
      AppSession.doc('stocks_v2').get(),
      AppSession.doc('orders').get(),
    ]);

    final stocksData = results[0].data() ?? {};
    final baseStocksData = results[1].exists
        ? (results[1].data() ?? <String, dynamic>{})
        : <String, dynamic>{};
    final v2Raw = results[2].data() ?? {};

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

    final ordersRaw = results[3].exists
        ? (results[3].data() ?? <String, dynamic>{})
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

    final orderedProducts = _parseStocksForStore(ordersPMap, widget.store.id);
    final orderedTesters = _parseStocksForStore(ordersTMap, widget.store.id);
    final orderedEquipments = _parseStocksForStore(ordersEMap, widget.store.id);

    int toInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse('$value') ?? 0;
    }

    void subtractOrdered(Map<String, int> target, String itemId, int qty) {
      if (itemId.isEmpty || qty <= 0) return;
      final current = target[itemId] ?? 0;
      final next = max(0, current - qty);
      if (next <= 0) {
        target.remove(itemId);
      } else {
        target[itemId] = next;
      }
    }

    // 納品済み情報は、すでに読み込んでいる orders._deliveredBatches から補正する。
    // 以前のように orders/batches を追加で最大30件読む処理は重いため行わない。
    final rawDeliveredBatches = ordersRaw['_deliveredBatches'];
    if (rawDeliveredBatches is Map) {
      for (final rawBatch in rawDeliveredBatches.values) {
        if (rawBatch is! Map) continue;
        for (final raw in rawBatch.values) {
          if (raw is! Map) continue;
          final delivered = Map<String, dynamic>.from(
            raw.map((k, v) => MapEntry(k.toString(), v)),
          );
          if ((delivered['storeId'] ?? '').toString() != widget.store.id) {
            continue;
          }
          final itemId = (delivered['itemId'] ?? '').toString();
          final typeKey = (delivered['typeKey'] ?? '').toString();
          final itemType = (delivered['itemType'] ?? '').toString();
          final qty = toInt(delivered['qty']);
          final normalizedTypeKey = normalizeInventoryTypeKey(
            typeKey: typeKey,
            itemType: itemType,
          );
          if (normalizedTypeKey == 'products') {
            subtractOrdered(orderedProducts, itemId, qty);
          } else if (normalizedTypeKey == 'testers') {
            subtractOrdered(orderedTesters, itemId, qty);
          } else if (normalizedTypeKey == 'equipments') {
            subtractOrdered(orderedEquipments, itemId, qty);
          }
        }
      }
    }

    return _InventoryData(
      products: master.products,
      testers: master.testers,
      equipments: master.equipments,
      productStocks: _parseStocksForStore(stocksData, widget.store.id),
      testerStocks: _parseStocksForStore(v2TMap, widget.store.id),
      equipmentStocks: _parseStocksForStore(v2EMap, widget.store.id),
      baseStocks: _parseStocksForStore(baseStocksData, widget.store.id),
      orderedProductStocks: orderedProducts,
      orderedTesterStocks: orderedTesters,
      orderedEquipmentStocks: orderedEquipments,
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

  Future<void> _clearOrderedDisplay(BuildContext context) async {
    final targetIds = _localOrderedStocks.entries
        .where((entry) => entry.value > 0)
        .map((entry) => entry.key)
        .toList();
    if (targetIds.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('発注済み表示をクリア'),
        content: Text(
          '${widget.storeName} の ${widget.title} ${targetIds.length}品目について、\n'
          '納品予定・発注済みの表示だけを消します。\n\n'
          '在庫数は変更しません。',
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
            child: const Text('表示だけ消す'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final updates = <String, dynamic>{};
    for (final id in targetIds) {
      updates['$_typeKey.${widget.storeId}.$id'] = FieldValue.delete();
      updates[_orderMetaField(id)] = FieldValue.delete();
    }

    try {
      await AppSession.doc('orders').update(updates);
      setState(() {
        for (final id in targetIds) {
          _localOrderedStocks.remove(id);
          _localOrderMetas.remove(id);
        }
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${widget.title}の発注済み表示をクリアしました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('表示クリア失敗: $e'), backgroundColor: Colors.red),
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

    final headerWidgets = <Widget>[
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
              Expanded(
                child: Text(
                  '発注済 $orderedCount 品目（リスト先頭に表示中）',
                  style: TextStyle(
                    color: Colors.orange.shade800,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _clearOrderedDisplay(context),
                child: const Text('表示クリア'),
              ),
            ],
          ),
        ),
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
    ];

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: headerWidgets.length + filtered.length,
            itemBuilder: (context, index) {
              if (index < headerWidgets.length) {
                return headerWidgets[index];
              }
              final item = filtered[index - headerWidgets.length];
              return _buildInventoryItemCard(context, item);
            },
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

  Widget _buildInventoryItemCard(BuildContext context, LegacyItem item) {
    return Card(
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
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '販売終了',
                  style: TextStyle(fontSize: 10, color: Colors.grey),
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
                            ? '納品予定: ${_localOrderedStocks[item.id]}'
                            : '納品予定: ${_localOrderedStocks[item.id]} / ${_formatDateTime(_localOrderMetas[item.id]!.orderedAt!)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade800,
                          fontWeight: FontWeight.bold,
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
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
              color: item.discontinued ? Colors.grey : Colors.redAccent,
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
    );
  }
}
