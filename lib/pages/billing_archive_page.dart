part of '../main.dart';

// ─────────────────────────────────────────────
// 発行済み書類アーカイブ（統括管理者専用）
// ─────────────────────────────────────────────

class BillingArchivePage extends StatefulWidget {
  const BillingArchivePage({super.key});

  @override
  State<BillingArchivePage> createState() => _BillingArchivePageState();
}

class _BillingArchivePageState extends State<BillingArchivePage> {
  static const int _pageSize = 20;
  static const Duration _timeout = Duration(seconds: 30);

  final TextEditingController _searchController = TextEditingController();
  final List<_BillingArchiveEntry> _entries = [];
  QueryDocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  Set<String> _excludedStoreIds = {};
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _pdfBusy = false;
  String? _error;
  String _kindFilter = 'all';
  String _storeFilter = '';
  String _monthFilter = '';

  DateTime get _retentionStart {
    final now = DateTime.now();
    return DateTime(now.year - 2, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_refreshFilters);
    _load(reset: true);
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_refreshFilters)
      ..dispose();
    super.dispose();
  }

  void _refreshFilters() {
    if (mounted) setState(() {});
  }

  Future<Set<String>> _loadExcludedStoreIds() async {
    final snap = await AppSession.doc(
      'stores',
    ).collection('billing_visibility').get().timeout(_timeout);
    return {
      for (final doc in snap.docs)
        if (doc.data()['hidden'] == true ||
            doc.data()['superAdminAcknowledged'] != true)
          doc.id,
    };
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _fetchPage({
    QueryDocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
    var query = AppSession.billingInvoices
        .where(
          'createdAt',
          isGreaterThanOrEqualTo: Timestamp.fromDate(_retentionStart),
        )
        .orderBy('createdAt', descending: true);
    if (startAfter != null) query = query.startAfterDocument(startAfter);
    final snap = await query.limit(_pageSize).get().timeout(_timeout);
    return snap.docs;
  }

  _BillingArchiveEntry? _entryFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final summary = _BillingInvoiceSummary.fromDoc(doc.id, data);
    final createdByUid = (data['createdByUid'] ?? '').toString();
    final isOwn = createdByUid.isNotEmpty && createdByUid == AppSession.uid;
    if (!isOwn && _excludedStoreIds.contains(summary.storeId)) return null;
    return _BillingArchiveEntry(
      summary: summary,
      status: (data['status'] ?? '').toString(),
      canceledBy: (data['canceledBy'] ?? '').toString(),
      createdByUid: createdByUid,
    );
  }

  Future<void> _load({required bool reset}) async {
    if (!AppSession.isSuperAdmin) {
      setState(() {
        _loading = false;
        _error = '発行済み書類を確認できるのは統括管理者のみです';
      });
      return;
    }
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      if (_loadingMore || !_hasMore || _lastDoc == null) return;
      setState(() => _loadingMore = true);
    }
    try {
      if (reset) _excludedStoreIds = await _loadExcludedStoreIds();
      final rawDocs = await _fetchPage(startAfter: reset ? null : _lastDoc);
      final nextEntries = rawDocs
          .map(_entryFromDoc)
          .whereType<_BillingArchiveEntry>()
          .toList();
      if (!mounted) return;
      setState(() {
        if (reset) {
          _entries
            ..clear()
            ..addAll(nextEntries);
        } else {
          _entries.addAll(nextEntries);
        }
        _lastDoc = rawDocs.isEmpty ? _lastDoc : rawDocs.last;
        _hasMore = rawDocs.length == _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  bool _matchesFilters(_BillingArchiveEntry entry) {
    final invoice = entry.summary;
    if (_kindFilter == 'invoice' && !entry.hasInvoice) return false;
    if (_kindFilter == 'receipt' && !entry.hasReceipt) return false;
    if (_kindFilter == 'shuryoshuu' && !entry.hasShuryoshuu) return false;
    if (_storeFilter.isNotEmpty && invoice.storeId != _storeFilter) {
      return false;
    }
    final monthKey =
        '${invoice.createdAt.year}-${invoice.createdAt.month.toString().padLeft(2, '0')}';
    if (_monthFilter.isNotEmpty && monthKey != _monthFilter) return false;
    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty &&
        !invoice.invoiceNo.toLowerCase().contains(query) &&
        !invoice.storeName.toLowerCase().contains(query)) {
      return false;
    }
    return true;
  }

  List<_BillingArchiveEntry> get _visibleEntries =>
      _entries.where(_matchesFilters).toList();

  Map<String, String> get _availableStores {
    final result = <String, String>{};
    for (final entry in _entries) {
      final summary = entry.summary;
      if (summary.storeId.isNotEmpty) {
        result[summary.storeId] = summary.storeName;
      }
    }
    final sorted = result.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return Map<String, String>.fromEntries(sorted);
  }

  List<String> get _availableMonths {
    final result = <String>{};
    for (final entry in _entries) {
      final date = entry.summary.createdAt;
      result.add('${date.year}-${date.month.toString().padLeft(2, '0')}');
    }
    final sorted = result.toList()..sort((a, b) => b.compareTo(a));
    return sorted;
  }

  String _yen(int value) {
    final digits = value.abs().toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return '${value < 0 ? '-' : ''}${buffer.toString()}';
  }

  String _dateText(DateTime date) => '${date.year}年${date.month}月${date.day}日';

  Future<void> _openSavedPdf({
    required CollectionReference<Map<String, dynamic>> collection,
    required String docId,
    required String fallbackFileName,
  }) async {
    if (_pdfBusy) return;
    setState(() => _pdfBusy = true);
    try {
      final doc = await collection
          .doc(docId)
          .get()
          .timeout(const Duration(seconds: 20));
      final data = doc.data() ?? <String, dynamic>{};
      final raw = (data['pdfBase64'] ?? '').toString();
      if (raw.isEmpty) throw Exception('保存済みPDFがありません');
      final savedName = (data['pdfFileName'] ?? '').toString();
      await Printing.sharePdf(
        bytes: base64Decode(raw),
        filename: savedName.isEmpty ? fallbackFileName : savedName,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('PDFを開けません: $e')));
      }
    } finally {
      if (mounted) setState(() => _pdfBusy = false);
    }
  }

  Widget _buildFilters() {
    final stores = _availableStores;
    final months = _availableMonths;
    final selectedStore = stores.containsKey(_storeFilter) ? _storeFilter : '';
    final selectedMonth = months.contains(_monthFilter) ? _monthFilter : '';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.deepPurple.shade100),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '保存期間: 過去2年（${_retentionStart.year}年${_retentionStart.month}月${_retentionStart.day}日以降）',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: '番号・店舗名で検索',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in const [
                ('all', 'すべて'),
                ('invoice', '請求書'),
                ('receipt', '受領書'),
                ('shuryoshuu', '領収書'),
              ])
                FilterChip(
                  label: Text(option.$2),
                  selected: _kindFilter == option.$1,
                  onSelected: (_) => setState(() => _kindFilter = option.$1),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('billing-archive-month-$selectedMonth'),
                  initialValue: selectedMonth,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '発行年月',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('すべて')),
                    for (final month in months)
                      DropdownMenuItem(
                        value: month,
                        child: Text(
                          '${month.substring(0, 4)}年${int.parse(month.substring(5))}月',
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _monthFilter = value ?? ''),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('billing-archive-store-$selectedStore'),
                  initialValue: selectedStore,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '店舗',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('すべて')),
                    for (final store in stores.entries)
                      DropdownMenuItem(
                        value: store.key,
                        child: Text(
                          store.value,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _storeFilter = value ?? ''),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEntryCard(_BillingArchiveEntry entry) {
    final invoice = entry.summary;
    return Card(
      color: entry.isCanceled ? Colors.grey.shade100 : null,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${invoice.invoiceNo} / ${invoice.storeName}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (entry.isCanceled)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('取消済み'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_dateText(invoice.createdAt)} / ${invoice.billingMonthLabel}',
              style: const TextStyle(color: Colors.black54),
            ),
            Text(
              '￥${_yen(invoice.total)} / ${invoice.billingItemTypesText}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (entry.hasInvoice)
                  OutlinedButton.icon(
                    onPressed: _pdfBusy
                        ? null
                        : () => _openSavedPdf(
                            collection: AppSession.billingInvoicePdfs,
                            docId: invoice.id,
                            fallbackFileName: '請求書_${invoice.invoiceNo}.pdf',
                          ),
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    label: const Text('請求書'),
                  ),
                if (entry.hasReceipt)
                  OutlinedButton.icon(
                    onPressed: _pdfBusy
                        ? null
                        : () => _openSavedPdf(
                            collection: AppSession.billingReceiptPdfs,
                            docId: invoice.receiptId,
                            fallbackFileName: '受領書_${invoice.invoiceNo}.pdf',
                          ),
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('受領書'),
                  ),
                if (entry.hasShuryoshuu)
                  OutlinedButton.icon(
                    onPressed: _pdfBusy
                        ? null
                        : () => _openSavedPdf(
                            collection: AppSession.billingReceiptPdfs,
                            docId: invoice.receiptId,
                            fallbackFileName: '領収書_${invoice.invoiceNo}.pdf',
                          ),
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('領収書'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleEntries = _visibleEntries;
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('発行済み書類'),
        actions: [
          IconButton(
            onPressed: _loading ? null : () => _load(reset: true),
            icon: const Icon(Icons.refresh),
            tooltip: '再読み込み',
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
            : Column(
                children: [
                  if (_pdfBusy) const LinearProgressIndicator(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: _buildFilters(),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount:
                          visibleEntries.length +
                          (_hasMore || visibleEntries.isEmpty ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index < visibleEntries.length) {
                          return _buildEntryCard(visibleEntries[index]);
                        }
                        if (_hasMore) {
                          return OutlinedButton.icon(
                            onPressed: _loadingMore
                                ? null
                                : () => _load(reset: false),
                            icon: _loadingMore
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.expand_more),
                            label: Text(
                              _loadingMore
                                  ? '読み込み中…'
                                  : 'もっと見る（読み込み済み${_entries.length}件）',
                            ),
                          );
                        }
                        return const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: Text('条件に一致する書類はありません')),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _BillingArchiveEntry {
  const _BillingArchiveEntry({
    required this.summary,
    required this.status,
    required this.canceledBy,
    required this.createdByUid,
  });

  final _BillingInvoiceSummary summary;
  final String status;
  final String canceledBy;
  final String createdByUid;

  bool get isCanceled => status == 'canceled';
  bool get hasShuryoshuu => summary.isShuryoshuu;
  bool get hasReceipt => summary.receiptId.isNotEmpty && !summary.isShuryoshuu;
  bool get hasInvoice =>
      summary.billingMode != 'manual_receipt_only' &&
      summary.billingMode != 'manual_shuryoshuu_only';
}
