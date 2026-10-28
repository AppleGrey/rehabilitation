import 'dart:async';
import 'dart:io';

/// 把各种异常转成用户看得懂的一句话，避免 SocketException 之类的原文直接上屏。
String friendlyError(Object error, {String fallback = '网络似乎不太顺畅，请稍后重试'}) {
  if (error is TimeoutException) return '网络有点慢，请检查网络后重试';
  if (error is SocketException) return '网络连接失败，请检查网络后重试';
  if (error is HttpException) return '和服务器的连接断开了，请稍后重试';

  final msg = error.toString();
  if (msg.contains('SocketException') ||
      msg.contains('Failed host lookup') ||
      msg.contains('Connection refused') ||
      msg.contains('Connection closed') ||
      msg.contains('Connection reset')) {
    return '网络连接失败，请检查网络后重试';
  }
  if (msg.contains('TimeoutException') || msg.contains('timed out')) {
    return '请求超时，请检查网络后重试';
  }
  final cleaned = msg.replaceFirst(RegExp(r'^Exception: '), '').trim();
  if (cleaned.isEmpty) return fallback;
  // 服务端返回的中文提示原样透出；纯英文/技术性文本回落到通用文案
  final hasChinese = RegExp(r'[一-鿿]').hasMatch(cleaned);
  return hasChinese ? cleaned : fallback;
}
