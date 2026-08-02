part of '../main.dart';

// ─────────────────────────────────────────────
// ホームケアセット納品履歴
// ─────────────────────────────────────────────

class _HandoverLogEntry {
  _HandoverLogEntry({
    required this.key,
    required this.code,
    required this.name,
    required this.customerCode,
    required this.qty,
    required this.at,
  });

  final String key;
  final String code;
  final String name;
  final String customerCode;
  final int qty;
  final DateTime at;

  factory _HandoverLogEntry.fromMap(Map<String, dynamic> map) {
    final rawAt = map['at'];
    DateTime at;
    if (rawAt is Timestamp) {
      at = rawAt.toDate();
    } else if (rawAt is String) {
      at = DateTime.tryParse(rawAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
    } else {
      at = DateTime.fromMillisecondsSinceEpoch(0);
    }
    return _HandoverLogEntry(
      key: (map['key'] ?? '').toString(),
      code: (map['code'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      customerCode: (map['customerCode'] ?? '').toString(),
      qty: inventoryIntValue(map['qty']),
      at: at,
    );
  }
}

class HomeCareHandoverLogPage extends StatefulWidget {
  const HomeCareHandoverLogPage({super.key});

  @override
  State<HomeCareHandoverLogPage> createState() =>
      _HomeCareHandoverLogPageState();
}

class _HomeCareHandoverLogPageState extends State<HomeCareHandoverLogPage> {
  final TextEditingController _customerCodeController = TextEditingController();

  bool _loading = true;
  String? _error;
  List<_HandoverLogEntry> _allLogs = [];
  int _visibleCount = 50;
  DateTime? _startDate;
  DateTime? _endDate;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _customerCodeController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final doc = await AppSession.doc('special_orders').get();
      final data = doc.data() ?? <String, dynamic>{};
      final raw = data['homeCareHandoverLogs'];
      final logs = <_HandoverLogEntry>[];
      if (raw is List) {
        for (final entry in raw) {
          if (entry is! Map) continue;
          logs.add(
            _HandoverLogEntry.fromMap(
              Map<String, dynamic>.from(
                entry.map((k, v) => MapEntry(k.toString(), v)),
              ),
            ),
          );
        }
      }
      logs.sort((a, b) => b.at.compareTo(a.at));
      setState(() {
        _allLogs = logs;
        _visibleCount = 50;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<_HandoverLogEntry> get _filteredLogs {
    final query = _customerCodeController.text.trim().toLowerCase();
    return _allLogs.where((log) {
      if (query.isNotEmpty && !log.customerCode.toLowerCase().contains(query)) {
        return false;
      }
      if (_startDate != null && log.at.isBefore(_startDate!)) {
        return false;
      }
      if (_endDate != null) {
        final endExclusive = DateTime(
          _endDate!.year,
          _endDate!.month,
          _endDate!.day,
          23,
          59,
          59,
          999,
        );
        if (log.at.isAfter(endExclusive)) return false;
      }
      return true;
    }).toList();
  }

  bool get _hasFilter =>
      _customerCodeController.text.trim().isNotEmpty ||
      _startDate != null ||
      _endDate != null;

  Future<void> _pickDate({required bool isStart}) async {
    final initial = (isStart ? _startDate : _endDate) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = DateTime(picked.year, picked.month, picked.day);
        if (_endDate != null && _endDate!.isBefore(_startDate!)) {
          _endDate = _startDate;
        }
      } else {
        _endDate = DateTime(picked.year, picked.month, picked.day);
        if (_startDate != null && _startDate!.isAfter(_endDate!)) {
          _startDate = _endDate;
        }
      }
      _visibleCount = 50;
    });
  }

  void _clearFilters() {
    setState(() {
      _customerCodeController.clear();
      _startDate = null;
      _endDate = null;
      _visibleCount = 50;
    });
  }

  String _dateLabel(DateTime? d) =>
      d == null ? '指定なし' : '${d.year}年${d.month}月${d.day}日';

  Widget _buildEntry(_HandoverLogEntry log) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          log.name.isEmpty ? log.key : log.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '納品日時: ${_formatDateTime(log.at)}\n'
          'コード: ${log.code.isEmpty ? '-' : log.code}\n'
          '顧客コード: ${log.customerCode.isEmpty ? '-' : log.customerCode}',
        ),
        trailing: Text(
          '${log.qty}個',
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
        title: const Text('ホームケアセット納品履歴'),
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
            : Builder(
                builder: (context) {
                  final filtered = _filteredLogs;
                  final visible = filtered.take(_visibleCount).toList();
                  final hasMore = visible.length < filtered.length;

                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '絞り込み',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _customerCodeController,
                                decoration: const InputDecoration(
                                  labelText: '顧客コードで検索',
                                  hintText: '部分一致',
                                  prefixIcon: Icon(Icons.search),
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (_) =>
                                    setState(() => _visibleCount = 50),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () => _pickDate(isStart: true),
                                      icon: const Icon(Icons.calendar_month),
                                      label: Text(
                                        '開始日: ${_dateLabel(_startDate)}',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () =>
                                          _pickDate(isStart: false),
                                      icon: const Icon(Icons.event),
                                      label: Text(
                                        '終了日: ${_dateLabel(_endDate)}',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (_hasFilter) ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    onPressed: _clearFilters,
                                    icon: const Icon(Icons.clear),
                                    label: const Text('絞り込みをクリア'),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _hasFilter
                            ? '該当件数: ${filtered.length} / 全${_allLogs.length}件'
                            : '全${_allLogs.length}件',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      const SizedBox(height: 8),
                      if (filtered.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _allLogs.isEmpty
                                ? 'ホームケアセットの納品履歴はまだありません'
                                : '条件に一致する履歴がありません',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                        )
                      else ...[
                        for (final log in visible) _buildEntry(log),
                        if (hasMore)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: OutlinedButton.icon(
                              onPressed: () {
                                setState(() {
                                  _visibleCount = min(
                                    _visibleCount + 50,
                                    filtered.length,
                                  );
                                });
                              },
                              icon: const Icon(Icons.expand_more),
                              label: Text(
                                'もっと見る（${visible.length}/${filtered.length}件）',
                              ),
                            ),
                          ),
                      ],
                    ],
                  );
                },
              ),
      ),
    );
  }
}
