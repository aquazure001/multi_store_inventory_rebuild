part of '../main.dart';

// ─────────────────────────────────────────────
// 商品・テスター・備品の種別変換共通ユーティリティ
// ─────────────────────────────────────────────

String normalizeInventoryTypeKey({String? typeKey, String? itemType}) {
  final rawTypeKey = (typeKey ?? '').trim();
  if (rawTypeKey == 'products' ||
      rawTypeKey == 'testers' ||
      rawTypeKey == 'equipments') {
    return rawTypeKey;
  }

  final rawItemType = (itemType ?? rawTypeKey).trim();
  if (rawItemType == '商品' || rawItemType == 'products') return 'products';
  if (rawItemType == 'テスター' || rawItemType == 'testers') return 'testers';
  if (rawItemType == '備品' || rawItemType == 'equipments') return 'equipments';

  return rawTypeKey.isNotEmpty ? rawTypeKey : rawItemType;
}

String inventoryTypeLabelFromKey(String typeKey) {
  final normalized = normalizeInventoryTypeKey(typeKey: typeKey);
  if (normalized == 'products') return '商品';
  if (normalized == 'testers') return 'テスター';
  if (normalized == 'equipments') return '備品';
  return typeKey;
}

bool isProductsType({String? typeKey, String? itemType}) {
  return normalizeInventoryTypeKey(typeKey: typeKey, itemType: itemType) ==
      'products';
}
