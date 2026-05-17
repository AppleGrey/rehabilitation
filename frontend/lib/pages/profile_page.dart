import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ProfilePage extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onComplete;

  const ProfilePage({
    super.key,
    required this.onBack,
    required this.onComplete,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _nameController = TextEditingController(text: '李明');
  final _ageController = TextEditingController(text: '32');
  final _allergyController = TextEditingController();
  final _symptomController = TextEditingController(text: '右肩疼痛3个月，抬手臂时加重，影响日常工作');

  String _gender = '男';
  String _occupation = '办公室职员';
  int _painLevel = 5;
  final List<String> _medicalHistory = ['无'];
  final List<String> _rehabilitationAreas = ['肩部'];

  @override
  void dispose() {
    _nameController.dispose();
    _ageController.dispose();
    _allergyController.dispose();
    _symptomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: widget.onBack,
        ),
        title: const Text('完善健康档案'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoAlert(),
            const SizedBox(height: 24),
            _buildSection('基本信息', [
              _buildTextInput('姓名', _nameController),
              _buildRadioGroup('性别', ['男', '女'], _gender, (v) => setState(() => _gender = v!)),
              _buildTextInput('年龄', _ageController, keyboardType: TextInputType.number),
              _buildRadioGroup('职业', ['办公室职员', 'IT从业者', '教师', '其他'], _occupation, (v) => setState(() => _occupation = v!)),
            ]),
            const SizedBox(height: 24),
            _buildSection('健康状况', [
              _buildCheckboxGroup('既往病史（可多选）', ['无', '心脏病', '高血压', '糖尿病'], _medicalHistory),
              _buildTextInput('过敏史（选填）', _allergyController),
            ]),
            const SizedBox(height: 24),
            _buildSection('康复诉求', [
              _buildCheckboxGroup('需要康复的部位（可多选）', ['颈椎', '肩部', '腰部', '膝关节'], _rehabilitationAreas),
              _buildPainSlider(),
              _buildTextArea('症状描述', _symptomController, '请描述您的症状，如：右肩疼痛3个月，抬手臂时加重...'),
            ]),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () {
                _showToast('档案已保存');
                Future.delayed(const Duration(milliseconds: 500), widget.onComplete);
              },
              child: const Text('保存并继续'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoAlert() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.primaryLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: AppTheme.primary, size: 22),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '为什么要填写这些信息？',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '准确的信息有助于我们为您制定更精准的康复方案，您的个人隐私会受到严格保护。',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppTheme.bgPrimary,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _buildTextInput(String label, TextEditingController controller, {TextInputType? keyboardType}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            keyboardType: keyboardType,
            decoration: InputDecoration(
              hintText: '请输入$label',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextArea(String label, TextEditingController controller, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: hint,
          ),
        ),
      ],
    );
  }

  Widget _buildRadioGroup(String label, List<String> options, String selected, Function(String?) onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: options.map((option) {
              final isSelected = selected == option;
              return GestureDetector(
                onTap: () => onChanged(option),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: isSelected ? AppTheme.primary : AppTheme.bgSecondary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    option,
                    style: TextStyle(
                      fontSize: 14,
                      color: isSelected ? Colors.white : AppTheme.textPrimary,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildCheckboxGroup(String label, List<String> options, List<String> selected) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: options.map((option) {
              final isSelected = selected.contains(option);
              return GestureDetector(
                onTap: () {
                  setState(() {
                    if (option == '无') {
                      selected.clear();
                      selected.add('无');
                    } else {
                      selected.remove('无');
                      if (isSelected) {
                        selected.remove(option);
                      } else {
                        selected.add(option);
                      }
                    }
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: isSelected ? AppTheme.primary : AppTheme.bgSecondary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isSelected)
                        const Icon(Icons.check, size: 14, color: Colors.white),
                      if (isSelected) const SizedBox(width: 4),
                      Text(
                        option,
                        style: TextStyle(
                          fontSize: 14,
                          color: isSelected ? Colors.white : AppTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildPainSlider() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('疼痛程度：$_painLevel/10', style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          Slider(
            value: _painLevel.toDouble(),
            min: 0,
            max: 10,
            divisions: 10,
            activeColor: AppTheme.primary,
            onChanged: (v) => setState(() => _painLevel = v.round()),
          ),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('轻微', style: TextStyle(fontSize: 12, color: AppTheme.textTertiary)),
              Text('剧烈', style: TextStyle(fontSize: 12, color: AppTheme.textTertiary)),
            ],
          ),
        ],
      ),
    );
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
