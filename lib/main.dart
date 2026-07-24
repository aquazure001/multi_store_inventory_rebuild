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

part 'app_root.dart';
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
part 'core/inventory_data.dart';
part 'core/master_data_cache.dart';
part 'core/item_type_utils.dart';

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
// 実装は lib/app_root.dart に分離
// ─────────────────────────────────────────────

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
// 発注・在庫共通データ
// 実装は lib/core/inventory_data.dart に分離
// ─────────────────────────────────────────────

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
