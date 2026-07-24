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
  List<HistoryEntry> _entries = <HistoryEntry>[];
  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  Object? _error;

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
      var query = AppSession.doc(
        'history',
      ).collection('entries').orderBy('at', descending: true).limit(50);
      final lastDoc = _lastDoc;
      if (!reset && lastDoc != null) {
        query = query.startAfterDocument(lastDoc);
      }
      final snap = await query.get();
      final loaded = snap.docs.map((doc) => HistoryEntry.fromDoc(doc)).toList();
      setState(() {
        _entries = reset ? loaded : [..._entries, ...loaded];
        _lastDoc = snap.docs.isEmpty ? _lastDoc : snap.docs.last;
        _hasMore = snap.docs.length == 50;
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
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: SelectableText('読み取りエラー\n\n$_error'),
              )
            : _entries.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    '履歴がありません\n在庫を変更すると記録されます',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
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
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.expand_more),
                      label: Text(_loadingMore ? '読み込み中...' : 'もっと見る'),
                    ),
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
