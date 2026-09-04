import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_api.dart';
import '../theme/app_theme.dart';

/// 登录 / 注册。手机号 + 密码，暂不做短信验证码。
class LoginPage extends StatefulWidget {
  /// 登录或注册成功后回调，由外层切到主界面。
  final VoidCallback onSuccess;

  const LoginPage({super.key, required this.onSuccess});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _nickname = TextEditingController();

  bool _isRegister = false;
  bool _busy = false;
  bool _obscure = true;
  String _error = '';

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    _confirm.dispose();
    _nickname.dispose();
    super.dispose();
  }

  String? _validate() {
    final phone = _phone.text.trim();
    if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(phone)) return '请输入 11 位手机号';
    final pwd = _password.text;
    if (pwd.length < 6 || pwd.length > 64) return '密码长度需为 6-64 位';
    if (_isRegister && pwd != _confirm.text) return '两次输入的密码不一致';
    return null;
  }

  Future<void> _submit() async {
    if (_busy) return;
    final err = _validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      if (_isRegister) {
        await AuthApi.register(
          phone: _phone.text.trim(),
          password: _password.text,
          nickname: _nickname.text.trim(),
        );
      } else {
        await AuthApi.login(phone: _phone.text.trim(), password: _password.text);
      }
      if (!mounted) return;
      widget.onSuccess();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleMode() {
    setState(() {
      _isRegister = !_isRegister;
      _error = '';
      _confirm.clear();
      _nickname.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                const SizedBox(height: 32),
                _field(
                  controller: _phone,
                  label: '手机号',
                  hint: '请输入 11 位手机号',
                  icon: Icons.phone_iphone,
                  keyboardType: TextInputType.phone,
                  formatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(11),
                  ],
                ),
                const SizedBox(height: 14),
                _field(
                  controller: _password,
                  label: '密码',
                  hint: '6-64 位',
                  icon: Icons.lock_outline,
                  obscure: _obscure,
                  suffix: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                      size: 20,
                      color: AppTheme.textTertiary,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                if (_isRegister) ...[
                  const SizedBox(height: 14),
                  _field(
                    controller: _confirm,
                    label: '确认密码',
                    hint: '再输入一次',
                    icon: Icons.lock_reset_outlined,
                    obscure: _obscure,
                  ),
                  const SizedBox(height: 14),
                  _field(
                    controller: _nickname,
                    label: '昵称（可选）',
                    hint: '不填将自动生成',
                    icon: Icons.person_outline,
                    formatters: [LengthLimitingTextInputFormatter(20)],
                  ),
                ],
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _errorBanner(),
                ],
                const SizedBox(height: 28),
                ElevatedButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(Colors.white),
                          ),
                        )
                      : Text(_isRegister ? '注 册' : '登 录'),
                ),
                const SizedBox(height: 14),
                TextButton(
                  onPressed: _busy ? null : _toggleMode,
                  child: Text(
                    _isRegister ? '已有账号？去登录' : '还没有账号？立即注册',
                    style: const TextStyle(fontSize: 14, color: AppTheme.primary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppTheme.primaryLight,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(Icons.accessibility_new, size: 38, color: AppTheme.primary),
        ),
        const SizedBox(height: 18),
        const Text(
          '运动康复',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _isRegister ? '创建账号，开始你的康复计划' : '登录后查看你的康复方案',
          style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary),
        ),
      ],
    );
  }

  Widget _errorBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppTheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error,
              style: const TextStyle(fontSize: 13, color: AppTheme.error),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool obscure = false,
    TextInputType? keyboardType,
    List<TextInputFormatter>? formatters,
    Widget? suffix,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      inputFormatters: formatters,
      onSubmitted: (_) => _submit(),
      style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 20, color: AppTheme.textTertiary),
        suffixIcon: suffix,
        filled: true,
        fillColor: AppTheme.bgPrimary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppTheme.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppTheme.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppTheme.primary, width: 1.5),
        ),
      ),
    );
  }
}
