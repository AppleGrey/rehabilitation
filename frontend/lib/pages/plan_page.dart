import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/exercise.dart';
import '../widgets/exercise_card.dart';

class PlanPage extends StatelessWidget {
  const PlanPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgSecondary,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 80),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              _buildPlanCard(),
              _buildCalendar(),
              _buildTrainingContent(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return const Padding(
      padding: EdgeInsets.all(20),
      child: Text(
        '康复方案',
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: AppTheme.textPrimary,
        ),
      ),
    );
  }

  Widget _buildPlanCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.bgPrimary,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '肩部综合康复方案',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryLight,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    '进行中',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              '针对肩周炎及肩袖肌群损伤的综合康复训练方案，通过循序渐进的动作练习，恢复肩关节活动度，增强肌力。',
              style: TextStyle(
                fontSize: 14,
                color: AppTheme.textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: const [
                _StatItem(value: '21', label: '总天数'),
                _StatItem(value: '7', label: '已完成'),
                _StatItem(value: '14', label: '剩余'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendar() {
    final days = ['一', '二', '三', '四', '五', '六', '日'];
    final dates = [1, 2, 3, 4, 5, 6, 7];

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '训练日历',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(7, (index) {
                final isToday = index == 0;
                return Container(
                  width: 48,
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: isToday ? AppTheme.primary : AppTheme.primaryLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Text(
                        days[index],
                        style: TextStyle(
                          fontSize: 11,
                          color: isToday ? Colors.white : AppTheme.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${dates[index]}',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: isToday ? Colors.white : AppTheme.primary,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrainingContent() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '训练内容',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Column(
            children: [
              ExerciseListItem(
                exercise: Exercise(
                  id: '1',
                  title: '颈部放松运动',
                  type: ExerciseType.warmup,
                  durationMinutes: 3,
                  description: '',
                  status: ExerciseStatus.completed,
                ),
              ),
              SizedBox(height: 8),
              ExerciseListItem(
                exercise: Exercise(
                  id: '2',
                  title: '肩部环绕练习',
                  type: ExerciseType.main,
                  durationMinutes: 5,
                  description: '',
                  status: ExerciseStatus.completed,
                ),
              ),
              SizedBox(height: 8),
              ExerciseListItem(
                exercise: Exercise(
                  id: '3',
                  title: '肩部拉伸训练',
                  type: ExerciseType.main,
                  durationMinutes: 8,
                  description: '',
                  status: ExerciseStatus.pending,
                ),
              ),
              SizedBox(height: 8),
              ExerciseListItem(
                exercise: Exercise(
                  id: '4',
                  title: '弹力带外旋训练',
                  type: ExerciseType.strength,
                  durationMinutes: 5,
                  description: '',
                  status: ExerciseStatus.pending,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String value;
  final String label;

  const _StatItem({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppTheme.primary,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }
}
