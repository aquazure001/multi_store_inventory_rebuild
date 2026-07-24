import 'dart:async';
import 'dart:convert';
import 'dart:math';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;
import 'package:image/image.dart' as img;
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'firebase_options.dart';

part 'pages/delivery_processing_page.dart';
part 'pages/order_list_page.dart';
part 'pages/past_order_pdf_page.dart';
part 'pages/inventory_snapshot_page.dart';
part 'pages/order_request_history_page.dart';
part 'pages/special_order_page.dart';
part 'pages/store_inventory_page.dart';
part 'pages/store_list_page.dart';
part 'pages/settings_page.dart';
part 'pages/store_reorder_page.dart';
part 'pages/history_page.dart';
part 'pages/all_stores_inventory_page.dart';
part 'pages/auth_pages.dart';
part 'pages/org_management_page.dart';
part 'pages/ad_pages.dart';
part 'pages/admin_review_pages.dart';
part 'pages/legal_page.dart';
part 'pages/item_master_page.dart';
part 'core/app_session.dart';
part 'core/models.dart';

const String _appVersion = '1.2.1-delivery-cache-reset';

// iOS Safari / Android Chrome のポップアップブロック回避:
// AnchorElement を直接クリックすることでユーザージェスチャーコンテキストを維持する
void _openLink(String url) {
  html.AnchorElement(href: url)
    ..target = '_blank'
    ..rel = 'noopener noreferrer'
    ..click();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MultiStoreInventoryApp());
}

// ページ遷移監視（StoreInventoryPageの自動リフレッシュに使用）
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

// ─────────────────────────────────────────────
// セッション・広告ユーティリティ
// 実装は lib/core/app_session.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// モデル定義
// 実装は lib/core/models.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// アプリルート
// ─────────────────────────────────────────────

final GlobalKey<ScaffoldMessengerState> _rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

class MultiStoreInventoryApp extends StatefulWidget {
  const MultiStoreInventoryApp({super.key});

  @override
  State<MultiStoreInventoryApp> createState() => _MultiStoreInventoryAppState();
}

class _MultiStoreInventoryAppState extends State<MultiStoreInventoryApp> {
  @override
  void initState() {
    super.initState();
    html.window.addEventListener('swUpdateReady', _onUpdateReady);
  }

  @override
  void dispose() {
    html.window.removeEventListener('swUpdateReady', _onUpdateReady);
    super.dispose();
  }

  void _onUpdateReady(html.Event _) {
    _rootScaffoldMessengerKey.currentState?.showMaterialBanner(
      MaterialBanner(
        backgroundColor: Colors.deepPurple,
        content: const Text(
          '新しいバージョンが利用可能です',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _rootScaffoldMessengerKey.currentState
                  ?.hideCurrentMaterialBanner();
            },
            child: const Text('後で', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () {
              js.context.callMethod('eval', [
                r"""
(function() {
  var nextUrl = window.location.origin + window.location.pathname + '?force_update=' + Date.now();
  var jobs = [];
  if ('serviceWorker' in navigator) {
    jobs.push(navigator.serviceWorker.getRegistrations().then(function(registrations) {
      return Promise.all(registrations.map(function(reg) { return reg.unregister(); }));
    }).catch(function() {}));
  }
  if ('caches' in window) {
    jobs.push(caches.keys().then(function(keys) {
      return Promise.all(keys.map(function(key) { return caches.delete(key); }));
    }).catch(function() {}));
  }
  Promise.all(jobs).finally(function() { window.location.replace(nextUrl); });
})();
""",
              ]);
            },
            child: const Text(
              '今すぐ更新',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '多店舗在庫管理システム',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _rootScaffoldMessengerKey,
      navigatorObservers: [appRouteObserver],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const AuthGate(),
    );
  }
}

// ─────────────────────────────────────────────
// 店舗一覧ページ
// 実装は lib/pages/store_list_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 設定ページ
// 実装は lib/pages/settings_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 店舗並び替えページ（独立ページ）
// 実装は lib/pages/store_reorder_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 履歴ページ
// 実装は lib/pages/history_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 全店舗在庫確認ページ
// 実装は lib/pages/all_stores_inventory_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 店舗別在庫ページ
// 実装は lib/pages/store_inventory_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 商品マスタ管理ページ
// 実装は lib/pages/item_master_page.dart に分離
// ─────────────────────────────────────────────

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

// ─────────────────────────────────────────────
// 認証・ログイン・初期ユーザー読込ページ
// 実装は lib/pages/auth_pages.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 組織管理ページ（管理者専用）
// 実装は lib/pages/org_management_page.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 広告表示・広告管理まわり
// 実装は lib/pages/ad_pages.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 承認待ち・統括管理ページ
// 実装は lib/pages/admin_review_pages.dart に分離
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// 利用規約・プライバシーポリシー
// 実装は lib/pages/legal_page.dart に分離
// ─────────────────────────────────────────────
