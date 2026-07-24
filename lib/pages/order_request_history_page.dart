part of '../main.dart';

// ─────────────────────────────────────────────
// 発注ボタン履歴
// ─────────────────────────────────────────────

class OrderRequestHistoryPage extends StatefulWidget {
  const OrderRequestHistoryPage({super.key});

  @override
  State<OrderRequestHistoryPage> createState() =>
      _OrderRequestHistoryPageState();
}

class _OrderRequestHistoryPageState extends State<OrderRequestHistoryPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _entries = [];

  bool get _canView => AppSession.isAdmin || AppSession.isSuperAdmin;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  DateTime? _readTime(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
    return null;
  }

  Future<void> _load() async {
    if (!_canView) {
      setState(() {
        _loading = false;
        _error = '発注ボタン履歴を確認できるのは管理者・統括管理者のみです';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = <Map<String, dynamic>>[];

      // 新形式: この機能追加後に発注ボタンを押した履歴。
      try {
        final snap = await AppSession.doc('order_request_history')
            .collection('entries')
            .orderBy('requestedAt', descending: true)
            .limit(500)
            .get();
        for (final doc in snap.docs) {
          final data = doc.data();
          result.add({...data, '_sourceLabel': '履歴'});
        }
      } catch (_) {
        // 初回はコレクションが無いことがあるため、そのまま旧形式の読取へ進む。
      }

      // 旧形式: 以前から orders._meta に残っている「最後に発注ボタンを押した情報」。
      // クリックごとの完全履歴ではなく、残存している現在値だけを表示する。
      final ordersDoc = await AppSession.doc('orders').get();
      final ordersData = ordersDoc.data() ?? <String, dynamic>{};
      final metaRaw = ordersData['_meta'];
      if (metaRaw is Map) {
        for (final entry in metaRaw.entries) {
          if (entry.value is! Map) continue;
          final key = entry.key.toString();
          final parts = key.split('__');
          if (parts.length < 3) continue;
          final typeKey = parts[0];
          final storeId = parts[1];
          final itemId = parts.sublist(2).join('__');
          final meta = Map<String, dynamic>.from(
            (entry.value as Map).map((k, v) => MapEntry(k.toString(), v)),
          );
          final requestedAt = meta['requestedAt'];
          if (requestedAt == null) continue;
          final typeRaw = ordersData[typeKey];
          var qty = 0;
          if (typeRaw is Map) {
            final storeRaw = typeRaw[storeId];
            if (storeRaw is Map) qty = _toInt(storeRaw[itemId]);
          }
          if (qty <= 0) continue;
          result.add({
            'requestedAt': requestedAt,
            'requestedAtLocal': meta['requestedAtLocal'],
            'requestedBy': meta['requestedBy'],
            'storeId': storeId,
            'storeName': meta['storeName'] ?? storeId,
            'itemType': meta['itemType'] ?? typeKey,
            'typeKey': typeKey,
            'itemId': itemId,
            'itemName': meta['itemName'] ?? itemId,
            'itemCode': meta['itemCode'] ?? '',
            'qty': qty,
            'totalQtyAfterRequest': qty,
            '_sourceLabel': '旧形式・残存データ',
          });
        }
      }

      result.sort((a, b) {
        final ad =
            _readTime(a['requestedAt']) ??
            _readTime(a['requestedAtLocal']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bd =
            _readTime(b['requestedAt']) ??
            _readTime(b['requestedAtLocal']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return bd.compareTo(ad);
      });

      setState(() {
        _entries = result;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Widget _buildEntry(Map<String, dynamic> data) {
    final requestedAt =
        _readTime(data['requestedAt']) ??
        _readTime(data['requestedAtLocal']) ??
        DateTime.now();
    final sourceLabel = (data['_sourceLabel'] ?? '履歴').toString();
    final qty = _toInt(data['qty']);
    final itemCode = (data['itemCode'] ?? '').toString();
    final requestedBy = (data['requestedBy'] ?? '').toString();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          (data['itemName'] ?? '').toString(),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '発注日: ${_formatDateTime(requestedAt)}\n'
          '店舗: ${(data['storeName'] ?? '').toString()}\n'
          'コード: ${itemCode.isEmpty ? '-' : itemCode} / 種別: ${(data['itemType'] ?? '').toString()}\n'
          '担当: ${requestedBy.isEmpty ? '-' : requestedBy} / $sourceLabel',
        ),
        trailing: Text(
          '$qty個',
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Colors.blue,
          ),
        ),
        isThreeLine: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('発注ボタン履歴'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
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
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: 2 + (_entries.isEmpty ? 1 : _entries.length),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return const Card(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          '発注ボタンを押した履歴です。今後の発注は1回ごとに保存されます。旧形式・残存データは、以前から残っている現在の発注予定情報です。',
                        ),
                      ),
                    );
                  }
                  if (index == 1) return const SizedBox(height: 12);
                  if (_entries.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '発注ボタン履歴はまだありません',
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  return _buildEntry(_entries[index - 2]);
                },
              ),
      ),
    );
  }
}
