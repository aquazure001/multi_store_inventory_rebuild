// multi-store-inventory-app のFirestoreデータを読み取り専用でローカルJSONに
// バックアップするスクリプト。実行するたびに日付入りの新しいファイルを作成する。
//
// 使い方:
//   npm install
//   node backup.js
//
// 環境変数（省略時はデフォルト値を使用）:
//   FIRESTORE_BACKUP_KEY  … サービスアカウント鍵JSONのパス
//                            (既定値: ~/Documents/multi_store_inventory_backups/.firebase-adminsdk-key.json)
//   FIRESTORE_BACKUP_DIR  … バックアップ出力先ディレクトリ
//                            (既定値: ~/Documents/multi_store_inventory_backups)
//   FIRESTORE_ORG_PREFIX  … 対象組織のinventory_shared_v1ドキュメントIDprefix
//                            (既定値: org_legacy__)

const admin = require('firebase-admin');
const fs = require('fs');
const path = require('path');
const os = require('os');

const KEY_PATH = process.env.FIRESTORE_BACKUP_KEY ||
  path.join(os.homedir(), 'Documents/multi_store_inventory_backups/.firebase-adminsdk-key.json');
const OUTPUT_DIR = process.env.FIRESTORE_BACKUP_DIR ||
  path.join(os.homedir(), 'Documents/multi_store_inventory_backups');
const ORG_PREFIX = process.env.FIRESTORE_ORG_PREFIX || 'org_legacy__';

// サブコレクションを辿る最大の深さ（entries/batches/billing_visibility等の
// 直下1階層のみを想定。想定外に深い構造があっても無限ループしないための保険）。
const MAX_SUBCOLLECTION_DEPTH = 4;

function serializeValue(value) {
  if (value === null || value === undefined) return value;
  if (value instanceof admin.firestore.Timestamp) {
    return { __type__: 'timestamp', value: value.toDate().toISOString() };
  }
  if (value instanceof admin.firestore.GeoPoint) {
    return { __type__: 'geopoint', latitude: value.latitude, longitude: value.longitude };
  }
  if (value instanceof admin.firestore.DocumentReference) {
    return { __type__: 'docref', path: value.path };
  }
  if (Array.isArray(value)) {
    return value.map(serializeValue);
  }
  if (typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = serializeValue(v);
    return out;
  }
  return value;
}

let docCount = 0;

async function dumpDocument(docSnap, depth) {
  const result = {
    id: docSnap.id,
    data: serializeValue(docSnap.data()),
  };
  docCount++;

  if (depth < MAX_SUBCOLLECTION_DEPTH) {
    const subcollections = await docSnap.ref.listCollections();
    for (const col of subcollections) {
      const docs = await dumpCollection(col, depth + 1);
      if (docs.length > 0) {
        result[`__subcollection__${col.id}`] = docs;
      }
    }
  }
  return result;
}

async function dumpCollection(colRef, depth) {
  const snapshot = await colRef.get();
  const docs = [];
  for (const docSnap of snapshot.docs) {
    docs.push(await dumpDocument(docSnap, depth));
  }
  return docs;
}

async function main() {
  if (!fs.existsSync(KEY_PATH)) {
    console.error(`サービスアカウント鍵が見つかりません: ${KEY_PATH}`);
    process.exit(1);
  }
  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  }

  admin.initializeApp({
    credential: admin.credential.cert(require(KEY_PATH)),
  });
  const db = admin.firestore();

  console.log('Firestoreからデータを取得しています（読み取り専用）...');

  const backup = {
    exportedAt: new Date().toISOString(),
    orgPrefix: ORG_PREFIX,
    orgs: [],
    users: [],
    inventory_shared_v1: [],
  };

  // orgs（トップレベルコレクション: 組織メタデータ）
  backup.orgs = await dumpCollection(db.collection('orgs'), 0);
  console.log(`  orgs: ${backup.orgs.length}件`);

  // users（トップレベルコレクション: ユーザー情報）
  backup.users = await dumpCollection(db.collection('users'), 0);
  console.log(`  users: ${backup.users.length}件`);

  // inventory_shared_v1（業務データ。ドキュメントIDは "org_{orgId}__{種別}" 形式。
  // ORG_PREFIX に一致するドキュメントのみ対象にする）
  const invSnapshot = await db.collection('inventory_shared_v1').get();
  const targetDocs = invSnapshot.docs.filter((d) => d.id.startsWith(ORG_PREFIX));
  console.log(`  inventory_shared_v1: 全${invSnapshot.docs.length}件中、対象(${ORG_PREFIX}*) ${targetDocs.length}件`);

  for (const docSnap of targetDocs) {
    const dumped = await dumpDocument(docSnap, 0);
    backup.inventory_shared_v1.push(dumped);
    console.log(`    - ${docSnap.id}`);
  }

  const dateStr = new Date().toISOString().slice(0, 10).replace(/-/g, '');
  const outputPath = path.join(OUTPUT_DIR, `firestore_backup_${dateStr}.json`);
  fs.writeFileSync(outputPath, JSON.stringify(backup, null, 2), 'utf8');

  const stats = fs.statSync(outputPath);
  console.log('');
  console.log('=== バックアップ完了 ===');
  console.log(`保存先: ${outputPath}`);
  console.log(`ファイルサイズ: ${(stats.size / 1024 / 1024).toFixed(2)} MB`);
  console.log(`取得ドキュメント総数（サブコレクション含む）: ${docCount}件`);

  process.exit(0);
}

main().catch((err) => {
  console.error('バックアップ中にエラーが発生しました:', err);
  process.exit(1);
});
