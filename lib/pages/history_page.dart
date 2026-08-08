part of '../main.dart';

// ─────────────────────────────────────────────
// 履歴ページ
// ─────────────────────────────────────────────

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  static const int _pageSize = 50;
  // 1回の読み込み操作で目指す「フィルタ後の表示件数」の目安。
  static const int _visibleTargetPerLoad = 50;
  // 閲覧可能店舗が少ないユーザーでも読み込みが暴走しないよう、
  // 1回の読み込み操作で読む生ドキュメント数の上限を設ける。
  static const int _maxRawDocsPerLoad = 500;

  List<HistoryEntry> _entries = <HistoryEntry>[];
  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  Object? _error;

  List<LegacyStore> _allStores = [];
  Set<String> _viewableStoreIds = {};
  bool _isRestricted = false;

  bool get _hasAnyViewableStore => _viewableStoreIds.isNotEmpty;

  List<String> get _visibleStoreNames => _allStores
      .where((s) => _viewableStoreIds.contains(s.id))
      .map((s) => s.name)
      .toList();

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_loadingMore) return;
    if (reset) {
      setState(() {
        _entries = <HistoryEntry>[];
        _lastDoc = null;
        _hasMore = true;
        _loading = true;
        _error = null;
      });
    } else {
      if (!_hasMore) return;
      setState(() => _loadingMore = true);
    }

    try {
      if (reset) {
        final masterData = await _loadMasterData();
        final allStores = List<LegacyStore>.from(masterData.stores);
        final allStoreIds = allStores.map((s) => s.id).toList();
        final viewableIds = AppSession.viewableStoreIds(allStoreIds).toSet();
        _allStores = allStores;
        _viewableStoreIds = viewableIds;
        _isRestricted = viewableIds.length < allStoreIds.length;
      }

      if (_viewableStoreIds.isEmpty) {
        setState(() {
          _entries = <HistoryEntry>[];
          _hasMore = false;
          _loading = false;
          _loadingMore = false;
        });
        return;
      }

      final newlyVisible = <HistoryEntry>[];
      var cursor = reset ? null : _lastDoc;
      var hasMoreRaw = true;
      var fetchedRaw = 0;

      // フィルタ後の件数が少なくなりすぎないよう、目標件数に届くか
      // 生データが尽きる（または上限に達する）まで内部で連続取得する。
      while (newlyVisible.length < _visibleTargetPerLoad &&
          hasMoreRaw &&
          fetchedRaw < _maxRawDocsPerLoad) {
        var query = AppSession.doc('history')
            .collection('entries')
            .orderBy('at', descending: true)
            .limit(_pageSize);
        if (cursor != null) {
          query = query.startAfterDocument(cursor);
        }
        final snap = await query.get();
        if (snap.docs.isEmpty) {
          hasMoreRaw = false;
          break;
        }
        fetchedRaw += snap.docs.length;
        cursor = snap.docs.last;
        hasMoreRaw = snap.docs.length == _pageSize;

        final loaded = snap.docs
            .map((doc) => HistoryEntry.fromDoc(doc))
            .toList();
        newlyVisible.addAll(
          loaded.where((e) => _viewableStoreIds.contains(e.storeId)),
        );
      }

      setState(() {
        _entries = reset ? newlyVisible : [..._entries, ...newlyVisible];
        _lastDoc = cursor ?? _lastDoc;
        _hasMore = hasMoreRaw;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      setState(() {
        _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
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
            onPressed: () => _load(reset: true),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!_loading &&
                _error == null &&
                _isRestricted &&
                _hasAnyViewableStore)
              Container(
                width: double.infinity,
                color: Colors.orange.shade50,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: Colors.orange.shade800,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '閲覧が許可されている店舗のみ対象にしています：'
                        '${_visibleStoreNames.join('、')}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.orange.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: SelectableText('読み取りエラー\n\n$_error'),
                    )
                  : _entries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: _hasAnyViewableStore
                            ? const Text(
                                '履歴がありません\n在庫を変更すると記録されます',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey),
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.error_outline,
                                    size: 40,
                                    color: Colors.red.shade400,
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    '閲覧できる店舗がありません。\n管理者にお問い合わせください。',
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _entries.length + 1 + (_hasMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Card(
                              child: ListTile(
                                title: const Text('件数'),
                                subtitle: const Text('直近から50件ずつ読み込みます'),
                                trailing: Text(
                                  '${_entries.length} 件',
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }
                        final entryIndex = index - 1;
                        if (entryIndex < _entries.length) {
                          return _buildEntryCard(_entries[entryIndex]);
                        }
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: OutlinedButton.icon(
                            onPressed: _loadingMore ? null : () => _load(),
                            icon: _loadingMore
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.expand_more),
                            label: Text(_loadingMore ? '読み込み中...' : 'もっと見る'),
                          ),
                        );
                      },
                    ),
            ),
          ],
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
