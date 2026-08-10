part of '../main.dart';

// ─────────────────────────────────────────────
// レジ開店・閉店履歴
// ─────────────────────────────────────────────

class _PosRegisterSessionRecord {
  _PosRegisterSessionRecord({
    required this.id,
    required this.storeId,
    required this.storeName,
    required this.status,
    required this.openedAt,
    required this.openedBy,
    required this.closedAt,
    required this.closedBy,
    required this.openingCashTotal,
    required this.closingCashTotal,
    required this.inventoryBasedSales,
    required this.manualSalesTotal,
    required this.manualCashSales,
    required this.manualCardSales,
    required this.cashSales,
    required this.cardSales,
  });

  final String id;
  final String storeId;
  final String storeName;
  final String status;
  final DateTime? openedAt;
  final String openedBy;
  final DateTime? closedAt;
  final String closedBy;
  final int openingCashTotal;
  final int closingCashTotal;
  final int inventoryBasedSales;
  final int manualSalesTotal;
  final int manualCashSales;
  final int manualCardSales;
  final int cashSales;
  final int cardSales;

  factory _PosRegisterSessionRecord.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    DateTime? toDate(dynamic v) => v is Timestamp ? v.toDate() : null;
    return _PosRegisterSessionRecord(
      id: doc.id,
      storeId: (data['storeId'] ?? '').toString(),
      storeName: (data['storeName'] ?? '').toString(),
      status: (data['status'] ?? '').toString(),
      openedAt: toDate(data['openedAt']),
      openedBy: (data['openedBy'] ?? '').toString(),
      closedAt: toDate(data['closedAt']),
      closedBy: (data['closedBy'] ?? '').toString(),
      openingCashTotal: inventoryIntValue(data['openingCashTotal']),
      closingCashTotal: inventoryIntValue(data['closingCashTotal']),
      inventoryBasedSales: inventoryIntValue(data['inventoryBasedSales']),
      manualSalesTotal: inventoryIntValue(data['manualSalesTotal']),
      manualCashSales: inventoryIntValue(data['manualCashSales']),
      manualCardSales: inventoryIntValue(data['manualCardSales']),
      cashSales: inventoryIntValue(data['cashSales']),
      cardSales: inventoryIntValue(data['cardSales']),
    );
  }
}

class PosRegisterSessionHistoryPage extends StatefulWidget {
  const PosRegisterSessionHistoryPage({super.key});

  @override
  State<PosRegisterSessionHistoryPage> createState() =>
      _PosRegisterSessionHistoryPageState();
}

class _PosRegisterSessionHistoryPageState
    extends State<PosRegisterSessionHistoryPage> {
  DateTime _startDate = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _endDate = DateTime.now();

  List<LegacyStore> _stores = [];
  LegacyStore? _selectedStore;

  bool _loadingStores = true;
  bool _loading = false;
  bool _hasResult = false;
  String? _message;

  List<_PosRegisterSessionRecord> _sessions = [];
  int _totalInventoryBasedSales = 0;
  int _totalManualSalesTotal = 0;
  int _totalCashSales = 0;
  int _totalCardSales = 0;

  @override
  void initState() {
    super.initState();
    _loadStores();
  }

  Future<void> _loadStores() async {
    setState(() => _loadingStores = true);
    try {
      final storesDoc = await AppSession.doc('stores').get();
      setState(() {
        _stores = _parseStores(storesDoc.data() ?? <String, dynamic>{});
        _loadingStores = false;
      });
    } catch (e) {
      setState(() {
        _message = '店舗一覧の読み込みに失敗しました: $e';
        _loadingStores = false;
      });
    }
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart ? _startDate : _endDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      locale: const Locale('ja'),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = DateTime(picked.year, picked.month, picked.day);
        if (_endDate.isBefore(_startDate)) _endDate = _startDate;
      } else {
        _endDate = DateTime(picked.year, picked.month, picked.day);
        if (_startDate.isAfter(_endDate)) _startDate = _endDate;
      }
    });
  }

  String _dateLabel(DateTime d) => '${d.year}年${d.month}月${d.day}日';

  String _yen(int value) => value.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );

  Future<void> _runSearch() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final start = DateTime(_startDate.year, _startDate.month, _startDate.day);
      final end = DateTime(
        _endDate.year,
        _endDate.month,
        _endDate.day,
        23,
        59,
        59,
        999,
      );

      final snap = await AppSession.posRegisterSessions
          .where('openedAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
          .where('openedAt', isLessThanOrEqualTo: Timestamp.fromDate(end))
          .orderBy('openedAt', descending: true)
          .get();

      final sessions = snap.docs
          .map(_PosRegisterSessionRecord.fromDoc)
          .where(
            (s) => _selectedStore == null || s.storeId == _selectedStore!.id,
          )
          .toList();

      final totalInventoryBasedSales = sessions.fold<int>(
        0,
        (total, s) => total + s.inventoryBasedSales,
      );
      final totalManualSalesTotal = sessions.fold<int>(
        0,
        (total, s) => total + s.manualSalesTotal,
      );
      final totalCashSales = sessions.fold<int>(
        0,
        (total, s) => total + s.cashSales,
      );
      final totalCardSales = sessions.fold<int>(
        0,
        (total, s) => total + s.cardSales,
      );

      setState(() {
        _sessions = sessions;
        _totalInventoryBasedSales = totalInventoryBasedSales;
        _totalManualSalesTotal = totalManualSalesTotal;
        _totalCashSales = totalCashSales;
        _totalCardSales = totalCardSales;
        _hasResult = true;
      });
    } catch (e) {
      setState(() => _message = '検索失敗: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _exportPdf() async {
    try {
      final pdfBytes = await _createHistoryPdf();
      final fileName =
          'レジ開閉店履歴_'
          '${_startDate.year}${_startDate.month.toString().padLeft(2, '0')}${_startDate.day.toString().padLeft(2, '0')}'
          '-'
          '${_endDate.year}${_endDate.month.toString().padLeft(2, '0')}${_endDate.day.toString().padLeft(2, '0')}'
          '.pdf';
      await Printing.sharePdf(bytes: pdfBytes, filename: fileName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF出力失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<Uint8List> _createHistoryPdf() async {
    final font = await PdfGoogleFonts.notoSansJPRegular();
    final bold = await PdfGoogleFonts.notoSansJPBold();
    final logoData = await rootBundle.load('assets/billing/restart_logo.png');
    final logo = pw.MemoryImage(logoData.buffer.asUint8List());
    final doc = pw.Document();
    final storeLabel = _selectedStore?.name ?? '全店舗';
    final periodLabel = '${_dateLabel(_startDate)} 〜 ${_dateLabel(_endDate)}';

    String fmt(DateTime? d) => d == null ? '-' : _formatDateTime(d);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (context) => [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'レジ開店・閉店履歴',
                style: pw.TextStyle(font: bold, fontSize: 24),
              ),
              pw.Image(logo, width: 110),
            ],
          ),
          pw.SizedBox(height: 16),
          pw.Text('対象期間：$periodLabel', style: pw.TextStyle(font: font)),
          pw.Text('対象店舗：$storeLabel', style: pw.TextStyle(font: font)),
          pw.Text(
            '出力日時：${_dateLabel(DateTime.now())}',
            style: pw.TextStyle(font: font, fontSize: 10),
          ),
          pw.SizedBox(height: 16),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(14),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.blueGrey, width: 1),
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('件数', style: pw.TextStyle(font: font)),
                    pw.Text(
                      '${_sessions.length} 件',
                      style: pw.TextStyle(font: bold, fontSize: 16),
                    ),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('商品売上合計', style: pw.TextStyle(font: font)),
                    pw.Text(
                      '￥${_yen(_totalInventoryBasedSales)}',
                      style: pw.TextStyle(font: bold, fontSize: 16),
                    ),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('手入力売上合計', style: pw.TextStyle(font: font)),
                    pw.Text(
                      '￥${_yen(_totalManualSalesTotal)}',
                      style: pw.TextStyle(font: bold, fontSize: 16),
                    ),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('現金売上合計', style: pw.TextStyle(font: font)),
                    pw.Text(
                      '￥${_yen(_totalCashSales)}',
                      style: pw.TextStyle(font: bold, fontSize: 16),
                    ),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('カード売上合計', style: pw.TextStyle(font: font)),
                    pw.Text(
                      '￥${_yen(_totalCardSales)}',
                      style: pw.TextStyle(font: bold, fontSize: 16),
                    ),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            '※在庫の増減から算出した概算です。値引き・ロス等は考慮されません。',
            style: pw.TextStyle(
              font: font,
              fontSize: 9,
              color: PdfColors.grey700,
            ),
          ),
          pw.SizedBox(height: 20),
          pw.Text('セッション別内訳', style: pw.TextStyle(font: bold, fontSize: 14)),
          pw.SizedBox(height: 8),
          if (_sessions.isEmpty)
            pw.Text('対象期間の記録はありません。', style: pw.TextStyle(font: font))
          else
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
              columnWidths: const {
                0: pw.FlexColumnWidth(1.3),
                1: pw.FlexColumnWidth(1.5),
                2: pw.FlexColumnWidth(1.5),
                3: pw.FlexColumnWidth(1.1),
                4: pw.FlexColumnWidth(1.1),
                5: pw.FlexColumnWidth(1.2),
                6: pw.FlexColumnWidth(1.7),
                7: pw.FlexColumnWidth(1.1),
                8: pw.FlexColumnWidth(1.1),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.blue50),
                  children: [
                    _pdfCell('店舗', bold),
                    _pdfCell('開店時刻', bold),
                    _pdfCell('閉店時刻', bold),
                    _pdfCell('開店釣銭', bold),
                    _pdfCell('閉店現金', bold),
                    _pdfCell('商品売上', bold),
                    _pdfCell('手入力(現金/カード)', bold),
                    _pdfCell('現金売上', bold),
                    _pdfCell('カード売上', bold),
                  ],
                ),
                for (final s in _sessions)
                  pw.TableRow(
                    children: [
                      _pdfCell(s.storeName, font),
                      _pdfCell(fmt(s.openedAt), font),
                      _pdfCell(fmt(s.closedAt), font),
                      _pdfCell('￥${_yen(s.openingCashTotal)}', font),
                      _pdfCell('￥${_yen(s.closingCashTotal)}', font),
                      _pdfCell('￥${_yen(s.inventoryBasedSales)}', font),
                      _pdfCell(
                        '￥${_yen(s.manualCashSales)} / ￥${_yen(s.manualCardSales)}',
                        font,
                      ),
                      _pdfCell('￥${_yen(s.cashSales)}', font),
                      _pdfCell('￥${_yen(s.cardSales)}', font),
                    ],
                  ),
              ],
            ),
          pw.SizedBox(height: 16),
          pw.Divider(),
          pw.Text('株式会社Re,stArt', style: pw.TextStyle(font: bold)),
        ],
      ),
    );
    return doc.save();
  }

  pw.Widget _pdfCell(String text, pw.Font font) => pw.Padding(
    padding: const pw.EdgeInsets.all(6),
    child: pw.Text(text, style: pw.TextStyle(font: font, fontSize: 9)),
  );

  Widget _statTile(String label, String value, {Color? color}) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _sessionTile(_PosRegisterSessionRecord s) {
    final isOpen = s.status == 'open';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.storeName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: isOpen
                        ? Colors.orange.shade100
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    isOpen ? '開店中' : '閉店済み',
                    style: TextStyle(
                      fontSize: 10,
                      color: isOpen
                          ? Colors.orange.shade900
                          : Colors.grey.shade700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '開店: ${s.openedAt != null ? _formatDateTime(s.openedAt!) : '-'}'
              ' / 閉店: ${s.closedAt != null ? _formatDateTime(s.closedAt!) : '-'}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            Text(
              '開店釣銭 ￥${_yen(s.openingCashTotal)} / 閉店現金 ￥${_yen(s.closingCashTotal)}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            if (!isOpen) ...[
              const Divider(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '商品売上\n￥${_yen(s.inventoryBasedSales)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '手入力売上\n￥${_yen(s.manualSalesTotal)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '現金売上\n￥${_yen(s.cashSales)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      'カード売上\n￥${_yen(s.cardSales)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '手入力内訳：現金 ￥${_yen(s.manualCashSales)} / '
                'カード ￥${_yen(s.manualCardSales)}（記録用）',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(title: const Text('レジ開店・閉店履歴')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '検索条件',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<LegacyStore?>(
                      initialValue: _selectedStore,
                      decoration: const InputDecoration(
                        labelText: '対象店舗',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<LegacyStore?>(
                          value: null,
                          child: Text('全店舗'),
                        ),
                        ..._stores.map(
                          (store) => DropdownMenuItem<LegacyStore?>(
                            value: store,
                            child: Text(store.name),
                          ),
                        ),
                      ],
                      onChanged: (_loading || _loadingStores)
                          ? null
                          : (store) => setState(() => _selectedStore = store),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _loading
                                ? null
                                : () => _pickDate(isStart: true),
                            icon: const Icon(Icons.calendar_month),
                            label: Text('開始日: ${_dateLabel(_startDate)}'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _loading
                                ? null
                                : () => _pickDate(isStart: false),
                            icon: const Icon(Icons.event),
                            label: Text('終了日: ${_dateLabel(_endDate)}'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _loading ? null : _runSearch,
                        icon: _loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.search),
                        label: Text(_loading ? '検索中...' : '検索する'),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_message != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _message!,
                    style: const TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            if (_hasResult) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '検索結果（${_dateLabel(_startDate)} 〜 ${_dateLabel(_endDate)}）',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _statTile(
                            '商品売上合計',
                            '￥${_yen(_totalInventoryBasedSales)}',
                            color: Colors.green.shade700,
                          ),
                          const SizedBox(width: 8),
                          _statTile(
                            '手入力売上合計',
                            '￥${_yen(_totalManualSalesTotal)}',
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _statTile('現金売上合計', '￥${_yen(_totalCashSales)}'),
                          const SizedBox(width: 8),
                          _statTile('カード売上合計', '￥${_yen(_totalCardSales)}'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _statTile('セッション数', '${_sessions.length} 件'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '※在庫の増減から算出した概算です。値引き・ロス等は考慮されません。',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _sessions.isEmpty ? null : _exportPdf,
                          icon: const Icon(Icons.picture_as_pdf),
                          label: const Text('履歴をPDFで出力'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.shade300,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_sessions.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '対象期間の記録はありません',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ),
                )
              else
                for (final s in _sessions) _sessionTile(s),
            ],
          ],
        ),
      ),
    );
  }
}
