part of '../main.dart';

// ─────────────────────────────────────────────
// ⑤ 発注リストページ
// ─────────────────────────────────────────────

class _OrderMeta {
  const _OrderMeta({
    this.requestedAt,
    this.orderedAt,
    this.acknowledgedAt,
    this.requestedBy = '',
    this.orderedBy = '',
    this.acknowledgedBy = '',
    this.lastRequestedQty = 0,
  });

  final DateTime? requestedAt;
  final DateTime? orderedAt;
  final DateTime? acknowledgedAt;
  final String requestedBy;
  final String orderedBy;
  final String acknowledgedBy;
  final int lastRequestedQty;

  bool get isPdfIssued => orderedAt != null;
  bool get needsAcknowledgement => orderedAt != null && acknowledgedAt == null;

  factory _OrderMeta.fromMap(Map<dynamic, dynamic> map) {
    DateTime? readTime(dynamic value) {
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is String && value.isNotEmpty) {
        return DateTime.tryParse(value);
      }
      return null;
    }

    return _OrderMeta(
      requestedAt: readTime(map['requestedAt']),
      orderedAt: readTime(map['orderedAt']),
      acknowledgedAt: readTime(map['acknowledgedAt']),
      requestedBy: (map['requestedBy'] ?? '').toString(),
      orderedBy: (map['orderedBy'] ?? '').toString(),
      acknowledgedBy: (map['acknowledgedBy'] ?? '').toString(),
      lastRequestedQty: (map['lastRequestedQty'] as num?)?.toInt() ?? 0,
    );
  }
}

class _OrderEntry {
  const _OrderEntry({
    required this.store,
    required this.item,
    required this.itemType,
    required this.current,
    required this.base,
    this.orderedQty = 0,
    this.orderMeta = const _OrderMeta(),
  });
  final LegacyStore store;
  final LegacyItem item;
  final String itemType;
  final int current;
  final int base;
  final int orderedQty;
  final _OrderMeta orderMeta;

  int get shortage => base - current;
  int get effectiveShortage => max(0, base - current - orderedQty);
  bool get hasOrderedQty => orderedQty > 0;
}

// ─────────────────────────────────────────────
// 発注リスト画面
// 実装は lib/pages/order_list_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 棚卸し一覧CSV出力
// 実装は lib/pages/inventory_snapshot_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 発注ボタン履歴
// 実装は lib/pages/order_request_history_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 過去の発注表PDF再出力
// 実装は lib/pages/past_order_pdf_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 納品処理ページ
// 実装は lib/pages/delivery_processing_page.dart に分離
// ─────────────────────────────────────────────

class _InventoryData {
  const _InventoryData({
    required this.products,
    required this.testers,
    required this.equipments,
    required this.productStocks,
    required this.testerStocks,
    required this.equipmentStocks,
    required this.baseStocks,
    this.orderedProductStocks = const {},
    this.orderedTesterStocks = const {},
    this.orderedEquipmentStocks = const {},
    this.productOrderMetas = const {},
    this.testerOrderMetas = const {},
    this.equipmentOrderMetas = const {},
  });

  final List<LegacyItem> products;
  final List<LegacyItem> testers;
  final List<LegacyItem> equipments;
  final Map<String, int> productStocks;
  final Map<String, int> testerStocks;
  final Map<String, int> equipmentStocks;
  final Map<String, int> baseStocks;
  final Map<String, int> orderedProductStocks;
  final Map<String, int> orderedTesterStocks;
  final Map<String, int> orderedEquipmentStocks;
  final Map<String, _OrderMeta> productOrderMetas;
  final Map<String, _OrderMeta> testerOrderMetas;
  final Map<String, _OrderMeta> equipmentOrderMetas;
}
