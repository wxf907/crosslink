import 'dart:convert';
import 'dart:typed_data';

/// TCP 帧协议。
///
/// 帧结构：
///   [4 字节大端 uint32：headerLen][header(JSON,UTF8)][可选 body 二进制]
/// header 为 JSON 对象，至少包含 `type` 字段；若包含 `bodyLen`(int>0)，
/// 则其后紧跟 bodyLen 字节的二进制负载（图片/文件分块）。
class Frame {
  final Map<String, dynamic> header;
  final Uint8List? body;

  Frame(this.header, [this.body]);

  String get type => header['type'] as String? ?? '';

  /// 编码为可直接写入 socket 的字节
  Uint8List encode() {
    final headerBytes = utf8.encode(jsonEncode(header));
    final bodyLen = body?.length ?? 0;
    final out = BytesBuilder();
    final lenBuf = ByteData(4)..setUint32(0, headerBytes.length, Endian.big);
    out.add(lenBuf.buffer.asUint8List());
    out.add(headerBytes);
    if (bodyLen > 0) out.add(body!);
    return out.toBytes();
  }
}

/// 增量帧解析器：持续 feed 收到的字节，回调完整帧。
class FrameParser {
  final void Function(Frame frame) onFrame;

  FrameParser(this.onFrame);

  Uint8List _pending = Uint8List(0);

  void addData(List<int> data) {
    // 合并缓存
    final merged = Uint8List(_pending.length + data.length);
    merged.setRange(0, _pending.length, _pending);
    merged.setRange(_pending.length, merged.length, data);
    _pending = merged;

    while (true) {
      if (_pending.length < 4) return;
      final headerLen =
          ByteData.sublistView(_pending, 0, 4).getUint32(0, Endian.big);
      if (_pending.length < 4 + headerLen) return;
      final headerBytes = _pending.sublist(4, 4 + headerLen);
      final Map<String, dynamic> header =
          jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
      final int bodyLen = (header['bodyLen'] as int?) ?? 0;
      final total = 4 + headerLen + bodyLen;
      if (_pending.length < total) return;

      Uint8List? body;
      if (bodyLen > 0) {
        body = _pending.sublist(4 + headerLen, total);
      }
      // 消费掉已解析部分
      _pending = _pending.sublist(total);
      onFrame(Frame(header, body));
    }
  }
}

/// 帧类型常量
class FrameType {
  static const hello = 'hello';
  static const text = 'text';
  static const image = 'image';
  static const fileOffer = 'file_offer';
  static const fileChunk = 'file_chunk';
  static const fileEnd = 'file_end';
  static const fileAck = 'file_ack';
  // 扫码登录授权：手机端把凭证下发给待登录设备
  static const loginGrant = 'login_grant';
  static const loginAck = 'login_ack';
  // V2 持久连接心跳：ping/pong 双向探活
  static const ping = 'ping';
  static const pong = 'pong';
  // V2 应用层确认：接收方确认消息/文件真实收到（防“假发送成功”）
  static const msgAck = 'msg_ack';
  // V2 头像同步：携带头像图片字节与时间戳，较新者胜出
  static const avatar = 'avatar';
  static const printOffer = 'print_offer';
}
