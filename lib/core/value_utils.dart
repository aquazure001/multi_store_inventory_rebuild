part of '../main.dart';

// ─────────────────────────────────────────────
// Firestore値変換 共通ユーティリティ
// ─────────────────────────────────────────────

int inventoryIntValue(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? 0;
}
