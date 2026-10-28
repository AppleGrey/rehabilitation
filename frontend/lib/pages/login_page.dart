import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_api.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/motion.dart';

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
        await AuthApi.login(
          phone: _phone.text.trim(),
          password: _password.text,
        );
      }
      if (!mounted) return;
      TextInput.finishAutofillContext();
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
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFE7F0E6),
              AppTheme.bgSecondary,
              AppTheme.bgSecondary,
            ],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -110,
              right: -100,
              child: _decorationCircle(
                260,
                AppTheme.mint.withValues(alpha: 0.18),
              ),
            ),
            Positioned(
              top: 90,
              left: -65,
              child: _decorationCircle(
                150,
                Colors.white.withValues(alpha: 0.35),
              ),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 28,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: AutofillGroup(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _brand(),
                          const SizedBox(height: 44),
                          const Text(
                            '每一步，都在\n靠近更好的自己。',
                            style: TextStyle(
                              fontSize: 31,
                              height: 1.25,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.8,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '科学跟练，清晰记录，让康复融入日常。',
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.5,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 30),
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.94),
                              borderRadius: BorderRadius.circular(26),
                              border: Border.all(color: Colors.white),
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.primaryDark.withValues(
                                    alpha: 0.07,
                                  ),
                                  blurRadius: 32,
                                  offset: const Offset(0, 16),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SegmentedButton<bool>(
                                  segments: const [
                                    ButtonSegment(
                                      value: false,
                                      label: Text('登录'),
                                    ),
                                    ButtonSegment(
                                      value: true,
                                      label: Text('创建账号'),
                                    ),
                                  ],
                                  selected: {_isRegister},
                                  showSelectedIcon: false,
                                  onSelectionChanged: _busy
                                      ? null
                                      : (selection) {
                                          if (selection.first != _isRegister) {
                                            _toggleMode();
                                          }
                                        },
                                  style: SegmentedButton.styleFrom(
                                    backgroundColor: AppTheme.bgSecondary,
                                    foregroundColor: AppTheme.textSecondary,
                                    selectedForegroundColor:
                                        AppTheme.primaryDark,
                                    selectedBackgroundColor:
                                        AppTheme.primaryLight,
                                    side: BorderSide.none,
                                    textStyle: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 22),
                                _field(
                                  controller: _phone,
                                  label: '手机号',
                                  hint: '请输入 11 位手机号',
                                  icon: Icons.phone_iphone_rounded,
                                  keyboardType: TextInputType.phone,
                                  submitOnEnter: false,
                                  autofillHints: const [
                                    AutofillHints.telephoneNumber,
                                  ],
                                  formatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                    LengthLimitingTextInputFormatter(11),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                _field(
                                  controller: _password,
                                  label: '密码',
                                  hint: '6-64 位',
                                  icon: Icons.lock_outline_rounded,
                                  obscure: _obscure,
                                  submitOnEnter: !_isRegister,
                                  autofillHints: const [AutofillHints.password],
                                  suffix: IconButton(
                                    tooltip: _obscure ? '显示密码' : '隐藏密码',
                                    icon: Icon(
                                      _obscure
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                      size: 20,
                                      color: AppTheme.textTertiary,
                                    ),
                                    onPressed: () =>
                                        setState(() => _obscure = !_obscure),
                                  ),
                                ),
                                ClipRect(
                                  child: AnimatedSize(
                                    duration: AppMotion.duration(
                                      context,
                                      AppMotion.standard,
                                    ),
                                    curve: AppMotion.emphasized,
                                    alignment: Alignment.topCenter,
                                    child: _isRegister
                                        ? Column(
                                            children: [
                                              const SizedBox(height: 12),
                                              _field(
                                                controller: _confirm,
                                                label: '确认密码',
                                                hint: '请再输入一次密码',
                                                icon: Icons.lock_reset_outlined,
                                                obscure: _obscure,
                                              ),
                                              const SizedBox(height: 12),
                                              _field(
                                                controller: _nickname,
                                                label: '昵称（可选）',
                                                hint: '希望我们怎么称呼你',
                                                icon: Icons
                                                    .person_outline_rounded,
                                                submitOnEnter: false,
                                                formatters: [
                                                  LengthLimitingTextInputFormatter(
                                                    20,
                                                  ),
                                                ],
                                              ),
                                            ],
                                          )
                                        : const SizedBox(
                                            width: double.infinity,
                                          ),
                                  ),
                                ),
                                AnimatedSize(
                                  duration: AppMotion.duration(
                                    context,
                                    AppMotion.quick,
                                  ),
                                  curve: AppMotion.curve,
                                  alignment: Alignment.topCenter,
                                  child: _error.isEmpty
                                      ? const SizedBox(width: double.infinity)
                                      : Padding(
                                          padding: const EdgeInsets.only(
                                            top: 14,
                                          ),
                                          child: _errorBanner(),
                                        ),
                                ),
                                const SizedBox(height: 20),
                                AppPressable(
                                  enabled: !_busy,
                                  child: ElevatedButton(
                                    onPressed: _busy ? null : _submit,
                                    child: _busy
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor:
                                                  AlwaysStoppedAnimation(
                                                    Colors.white,
                                                  ),
                                            ),
                                          )
                                        : Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                _isRegister ? '开始康复之旅' : '登录',
                                              ),
                                              const SizedBox(width: 8),
                                              const Icon(
                                                Icons.arrow_forward_rounded,
                                                size: 19,
                                              ),
                                            ],
                                          ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 22),
                          const Text(
                            '训练过程中如感到不适，请立即停止并咨询专业医生。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.5,
                              color: AppTheme.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _decorationCircle(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }

  Widget _brand() {
    return const Row(
      children: [
        AppIconBadge(
          icon: Icons.accessibility_new_rounded,
          color: Colors.white,
          backgroundColor: AppTheme.primaryDark,
          size: 46,
        ),
        SizedBox(width: 12),
        Text(
          '运动康复',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: AppTheme.primaryDark,
          ),
        ),
        SizedBox(width: 8),
        Text(
          'REHAB CARE',
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1.3,
            color: AppTheme.primary,
          ),
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
    Iterable<String>? autofillHints,
    Widget? suffix,
    bool submitOnEnter = true,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      inputFormatters: formatters,
      autofillHints: autofillHints,
      textInputAction: submitOnEnter
          ? TextInputAction.done
          : TextInputAction.next,
      onSubmitted: (_) {
        if (submitOnEnter) _submit();
      },
      style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 20, color: AppTheme.textTertiary),
        suffixIcon: suffix,
        filled: true,
        fillColor: AppTheme.bgPrimary,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
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
