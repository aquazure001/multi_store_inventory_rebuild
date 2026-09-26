part of '../main.dart';

// ─────────────────────────────────────────────
// アカウント無効化依頼ページ（統括管理者専用）
// 組織管理画面でメンバー削除時に作成された deletionRequests を一覧表示し、
// Auth側での無効化を実施した後に「対応済み」をマークする。
// ─────────────────────────────────────────────

class DeletionRequestsPage extends StatefulWidget {
  const DeletionRequestsPage({super.key});

  @override
  State<DeletionRequestsPage> createState() => _DeletionRequestsPageState();
}

class _DeletionRequestsPageState extends State<DeletionRequestsPage> {
  bool _showHandled = false;

  // 複合インデックス不要にするため日時順のみで取得し、status はアプリ側で絞り込む
  final Stream<QuerySnapshot<Map<String, dynamic>>> _stream = FirebaseFirestore
      .instance
      .collection('deletionRequests')
      .orderBy('requestedAt', descending: true)
      .snapshots();

  String _formatDate(dynamic v) {
    if (v is! Timestamp) return '-';
    final d = v.toDate();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}/${two(d.month)}/${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _markHandled(String id, String email) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('対応済みにする'),
        content: Text('$email のアカウント無効化を実施済みとしてマークしますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('対応済みにする'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await FirebaseFirestore.instance
          .collection('deletionRequests')
          .doc(id)
          .update({
            'status': 'handled',
            'handledAt': FieldValue.serverTimestamp(),
            'handledBy': AppSession.email,
          });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _copyUid(String uid) async {
    await Clipboard.setData(ClipboardData(text: uid));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('uidをコピーしました')));
    }
  }

  Widget _buildTile(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    final uid = d['targetUid']?.toString() ?? '';
    final email = d['targetEmail']?.toString() ?? '';
    final handled = d['status'] == 'handled';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              email.isNotEmpty ? email : '(メールアドレス不明)',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'uid: $uid',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: 'uidをコピー',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => _copyUid(uid),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '組織: ${d['orgName'] ?? ''}（${d['orgId'] ?? ''}）',
              style: const TextStyle(fontSize: 12),
            ),
            Text(
              '依頼者: ${d['requestedByNickname'] ?? ''}　依頼日時: ${_formatDate(d['requestedAt'])}',
              style: const TextStyle(fontSize: 12),
            ),
            if (handled)
              Text(
                '対応済み: ${_formatDate(d['handledAt'])}　${d['handledBy'] ?? ''}',
                style: TextStyle(fontSize: 12, color: Colors.green.shade700),
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _markHandled(doc.id, email),
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  label: const Text('対応済みにする'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(title: const Text('アカウント無効化依頼')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('エラー: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs;
          final pending = docs.where((d) => d.data()['status'] != 'handled');
          final handled = docs.where((d) => d.data()['status'] == 'handled');
          final shown = (_showHandled ? handled : pending).toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text('未対応 (${pending.length})'),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('対応済み (${handled.length})'),
                    ),
                  ],
                  selected: {_showHandled},
                  onSelectionChanged: (s) =>
                      setState(() => _showHandled = s.first),
                ),
              ),
              Expanded(
                child: shown.isEmpty
                    ? Center(
                        child: Text(
                          _showHandled ? '対応済みの依頼はありません' : '未対応の依頼はありません',
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 16),
                        children: shown.map(_buildTile).toList(),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
