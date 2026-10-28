import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_api.dart';
import '../services/auth_store.dart';
import '../services/error_text.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

/// 个人资料：帮助问诊与方案更贴合（性别/年龄/身高体重/基础病史等）。
/// 全部可选、随时可改；不填全也不影响使用。
class ProfileEditPage extends StatefulWidget {
  const ProfileEditPage({super.key});

  @override
  State<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends State<ProfileEditPage> {
  final _nicknameCtrl = TextEditingController();
  final _heightCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  final _surgeryCtrl = TextEditingController();
  final _allergyCtrl = TextEditingController();

  String? _gender; // male / female / other
  int? _birthYear;
  String? _activityLevel;
  final Set<String> _conditions = {};

  bool _loading = true;
  bool _saving = false;

  static const _conditionOptions = ['无', '高血压', '糖尿病', '心脏病', '骨质疏松', '关节炎', '其他'];
  static const _activityOptions = [
    ('sedentary', '久坐少动'),
    ('light', '轻度活动'),
    ('moderate', '中等强度'),
    ('active', '高强度'),
  ];

  @override
  void initState() {
    super.initState();
    _nicknameCtrl.text = AuthStore.user?.nickname ?? '';
    _load();
  }

  @override
  void dispose() {
    _nicknameCtrl.dispose();
    _heightCtrl.dispose();
    _weightCtrl.dispose();
    _surgeryCtrl.dispose();
    _allergyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final profile = await AuthApi.getProfile() ?? const <String, dynamic>{};
    if (!mounted) return;
    setState(() {
      _gender = profile['gender']?.toString();
      _birthYear = (profile['birth_year'] as num?)?.toInt();
      final h = (profile['height_cm'] as num?)?.toDouble();
      final w = (profile['weight_kg'] as num?)?.toDouble();
      if (h != null) _heightCtrl.text = h.toStringAsFixed(h.truncateToDouble() == h ? 0 : 1);
      if (w != null) _weightCtrl.text = w.toStringAsFixed(w.truncateToDouble() == w ? 0 : 1);
      _activityLevel = profile['activity_level']?.toString();
      _surgeryCtrl.text = profile['surgery_history']?.toString() ?? '';
      _allergyCtrl.text = profile['allergies']?.toString() ?? '';
      final conds = profile['chronic_conditions'];
      if (conds is List) {
        _conditions
          ..clear()
          ..addAll(conds.map((e) => e.toString()).where((e) => e.isNotEmpty));
      }
      _loading = false;
    });
  }

  double? _parseNum(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll('，', ''));

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final fields = <String, dynamic>{};
      if (_gender != null) fields['gender'] = _gender;
      if (_birthYear != null) fields['birth_year'] = _birthYear;
      final h = _parseNum(_heightCtrl);
      if (h != null && h >= 60 && h <= 250) fields['height_cm'] = h;
      final w = _parseNum(_weightCtrl);
      if (w != null && w >= 20 && w <= 300) fields['weight_kg'] = w;
      if (_activityLevel != null) fields['activity_level'] = _activityLevel;
      fields['chronic_conditions'] = _conditions.toList();
      fields['surgery_history'] = _surgeryCtrl.text.trim();
      fields['allergies'] = _allergyCtrl.text.trim();
      await AuthApi.saveProfile(
        fields: fields,
        nickname: _nicknameCtrl.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('已保存，问诊和方案会更贴合你')));
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(friendlyError(e, fallback: '保存失败，请稍后重试'))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const AppBackButton(),
        title: const Text('个人资料'),
      ),
      body: _loading
          ? const AppLoading(label: '正在读取资料')
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                const Text(
                  '这些信息会帮助问诊与方案更贴合你。全部可选，随时可以回来补充；资料只用于康复服务。',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.6,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 18),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FieldLabel('昵称'),
                      TextField(
                        controller: _nicknameCtrl,
                        maxLength: 20,
                        decoration: const InputDecoration(
                          hintText: '怎么称呼你',
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 16),
                      const _FieldLabel('性别'),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final (value, label) in const [
                            ('male', '男'),
                            ('female', '女'),
                            ('other', '不便透露'),
                          ])
                            ChoiceChip(
                              label: Text(label),
                              selected: _gender == value,
                              onSelected: (sel) =>
                                  setState(() => _gender = sel ? value : null),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const _FieldLabel('出生年份'),
                      DropdownButtonFormField<int>(
                        initialValue: _birthYear,
                        hint: const Text('选择年份', style: TextStyle(fontSize: 14)),
                        items: [
                          for (var y = 2015; y >= 1935; y--)
                            DropdownMenuItem(value: y, child: Text('$y 年')),
                        ],
                        onChanged: (v) => setState(() => _birthYear = v),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _FieldLabel('身高（cm）'),
                                TextField(
                                  controller: _heightCtrl,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                                  ],
                                  decoration: const InputDecoration(hintText: '如 170'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _FieldLabel('体重（kg）'),
                                TextField(
                                  controller: _weightCtrl,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                                  ],
                                  decoration: const InputDecoration(hintText: '如 65'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const _FieldLabel('日常活动量'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (value, label) in _activityOptions)
                            ChoiceChip(
                              label: Text(label),
                              selected: _activityLevel == value,
                              onSelected: (sel) => setState(
                                () => _activityLevel = sel ? value : null,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _FieldLabel('基础病史（可多选）'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final c in _conditionOptions)
                            FilterChip(
                              label: Text(c),
                              selected: _conditions.contains(c),
                              onSelected: (sel) => setState(() {
                                if (c == '无' && sel) {
                                  _conditions.clear();
                                } else {
                                  _conditions.remove('无');
                                }
                                if (sel) {
                                  _conditions.add(c);
                                } else {
                                  _conditions.remove(c);
                                }
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const _FieldLabel('手术史（可选）'),
                      TextField(
                        controller: _surgeryCtrl,
                        maxLines: 2,
                        maxLength: 200,
                        decoration: const InputDecoration(
                          hintText: '如：2023 年右膝半月板手术',
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 10),
                      const _FieldLabel('过敏史（可选）'),
                      TextField(
                        controller: _allergyCtrl,
                        maxLines: 2,
                        maxLength: 200,
                        decoration: const InputDecoration(
                          hintText: '如：青霉素过敏',
                          counterText: '',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(Colors.white),
                          ),
                        )
                      : const Text('保存'),
                ),
                const SizedBox(height: 10),
                const Text(
                  '不想填的项直接跳过即可，问诊过程中还会再了解必要信息。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppTheme.textTertiary),
                ),
              ],
            ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;

  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppTheme.textPrimary,
        ),
      ),
    );
  }
}
