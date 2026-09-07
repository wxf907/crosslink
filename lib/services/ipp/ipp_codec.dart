// IPP 协议编解码（RFC 8010/8011 子集），服务端与自测共用。
// 仅实现产品需要的操作与值类型；1setOf 用同 tag 多值表达。
import 'dart:convert';
import 'dart:typed_data';

// 值 tag（RFC 8010 §4.1）
const int kTagOctetArray = 0x30;
const int kTagBoolean = 0x22;
const int kTagInteger = 0x21;
const int kTagEnum = 0x23;
const int kTagRangeOfInteger = 0x33;
const int kTagTextNoLang = 0x41;
const int kTagNameNoLang = 0x42;
const int kTagKeyword = 0x44;
const int kTagUri = 0x45;
const int kTagCharset = 0x47;
const int kTagNaturalLang = 0x48;
const int kTagMimeMediaType = 0x49;

// 属性组分隔 tag
const int kTagEnd = 0x00;
const int kTagOperation = 0x01;
const int kTagJob = 0x02;
const int kTagPrinter = 0x04;
const int kTagUnsupported = 0x05;

// 操作码（RFC 8011 / IPP 2.0）
const int kOpPrintJob = 0x0002;
const int kOpValidateJob = 0x0004;
const int kOpCreateJob = 0x0005;
const int kOpSendDocument = 0x0006;
const int kOpCancelJob = 0x0008;
const int kOpGetJobAttributes = 0x0009;
const int kOpGetJobs = 0x000A;
const int kOpGetPrinterAttributes = 0x000B;
const int kOpHoldJob = 0x0010;
const int kOpReleaseJob = 0x0011;
const int kOpPausePrinter = 0x0012;
const int kOpResumePrinter = 0x0013;

// 状态码
const int kOk = 0x0000;
const int kErrBadRequest = 0x0400;
const int kErrUnauthorized = 0x0401;
const int kErrForbidden = 0x0403;
const int kErrNotFound = 0x0406;
const int kErrGone = 0x0405;
const int kErrInternal = 0x0500;

class IppRange {
  final int lower;
  final int upper;
  const IppRange(this.lower, this.upper);
  @override
  bool operator ==(Object other) =>
      other is IppRange && other.lower == lower && other.upper == upper;
  @override
  int get hashCode => Object.hash(lower, upper);
  @override
  String toString() => '$lower-$upper';
}

class IppAttr {
  final String name;
  final int tag;
  final List<Object> values; // int | bool | String | Uint8List | IppRange
  const IppAttr(this.name, this.tag, this.values);

  int? get firstInt => values.isEmpty ? null : (values.first as int);
  bool? get firstBool => values.isEmpty ? null : (values.first as bool);
  String? get firstString => values.isEmpty ? null : (values.first as String);
}

class IppGroup {
  final int tag; // kTagOperation / kTagJob / kTagPrinter / kTagUnsupported
  final List<IppAttr> attrs;
  IppGroup(this.tag, this.attrs);

  IppAttr? operator [](String name) {
    for (final a in attrs) {
      if (a.name == name) return a;
    }
    return null;
  }
}

class IppMessage {
  int versionMajor;
  int versionMinor;
  /// 请求 = operation-id；响应 = status-code
  int operationOrStatus;
  int requestId;
  final List<IppGroup> groups;

  IppMessage(this.versionMajor, this.versionMinor, this.operationOrStatus,
      this.requestId, this.groups);

  IppGroup? group(int tag) {
    for (final g in groups) {
      if (g.tag == tag) return g;
    }
    return null;
  }

  IppGroup ensureGroup(int tag) =>
      groups.firstWhere((g) => g.tag == tag, orElse: () {
        final g = IppGroup(tag, []);
        groups.add(g);
        return g;
      });

  Uint8List encode() {
    final b = BytesBuilder();
    b.addByte(versionMajor);
    b.addByte(versionMinor);
    _u16(b, operationOrStatus);
    _u32(b, requestId);
    for (final g in groups) {
      if (g.attrs.isEmpty) continue;
      b.addByte(g.tag);
      for (final a in g.attrs) {
        for (var i = 0; i < a.values.length; i++) {
          // 1setOf：仅第一个属性带名字，后续 name-length = 0
          final named = i == 0;
          final nameBytes = named ? utf8.encode(a.name) : const <int>[];
          b.addByte(a.tag);
          _u16(b, nameBytes.length);
          b.add(nameBytes);
          final v = _encodeValue(a.values[i], a.tag);
          _u32(b, v.length);
          b.add(v);
        }
      }
    }
    b.addByte(kTagEnd);
    return b.toBytes();
  }

  static Uint8List buildResponse(int requestId, int statusCode,
      {List<IppGroup>? groups}) {
    final m = IppMessage(1, 1, statusCode, requestId, groups ?? []);
    return m.encode();
  }

  static Uint8List _encodeValue(Object v, int tag) {
    final b = BytesBuilder();
    if (v is bool) {
      b.addByte(v ? 1 : 0);
    } else if (v is int) {
      _s32(b, v);
    } else if (v is IppRange) {
      _s32(b, v.lower);
      _s32(b, v.upper);
    } else if (v is String) {
      b.add(utf8.encode(v));
    } else if (v is List<int>) {
      b.add(v);
    }
    return b.toBytes();
  }
}

void _u16(BytesBuilder b, int v) {
  b.addByte((v >> 8) & 0xFF);
  b.addByte(v & 0xFF);
}

void _u32(BytesBuilder b, int v) {
  b.addByte((v >> 24) & 0xFF);
  b.addByte((v >> 16) & 0xFF);
  b.addByte((v >> 8) & 0xFF);
  b.addByte(v & 0xFF);
}

void _s32(BytesBuilder b, int v) => _u32(b, v.toSigned(32) & 0xFFFFFFFF);

class _Reader {
  final ByteData d;
  int p = 0;
  _Reader(Uint8List bytes) : d = ByteData.sublistView(bytes);

  int u8() => d.getUint8(p++);
  int u16() {
    final v = d.getUint16(p);
    p += 2;
    return v;
  }

  int u32() {
    final v = d.getUint32(p);
    p += 4;
    return v;
  }

  int s32() {
    final v = d.getInt32(p);
    p += 4;
    return v;
  }

  Uint8List bytes(int n) {
    final v = Uint8List.sublistView(d, p, p + n);
    p += n;
    return v;
  }
}

/// 解析 IPP 报文；容忍尾部多余数据（Print-Job 的文档二进制）。
/// 返回 (消息, 属性区结束偏移=文档起始)。
(IppMessage, int) decodeIpp(Uint8List data) {
  final r = _Reader(data);
  final vm = r.u8(), vn = r.u8();
  final op = r.u16();
  final reqId = r.u32();
  final groups = <IppGroup>[];
  IppGroup? cur;
  IppAttr? lastAttr;

  int? groupTag = r.u8();
  while (groupTag != null && groupTag != kTagEnd) {
    if (groupTag <= 0x0F) {
      // 新属性组
      cur = IppGroup(groupTag, []);
      groups.add(cur);
      lastAttr = null;
      groupTag = r.u8();
      continue;
    }
    final valueTag = groupTag;
    final nameLen = r.u16();
    final nameBytes = r.bytes(nameLen);
    final valLen = r.u32(); // RFC 8010：value-length 为 32 位
    final valBytes = r.bytes(valLen);
    final name = utf8.decode(nameBytes, allowMalformed: true);
    final value = _decodeValue(valueTag, valBytes);
    if (nameLen > 0 || cur == null) {
      lastAttr = IppAttr(name, valueTag, [value]);
      cur ??= IppGroup(kTagOperation, []);
      cur.attrs.add(lastAttr);
    } else if (lastAttr != null && lastAttr.tag == valueTag) {
      // 1setOf 续值（dart list 不可变包装）
      final ext = [...lastAttr.values, value];
      final idx = cur.attrs.indexOf(lastAttr);
      lastAttr = IppAttr(lastAttr.name, valueTag, ext);
      cur.attrs[idx] = lastAttr;
    } else {
      lastAttr = IppAttr(name.isEmpty ? lastAttr?.name ?? '' : name, valueTag, [value]);
      cur.attrs.add(lastAttr);
    }
    groupTag = r.u8();
  }
  return (IppMessage(vm, vn, op, reqId, groups), r.p);
}

Object _decodeValue(int tag, Uint8List bytes) {
  switch (tag) {
    case kTagBoolean:
      return bytes.isNotEmpty && bytes[0] != 0;
    case kTagInteger:
    case kTagEnum:
      if (bytes.length < 4) return 0;
      return ByteData.sublistView(bytes).getInt32(0);
    case kTagRangeOfInteger:
      if (bytes.length < 8) return const IppRange(0, 0);
      final bd = ByteData.sublistView(bytes);
      return IppRange(bd.getInt32(0), bd.getInt32(4));
    case kTagTextNoLang:
    case kTagNameNoLang:
    case kTagKeyword:
    case kTagUri:
    case kTagCharset:
    case kTagNaturalLang:
    case kTagMimeMediaType:
      return utf8.decode(bytes, allowMalformed: true);
    default:
      return bytes;
  }
}
