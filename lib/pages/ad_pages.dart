part of '../main.dart';

// ─────────────────────────────────────────────
// 全画面広告ダイアログ（3秒で自動クローズ）
// ─────────────────────────────────────────────

class _FullScreenAdDialog extends StatefulWidget {
  final _AdEntry ad;
  const _FullScreenAdDialog({required this.ad});

  @override
  State<_FullScreenAdDialog> createState() => _FullScreenAdDialogState();
}

class _FullScreenAdDialogState extends State<_FullScreenAdDialog> {
  int _remaining = 3;

  @override
  void initState() {
    super.initState();
    _tick();
  }

  void _tick() async {
    for (int i = 3; i > 0; i--) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      setState(() => _remaining = i - 1);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ad = widget.ad;
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.black,
      child: SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: Stack(
          children: [
            // 広告コンテンツ（URLがあればタップで遷移）
            GestureDetector(
              onTap: ad.url.isNotEmpty ? () => _openLink(ad.url) : null,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (ad.image.isNotEmpty)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.85,
                          maxHeight: MediaQuery.of(context).size.height * 0.6,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(
                            base64Decode(ad.image),
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    if (ad.message.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          ad.message,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                    if (ad.url.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.open_in_new,
                            size: 13,
                            color: Colors.white54,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'タップして詳細を見る',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.6),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // カウントダウン
            Positioned(
              top: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _remaining > 0 ? '$_remaining 秒' : '閉じる',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
            // 広告主名
            Positioned(
              bottom: 16,
              right: 16,
              child: Text(
                '提供: ${ad.orgName}',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 画面内広告カード（操作を止めない広告）
// ─────────────────────────────────────────────

class AdInlineCardWidget extends StatelessWidget {
  const AdInlineCardWidget({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (!AppSession.adViewEnabled) return const SizedBox.shrink();
    final ads = AppSession.distributedAds;
    if (ads.isEmpty) return const SizedBox.shrink();
    final now = DateTime.now().millisecondsSinceEpoch;
    final ad = ads[(now ~/ 10000) % ads.length];

    return Card(
      color: Colors.white,
      elevation: compact ? 1 : 2,
      child: InkWell(
        onTap: ad.url.isNotEmpty ? () => _openLink(ad.url) : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(compact ? 8 : 10),
          child: Row(
            children: [
              if (ad.image.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    base64Decode(ad.image),
                    width: compact ? 56 : 72,
                    height: compact ? 56 : 72,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              if (ad.image.isNotEmpty) const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.campaign_outlined,
                          size: compact ? 16 : 18,
                          color: Colors.deepPurple,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'お知らせ',
                          style: TextStyle(
                            fontSize: compact ? 12 : 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.deepPurple,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      ad.message.isEmpty ? ad.orgName : ad.message,
                      style: TextStyle(fontSize: compact ? 12 : 13),
                      maxLines: compact ? 2 : 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ad.url.isNotEmpty ? 'タップして詳細を見る' : '提供: ${ad.orgName}',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              if (ad.url.isNotEmpty)
                Icon(Icons.chevron_right, color: Colors.grey.shade500),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 広告バナーウィジェット
// ─────────────────────────────────────────────

class AdBannerWidget extends StatefulWidget {
  const AdBannerWidget({super.key});

  @override
  State<AdBannerWidget> createState() => _AdBannerWidgetState();
}

class _AdBannerWidgetState extends State<AdBannerWidget> {
  Timer? _timer;
  int _index = 0;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    // 初期表示もランダム
    final initAds = AppSession.distributedAds;
    if (initAds.isNotEmpty) _index = Random().nextInt(initAds.length);
    // 広告がなくてもタイマーは常に起動（後からロードされた場合も対応）
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted) return;
      final ads = AppSession.distributedAds;
      if (ads.isEmpty) return;
      int next;
      if (ads.length == 1) {
        next = 0;
      } else {
        do {
          next = Random().nextInt(ads.length);
        } while (next == _index);
      }
      setState(() {
        _index = next;
        _tick++;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AppSession.adViewEnabled) return const SizedBox.shrink();
    final ads = AppSession.distributedAds;
    if (ads.isNotEmpty) {
      final ad = ads[_index % ads.length];
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: GestureDetector(
          key: ValueKey(_tick),
          onTap: ad.url.isNotEmpty ? () => _openLink(ad.url) : null,
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 80, maxHeight: 160),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Colors.grey.shade300)),
            ),
            child: Stack(
              children: [
                Row(
                  children: [
                    if (ad.image.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            base64Decode(ad.image),
                            height: 100,
                            width: 100,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    if (ad.message.isNotEmpty)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Text(
                            ad.message,
                            style: const TextStyle(fontSize: 13),
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ],
                ),
                Positioned(
                  bottom: 4,
                  right: 8,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (ad.url.isNotEmpty)
                        Icon(
                          Icons.open_in_new,
                          size: 11,
                          color: Colors.grey.shade400,
                        ),
                      if (ad.url.isNotEmpty) const SizedBox(width: 3),
                      Text(
                        '提供: ${ad.orgName}  [${_index + 1}/${ads.length}]',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}

// ─────────────────────────────────────────────
// 広告スペース管理ページ（管理者専用）
// ─────────────────────────────────────────────

class AdManagementPage extends StatefulWidget {
  const AdManagementPage({super.key});

  @override
  State<AdManagementPage> createState() => _AdManagementPageState();
}

class _AdManagementPageState extends State<AdManagementPage> {
  // 各スロットの状態: {image, message, url}
  List<Map<String, String>> _slots = [];
  // メッセージ用コントローラ（最大5個）
  final List<TextEditingController> _msgCtrls = List.generate(
    5,
    (_) => TextEditingController(),
  );
  // URL用コントローラ（最大5個）
  final List<TextEditingController> _urlCtrls = List.generate(
    5,
    (_) => TextEditingController(),
  );
  bool _loading = true;
  bool _saving = false;

  int get _maxSlots => AppSession.isSuperAdmin ? 5 : 3;

  @override
  void initState() {
    super.initState();
    _loadSlots();
  }

  @override
  void dispose() {
    for (final c in _msgCtrls) c.dispose();
    for (final c in _urlCtrls) c.dispose();
    super.dispose();
  }

  Future<void> _loadSlots() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .get();
      final data = doc.data();
      final raw = data?['adSlots'];
      List<Map<String, String>> loaded = [];
      if (raw is List && raw.isNotEmpty) {
        loaded = raw.map<Map<String, String>>((e) {
          if (e is Map) {
            return {
              'image': (e['image'] as String?) ?? '',
              'message': (e['message'] as String?) ?? '',
              'url': (e['url'] as String?) ?? '',
            };
          }
          return {'image': '', 'message': '', 'url': ''};
        }).toList();
      } else {
        // レガシー移行: adImage/adMessageをスロット0に
        final img = (data?['adImage'] as String?) ?? '';
        final msg = (data?['adMessage'] as String?) ?? '';
        if (img.isNotEmpty || msg.isNotEmpty) {
          loaded = [
            {'image': img, 'message': msg, 'url': ''},
          ];
        }
      }
      setState(() {
        _slots = loaded;
        for (int i = 0; i < _slots.length && i < _msgCtrls.length; i++) {
          _msgCtrls[i].text = _slots[i]['message'] ?? '';
          _urlCtrls[i].text = _slots[i]['url'] ?? '';
        }
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _pickImage(int i) async {
    final picker = ImagePicker();
    XFile? picked;
    try {
      picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 60,
        maxWidth: 600,
        maxHeight: 600,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('画像の選択に失敗しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    if (picked == null) return;
    try {
      final bytes = await picked.readAsBytes();
      // Web では image_picker のサイズ制限が効かないため Dart 側でリサイズ・圧縮
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('画像のデコードに失敗しました');
      final resized = img.copyResize(decoded, width: 300, height: -1);
      final compressed = img.encodeJpg(resized, quality: 55);
      setState(() {
        _slots[i] = {..._slots[i], 'image': base64Encode(compressed)};
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('画像の読み込みに失敗しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    // コントローラの内容をスロットに反映
    for (int i = 0; i < _slots.length && i < _msgCtrls.length; i++) {
      _slots[i] = {
        ..._slots[i],
        'message': _msgCtrls[i].text.trim(),
        'url': _urlCtrls[i].text.trim(),
      };
    }
    try {
      // 空のスロットは保存しない
      final slotsData = _slots
          .where(
            (s) =>
                (s['image'] ?? '').isNotEmpty ||
                (s['message'] ?? '').isNotEmpty,
          )
          .map(
            (s) => <String, dynamic>{
              'image': s['image'] ?? '',
              'message': s['message'] ?? '',
              'url': s['url'] ?? '',
            },
          )
          .toList();
      final orgRef = FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId);
      // 有効な広告があれば配信ON、なければOFF（adDistribEnabled を自動管理）
      // adImage/adMessage はレガシーフィールドのため同時に削除
      await orgRef.update({
        'adSlots': slotsData,
        'adDistribEnabled': slotsData.isNotEmpty,
        'adImage': FieldValue.delete(),
        'adMessage': FieldValue.delete(),
      });
      // 保存後に自組織データを再取得して広告リストを更新
      final updatedDoc = await orgRef.get();
      if (updatedDoc.exists) {
        await _loadAllAdsImpl(
          FirebaseFirestore.instance,
          ownOrgData: updatedDoc.data()!,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = AppSession.adSlotBase;
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: Text('広告管理（最大$_maxSlots枠）'),
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : TextButton(
                  onPressed: _save,
                  child: const Text(
                    '保存',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (base >= 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '割り当てスロット番号: ${base}〜${base + _maxSlots - 1}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                for (int i = 0; i < _slots.length; i++) _buildSlotCard(i),
                if (_slots.length < _maxSlots)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _slots.add({'image': '', 'message': '', 'url': ''});
                        });
                      },
                      icon: const Icon(Icons.add),
                      label: Text('スロットを追加（${_slots.length}/$_maxSlots）'),
                    ),
                  ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _buildSlotCard(int i) {
    final slot = _slots[i];
    final image = slot['image'] ?? '';
    final base = AppSession.adSlotBase;
    final globalNum = base >= 0 ? base + i : i;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'スロット $globalNum',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => setState(() {
                    _slots.removeAt(i);
                    _msgCtrls[i].text = '';
                    _urlCtrls[i].text = '';
                    // コントローラをシフト
                    for (
                      int j = i;
                      j < _slots.length && j + 1 < _msgCtrls.length;
                      j++
                    ) {
                      _msgCtrls[j].text = _msgCtrls[j + 1].text;
                      _urlCtrls[j].text = _urlCtrls[j + 1].text;
                    }
                    if (_slots.length < _msgCtrls.length) {
                      _msgCtrls[_slots.length].text = '';
                      _urlCtrls[_slots.length].text = '';
                    }
                  }),
                  tooltip: 'このスロットを削除',
                ),
              ],
            ),
            Center(
              child: GestureDetector(
                onTap: () => _pickImage(i),
                child: image.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          base64Decode(image),
                          height: 100,
                          fit: BoxFit.cover,
                        ),
                      )
                    : Container(
                        width: 160,
                        height: 80,
                        decoration: BoxDecoration(
                          color: Colors.deepPurple.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.deepPurple.shade100),
                        ),
                        child: Icon(
                          Icons.add_photo_alternate,
                          color: Colors.deepPurple.shade300,
                        ),
                      ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () => _pickImage(i),
                  icon: const Icon(Icons.upload_file, size: 16),
                  label: Text(image.isNotEmpty ? '画像を変更' : '画像をアップロード'),
                ),
                if (image.isNotEmpty)
                  TextButton(
                    onPressed: () =>
                        setState(() => _slots[i] = {...slot, 'image': ''}),
                    child: const Text(
                      '削除',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _msgCtrls[i],
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'メッセージテキスト（任意）',
                border: OutlineInputBorder(),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlCtrls[i],
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'リンクURL（任意）',
                hintText: 'https://example.com',
                prefixIcon: Icon(Icons.link, size: 18),
                border: OutlineInputBorder(),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
