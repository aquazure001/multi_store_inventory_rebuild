// billing_invoices / billing_receipts の既存エントリに createdByUid / createdByEmail を補完する。
//
// createdBy（ニックネーム）から users コレクションを引いて uid / email を特定する。
// - ニックネームが users 内で一意に引ける場合のみ補完対象とする。
// - ニックネームが null/空、または users 内で重複する場合は補完せず「要手動確認」として一覧報告する。
// - 既に createdByUid が入っているエントリはスキップする。
//
// 使い方:
//   node backfill_createdByUid.js            … ドライラン（読み取り＋確認のみ。書き込みなし）
//   node backfill_createdByUid.js --apply    … 実際に Firestore へ書き込む
//
// 環境変数:
//   FIRESTORE_BACKUP_KEY  … サービスアカウント鍵JSONのパス
//   ORG_ID                … 対象組織ID（既定: legacy）

const admin = require('firebase-admin');
const path = require('path');
const os = require('os');

const KEY_PATH = process.env.FIRESTORE_BACKUP_KEY ||
  path.join(os.homedir(), 'Documents/multi_store_inventory_backups/.firebase-adminsdk-key.json');
const ORG = process.env.ORG_ID || 'legacy';
const APPLY = process.argv.includes('--apply');

admin.initializeApp({ credential: admin.credential.cert(require(KEY_PATH)) });
const db = admin.firestore();
const base = db.collection('inventory_shared_v1');

const TARGETS = [
  { suffix: 'billing_invoices', label: '請求書 billing_invoices' },
  { suffix: 'billing_receipts', label: '受領書 billing_receipts' },
  { suffix: 'billing_invoice_pdfs', label: '請求書PDF billing_invoice_pdfs' },
  { suffix: 'billing_receipt_pdfs', label: '受領書PDF billing_receipt_pdfs' },
];

function norm(s) {
  return (s == null ? '' : String(s)).trim();
}

async function buildNicknameIndex() {
  const snap = await db.collection('users').get();
  // nickname(正規化) -> [{uid, email, nicknameRaw}]
  const byNickname = new Map();
  let nullNicknameUsers = 0;
  for (const doc of snap.docs) {
    const d = doc.data();
    const nick = norm(d.nickname);
    if (!nick) { nullNicknameUsers++; continue; }
    const key = nick;
    if (!byNickname.has(key)) byNickname.set(key, []);
    byNickname.get(key).push({ uid: doc.id, email: norm(d.email), nicknameRaw: d.nickname });
  }
  return { byNickname, totalUsers: snap.size, nullNicknameUsers };
}

async function main() {
  console.log(`鍵: ${KEY_PATH}`);
  console.log(`対象組織: org_${ORG}`);
  console.log(`モード: ${APPLY ? '★★ APPLY（書き込みあり）★★' : 'ドライラン（書き込みなし）'}`);

  const { byNickname, totalUsers, nullNicknameUsers } = await buildNicknameIndex();
  console.log(`\nusers: ${totalUsers}件（うち nickname 未設定 ${nullNicknameUsers}件）`);
  const dupNicknames = [...byNickname.entries()].filter(([, v]) => v.length > 1);
  if (dupNicknames.length) {
    console.log('users 内で重複するニックネーム:');
    for (const [k, v] of dupNicknames) {
      console.log(`  "${k}" -> ${v.map((x) => `${x.uid}(${x.email})`).join(' , ')}`);
    }
  } else {
    console.log('users 内で重複するニックネーム: なし');
  }

  const grandSummary = [];

  for (const t of TARGETS) {
    const col = base.doc(`org_${ORG}__${t.suffix}`).collection('entries');
    const snap = await col.get();

    const already = [];       // 既に createdByUid あり
    const toFill = [];        // 補完可能（ニックネーム一意）
    const needManual = [];    // 要手動確認（null / 重複 / users に存在しない）

    for (const doc of snap.docs) {
      const d = doc.data();
      const existingUid = norm(d.createdByUid);
      const nick = norm(d.createdBy);
      if (existingUid) {
        already.push({ id: doc.id, nick, uid: existingUid });
        continue;
      }
      if (!nick) {
        needManual.push({ id: doc.id, reason: 'createdBy が null/空', nick: d.createdBy, storeName: d.storeName, invoiceNo: d.invoiceNo, createdAtLocal: d.createdAtLocal });
        continue;
      }
      const matches = byNickname.get(nick);
      if (!matches) {
        needManual.push({ id: doc.id, reason: `users に該当ニックネームなし ("${nick}")`, nick, storeName: d.storeName, invoiceNo: d.invoiceNo, createdAtLocal: d.createdAtLocal });
        continue;
      }
      if (matches.length > 1) {
        needManual.push({ id: doc.id, reason: `ニックネーム "${nick}" が users 内で重複`, nick, storeName: d.storeName, invoiceNo: d.invoiceNo, createdAtLocal: d.createdAtLocal });
        continue;
      }
      toFill.push({ id: doc.id, nick, uid: matches[0].uid, email: matches[0].email, storeName: d.storeName, invoiceNo: d.invoiceNo, createdAtLocal: d.createdAtLocal });
    }

    console.log(`\n===== ${t.label} : 全 ${snap.size} 件 =====`);
    console.log(`  既に createdByUid あり : ${already.length} 件`);
    console.log(`  補完可能（ニックネーム一意）: ${toFill.length} 件`);
    for (const r of toFill) {
      console.log(`    - ${r.id}  createdBy="${r.nick}" -> uid=${r.uid} email=${r.email}  [${r.invoiceNo} / ${r.storeName} / ${r.createdAtLocal}]`);
    }
    console.log(`  要手動確認 : ${needManual.length} 件`);
    for (const r of needManual) {
      console.log(`    ! ${r.id}  理由: ${r.reason}  createdBy=${JSON.stringify(r.nick)}  [${r.invoiceNo} / ${r.storeName} / ${r.createdAtLocal}]`);
    }

    grandSummary.push({ label: t.label, total: snap.size, already: already.length, toFill: toFill.length, needManual: needManual.length });

    if (APPLY && toFill.length) {
      let done = 0;
      for (const r of toFill) {
        await col.doc(r.id).set(
          { createdByUid: r.uid, createdByEmail: r.email, createdByUidBackfilledAt: admin.firestore.FieldValue.serverTimestamp() },
          { merge: true },
        );
        done++;
      }
      console.log(`  → APPLY: ${done} 件を書き込みました`);
    }
  }

  console.log('\n========== 集計 ==========');
  for (const s of grandSummary) {
    console.log(`  ${s.label}: 全${s.total} / 既存${s.already} / 補完可能${s.toFill} / 要手動確認${s.needManual}`);
  }
  if (!APPLY) {
    console.log('\n（ドライラン。書き込みは行っていません。実行するには --apply を付けてください）');
  }
  process.exit(0);
}

main().catch((e) => { console.error(e); process.exit(1); });
