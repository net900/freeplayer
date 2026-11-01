import 'dart:async';
import 'dart:io';

import '../sp/models.dart';

/// One sentence the user can act on. Raw exception text ("HandshakeException:
/// ...") never reaches the UI — callers render this string instead.
String describeGatewayError(Object error) {
  if (error is SpException) return error.message;
  if (error is TlsException) {
    return 'HTTPS 握手失败：地址的证书无效或未被信任（自签证书、证书未部署或已过期）';
  }
  if (error is TimeoutException) {
    return '连接超时：地址没有在限定时间内响应';
  }
  if (error is SocketException) return _socketMessage(error);
  if (error is FormatException) {
    return '地址返回的不是接口数据，可能是一个网页或 404 页面';
  }
  if (error is HttpException) {
    return '连接被中断：${error.message}';
  }
  return '操作失败：$error';
}

String _socketMessage(SocketException error) {
  final os = error.osError;
  final text = '${error.message} ${os?.message ?? ''}'.toLowerCase();
  if (os?.errorCode == 11001 ||
      text.contains('failed host lookup') ||
      text.contains('name or service not known') ||
      text.contains('no such host')) {
    return '域名解析失败：检查地址拼写和 DNS';
  }
  if (os?.errorCode == 10061 || text.contains('refused')) {
    return '连接被拒绝：该地址的端口没有服务在监听';
  }
  if (os?.errorCode == 10060 ||
      text.contains('timed out') ||
      text.contains('timeout')) {
    return '连接超时：地址没有在限定时间内响应';
  }
  if (text.contains('unreachable')) {
    return '网络不可达：检查服务器地址或本机网络';
  }
  return '无法连接到该地址：${os?.message ?? error.message}';
}
