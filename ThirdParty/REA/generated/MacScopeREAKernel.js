var MacScopeREA = (() => {
  var __create = Object.create;
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __getProtoOf = Object.getPrototypeOf;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __esm = (fn, res, err) => function __init() {
    if (err) throw err[0];
    try {
      return fn && (res = (0, fn[__getOwnPropNames(fn)[0]])(fn = 0)), res;
    } catch (e) {
      throw err = [e], e;
    }
  };
  var __commonJS = (cb, mod) => function __require() {
    try {
      return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
    } catch (e) {
      throw mod = 0, e;
    }
  };
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
    // If the importer is in node compatibility mode or this is not an ESM
    // file that has been converted to a CommonJS file using a Babel-
    // compatible transform (i.e. "__esModule" has not been set), then set
    // "default" to the CommonJS "module.exports" for node compatibility.
    isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
    mod
  ));
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // ThirdParty/REA/dependencies/base64-js/index.js
  var require_base64_js = __commonJS({
    "ThirdParty/REA/dependencies/base64-js/index.js"(exports) {
      "use strict";
      init_runtime();
      exports.byteLength = byteLength;
      exports.toByteArray = toByteArray;
      exports.fromByteArray = fromByteArray;
      var lookup = [];
      var revLookup = [];
      var Arr = typeof Uint8Array !== "undefined" ? Uint8Array : Array;
      var code = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      for (i = 0, len = code.length; i < len; ++i) {
        lookup[i] = code[i];
        revLookup[code.charCodeAt(i)] = i;
      }
      var i;
      var len;
      revLookup["-".charCodeAt(0)] = 62;
      revLookup["_".charCodeAt(0)] = 63;
      function getLens(b64) {
        var len2 = b64.length;
        if (len2 % 4 > 0) {
          throw new Error("Invalid string. Length must be a multiple of 4");
        }
        var validLen = b64.indexOf("=");
        if (validLen === -1) validLen = len2;
        var placeHoldersLen = validLen === len2 ? 0 : 4 - validLen % 4;
        return [validLen, placeHoldersLen];
      }
      function byteLength(b64) {
        var lens = getLens(b64);
        var validLen = lens[0];
        var placeHoldersLen = lens[1];
        return (validLen + placeHoldersLen) * 3 / 4 - placeHoldersLen;
      }
      function _byteLength(b64, validLen, placeHoldersLen) {
        return (validLen + placeHoldersLen) * 3 / 4 - placeHoldersLen;
      }
      function toByteArray(b64) {
        var tmp;
        var lens = getLens(b64);
        var validLen = lens[0];
        var placeHoldersLen = lens[1];
        var arr = new Arr(_byteLength(b64, validLen, placeHoldersLen));
        var curByte = 0;
        var len2 = placeHoldersLen > 0 ? validLen - 4 : validLen;
        var i2;
        for (i2 = 0; i2 < len2; i2 += 4) {
          tmp = revLookup[b64.charCodeAt(i2)] << 18 | revLookup[b64.charCodeAt(i2 + 1)] << 12 | revLookup[b64.charCodeAt(i2 + 2)] << 6 | revLookup[b64.charCodeAt(i2 + 3)];
          arr[curByte++] = tmp >> 16 & 255;
          arr[curByte++] = tmp >> 8 & 255;
          arr[curByte++] = tmp & 255;
        }
        if (placeHoldersLen === 2) {
          tmp = revLookup[b64.charCodeAt(i2)] << 2 | revLookup[b64.charCodeAt(i2 + 1)] >> 4;
          arr[curByte++] = tmp & 255;
        }
        if (placeHoldersLen === 1) {
          tmp = revLookup[b64.charCodeAt(i2)] << 10 | revLookup[b64.charCodeAt(i2 + 1)] << 4 | revLookup[b64.charCodeAt(i2 + 2)] >> 2;
          arr[curByte++] = tmp >> 8 & 255;
          arr[curByte++] = tmp & 255;
        }
        return arr;
      }
      function tripletToBase64(num) {
        return lookup[num >> 18 & 63] + lookup[num >> 12 & 63] + lookup[num >> 6 & 63] + lookup[num & 63];
      }
      function encodeChunk(uint8, start, end) {
        var tmp;
        var output = [];
        for (var i2 = start; i2 < end; i2 += 3) {
          tmp = (uint8[i2] << 16 & 16711680) + (uint8[i2 + 1] << 8 & 65280) + (uint8[i2 + 2] & 255);
          output.push(tripletToBase64(tmp));
        }
        return output.join("");
      }
      function fromByteArray(uint8) {
        var tmp;
        var len2 = uint8.length;
        var extraBytes = len2 % 3;
        var parts = [];
        var maxChunkLength = 16383;
        for (var i2 = 0, len22 = len2 - extraBytes; i2 < len22; i2 += maxChunkLength) {
          parts.push(encodeChunk(uint8, i2, i2 + maxChunkLength > len22 ? len22 : i2 + maxChunkLength));
        }
        if (extraBytes === 1) {
          tmp = uint8[len2 - 1];
          parts.push(
            lookup[tmp >> 2] + lookup[tmp << 4 & 63] + "=="
          );
        } else if (extraBytes === 2) {
          tmp = (uint8[len2 - 2] << 8) + uint8[len2 - 1];
          parts.push(
            lookup[tmp >> 10] + lookup[tmp >> 4 & 63] + lookup[tmp << 2 & 63] + "="
          );
        }
        return parts.join("");
      }
    }
  });

  // ThirdParty/REA/dependencies/ieee754/index.js
  var require_ieee754 = __commonJS({
    "ThirdParty/REA/dependencies/ieee754/index.js"(exports) {
      init_runtime();
      /*! ieee754. BSD-3-Clause License. Feross Aboukhadijeh <https://feross.org/opensource> */
      exports.read = function(buffer, offset, isLE, mLen, nBytes) {
        var e, m;
        var eLen = nBytes * 8 - mLen - 1;
        var eMax = (1 << eLen) - 1;
        var eBias = eMax >> 1;
        var nBits = -7;
        var i = isLE ? nBytes - 1 : 0;
        var d = isLE ? -1 : 1;
        var s = buffer[offset + i];
        i += d;
        e = s & (1 << -nBits) - 1;
        s >>= -nBits;
        nBits += eLen;
        for (; nBits > 0; e = e * 256 + buffer[offset + i], i += d, nBits -= 8) {
        }
        m = e & (1 << -nBits) - 1;
        e >>= -nBits;
        nBits += mLen;
        for (; nBits > 0; m = m * 256 + buffer[offset + i], i += d, nBits -= 8) {
        }
        if (e === 0) {
          e = 1 - eBias;
        } else if (e === eMax) {
          return m ? NaN : (s ? -1 : 1) * Infinity;
        } else {
          m = m + Math.pow(2, mLen);
          e = e - eBias;
        }
        return (s ? -1 : 1) * m * Math.pow(2, e - mLen);
      };
      exports.write = function(buffer, value, offset, isLE, mLen, nBytes) {
        var e, m, c;
        var eLen = nBytes * 8 - mLen - 1;
        var eMax = (1 << eLen) - 1;
        var eBias = eMax >> 1;
        var rt = mLen === 23 ? Math.pow(2, -24) - Math.pow(2, -77) : 0;
        var i = isLE ? 0 : nBytes - 1;
        var d = isLE ? 1 : -1;
        var s = value < 0 || value === 0 && 1 / value < 0 ? 1 : 0;
        value = Math.abs(value);
        if (isNaN(value) || value === Infinity) {
          m = isNaN(value) ? 1 : 0;
          e = eMax;
        } else {
          e = Math.floor(Math.log(value) / Math.LN2);
          if (value * (c = Math.pow(2, -e)) < 1) {
            e--;
            c *= 2;
          }
          if (e + eBias >= 1) {
            value += rt / c;
          } else {
            value += rt * Math.pow(2, 1 - eBias);
          }
          if (value * c >= 2) {
            e++;
            c /= 2;
          }
          if (e + eBias >= eMax) {
            m = 0;
            e = eMax;
          } else if (e + eBias >= 1) {
            m = (value * c - 1) * Math.pow(2, mLen);
            e = e + eBias;
          } else {
            m = value * Math.pow(2, eBias - 1) * Math.pow(2, mLen);
            e = 0;
          }
        }
        for (; mLen >= 8; buffer[offset + i] = m & 255, i += d, m /= 256, mLen -= 8) {
        }
        e = e << mLen | m;
        eLen += mLen;
        for (; eLen > 0; buffer[offset + i] = e & 255, i += d, e /= 256, eLen -= 8) {
        }
        buffer[offset + i - d] |= s * 128;
      };
    }
  });

  // ThirdParty/REA/dependencies/buffer/index.js
  var require_buffer = __commonJS({
    "ThirdParty/REA/dependencies/buffer/index.js"(exports) {
      "use strict";
      init_runtime();
      /*!
       * The buffer module from node.js, for the browser.
       *
       * @author   Feross Aboukhadijeh <https://feross.org>
       * @license  MIT
       */
      var base643 = require_base64_js();
      var ieee754 = require_ieee754();
      var customInspectSymbol = typeof Symbol === "function" && typeof Symbol["for"] === "function" ? Symbol["for"]("nodejs.util.inspect.custom") : null;
      exports.Buffer = Buffer3;
      exports.SlowBuffer = SlowBuffer;
      exports.INSPECT_MAX_BYTES = 50;
      var K_MAX_LENGTH = 2147483647;
      exports.kMaxLength = K_MAX_LENGTH;
      Buffer3.TYPED_ARRAY_SUPPORT = typedArraySupport();
      if (!Buffer3.TYPED_ARRAY_SUPPORT && typeof console !== "undefined" && typeof console.error === "function") {
        console.error(
          "This browser lacks typed array (Uint8Array) support which is required by `buffer` v5.x. Use `buffer` v4.x if you require old browser support."
        );
      }
      function typedArraySupport() {
        try {
          const arr = new Uint8Array(1);
          const proto = { foo: function() {
            return 42;
          } };
          Object.setPrototypeOf(proto, Uint8Array.prototype);
          Object.setPrototypeOf(arr, proto);
          return arr.foo() === 42;
        } catch (e) {
          return false;
        }
      }
      Object.defineProperty(Buffer3.prototype, "parent", {
        enumerable: true,
        get: function() {
          if (!Buffer3.isBuffer(this)) return void 0;
          return this.buffer;
        }
      });
      Object.defineProperty(Buffer3.prototype, "offset", {
        enumerable: true,
        get: function() {
          if (!Buffer3.isBuffer(this)) return void 0;
          return this.byteOffset;
        }
      });
      function createBuffer(length) {
        if (length > K_MAX_LENGTH) {
          throw new RangeError('The value "' + length + '" is invalid for option "size"');
        }
        const buf = new Uint8Array(length);
        Object.setPrototypeOf(buf, Buffer3.prototype);
        return buf;
      }
      function Buffer3(arg, encodingOrOffset, length) {
        if (typeof arg === "number") {
          if (typeof encodingOrOffset === "string") {
            throw new TypeError(
              'The "string" argument must be of type string. Received type number'
            );
          }
          return allocUnsafe(arg);
        }
        return from(arg, encodingOrOffset, length);
      }
      Buffer3.poolSize = 8192;
      function from(value, encodingOrOffset, length) {
        if (typeof value === "string") {
          return fromString(value, encodingOrOffset);
        }
        if (ArrayBuffer.isView(value)) {
          return fromArrayView(value);
        }
        if (value == null) {
          throw new TypeError(
            "The first argument must be one of type string, Buffer, ArrayBuffer, Array, or Array-like Object. Received type " + typeof value
          );
        }
        if (isInstance(value, ArrayBuffer) || value && isInstance(value.buffer, ArrayBuffer)) {
          return fromArrayBuffer(value, encodingOrOffset, length);
        }
        if (typeof SharedArrayBuffer !== "undefined" && (isInstance(value, SharedArrayBuffer) || value && isInstance(value.buffer, SharedArrayBuffer))) {
          return fromArrayBuffer(value, encodingOrOffset, length);
        }
        if (typeof value === "number") {
          throw new TypeError(
            'The "value" argument must not be of type number. Received type number'
          );
        }
        const valueOf = value.valueOf && value.valueOf();
        if (valueOf != null && valueOf !== value) {
          return Buffer3.from(valueOf, encodingOrOffset, length);
        }
        const b = fromObject(value);
        if (b) return b;
        if (typeof Symbol !== "undefined" && Symbol.toPrimitive != null && typeof value[Symbol.toPrimitive] === "function") {
          return Buffer3.from(value[Symbol.toPrimitive]("string"), encodingOrOffset, length);
        }
        throw new TypeError(
          "The first argument must be one of type string, Buffer, ArrayBuffer, Array, or Array-like Object. Received type " + typeof value
        );
      }
      Buffer3.from = function(value, encodingOrOffset, length) {
        return from(value, encodingOrOffset, length);
      };
      Object.setPrototypeOf(Buffer3.prototype, Uint8Array.prototype);
      Object.setPrototypeOf(Buffer3, Uint8Array);
      function assertSize(size) {
        if (typeof size !== "number") {
          throw new TypeError('"size" argument must be of type number');
        } else if (size < 0) {
          throw new RangeError('The value "' + size + '" is invalid for option "size"');
        }
      }
      function alloc(size, fill, encoding) {
        assertSize(size);
        if (size <= 0) {
          return createBuffer(size);
        }
        if (fill !== void 0) {
          return typeof encoding === "string" ? createBuffer(size).fill(fill, encoding) : createBuffer(size).fill(fill);
        }
        return createBuffer(size);
      }
      Buffer3.alloc = function(size, fill, encoding) {
        return alloc(size, fill, encoding);
      };
      function allocUnsafe(size) {
        assertSize(size);
        return createBuffer(size < 0 ? 0 : checked(size) | 0);
      }
      Buffer3.allocUnsafe = function(size) {
        return allocUnsafe(size);
      };
      Buffer3.allocUnsafeSlow = function(size) {
        return allocUnsafe(size);
      };
      function fromString(string4, encoding) {
        if (typeof encoding !== "string" || encoding === "") {
          encoding = "utf8";
        }
        if (!Buffer3.isEncoding(encoding)) {
          throw new TypeError("Unknown encoding: " + encoding);
        }
        const length = byteLength(string4, encoding) | 0;
        let buf = createBuffer(length);
        const actual = buf.write(string4, encoding);
        if (actual !== length) {
          buf = buf.slice(0, actual);
        }
        return buf;
      }
      function fromArrayLike(array2) {
        const length = array2.length < 0 ? 0 : checked(array2.length) | 0;
        const buf = createBuffer(length);
        for (let i = 0; i < length; i += 1) {
          buf[i] = array2[i] & 255;
        }
        return buf;
      }
      function fromArrayView(arrayView) {
        if (isInstance(arrayView, Uint8Array)) {
          const copy = new Uint8Array(arrayView);
          return fromArrayBuffer(copy.buffer, copy.byteOffset, copy.byteLength);
        }
        return fromArrayLike(arrayView);
      }
      function fromArrayBuffer(array2, byteOffset, length) {
        if (byteOffset < 0 || array2.byteLength < byteOffset) {
          throw new RangeError('"offset" is outside of buffer bounds');
        }
        if (array2.byteLength < byteOffset + (length || 0)) {
          throw new RangeError('"length" is outside of buffer bounds');
        }
        let buf;
        if (byteOffset === void 0 && length === void 0) {
          buf = new Uint8Array(array2);
        } else if (length === void 0) {
          buf = new Uint8Array(array2, byteOffset);
        } else {
          buf = new Uint8Array(array2, byteOffset, length);
        }
        Object.setPrototypeOf(buf, Buffer3.prototype);
        return buf;
      }
      function fromObject(obj) {
        if (Buffer3.isBuffer(obj)) {
          const len = checked(obj.length) | 0;
          const buf = createBuffer(len);
          if (buf.length === 0) {
            return buf;
          }
          obj.copy(buf, 0, 0, len);
          return buf;
        }
        if (obj.length !== void 0) {
          if (typeof obj.length !== "number" || numberIsNaN(obj.length)) {
            return createBuffer(0);
          }
          return fromArrayLike(obj);
        }
        if (obj.type === "Buffer" && Array.isArray(obj.data)) {
          return fromArrayLike(obj.data);
        }
      }
      function checked(length) {
        if (length >= K_MAX_LENGTH) {
          throw new RangeError("Attempt to allocate Buffer larger than maximum size: 0x" + K_MAX_LENGTH.toString(16) + " bytes");
        }
        return length | 0;
      }
      function SlowBuffer(length) {
        if (+length != length) {
          length = 0;
        }
        return Buffer3.alloc(+length);
      }
      Buffer3.isBuffer = function isBuffer(b) {
        return b != null && b._isBuffer === true && b !== Buffer3.prototype;
      };
      Buffer3.compare = function compare3(a, b) {
        if (isInstance(a, Uint8Array)) a = Buffer3.from(a, a.offset, a.byteLength);
        if (isInstance(b, Uint8Array)) b = Buffer3.from(b, b.offset, b.byteLength);
        if (!Buffer3.isBuffer(a) || !Buffer3.isBuffer(b)) {
          throw new TypeError(
            'The "buf1", "buf2" arguments must be one of type Buffer or Uint8Array'
          );
        }
        if (a === b) return 0;
        let x = a.length;
        let y = b.length;
        for (let i = 0, len = Math.min(x, y); i < len; ++i) {
          if (a[i] !== b[i]) {
            x = a[i];
            y = b[i];
            break;
          }
        }
        if (x < y) return -1;
        if (y < x) return 1;
        return 0;
      };
      Buffer3.isEncoding = function isEncoding(encoding) {
        switch (String(encoding).toLowerCase()) {
          case "hex":
          case "utf8":
          case "utf-8":
          case "ascii":
          case "latin1":
          case "binary":
          case "base64":
          case "ucs2":
          case "ucs-2":
          case "utf16le":
          case "utf-16le":
            return true;
          default:
            return false;
        }
      };
      Buffer3.concat = function concat(list, length) {
        if (!Array.isArray(list)) {
          throw new TypeError('"list" argument must be an Array of Buffers');
        }
        if (list.length === 0) {
          return Buffer3.alloc(0);
        }
        let i;
        if (length === void 0) {
          length = 0;
          for (i = 0; i < list.length; ++i) {
            length += list[i].length;
          }
        }
        const buffer = Buffer3.allocUnsafe(length);
        let pos = 0;
        for (i = 0; i < list.length; ++i) {
          let buf = list[i];
          if (isInstance(buf, Uint8Array)) {
            if (pos + buf.length > buffer.length) {
              if (!Buffer3.isBuffer(buf)) buf = Buffer3.from(buf);
              buf.copy(buffer, pos);
            } else {
              Uint8Array.prototype.set.call(
                buffer,
                buf,
                pos
              );
            }
          } else if (!Buffer3.isBuffer(buf)) {
            throw new TypeError('"list" argument must be an Array of Buffers');
          } else {
            buf.copy(buffer, pos);
          }
          pos += buf.length;
        }
        return buffer;
      };
      function byteLength(string4, encoding) {
        if (Buffer3.isBuffer(string4)) {
          return string4.length;
        }
        if (ArrayBuffer.isView(string4) || isInstance(string4, ArrayBuffer)) {
          return string4.byteLength;
        }
        if (typeof string4 !== "string") {
          throw new TypeError(
            'The "string" argument must be one of type string, Buffer, or ArrayBuffer. Received type ' + typeof string4
          );
        }
        const len = string4.length;
        const mustMatch = arguments.length > 2 && arguments[2] === true;
        if (!mustMatch && len === 0) return 0;
        let loweredCase = false;
        for (; ; ) {
          switch (encoding) {
            case "ascii":
            case "latin1":
            case "binary":
              return len;
            case "utf8":
            case "utf-8":
              return utf8ToBytes(string4).length;
            case "ucs2":
            case "ucs-2":
            case "utf16le":
            case "utf-16le":
              return len * 2;
            case "hex":
              return len >>> 1;
            case "base64":
              return base64ToBytes(string4).length;
            default:
              if (loweredCase) {
                return mustMatch ? -1 : utf8ToBytes(string4).length;
              }
              encoding = ("" + encoding).toLowerCase();
              loweredCase = true;
          }
        }
      }
      Buffer3.byteLength = byteLength;
      function slowToString(encoding, start, end) {
        let loweredCase = false;
        if (start === void 0 || start < 0) {
          start = 0;
        }
        if (start > this.length) {
          return "";
        }
        if (end === void 0 || end > this.length) {
          end = this.length;
        }
        if (end <= 0) {
          return "";
        }
        end >>>= 0;
        start >>>= 0;
        if (end <= start) {
          return "";
        }
        if (!encoding) encoding = "utf8";
        while (true) {
          switch (encoding) {
            case "hex":
              return hexSlice(this, start, end);
            case "utf8":
            case "utf-8":
              return utf8Slice(this, start, end);
            case "ascii":
              return asciiSlice(this, start, end);
            case "latin1":
            case "binary":
              return latin1Slice(this, start, end);
            case "base64":
              return base64Slice(this, start, end);
            case "ucs2":
            case "ucs-2":
            case "utf16le":
            case "utf-16le":
              return utf16leSlice(this, start, end);
            default:
              if (loweredCase) throw new TypeError("Unknown encoding: " + encoding);
              encoding = (encoding + "").toLowerCase();
              loweredCase = true;
          }
        }
      }
      Buffer3.prototype._isBuffer = true;
      function swap(b, n, m) {
        const i = b[n];
        b[n] = b[m];
        b[m] = i;
      }
      Buffer3.prototype.swap16 = function swap16() {
        const len = this.length;
        if (len % 2 !== 0) {
          throw new RangeError("Buffer size must be a multiple of 16-bits");
        }
        for (let i = 0; i < len; i += 2) {
          swap(this, i, i + 1);
        }
        return this;
      };
      Buffer3.prototype.swap32 = function swap32() {
        const len = this.length;
        if (len % 4 !== 0) {
          throw new RangeError("Buffer size must be a multiple of 32-bits");
        }
        for (let i = 0; i < len; i += 4) {
          swap(this, i, i + 3);
          swap(this, i + 1, i + 2);
        }
        return this;
      };
      Buffer3.prototype.swap64 = function swap64() {
        const len = this.length;
        if (len % 8 !== 0) {
          throw new RangeError("Buffer size must be a multiple of 64-bits");
        }
        for (let i = 0; i < len; i += 8) {
          swap(this, i, i + 7);
          swap(this, i + 1, i + 6);
          swap(this, i + 2, i + 5);
          swap(this, i + 3, i + 4);
        }
        return this;
      };
      Buffer3.prototype.toString = function toString() {
        const length = this.length;
        if (length === 0) return "";
        if (arguments.length === 0) return utf8Slice(this, 0, length);
        return slowToString.apply(this, arguments);
      };
      Buffer3.prototype.toLocaleString = Buffer3.prototype.toString;
      Buffer3.prototype.equals = function equals(b) {
        if (!Buffer3.isBuffer(b)) throw new TypeError("Argument must be a Buffer");
        if (this === b) return true;
        return Buffer3.compare(this, b) === 0;
      };
      Buffer3.prototype.inspect = function inspect() {
        let str = "";
        const max = exports.INSPECT_MAX_BYTES;
        str = this.toString("hex", 0, max).replace(/(.{2})/g, "$1 ").trim();
        if (this.length > max) str += " ... ";
        return "<Buffer " + str + ">";
      };
      if (customInspectSymbol) {
        Buffer3.prototype[customInspectSymbol] = Buffer3.prototype.inspect;
      }
      Buffer3.prototype.compare = function compare3(target, start, end, thisStart, thisEnd) {
        if (isInstance(target, Uint8Array)) {
          target = Buffer3.from(target, target.offset, target.byteLength);
        }
        if (!Buffer3.isBuffer(target)) {
          throw new TypeError(
            'The "target" argument must be one of type Buffer or Uint8Array. Received type ' + typeof target
          );
        }
        if (start === void 0) {
          start = 0;
        }
        if (end === void 0) {
          end = target ? target.length : 0;
        }
        if (thisStart === void 0) {
          thisStart = 0;
        }
        if (thisEnd === void 0) {
          thisEnd = this.length;
        }
        if (start < 0 || end > target.length || thisStart < 0 || thisEnd > this.length) {
          throw new RangeError("out of range index");
        }
        if (thisStart >= thisEnd && start >= end) {
          return 0;
        }
        if (thisStart >= thisEnd) {
          return -1;
        }
        if (start >= end) {
          return 1;
        }
        start >>>= 0;
        end >>>= 0;
        thisStart >>>= 0;
        thisEnd >>>= 0;
        if (this === target) return 0;
        let x = thisEnd - thisStart;
        let y = end - start;
        const len = Math.min(x, y);
        const thisCopy = this.slice(thisStart, thisEnd);
        const targetCopy = target.slice(start, end);
        for (let i = 0; i < len; ++i) {
          if (thisCopy[i] !== targetCopy[i]) {
            x = thisCopy[i];
            y = targetCopy[i];
            break;
          }
        }
        if (x < y) return -1;
        if (y < x) return 1;
        return 0;
      };
      function bidirectionalIndexOf(buffer, val, byteOffset, encoding, dir) {
        if (buffer.length === 0) return -1;
        if (typeof byteOffset === "string") {
          encoding = byteOffset;
          byteOffset = 0;
        } else if (byteOffset > 2147483647) {
          byteOffset = 2147483647;
        } else if (byteOffset < -2147483648) {
          byteOffset = -2147483648;
        }
        byteOffset = +byteOffset;
        if (numberIsNaN(byteOffset)) {
          byteOffset = dir ? 0 : buffer.length - 1;
        }
        if (byteOffset < 0) byteOffset = buffer.length + byteOffset;
        if (byteOffset >= buffer.length) {
          if (dir) return -1;
          else byteOffset = buffer.length - 1;
        } else if (byteOffset < 0) {
          if (dir) byteOffset = 0;
          else return -1;
        }
        if (typeof val === "string") {
          val = Buffer3.from(val, encoding);
        }
        if (Buffer3.isBuffer(val)) {
          if (val.length === 0) {
            return -1;
          }
          return arrayIndexOf(buffer, val, byteOffset, encoding, dir);
        } else if (typeof val === "number") {
          val = val & 255;
          if (typeof Uint8Array.prototype.indexOf === "function") {
            if (dir) {
              return Uint8Array.prototype.indexOf.call(buffer, val, byteOffset);
            } else {
              return Uint8Array.prototype.lastIndexOf.call(buffer, val, byteOffset);
            }
          }
          return arrayIndexOf(buffer, [val], byteOffset, encoding, dir);
        }
        throw new TypeError("val must be string, number or Buffer");
      }
      function arrayIndexOf(arr, val, byteOffset, encoding, dir) {
        let indexSize = 1;
        let arrLength = arr.length;
        let valLength = val.length;
        if (encoding !== void 0) {
          encoding = String(encoding).toLowerCase();
          if (encoding === "ucs2" || encoding === "ucs-2" || encoding === "utf16le" || encoding === "utf-16le") {
            if (arr.length < 2 || val.length < 2) {
              return -1;
            }
            indexSize = 2;
            arrLength /= 2;
            valLength /= 2;
            byteOffset /= 2;
          }
        }
        function read(buf, i2) {
          if (indexSize === 1) {
            return buf[i2];
          } else {
            return buf.readUInt16BE(i2 * indexSize);
          }
        }
        let i;
        if (dir) {
          let foundIndex = -1;
          for (i = byteOffset; i < arrLength; i++) {
            if (read(arr, i) === read(val, foundIndex === -1 ? 0 : i - foundIndex)) {
              if (foundIndex === -1) foundIndex = i;
              if (i - foundIndex + 1 === valLength) return foundIndex * indexSize;
            } else {
              if (foundIndex !== -1) i -= i - foundIndex;
              foundIndex = -1;
            }
          }
        } else {
          if (byteOffset + valLength > arrLength) byteOffset = arrLength - valLength;
          for (i = byteOffset; i >= 0; i--) {
            let found = true;
            for (let j = 0; j < valLength; j++) {
              if (read(arr, i + j) !== read(val, j)) {
                found = false;
                break;
              }
            }
            if (found) return i;
          }
        }
        return -1;
      }
      Buffer3.prototype.includes = function includes(val, byteOffset, encoding) {
        return this.indexOf(val, byteOffset, encoding) !== -1;
      };
      Buffer3.prototype.indexOf = function indexOf(val, byteOffset, encoding) {
        return bidirectionalIndexOf(this, val, byteOffset, encoding, true);
      };
      Buffer3.prototype.lastIndexOf = function lastIndexOf(val, byteOffset, encoding) {
        return bidirectionalIndexOf(this, val, byteOffset, encoding, false);
      };
      function hexWrite(buf, string4, offset, length) {
        offset = Number(offset) || 0;
        const remaining = buf.length - offset;
        if (!length) {
          length = remaining;
        } else {
          length = Number(length);
          if (length > remaining) {
            length = remaining;
          }
        }
        const strLen = string4.length;
        if (length > strLen / 2) {
          length = strLen / 2;
        }
        let i;
        for (i = 0; i < length; ++i) {
          const parsed = parseInt(string4.substr(i * 2, 2), 16);
          if (numberIsNaN(parsed)) return i;
          buf[offset + i] = parsed;
        }
        return i;
      }
      function utf8Write(buf, string4, offset, length) {
        return blitBuffer(utf8ToBytes(string4, buf.length - offset), buf, offset, length);
      }
      function asciiWrite(buf, string4, offset, length) {
        return blitBuffer(asciiToBytes(string4), buf, offset, length);
      }
      function base64Write(buf, string4, offset, length) {
        return blitBuffer(base64ToBytes(string4), buf, offset, length);
      }
      function ucs2Write(buf, string4, offset, length) {
        return blitBuffer(utf16leToBytes(string4, buf.length - offset), buf, offset, length);
      }
      Buffer3.prototype.write = function write(string4, offset, length, encoding) {
        if (offset === void 0) {
          encoding = "utf8";
          length = this.length;
          offset = 0;
        } else if (length === void 0 && typeof offset === "string") {
          encoding = offset;
          length = this.length;
          offset = 0;
        } else if (isFinite(offset)) {
          offset = offset >>> 0;
          if (isFinite(length)) {
            length = length >>> 0;
            if (encoding === void 0) encoding = "utf8";
          } else {
            encoding = length;
            length = void 0;
          }
        } else {
          throw new Error(
            "Buffer.write(string, encoding, offset[, length]) is no longer supported"
          );
        }
        const remaining = this.length - offset;
        if (length === void 0 || length > remaining) length = remaining;
        if (string4.length > 0 && (length < 0 || offset < 0) || offset > this.length) {
          throw new RangeError("Attempt to write outside buffer bounds");
        }
        if (!encoding) encoding = "utf8";
        let loweredCase = false;
        for (; ; ) {
          switch (encoding) {
            case "hex":
              return hexWrite(this, string4, offset, length);
            case "utf8":
            case "utf-8":
              return utf8Write(this, string4, offset, length);
            case "ascii":
            case "latin1":
            case "binary":
              return asciiWrite(this, string4, offset, length);
            case "base64":
              return base64Write(this, string4, offset, length);
            case "ucs2":
            case "ucs-2":
            case "utf16le":
            case "utf-16le":
              return ucs2Write(this, string4, offset, length);
            default:
              if (loweredCase) throw new TypeError("Unknown encoding: " + encoding);
              encoding = ("" + encoding).toLowerCase();
              loweredCase = true;
          }
        }
      };
      Buffer3.prototype.toJSON = function toJSON() {
        return {
          type: "Buffer",
          data: Array.prototype.slice.call(this._arr || this, 0)
        };
      };
      function base64Slice(buf, start, end) {
        if (start === 0 && end === buf.length) {
          return base643.fromByteArray(buf);
        } else {
          return base643.fromByteArray(buf.slice(start, end));
        }
      }
      function utf8Slice(buf, start, end) {
        end = Math.min(buf.length, end);
        const res = [];
        let i = start;
        while (i < end) {
          const firstByte = buf[i];
          let codePoint = null;
          let bytesPerSequence = firstByte > 239 ? 4 : firstByte > 223 ? 3 : firstByte > 191 ? 2 : 1;
          if (i + bytesPerSequence <= end) {
            let secondByte, thirdByte, fourthByte, tempCodePoint;
            switch (bytesPerSequence) {
              case 1:
                if (firstByte < 128) {
                  codePoint = firstByte;
                }
                break;
              case 2:
                secondByte = buf[i + 1];
                if ((secondByte & 192) === 128) {
                  tempCodePoint = (firstByte & 31) << 6 | secondByte & 63;
                  if (tempCodePoint > 127) {
                    codePoint = tempCodePoint;
                  }
                }
                break;
              case 3:
                secondByte = buf[i + 1];
                thirdByte = buf[i + 2];
                if ((secondByte & 192) === 128 && (thirdByte & 192) === 128) {
                  tempCodePoint = (firstByte & 15) << 12 | (secondByte & 63) << 6 | thirdByte & 63;
                  if (tempCodePoint > 2047 && (tempCodePoint < 55296 || tempCodePoint > 57343)) {
                    codePoint = tempCodePoint;
                  }
                }
                break;
              case 4:
                secondByte = buf[i + 1];
                thirdByte = buf[i + 2];
                fourthByte = buf[i + 3];
                if ((secondByte & 192) === 128 && (thirdByte & 192) === 128 && (fourthByte & 192) === 128) {
                  tempCodePoint = (firstByte & 15) << 18 | (secondByte & 63) << 12 | (thirdByte & 63) << 6 | fourthByte & 63;
                  if (tempCodePoint > 65535 && tempCodePoint < 1114112) {
                    codePoint = tempCodePoint;
                  }
                }
            }
          }
          if (codePoint === null) {
            codePoint = 65533;
            bytesPerSequence = 1;
          } else if (codePoint > 65535) {
            codePoint -= 65536;
            res.push(codePoint >>> 10 & 1023 | 55296);
            codePoint = 56320 | codePoint & 1023;
          }
          res.push(codePoint);
          i += bytesPerSequence;
        }
        return decodeCodePointsArray(res);
      }
      var MAX_ARGUMENTS_LENGTH = 4096;
      function decodeCodePointsArray(codePoints) {
        const len = codePoints.length;
        if (len <= MAX_ARGUMENTS_LENGTH) {
          return String.fromCharCode.apply(String, codePoints);
        }
        let res = "";
        let i = 0;
        while (i < len) {
          res += String.fromCharCode.apply(
            String,
            codePoints.slice(i, i += MAX_ARGUMENTS_LENGTH)
          );
        }
        return res;
      }
      function asciiSlice(buf, start, end) {
        let ret = "";
        end = Math.min(buf.length, end);
        for (let i = start; i < end; ++i) {
          ret += String.fromCharCode(buf[i] & 127);
        }
        return ret;
      }
      function latin1Slice(buf, start, end) {
        let ret = "";
        end = Math.min(buf.length, end);
        for (let i = start; i < end; ++i) {
          ret += String.fromCharCode(buf[i]);
        }
        return ret;
      }
      function hexSlice(buf, start, end) {
        const len = buf.length;
        if (!start || start < 0) start = 0;
        if (!end || end < 0 || end > len) end = len;
        let out = "";
        for (let i = start; i < end; ++i) {
          out += hexSliceLookupTable[buf[i]];
        }
        return out;
      }
      function utf16leSlice(buf, start, end) {
        const bytes = buf.slice(start, end);
        let res = "";
        for (let i = 0; i < bytes.length - 1; i += 2) {
          res += String.fromCharCode(bytes[i] + bytes[i + 1] * 256);
        }
        return res;
      }
      Buffer3.prototype.slice = function slice(start, end) {
        const len = this.length;
        start = ~~start;
        end = end === void 0 ? len : ~~end;
        if (start < 0) {
          start += len;
          if (start < 0) start = 0;
        } else if (start > len) {
          start = len;
        }
        if (end < 0) {
          end += len;
          if (end < 0) end = 0;
        } else if (end > len) {
          end = len;
        }
        if (end < start) end = start;
        const newBuf = this.subarray(start, end);
        Object.setPrototypeOf(newBuf, Buffer3.prototype);
        return newBuf;
      };
      function checkOffset(offset, ext, length) {
        if (offset % 1 !== 0 || offset < 0) throw new RangeError("offset is not uint");
        if (offset + ext > length) throw new RangeError("Trying to access beyond buffer length");
      }
      Buffer3.prototype.readUintLE = Buffer3.prototype.readUIntLE = function readUIntLE(offset, byteLength2, noAssert) {
        offset = offset >>> 0;
        byteLength2 = byteLength2 >>> 0;
        if (!noAssert) checkOffset(offset, byteLength2, this.length);
        let val = this[offset];
        let mul = 1;
        let i = 0;
        while (++i < byteLength2 && (mul *= 256)) {
          val += this[offset + i] * mul;
        }
        return val;
      };
      Buffer3.prototype.readUintBE = Buffer3.prototype.readUIntBE = function readUIntBE(offset, byteLength2, noAssert) {
        offset = offset >>> 0;
        byteLength2 = byteLength2 >>> 0;
        if (!noAssert) {
          checkOffset(offset, byteLength2, this.length);
        }
        let val = this[offset + --byteLength2];
        let mul = 1;
        while (byteLength2 > 0 && (mul *= 256)) {
          val += this[offset + --byteLength2] * mul;
        }
        return val;
      };
      Buffer3.prototype.readUint8 = Buffer3.prototype.readUInt8 = function readUInt8(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 1, this.length);
        return this[offset];
      };
      Buffer3.prototype.readUint16LE = Buffer3.prototype.readUInt16LE = function readUInt16LE(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 2, this.length);
        return this[offset] | this[offset + 1] << 8;
      };
      Buffer3.prototype.readUint16BE = Buffer3.prototype.readUInt16BE = function readUInt16BE(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 2, this.length);
        return this[offset] << 8 | this[offset + 1];
      };
      Buffer3.prototype.readUint32LE = Buffer3.prototype.readUInt32LE = function readUInt32LE(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 4, this.length);
        return (this[offset] | this[offset + 1] << 8 | this[offset + 2] << 16) + this[offset + 3] * 16777216;
      };
      Buffer3.prototype.readUint32BE = Buffer3.prototype.readUInt32BE = function readUInt32BE(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 4, this.length);
        return this[offset] * 16777216 + (this[offset + 1] << 16 | this[offset + 2] << 8 | this[offset + 3]);
      };
      Buffer3.prototype.readBigUInt64LE = defineBigIntMethod(function readBigUInt64LE(offset) {
        offset = offset >>> 0;
        validateNumber(offset, "offset");
        const first = this[offset];
        const last = this[offset + 7];
        if (first === void 0 || last === void 0) {
          boundsError(offset, this.length - 8);
        }
        const lo = first + this[++offset] * 2 ** 8 + this[++offset] * 2 ** 16 + this[++offset] * 2 ** 24;
        const hi = this[++offset] + this[++offset] * 2 ** 8 + this[++offset] * 2 ** 16 + last * 2 ** 24;
        return BigInt(lo) + (BigInt(hi) << BigInt(32));
      });
      Buffer3.prototype.readBigUInt64BE = defineBigIntMethod(function readBigUInt64BE(offset) {
        offset = offset >>> 0;
        validateNumber(offset, "offset");
        const first = this[offset];
        const last = this[offset + 7];
        if (first === void 0 || last === void 0) {
          boundsError(offset, this.length - 8);
        }
        const hi = first * 2 ** 24 + this[++offset] * 2 ** 16 + this[++offset] * 2 ** 8 + this[++offset];
        const lo = this[++offset] * 2 ** 24 + this[++offset] * 2 ** 16 + this[++offset] * 2 ** 8 + last;
        return (BigInt(hi) << BigInt(32)) + BigInt(lo);
      });
      Buffer3.prototype.readIntLE = function readIntLE(offset, byteLength2, noAssert) {
        offset = offset >>> 0;
        byteLength2 = byteLength2 >>> 0;
        if (!noAssert) checkOffset(offset, byteLength2, this.length);
        let val = this[offset];
        let mul = 1;
        let i = 0;
        while (++i < byteLength2 && (mul *= 256)) {
          val += this[offset + i] * mul;
        }
        mul *= 128;
        if (val >= mul) val -= Math.pow(2, 8 * byteLength2);
        return val;
      };
      Buffer3.prototype.readIntBE = function readIntBE(offset, byteLength2, noAssert) {
        offset = offset >>> 0;
        byteLength2 = byteLength2 >>> 0;
        if (!noAssert) checkOffset(offset, byteLength2, this.length);
        let i = byteLength2;
        let mul = 1;
        let val = this[offset + --i];
        while (i > 0 && (mul *= 256)) {
          val += this[offset + --i] * mul;
        }
        mul *= 128;
        if (val >= mul) val -= Math.pow(2, 8 * byteLength2);
        return val;
      };
      Buffer3.prototype.readInt8 = function readInt8(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 1, this.length);
        if (!(this[offset] & 128)) return this[offset];
        return (255 - this[offset] + 1) * -1;
      };
      Buffer3.prototype.readInt16LE = function readInt16LE(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 2, this.length);
        const val = this[offset] | this[offset + 1] << 8;
        return val & 32768 ? val | 4294901760 : val;
      };
      Buffer3.prototype.readInt16BE = function readInt16BE(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 2, this.length);
        const val = this[offset + 1] | this[offset] << 8;
        return val & 32768 ? val | 4294901760 : val;
      };
      Buffer3.prototype.readInt32LE = function readInt32LE(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 4, this.length);
        return this[offset] | this[offset + 1] << 8 | this[offset + 2] << 16 | this[offset + 3] << 24;
      };
      Buffer3.prototype.readInt32BE = function readInt32BE(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 4, this.length);
        return this[offset] << 24 | this[offset + 1] << 16 | this[offset + 2] << 8 | this[offset + 3];
      };
      Buffer3.prototype.readBigInt64LE = defineBigIntMethod(function readBigInt64LE(offset) {
        offset = offset >>> 0;
        validateNumber(offset, "offset");
        const first = this[offset];
        const last = this[offset + 7];
        if (first === void 0 || last === void 0) {
          boundsError(offset, this.length - 8);
        }
        const val = this[offset + 4] + this[offset + 5] * 2 ** 8 + this[offset + 6] * 2 ** 16 + (last << 24);
        return (BigInt(val) << BigInt(32)) + BigInt(first + this[++offset] * 2 ** 8 + this[++offset] * 2 ** 16 + this[++offset] * 2 ** 24);
      });
      Buffer3.prototype.readBigInt64BE = defineBigIntMethod(function readBigInt64BE(offset) {
        offset = offset >>> 0;
        validateNumber(offset, "offset");
        const first = this[offset];
        const last = this[offset + 7];
        if (first === void 0 || last === void 0) {
          boundsError(offset, this.length - 8);
        }
        const val = (first << 24) + // Overflow
        this[++offset] * 2 ** 16 + this[++offset] * 2 ** 8 + this[++offset];
        return (BigInt(val) << BigInt(32)) + BigInt(this[++offset] * 2 ** 24 + this[++offset] * 2 ** 16 + this[++offset] * 2 ** 8 + last);
      });
      Buffer3.prototype.readFloatLE = function readFloatLE(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 4, this.length);
        return ieee754.read(this, offset, true, 23, 4);
      };
      Buffer3.prototype.readFloatBE = function readFloatBE(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 4, this.length);
        return ieee754.read(this, offset, false, 23, 4);
      };
      Buffer3.prototype.readDoubleLE = function readDoubleLE(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 8, this.length);
        return ieee754.read(this, offset, true, 52, 8);
      };
      Buffer3.prototype.readDoubleBE = function readDoubleBE(offset, noAssert) {
        offset = offset >>> 0;
        if (!noAssert) checkOffset(offset, 8, this.length);
        return ieee754.read(this, offset, false, 52, 8);
      };
      function checkInt(buf, value, offset, ext, max, min) {
        if (!Buffer3.isBuffer(buf)) throw new TypeError('"buffer" argument must be a Buffer instance');
        if (value > max || value < min) throw new RangeError('"value" argument is out of bounds');
        if (offset + ext > buf.length) throw new RangeError("Index out of range");
      }
      Buffer3.prototype.writeUintLE = Buffer3.prototype.writeUIntLE = function writeUIntLE(value, offset, byteLength2, noAssert) {
        value = +value;
        offset = offset >>> 0;
        byteLength2 = byteLength2 >>> 0;
        if (!noAssert) {
          const maxBytes = Math.pow(2, 8 * byteLength2) - 1;
          checkInt(this, value, offset, byteLength2, maxBytes, 0);
        }
        let mul = 1;
        let i = 0;
        this[offset] = value & 255;
        while (++i < byteLength2 && (mul *= 256)) {
          this[offset + i] = value / mul & 255;
        }
        return offset + byteLength2;
      };
      Buffer3.prototype.writeUintBE = Buffer3.prototype.writeUIntBE = function writeUIntBE(value, offset, byteLength2, noAssert) {
        value = +value;
        offset = offset >>> 0;
        byteLength2 = byteLength2 >>> 0;
        if (!noAssert) {
          const maxBytes = Math.pow(2, 8 * byteLength2) - 1;
          checkInt(this, value, offset, byteLength2, maxBytes, 0);
        }
        let i = byteLength2 - 1;
        let mul = 1;
        this[offset + i] = value & 255;
        while (--i >= 0 && (mul *= 256)) {
          this[offset + i] = value / mul & 255;
        }
        return offset + byteLength2;
      };
      Buffer3.prototype.writeUint8 = Buffer3.prototype.writeUInt8 = function writeUInt8(value, offset, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) checkInt(this, value, offset, 1, 255, 0);
        this[offset] = value & 255;
        return offset + 1;
      };
      Buffer3.prototype.writeUint16LE = Buffer3.prototype.writeUInt16LE = function writeUInt16LE(value, offset, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) checkInt(this, value, offset, 2, 65535, 0);
        this[offset] = value & 255;
        this[offset + 1] = value >>> 8;
        return offset + 2;
      };
      Buffer3.prototype.writeUint16BE = Buffer3.prototype.writeUInt16BE = function writeUInt16BE(value, offset, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) checkInt(this, value, offset, 2, 65535, 0);
        this[offset] = value >>> 8;
        this[offset + 1] = value & 255;
        return offset + 2;
      };
      Buffer3.prototype.writeUint32LE = Buffer3.prototype.writeUInt32LE = function writeUInt32LE(value, offset, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) checkInt(this, value, offset, 4, 4294967295, 0);
        this[offset + 3] = value >>> 24;
        this[offset + 2] = value >>> 16;
        this[offset + 1] = value >>> 8;
        this[offset] = value & 255;
        return offset + 4;
      };
      Buffer3.prototype.writeUint32BE = Buffer3.prototype.writeUInt32BE = function writeUInt32BE(value, offset, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) checkInt(this, value, offset, 4, 4294967295, 0);
        this[offset] = value >>> 24;
        this[offset + 1] = value >>> 16;
        this[offset + 2] = value >>> 8;
        this[offset + 3] = value & 255;
        return offset + 4;
      };
      function wrtBigUInt64LE(buf, value, offset, min, max) {
        checkIntBI(value, min, max, buf, offset, 7);
        let lo = Number(value & BigInt(4294967295));
        buf[offset++] = lo;
        lo = lo >> 8;
        buf[offset++] = lo;
        lo = lo >> 8;
        buf[offset++] = lo;
        lo = lo >> 8;
        buf[offset++] = lo;
        let hi = Number(value >> BigInt(32) & BigInt(4294967295));
        buf[offset++] = hi;
        hi = hi >> 8;
        buf[offset++] = hi;
        hi = hi >> 8;
        buf[offset++] = hi;
        hi = hi >> 8;
        buf[offset++] = hi;
        return offset;
      }
      function wrtBigUInt64BE(buf, value, offset, min, max) {
        checkIntBI(value, min, max, buf, offset, 7);
        let lo = Number(value & BigInt(4294967295));
        buf[offset + 7] = lo;
        lo = lo >> 8;
        buf[offset + 6] = lo;
        lo = lo >> 8;
        buf[offset + 5] = lo;
        lo = lo >> 8;
        buf[offset + 4] = lo;
        let hi = Number(value >> BigInt(32) & BigInt(4294967295));
        buf[offset + 3] = hi;
        hi = hi >> 8;
        buf[offset + 2] = hi;
        hi = hi >> 8;
        buf[offset + 1] = hi;
        hi = hi >> 8;
        buf[offset] = hi;
        return offset + 8;
      }
      Buffer3.prototype.writeBigUInt64LE = defineBigIntMethod(function writeBigUInt64LE(value, offset = 0) {
        return wrtBigUInt64LE(this, value, offset, BigInt(0), BigInt("0xffffffffffffffff"));
      });
      Buffer3.prototype.writeBigUInt64BE = defineBigIntMethod(function writeBigUInt64BE(value, offset = 0) {
        return wrtBigUInt64BE(this, value, offset, BigInt(0), BigInt("0xffffffffffffffff"));
      });
      Buffer3.prototype.writeIntLE = function writeIntLE(value, offset, byteLength2, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) {
          const limit = Math.pow(2, 8 * byteLength2 - 1);
          checkInt(this, value, offset, byteLength2, limit - 1, -limit);
        }
        let i = 0;
        let mul = 1;
        let sub = 0;
        this[offset] = value & 255;
        while (++i < byteLength2 && (mul *= 256)) {
          if (value < 0 && sub === 0 && this[offset + i - 1] !== 0) {
            sub = 1;
          }
          this[offset + i] = (value / mul >> 0) - sub & 255;
        }
        return offset + byteLength2;
      };
      Buffer3.prototype.writeIntBE = function writeIntBE(value, offset, byteLength2, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) {
          const limit = Math.pow(2, 8 * byteLength2 - 1);
          checkInt(this, value, offset, byteLength2, limit - 1, -limit);
        }
        let i = byteLength2 - 1;
        let mul = 1;
        let sub = 0;
        this[offset + i] = value & 255;
        while (--i >= 0 && (mul *= 256)) {
          if (value < 0 && sub === 0 && this[offset + i + 1] !== 0) {
            sub = 1;
          }
          this[offset + i] = (value / mul >> 0) - sub & 255;
        }
        return offset + byteLength2;
      };
      Buffer3.prototype.writeInt8 = function writeInt8(value, offset, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) checkInt(this, value, offset, 1, 127, -128);
        if (value < 0) value = 255 + value + 1;
        this[offset] = value & 255;
        return offset + 1;
      };
      Buffer3.prototype.writeInt16LE = function writeInt16LE(value, offset, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) checkInt(this, value, offset, 2, 32767, -32768);
        this[offset] = value & 255;
        this[offset + 1] = value >>> 8;
        return offset + 2;
      };
      Buffer3.prototype.writeInt16BE = function writeInt16BE(value, offset, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) checkInt(this, value, offset, 2, 32767, -32768);
        this[offset] = value >>> 8;
        this[offset + 1] = value & 255;
        return offset + 2;
      };
      Buffer3.prototype.writeInt32LE = function writeInt32LE(value, offset, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) checkInt(this, value, offset, 4, 2147483647, -2147483648);
        this[offset] = value & 255;
        this[offset + 1] = value >>> 8;
        this[offset + 2] = value >>> 16;
        this[offset + 3] = value >>> 24;
        return offset + 4;
      };
      Buffer3.prototype.writeInt32BE = function writeInt32BE(value, offset, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) checkInt(this, value, offset, 4, 2147483647, -2147483648);
        if (value < 0) value = 4294967295 + value + 1;
        this[offset] = value >>> 24;
        this[offset + 1] = value >>> 16;
        this[offset + 2] = value >>> 8;
        this[offset + 3] = value & 255;
        return offset + 4;
      };
      Buffer3.prototype.writeBigInt64LE = defineBigIntMethod(function writeBigInt64LE(value, offset = 0) {
        return wrtBigUInt64LE(this, value, offset, -BigInt("0x8000000000000000"), BigInt("0x7fffffffffffffff"));
      });
      Buffer3.prototype.writeBigInt64BE = defineBigIntMethod(function writeBigInt64BE(value, offset = 0) {
        return wrtBigUInt64BE(this, value, offset, -BigInt("0x8000000000000000"), BigInt("0x7fffffffffffffff"));
      });
      function checkIEEE754(buf, value, offset, ext, max, min) {
        if (offset + ext > buf.length) throw new RangeError("Index out of range");
        if (offset < 0) throw new RangeError("Index out of range");
      }
      function writeFloat(buf, value, offset, littleEndian, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) {
          checkIEEE754(buf, value, offset, 4, 34028234663852886e22, -34028234663852886e22);
        }
        ieee754.write(buf, value, offset, littleEndian, 23, 4);
        return offset + 4;
      }
      Buffer3.prototype.writeFloatLE = function writeFloatLE(value, offset, noAssert) {
        return writeFloat(this, value, offset, true, noAssert);
      };
      Buffer3.prototype.writeFloatBE = function writeFloatBE(value, offset, noAssert) {
        return writeFloat(this, value, offset, false, noAssert);
      };
      function writeDouble(buf, value, offset, littleEndian, noAssert) {
        value = +value;
        offset = offset >>> 0;
        if (!noAssert) {
          checkIEEE754(buf, value, offset, 8, 17976931348623157e292, -17976931348623157e292);
        }
        ieee754.write(buf, value, offset, littleEndian, 52, 8);
        return offset + 8;
      }
      Buffer3.prototype.writeDoubleLE = function writeDoubleLE(value, offset, noAssert) {
        return writeDouble(this, value, offset, true, noAssert);
      };
      Buffer3.prototype.writeDoubleBE = function writeDoubleBE(value, offset, noAssert) {
        return writeDouble(this, value, offset, false, noAssert);
      };
      Buffer3.prototype.copy = function copy(target, targetStart, start, end) {
        if (!Buffer3.isBuffer(target)) throw new TypeError("argument should be a Buffer");
        if (!start) start = 0;
        if (!end && end !== 0) end = this.length;
        if (targetStart >= target.length) targetStart = target.length;
        if (!targetStart) targetStart = 0;
        if (end > 0 && end < start) end = start;
        if (end === start) return 0;
        if (target.length === 0 || this.length === 0) return 0;
        if (targetStart < 0) {
          throw new RangeError("targetStart out of bounds");
        }
        if (start < 0 || start >= this.length) throw new RangeError("Index out of range");
        if (end < 0) throw new RangeError("sourceEnd out of bounds");
        if (end > this.length) end = this.length;
        if (target.length - targetStart < end - start) {
          end = target.length - targetStart + start;
        }
        const len = end - start;
        if (this === target && typeof Uint8Array.prototype.copyWithin === "function") {
          this.copyWithin(targetStart, start, end);
        } else {
          Uint8Array.prototype.set.call(
            target,
            this.subarray(start, end),
            targetStart
          );
        }
        return len;
      };
      Buffer3.prototype.fill = function fill(val, start, end, encoding) {
        if (typeof val === "string") {
          if (typeof start === "string") {
            encoding = start;
            start = 0;
            end = this.length;
          } else if (typeof end === "string") {
            encoding = end;
            end = this.length;
          }
          if (encoding !== void 0 && typeof encoding !== "string") {
            throw new TypeError("encoding must be a string");
          }
          if (typeof encoding === "string" && !Buffer3.isEncoding(encoding)) {
            throw new TypeError("Unknown encoding: " + encoding);
          }
          if (val.length === 1) {
            const code = val.charCodeAt(0);
            if (encoding === "utf8" && code < 128 || encoding === "latin1") {
              val = code;
            }
          }
        } else if (typeof val === "number") {
          val = val & 255;
        } else if (typeof val === "boolean") {
          val = Number(val);
        }
        if (start < 0 || this.length < start || this.length < end) {
          throw new RangeError("Out of range index");
        }
        if (end <= start) {
          return this;
        }
        start = start >>> 0;
        end = end === void 0 ? this.length : end >>> 0;
        if (!val) val = 0;
        let i;
        if (typeof val === "number") {
          for (i = start; i < end; ++i) {
            this[i] = val;
          }
        } else {
          const bytes = Buffer3.isBuffer(val) ? val : Buffer3.from(val, encoding);
          const len = bytes.length;
          if (len === 0) {
            throw new TypeError('The value "' + val + '" is invalid for argument "value"');
          }
          for (i = 0; i < end - start; ++i) {
            this[i + start] = bytes[i % len];
          }
        }
        return this;
      };
      var errors = {};
      function E(sym, getMessage, Base) {
        errors[sym] = class NodeError extends Base {
          constructor() {
            super();
            Object.defineProperty(this, "message", {
              value: getMessage.apply(this, arguments),
              writable: true,
              configurable: true
            });
            this.name = `${this.name} [${sym}]`;
            this.stack;
            delete this.name;
          }
          get code() {
            return sym;
          }
          set code(value) {
            Object.defineProperty(this, "code", {
              configurable: true,
              enumerable: true,
              value,
              writable: true
            });
          }
          toString() {
            return `${this.name} [${sym}]: ${this.message}`;
          }
        };
      }
      E(
        "ERR_BUFFER_OUT_OF_BOUNDS",
        function(name) {
          if (name) {
            return `${name} is outside of buffer bounds`;
          }
          return "Attempt to access memory outside buffer bounds";
        },
        RangeError
      );
      E(
        "ERR_INVALID_ARG_TYPE",
        function(name, actual) {
          return `The "${name}" argument must be of type number. Received type ${typeof actual}`;
        },
        TypeError
      );
      E(
        "ERR_OUT_OF_RANGE",
        function(str, range, input) {
          let msg = `The value of "${str}" is out of range.`;
          let received = input;
          if (Number.isInteger(input) && Math.abs(input) > 2 ** 32) {
            received = addNumericalSeparator(String(input));
          } else if (typeof input === "bigint") {
            received = String(input);
            if (input > BigInt(2) ** BigInt(32) || input < -(BigInt(2) ** BigInt(32))) {
              received = addNumericalSeparator(received);
            }
            received += "n";
          }
          msg += ` It must be ${range}. Received ${received}`;
          return msg;
        },
        RangeError
      );
      function addNumericalSeparator(val) {
        let res = "";
        let i = val.length;
        const start = val[0] === "-" ? 1 : 0;
        for (; i >= start + 4; i -= 3) {
          res = `_${val.slice(i - 3, i)}${res}`;
        }
        return `${val.slice(0, i)}${res}`;
      }
      function checkBounds(buf, offset, byteLength2) {
        validateNumber(offset, "offset");
        if (buf[offset] === void 0 || buf[offset + byteLength2] === void 0) {
          boundsError(offset, buf.length - (byteLength2 + 1));
        }
      }
      function checkIntBI(value, min, max, buf, offset, byteLength2) {
        if (value > max || value < min) {
          const n = typeof min === "bigint" ? "n" : "";
          let range;
          if (byteLength2 > 3) {
            if (min === 0 || min === BigInt(0)) {
              range = `>= 0${n} and < 2${n} ** ${(byteLength2 + 1) * 8}${n}`;
            } else {
              range = `>= -(2${n} ** ${(byteLength2 + 1) * 8 - 1}${n}) and < 2 ** ${(byteLength2 + 1) * 8 - 1}${n}`;
            }
          } else {
            range = `>= ${min}${n} and <= ${max}${n}`;
          }
          throw new errors.ERR_OUT_OF_RANGE("value", range, value);
        }
        checkBounds(buf, offset, byteLength2);
      }
      function validateNumber(value, name) {
        if (typeof value !== "number") {
          throw new errors.ERR_INVALID_ARG_TYPE(name, "number", value);
        }
      }
      function boundsError(value, length, type) {
        if (Math.floor(value) !== value) {
          validateNumber(value, type);
          throw new errors.ERR_OUT_OF_RANGE(type || "offset", "an integer", value);
        }
        if (length < 0) {
          throw new errors.ERR_BUFFER_OUT_OF_BOUNDS();
        }
        throw new errors.ERR_OUT_OF_RANGE(
          type || "offset",
          `>= ${type ? 1 : 0} and <= ${length}`,
          value
        );
      }
      var INVALID_BASE64_RE = /[^+/0-9A-Za-z-_]/g;
      function base64clean(str) {
        str = str.split("=")[0];
        str = str.trim().replace(INVALID_BASE64_RE, "");
        if (str.length < 2) return "";
        while (str.length % 4 !== 0) {
          str = str + "=";
        }
        return str;
      }
      function utf8ToBytes(string4, units) {
        units = units || Infinity;
        let codePoint;
        const length = string4.length;
        let leadSurrogate = null;
        const bytes = [];
        for (let i = 0; i < length; ++i) {
          codePoint = string4.charCodeAt(i);
          if (codePoint > 55295 && codePoint < 57344) {
            if (!leadSurrogate) {
              if (codePoint > 56319) {
                if ((units -= 3) > -1) bytes.push(239, 191, 189);
                continue;
              } else if (i + 1 === length) {
                if ((units -= 3) > -1) bytes.push(239, 191, 189);
                continue;
              }
              leadSurrogate = codePoint;
              continue;
            }
            if (codePoint < 56320) {
              if ((units -= 3) > -1) bytes.push(239, 191, 189);
              leadSurrogate = codePoint;
              continue;
            }
            codePoint = (leadSurrogate - 55296 << 10 | codePoint - 56320) + 65536;
          } else if (leadSurrogate) {
            if ((units -= 3) > -1) bytes.push(239, 191, 189);
          }
          leadSurrogate = null;
          if (codePoint < 128) {
            if ((units -= 1) < 0) break;
            bytes.push(codePoint);
          } else if (codePoint < 2048) {
            if ((units -= 2) < 0) break;
            bytes.push(
              codePoint >> 6 | 192,
              codePoint & 63 | 128
            );
          } else if (codePoint < 65536) {
            if ((units -= 3) < 0) break;
            bytes.push(
              codePoint >> 12 | 224,
              codePoint >> 6 & 63 | 128,
              codePoint & 63 | 128
            );
          } else if (codePoint < 1114112) {
            if ((units -= 4) < 0) break;
            bytes.push(
              codePoint >> 18 | 240,
              codePoint >> 12 & 63 | 128,
              codePoint >> 6 & 63 | 128,
              codePoint & 63 | 128
            );
          } else {
            throw new Error("Invalid code point");
          }
        }
        return bytes;
      }
      function asciiToBytes(str) {
        const byteArray = [];
        for (let i = 0; i < str.length; ++i) {
          byteArray.push(str.charCodeAt(i) & 255);
        }
        return byteArray;
      }
      function utf16leToBytes(str, units) {
        let c, hi, lo;
        const byteArray = [];
        for (let i = 0; i < str.length; ++i) {
          if ((units -= 2) < 0) break;
          c = str.charCodeAt(i);
          hi = c >> 8;
          lo = c % 256;
          byteArray.push(lo);
          byteArray.push(hi);
        }
        return byteArray;
      }
      function base64ToBytes(str) {
        return base643.toByteArray(base64clean(str));
      }
      function blitBuffer(src, dst, offset, length) {
        let i;
        for (i = 0; i < length; ++i) {
          if (i + offset >= dst.length || i >= src.length) break;
          dst[i + offset] = src[i];
        }
        return i;
      }
      function isInstance(obj, type) {
        return obj instanceof type || obj != null && obj.constructor != null && obj.constructor.name != null && obj.constructor.name === type.name;
      }
      function numberIsNaN(obj) {
        return obj !== obj;
      }
      var hexSliceLookupTable = (function() {
        const alphabet = "0123456789abcdef";
        const table = new Array(256);
        for (let i = 0; i < 16; ++i) {
          const i16 = i * 16;
          for (let j = 0; j < 16; ++j) {
            table[i16 + j] = alphabet[i] + alphabet[j];
          }
        }
        return table;
      })();
      function defineBigIntMethod(fn) {
        return typeof BigInt === "undefined" ? BufferBigIntNotDefined : fn;
      }
      function BufferBigIntNotDefined() {
        throw new Error("BigInt not supported");
      }
    }
  });

  // ThirdParty/REA/adapters/runtime.ts
  function checkpoint() {
    const callback = globalThis.__macscopeCheckpoint;
    if (typeof callback === "function") callback();
  }
  function guardJSON(value) {
    const stack = [[value, 0]];
    let count = 0;
    while (stack.length) {
      const [item, depth] = stack.pop();
      if (++count > 5e5 || depth > 96) throw new Error("structural budget");
      if ((count & 255) === 0) checkpoint();
      if (typeof item === "number" && !Number.isSafeInteger(item) && Number.isInteger(item)) throw new Error("unsafe integer: use decimal/hex string");
      if (typeof item === "number" && !Number.isFinite(item)) throw new Error("nonfinite number");
      if (typeof item === "string") {
        for (let i = 0; i < item.length; i++) {
          const n = item.charCodeAt(i);
          if (n >= 55296 && n <= 56319) {
            const next = item.charCodeAt(++i);
            if (!(next >= 56320 && next <= 57343)) throw new Error("unpaired surrogate");
          } else if (n >= 56320 && n <= 57343) throw new Error("unpaired surrogate");
        }
      }
      if (item && typeof item === "object") {
        const children = Array.isArray(item) ? item : Object.entries(item).flatMap(([k, v]) => [k, v]);
        if (count + stack.length + children.length > 5e5) throw new Error("structural budget");
        for (const child of children) stack.push([child, depth + 1]);
      }
    }
  }
  function canonical(value) {
    if (value === null || typeof value !== "object") return JSON.stringify(value);
    if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
    return "{" + Object.keys(value).sort().filter((k) => value[k] !== void 0).map((k) => JSON.stringify(k) + ":" + canonical(value[k])).join(",") + "}";
  }
  function sha256UTF8(text) {
    guardJSON(text);
    const fn = globalThis.__macscopeSHA256;
    if (typeof fn !== "function") throw new Error("SHA256 host unavailable");
    const digest2 = fn(text);
    if (typeof digest2 !== "string" || !/^[a-f0-9]{64}$/.test(digest2)) throw new Error("invalid SHA256 host result");
    return digest2;
  }
  function sha256Base64(text) {
    if (import_buffer.Buffer.from(text, "base64").toString("base64") !== text) throw new Error("noncanonical base64");
    const fn = globalThis.__macscopeSHA256Base64;
    if (typeof fn !== "function") throw new Error("SHA256 host unavailable");
    const digest2 = fn(text);
    if (typeof digest2 !== "string" || !/^[a-f0-9]{64}$/.test(digest2)) throw new Error("invalid SHA256 host result");
    return digest2;
  }
  var import_buffer, TextDecoder;
  var init_runtime = __esm({
    "ThirdParty/REA/adapters/runtime.ts"() {
      import_buffer = __toESM(require_buffer(), 1);
      TextDecoder = class {
        constructor(encoding = "utf-8", _options = {}) {
          this.encoding = encoding;
        }
        encoding;
        decode(input) {
          const bytes = import_buffer.Buffer.from(input);
          let text;
          if (this.encoding === "utf-8") {
            text = bytes.toString("utf8");
            if (!import_buffer.Buffer.from(text, "utf8").equals(bytes)) throw new Error("invalid UTF-8");
          } else if (this.encoding === "utf-16le" || this.encoding === "utf-16be") {
            if (bytes.length % 2) throw new Error("invalid UTF-16");
            const normalized = import_buffer.Buffer.from(bytes);
            if (this.encoding === "utf-16be") normalized.swap16();
            text = normalized.toString("utf16le");
            for (let i = 0; i < text.length; i++) {
              const n = text.charCodeAt(i);
              if (n >= 55296 && n <= 56319) {
                const next = text.charCodeAt(++i);
                if (!(next >= 56320 && next <= 57343)) throw new Error("invalid UTF-16");
              } else if (n >= 56320 && n <= 57343) throw new Error("invalid UTF-16");
            }
          } else throw new Error("unsupported encoding");
          return text.charCodeAt(0) === 65279 ? text.slice(1) : text;
        }
      };
    }
  });

  // ThirdParty/REA/adapters/kernel.ts
  var kernel_exports = {};
  __export(kernel_exports, {
    analyze: () => analyze,
    implementationIdentity: () => implementationIdentity
  });
  init_runtime();
  init_runtime();

  // ThirdParty/REA/adapters/native.ts
  init_runtime();

  // ThirdParty/REA/dependencies/zod/index.js
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/classic/external.js
  var external_exports = {};
  __export(external_exports, {
    $brand: () => $brand,
    $input: () => $input,
    $output: () => $output,
    NEVER: () => NEVER,
    TimePrecision: () => TimePrecision,
    ZodAny: () => ZodAny,
    ZodArray: () => ZodArray,
    ZodBase64: () => ZodBase64,
    ZodBase64URL: () => ZodBase64URL,
    ZodBigInt: () => ZodBigInt,
    ZodBigIntFormat: () => ZodBigIntFormat,
    ZodBoolean: () => ZodBoolean,
    ZodCIDRv4: () => ZodCIDRv4,
    ZodCIDRv6: () => ZodCIDRv6,
    ZodCUID: () => ZodCUID,
    ZodCUID2: () => ZodCUID2,
    ZodCatch: () => ZodCatch,
    ZodCodec: () => ZodCodec,
    ZodCustom: () => ZodCustom,
    ZodCustomStringFormat: () => ZodCustomStringFormat,
    ZodDate: () => ZodDate,
    ZodDefault: () => ZodDefault,
    ZodDiscriminatedUnion: () => ZodDiscriminatedUnion,
    ZodE164: () => ZodE164,
    ZodEmail: () => ZodEmail,
    ZodEmoji: () => ZodEmoji,
    ZodEnum: () => ZodEnum,
    ZodError: () => ZodError,
    ZodExactOptional: () => ZodExactOptional,
    ZodFile: () => ZodFile,
    ZodFirstPartyTypeKind: () => ZodFirstPartyTypeKind,
    ZodFunction: () => ZodFunction,
    ZodGUID: () => ZodGUID,
    ZodIPv4: () => ZodIPv4,
    ZodIPv6: () => ZodIPv6,
    ZodISODate: () => ZodISODate,
    ZodISODateTime: () => ZodISODateTime,
    ZodISODuration: () => ZodISODuration,
    ZodISOTime: () => ZodISOTime,
    ZodIntersection: () => ZodIntersection,
    ZodIssueCode: () => ZodIssueCode,
    ZodJWT: () => ZodJWT,
    ZodKSUID: () => ZodKSUID,
    ZodLazy: () => ZodLazy,
    ZodLiteral: () => ZodLiteral,
    ZodMAC: () => ZodMAC,
    ZodMap: () => ZodMap,
    ZodNaN: () => ZodNaN,
    ZodNanoID: () => ZodNanoID,
    ZodNever: () => ZodNever,
    ZodNonOptional: () => ZodNonOptional,
    ZodNull: () => ZodNull,
    ZodNullable: () => ZodNullable,
    ZodNumber: () => ZodNumber,
    ZodNumberFormat: () => ZodNumberFormat,
    ZodObject: () => ZodObject,
    ZodOptional: () => ZodOptional,
    ZodPipe: () => ZodPipe,
    ZodPrefault: () => ZodPrefault,
    ZodPreprocess: () => ZodPreprocess,
    ZodPromise: () => ZodPromise,
    ZodReadonly: () => ZodReadonly,
    ZodRealError: () => ZodRealError,
    ZodRecord: () => ZodRecord,
    ZodSet: () => ZodSet,
    ZodString: () => ZodString,
    ZodStringFormat: () => ZodStringFormat,
    ZodSuccess: () => ZodSuccess,
    ZodSymbol: () => ZodSymbol,
    ZodTemplateLiteral: () => ZodTemplateLiteral,
    ZodTransform: () => ZodTransform,
    ZodTuple: () => ZodTuple,
    ZodType: () => ZodType,
    ZodULID: () => ZodULID,
    ZodURL: () => ZodURL,
    ZodUUID: () => ZodUUID,
    ZodUndefined: () => ZodUndefined,
    ZodUnion: () => ZodUnion,
    ZodUnknown: () => ZodUnknown,
    ZodVoid: () => ZodVoid,
    ZodXID: () => ZodXID,
    ZodXor: () => ZodXor,
    _ZodString: () => _ZodString,
    _default: () => _default2,
    _function: () => _function,
    any: () => any,
    array: () => array,
    base64: () => base642,
    base64url: () => base64url2,
    bigint: () => bigint2,
    boolean: () => boolean2,
    catch: () => _catch2,
    check: () => check,
    cidrv4: () => cidrv42,
    cidrv6: () => cidrv62,
    clone: () => clone,
    codec: () => codec,
    coerce: () => coerce_exports,
    config: () => config,
    core: () => core_exports2,
    cuid: () => cuid3,
    cuid2: () => cuid22,
    custom: () => custom,
    date: () => date3,
    decode: () => decode2,
    decodeAsync: () => decodeAsync2,
    describe: () => describe2,
    discriminatedUnion: () => discriminatedUnion,
    e164: () => e1642,
    email: () => email2,
    emoji: () => emoji2,
    encode: () => encode2,
    encodeAsync: () => encodeAsync2,
    endsWith: () => _endsWith,
    enum: () => _enum2,
    exactOptional: () => exactOptional,
    file: () => file,
    flattenError: () => flattenError,
    float32: () => float32,
    float64: () => float64,
    formatError: () => formatError,
    fromJSONSchema: () => fromJSONSchema,
    function: () => _function,
    getErrorMap: () => getErrorMap,
    globalRegistry: () => globalRegistry,
    gt: () => _gt,
    gte: () => _gte,
    guid: () => guid2,
    hash: () => hash,
    hex: () => hex2,
    hostname: () => hostname2,
    httpUrl: () => httpUrl,
    includes: () => _includes,
    instanceof: () => _instanceof,
    int: () => int,
    int32: () => int32,
    int64: () => int64,
    intersection: () => intersection,
    invertCodec: () => invertCodec,
    ipv4: () => ipv42,
    ipv6: () => ipv62,
    iso: () => iso_exports,
    json: () => json,
    jwt: () => jwt,
    keyof: () => keyof,
    ksuid: () => ksuid2,
    lazy: () => lazy,
    length: () => _length,
    literal: () => literal,
    locales: () => locales_exports,
    looseObject: () => looseObject,
    looseRecord: () => looseRecord,
    lowercase: () => _lowercase,
    lt: () => _lt,
    lte: () => _lte,
    mac: () => mac2,
    map: () => map,
    maxLength: () => _maxLength,
    maxSize: () => _maxSize,
    meta: () => meta2,
    mime: () => _mime,
    minLength: () => _minLength,
    minSize: () => _minSize,
    multipleOf: () => _multipleOf,
    nan: () => nan,
    nanoid: () => nanoid2,
    nativeEnum: () => nativeEnum,
    negative: () => _negative,
    never: () => never,
    nonnegative: () => _nonnegative,
    nonoptional: () => nonoptional,
    nonpositive: () => _nonpositive,
    normalize: () => _normalize,
    null: () => _null3,
    nullable: () => nullable,
    nullish: () => nullish2,
    number: () => number2,
    object: () => object,
    optional: () => optional,
    overwrite: () => _overwrite,
    parse: () => parse2,
    parseAsync: () => parseAsync2,
    partialRecord: () => partialRecord,
    pipe: () => pipe,
    positive: () => _positive,
    prefault: () => prefault,
    preprocess: () => preprocess,
    prettifyError: () => prettifyError,
    promise: () => promise,
    property: () => _property,
    readonly: () => readonly,
    record: () => record,
    refine: () => refine,
    regex: () => _regex,
    regexes: () => regexes_exports,
    registry: () => registry,
    safeDecode: () => safeDecode2,
    safeDecodeAsync: () => safeDecodeAsync2,
    safeEncode: () => safeEncode2,
    safeEncodeAsync: () => safeEncodeAsync2,
    safeParse: () => safeParse2,
    safeParseAsync: () => safeParseAsync2,
    set: () => set,
    setErrorMap: () => setErrorMap,
    size: () => _size,
    slugify: () => _slugify,
    startsWith: () => _startsWith,
    strictObject: () => strictObject,
    string: () => string2,
    stringFormat: () => stringFormat,
    stringbool: () => stringbool,
    success: () => success,
    superRefine: () => superRefine,
    symbol: () => symbol,
    templateLiteral: () => templateLiteral,
    toJSONSchema: () => toJSONSchema,
    toLowerCase: () => _toLowerCase,
    toUpperCase: () => _toUpperCase,
    transform: () => transform,
    treeifyError: () => treeifyError,
    trim: () => _trim,
    tuple: () => tuple,
    uint32: () => uint32,
    uint64: () => uint64,
    ulid: () => ulid2,
    undefined: () => _undefined3,
    union: () => union,
    unknown: () => unknown,
    uppercase: () => _uppercase,
    url: () => url,
    util: () => util_exports,
    uuid: () => uuid2,
    uuidv4: () => uuidv4,
    uuidv6: () => uuidv6,
    uuidv7: () => uuidv7,
    void: () => _void2,
    xid: () => xid2,
    xor: () => xor
  });
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/core/index.js
  var core_exports2 = {};
  __export(core_exports2, {
    $ZodAny: () => $ZodAny,
    $ZodArray: () => $ZodArray,
    $ZodAsyncError: () => $ZodAsyncError,
    $ZodBase64: () => $ZodBase64,
    $ZodBase64URL: () => $ZodBase64URL,
    $ZodBigInt: () => $ZodBigInt,
    $ZodBigIntFormat: () => $ZodBigIntFormat,
    $ZodBoolean: () => $ZodBoolean,
    $ZodCIDRv4: () => $ZodCIDRv4,
    $ZodCIDRv6: () => $ZodCIDRv6,
    $ZodCUID: () => $ZodCUID,
    $ZodCUID2: () => $ZodCUID2,
    $ZodCatch: () => $ZodCatch,
    $ZodCheck: () => $ZodCheck,
    $ZodCheckBigIntFormat: () => $ZodCheckBigIntFormat,
    $ZodCheckEndsWith: () => $ZodCheckEndsWith,
    $ZodCheckGreaterThan: () => $ZodCheckGreaterThan,
    $ZodCheckIncludes: () => $ZodCheckIncludes,
    $ZodCheckLengthEquals: () => $ZodCheckLengthEquals,
    $ZodCheckLessThan: () => $ZodCheckLessThan,
    $ZodCheckLowerCase: () => $ZodCheckLowerCase,
    $ZodCheckMaxLength: () => $ZodCheckMaxLength,
    $ZodCheckMaxSize: () => $ZodCheckMaxSize,
    $ZodCheckMimeType: () => $ZodCheckMimeType,
    $ZodCheckMinLength: () => $ZodCheckMinLength,
    $ZodCheckMinSize: () => $ZodCheckMinSize,
    $ZodCheckMultipleOf: () => $ZodCheckMultipleOf,
    $ZodCheckNumberFormat: () => $ZodCheckNumberFormat,
    $ZodCheckOverwrite: () => $ZodCheckOverwrite,
    $ZodCheckProperty: () => $ZodCheckProperty,
    $ZodCheckRegex: () => $ZodCheckRegex,
    $ZodCheckSizeEquals: () => $ZodCheckSizeEquals,
    $ZodCheckStartsWith: () => $ZodCheckStartsWith,
    $ZodCheckStringFormat: () => $ZodCheckStringFormat,
    $ZodCheckUpperCase: () => $ZodCheckUpperCase,
    $ZodCodec: () => $ZodCodec,
    $ZodCustom: () => $ZodCustom,
    $ZodCustomStringFormat: () => $ZodCustomStringFormat,
    $ZodDate: () => $ZodDate,
    $ZodDefault: () => $ZodDefault,
    $ZodDiscriminatedUnion: () => $ZodDiscriminatedUnion,
    $ZodE164: () => $ZodE164,
    $ZodEmail: () => $ZodEmail,
    $ZodEmoji: () => $ZodEmoji,
    $ZodEncodeError: () => $ZodEncodeError,
    $ZodEnum: () => $ZodEnum,
    $ZodError: () => $ZodError,
    $ZodExactOptional: () => $ZodExactOptional,
    $ZodFile: () => $ZodFile,
    $ZodFunction: () => $ZodFunction,
    $ZodGUID: () => $ZodGUID,
    $ZodIPv4: () => $ZodIPv4,
    $ZodIPv6: () => $ZodIPv6,
    $ZodISODate: () => $ZodISODate,
    $ZodISODateTime: () => $ZodISODateTime,
    $ZodISODuration: () => $ZodISODuration,
    $ZodISOTime: () => $ZodISOTime,
    $ZodIntersection: () => $ZodIntersection,
    $ZodJWT: () => $ZodJWT,
    $ZodKSUID: () => $ZodKSUID,
    $ZodLazy: () => $ZodLazy,
    $ZodLiteral: () => $ZodLiteral,
    $ZodMAC: () => $ZodMAC,
    $ZodMap: () => $ZodMap,
    $ZodNaN: () => $ZodNaN,
    $ZodNanoID: () => $ZodNanoID,
    $ZodNever: () => $ZodNever,
    $ZodNonOptional: () => $ZodNonOptional,
    $ZodNull: () => $ZodNull,
    $ZodNullable: () => $ZodNullable,
    $ZodNumber: () => $ZodNumber,
    $ZodNumberFormat: () => $ZodNumberFormat,
    $ZodObject: () => $ZodObject,
    $ZodObjectJIT: () => $ZodObjectJIT,
    $ZodOptional: () => $ZodOptional,
    $ZodPipe: () => $ZodPipe,
    $ZodPrefault: () => $ZodPrefault,
    $ZodPreprocess: () => $ZodPreprocess,
    $ZodPromise: () => $ZodPromise,
    $ZodReadonly: () => $ZodReadonly,
    $ZodRealError: () => $ZodRealError,
    $ZodRecord: () => $ZodRecord,
    $ZodRegistry: () => $ZodRegistry,
    $ZodSet: () => $ZodSet,
    $ZodString: () => $ZodString,
    $ZodStringFormat: () => $ZodStringFormat,
    $ZodSuccess: () => $ZodSuccess,
    $ZodSymbol: () => $ZodSymbol,
    $ZodTemplateLiteral: () => $ZodTemplateLiteral,
    $ZodTransform: () => $ZodTransform,
    $ZodTuple: () => $ZodTuple,
    $ZodType: () => $ZodType,
    $ZodULID: () => $ZodULID,
    $ZodURL: () => $ZodURL,
    $ZodUUID: () => $ZodUUID,
    $ZodUndefined: () => $ZodUndefined,
    $ZodUnion: () => $ZodUnion,
    $ZodUnknown: () => $ZodUnknown,
    $ZodVoid: () => $ZodVoid,
    $ZodXID: () => $ZodXID,
    $ZodXor: () => $ZodXor,
    $brand: () => $brand,
    $constructor: () => $constructor,
    $input: () => $input,
    $output: () => $output,
    Doc: () => Doc,
    JSONSchema: () => json_schema_exports,
    JSONSchemaGenerator: () => JSONSchemaGenerator,
    NEVER: () => NEVER,
    TimePrecision: () => TimePrecision,
    _any: () => _any,
    _array: () => _array,
    _base64: () => _base64,
    _base64url: () => _base64url,
    _bigint: () => _bigint,
    _boolean: () => _boolean,
    _catch: () => _catch,
    _check: () => _check,
    _cidrv4: () => _cidrv4,
    _cidrv6: () => _cidrv6,
    _coercedBigint: () => _coercedBigint,
    _coercedBoolean: () => _coercedBoolean,
    _coercedDate: () => _coercedDate,
    _coercedNumber: () => _coercedNumber,
    _coercedString: () => _coercedString,
    _cuid: () => _cuid,
    _cuid2: () => _cuid2,
    _custom: () => _custom,
    _date: () => _date,
    _decode: () => _decode,
    _decodeAsync: () => _decodeAsync,
    _default: () => _default,
    _discriminatedUnion: () => _discriminatedUnion,
    _e164: () => _e164,
    _email: () => _email,
    _emoji: () => _emoji2,
    _encode: () => _encode,
    _encodeAsync: () => _encodeAsync,
    _endsWith: () => _endsWith,
    _enum: () => _enum,
    _file: () => _file,
    _float32: () => _float32,
    _float64: () => _float64,
    _gt: () => _gt,
    _gte: () => _gte,
    _guid: () => _guid,
    _includes: () => _includes,
    _int: () => _int,
    _int32: () => _int32,
    _int64: () => _int64,
    _intersection: () => _intersection,
    _ipv4: () => _ipv4,
    _ipv6: () => _ipv6,
    _isoDate: () => _isoDate,
    _isoDateTime: () => _isoDateTime,
    _isoDuration: () => _isoDuration,
    _isoTime: () => _isoTime,
    _jwt: () => _jwt,
    _ksuid: () => _ksuid,
    _lazy: () => _lazy,
    _length: () => _length,
    _literal: () => _literal,
    _lowercase: () => _lowercase,
    _lt: () => _lt,
    _lte: () => _lte,
    _mac: () => _mac,
    _map: () => _map,
    _max: () => _lte,
    _maxLength: () => _maxLength,
    _maxSize: () => _maxSize,
    _mime: () => _mime,
    _min: () => _gte,
    _minLength: () => _minLength,
    _minSize: () => _minSize,
    _multipleOf: () => _multipleOf,
    _nan: () => _nan,
    _nanoid: () => _nanoid,
    _nativeEnum: () => _nativeEnum,
    _negative: () => _negative,
    _never: () => _never,
    _nonnegative: () => _nonnegative,
    _nonoptional: () => _nonoptional,
    _nonpositive: () => _nonpositive,
    _normalize: () => _normalize,
    _null: () => _null2,
    _nullable: () => _nullable,
    _number: () => _number,
    _optional: () => _optional,
    _overwrite: () => _overwrite,
    _parse: () => _parse,
    _parseAsync: () => _parseAsync,
    _pipe: () => _pipe,
    _positive: () => _positive,
    _promise: () => _promise,
    _property: () => _property,
    _readonly: () => _readonly,
    _record: () => _record,
    _refine: () => _refine,
    _regex: () => _regex,
    _safeDecode: () => _safeDecode,
    _safeDecodeAsync: () => _safeDecodeAsync,
    _safeEncode: () => _safeEncode,
    _safeEncodeAsync: () => _safeEncodeAsync,
    _safeParse: () => _safeParse,
    _safeParseAsync: () => _safeParseAsync,
    _set: () => _set,
    _size: () => _size,
    _slugify: () => _slugify,
    _startsWith: () => _startsWith,
    _string: () => _string,
    _stringFormat: () => _stringFormat,
    _stringbool: () => _stringbool,
    _success: () => _success,
    _superRefine: () => _superRefine,
    _symbol: () => _symbol,
    _templateLiteral: () => _templateLiteral,
    _toLowerCase: () => _toLowerCase,
    _toUpperCase: () => _toUpperCase,
    _transform: () => _transform,
    _trim: () => _trim,
    _tuple: () => _tuple,
    _uint32: () => _uint32,
    _uint64: () => _uint64,
    _ulid: () => _ulid,
    _undefined: () => _undefined2,
    _union: () => _union,
    _unknown: () => _unknown,
    _uppercase: () => _uppercase,
    _url: () => _url,
    _uuid: () => _uuid,
    _uuidv4: () => _uuidv4,
    _uuidv6: () => _uuidv6,
    _uuidv7: () => _uuidv7,
    _void: () => _void,
    _xid: () => _xid,
    _xor: () => _xor,
    clone: () => clone,
    config: () => config,
    createStandardJSONSchemaMethod: () => createStandardJSONSchemaMethod,
    createToJSONSchemaMethod: () => createToJSONSchemaMethod,
    decode: () => decode,
    decodeAsync: () => decodeAsync,
    describe: () => describe,
    encode: () => encode,
    encodeAsync: () => encodeAsync,
    extractDefs: () => extractDefs,
    finalize: () => finalize,
    flattenError: () => flattenError,
    formatError: () => formatError,
    globalConfig: () => globalConfig,
    globalRegistry: () => globalRegistry,
    initializeContext: () => initializeContext,
    isValidBase64: () => isValidBase64,
    isValidBase64URL: () => isValidBase64URL,
    isValidJWT: () => isValidJWT,
    locales: () => locales_exports,
    meta: () => meta,
    parse: () => parse,
    parseAsync: () => parseAsync,
    prettifyError: () => prettifyError,
    process: () => process,
    regexes: () => regexes_exports,
    registry: () => registry,
    safeDecode: () => safeDecode,
    safeDecodeAsync: () => safeDecodeAsync,
    safeEncode: () => safeEncode,
    safeEncodeAsync: () => safeEncodeAsync,
    safeParse: () => safeParse,
    safeParseAsync: () => safeParseAsync,
    toDotPath: () => toDotPath,
    toJSONSchema: () => toJSONSchema,
    treeifyError: () => treeifyError,
    util: () => util_exports,
    version: () => version
  });
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/core/core.js
  init_runtime();
  var _a;
  var NEVER = /* @__PURE__ */ Object.freeze({
    status: "aborted"
  });
  // @__NO_SIDE_EFFECTS__
  function $constructor(name, initializer3, params) {
    function init(inst, def) {
      if (!inst._zod) {
        Object.defineProperty(inst, "_zod", {
          value: {
            def,
            constr: _,
            traits: /* @__PURE__ */ new Set()
          },
          enumerable: false
        });
      }
      if (inst._zod.traits.has(name)) {
        return;
      }
      inst._zod.traits.add(name);
      initializer3(inst, def);
      const proto = _.prototype;
      const keys = Object.keys(proto);
      for (let i = 0; i < keys.length; i++) {
        const k = keys[i];
        if (!(k in inst)) {
          inst[k] = proto[k].bind(inst);
        }
      }
    }
    const Parent = params?.Parent ?? Object;
    class Definition extends Parent {
    }
    Object.defineProperty(Definition, "name", { value: name });
    function _(def) {
      var _a3;
      const inst = params?.Parent ? new Definition() : this;
      init(inst, def);
      (_a3 = inst._zod).deferred ?? (_a3.deferred = []);
      for (const fn of inst._zod.deferred) {
        fn();
      }
      return inst;
    }
    Object.defineProperty(_, "init", { value: init });
    Object.defineProperty(_, Symbol.hasInstance, {
      value: (inst) => {
        if (params?.Parent && inst instanceof params.Parent)
          return true;
        return inst?._zod?.traits?.has(name);
      }
    });
    Object.defineProperty(_, "name", { value: name });
    return _;
  }
  var $brand = /* @__PURE__ */ Symbol("zod_brand");
  var $ZodAsyncError = class extends Error {
    constructor() {
      super(`Encountered Promise during synchronous parse. Use .parseAsync() instead.`);
    }
  };
  var $ZodEncodeError = class extends Error {
    constructor(name) {
      super(`Encountered unidirectional transform during encode: ${name}`);
      this.name = "ZodEncodeError";
    }
  };
  (_a = globalThis).__zod_globalConfig ?? (_a.__zod_globalConfig = {});
  var globalConfig = globalThis.__zod_globalConfig;
  function config(newConfig) {
    if (newConfig)
      Object.assign(globalConfig, newConfig);
    return globalConfig;
  }

  // ThirdParty/REA/dependencies/zod/v4/core/parse.js
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/core/errors.js
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/core/util.js
  var util_exports = {};
  __export(util_exports, {
    BIGINT_FORMAT_RANGES: () => BIGINT_FORMAT_RANGES,
    Class: () => Class,
    NUMBER_FORMAT_RANGES: () => NUMBER_FORMAT_RANGES,
    aborted: () => aborted,
    allowsEval: () => allowsEval,
    assert: () => assert,
    assertEqual: () => assertEqual,
    assertIs: () => assertIs,
    assertNever: () => assertNever,
    assertNotEqual: () => assertNotEqual,
    assignProp: () => assignProp,
    base64ToUint8Array: () => base64ToUint8Array,
    base64urlToUint8Array: () => base64urlToUint8Array,
    cached: () => cached,
    captureStackTrace: () => captureStackTrace,
    cleanEnum: () => cleanEnum,
    cleanRegex: () => cleanRegex,
    clone: () => clone,
    cloneDef: () => cloneDef,
    createTransparentProxy: () => createTransparentProxy,
    defineLazy: () => defineLazy,
    esc: () => esc,
    escapeRegex: () => escapeRegex,
    explicitlyAborted: () => explicitlyAborted,
    extend: () => extend,
    finalizeIssue: () => finalizeIssue,
    floatSafeRemainder: () => floatSafeRemainder,
    getElementAtPath: () => getElementAtPath,
    getEnumValues: () => getEnumValues,
    getLengthableOrigin: () => getLengthableOrigin,
    getParsedType: () => getParsedType,
    getSizableOrigin: () => getSizableOrigin,
    hexToUint8Array: () => hexToUint8Array,
    isObject: () => isObject,
    isPlainObject: () => isPlainObject,
    issue: () => issue,
    joinValues: () => joinValues,
    jsonStringifyReplacer: () => jsonStringifyReplacer,
    merge: () => merge,
    mergeDefs: () => mergeDefs,
    normalizeParams: () => normalizeParams,
    nullish: () => nullish,
    numKeys: () => numKeys,
    objectClone: () => objectClone,
    omit: () => omit,
    optionalKeys: () => optionalKeys,
    parsedType: () => parsedType,
    partial: () => partial,
    pick: () => pick,
    prefixIssues: () => prefixIssues,
    primitiveTypes: () => primitiveTypes,
    promiseAllObject: () => promiseAllObject,
    propertyKeyTypes: () => propertyKeyTypes,
    randomString: () => randomString,
    required: () => required,
    safeExtend: () => safeExtend,
    shallowClone: () => shallowClone,
    slugify: () => slugify,
    stringifyPrimitive: () => stringifyPrimitive,
    uint8ArrayToBase64: () => uint8ArrayToBase64,
    uint8ArrayToBase64url: () => uint8ArrayToBase64url,
    uint8ArrayToHex: () => uint8ArrayToHex,
    unwrapMessage: () => unwrapMessage
  });
  init_runtime();
  function assertEqual(val) {
    return val;
  }
  function assertNotEqual(val) {
    return val;
  }
  function assertIs(_arg) {
  }
  function assertNever(_x) {
    throw new Error("Unexpected value in exhaustive check");
  }
  function assert(_) {
  }
  function getEnumValues(entries) {
    const numericValues = Object.values(entries).filter((v) => typeof v === "number");
    const values = Object.entries(entries).filter(([k, _]) => numericValues.indexOf(+k) === -1).map(([_, v]) => v);
    return values;
  }
  function joinValues(array2, separator = "|") {
    return array2.map((val) => stringifyPrimitive(val)).join(separator);
  }
  function jsonStringifyReplacer(_, value) {
    if (typeof value === "bigint")
      return value.toString();
    return value;
  }
  function cached(getter) {
    const set2 = false;
    return {
      get value() {
        if (!set2) {
          const value = getter();
          Object.defineProperty(this, "value", { value });
          return value;
        }
        throw new Error("cached value already set");
      }
    };
  }
  function nullish(input) {
    return input === null || input === void 0;
  }
  function cleanRegex(source2) {
    const start = source2.startsWith("^") ? 1 : 0;
    const end = source2.endsWith("$") ? source2.length - 1 : source2.length;
    return source2.slice(start, end);
  }
  function floatSafeRemainder(val, step) {
    const ratio = val / step;
    const roundedRatio = Math.round(ratio);
    const tolerance = Number.EPSILON * Math.max(Math.abs(ratio), 1);
    if (Math.abs(ratio - roundedRatio) < tolerance)
      return 0;
    return ratio - roundedRatio;
  }
  var EVALUATING = /* @__PURE__ */ Symbol("evaluating");
  function defineLazy(object2, key, getter) {
    let value = void 0;
    Object.defineProperty(object2, key, {
      get() {
        if (value === EVALUATING) {
          return void 0;
        }
        if (value === void 0) {
          value = EVALUATING;
          value = getter();
        }
        return value;
      },
      set(v) {
        Object.defineProperty(object2, key, {
          value: v
          // configurable: true,
        });
      },
      configurable: true
    });
  }
  function objectClone(obj) {
    return Object.create(Object.getPrototypeOf(obj), Object.getOwnPropertyDescriptors(obj));
  }
  function assignProp(target, prop, value) {
    Object.defineProperty(target, prop, {
      value,
      writable: true,
      enumerable: true,
      configurable: true
    });
  }
  function mergeDefs(...defs) {
    const mergedDescriptors = {};
    for (const def of defs) {
      const descriptors = Object.getOwnPropertyDescriptors(def);
      Object.assign(mergedDescriptors, descriptors);
    }
    return Object.defineProperties({}, mergedDescriptors);
  }
  function cloneDef(schema) {
    return mergeDefs(schema._zod.def);
  }
  function getElementAtPath(obj, path3) {
    if (!path3)
      return obj;
    return path3.reduce((acc, key) => acc?.[key], obj);
  }
  function promiseAllObject(promisesObj) {
    const keys = Object.keys(promisesObj);
    const promises = keys.map((key) => promisesObj[key]);
    return Promise.all(promises).then((results) => {
      const resolvedObj = {};
      for (let i = 0; i < keys.length; i++) {
        resolvedObj[keys[i]] = results[i];
      }
      return resolvedObj;
    });
  }
  function randomString(length = 10) {
    const chars = "abcdefghijklmnopqrstuvwxyz";
    let str = "";
    for (let i = 0; i < length; i++) {
      str += chars[Math.floor(Math.random() * chars.length)];
    }
    return str;
  }
  function esc(str) {
    return JSON.stringify(str);
  }
  function slugify(input) {
    return input.toLowerCase().trim().replace(/[^\w\s-]/g, "").replace(/[\s_-]+/g, "-").replace(/^-+|-+$/g, "");
  }
  var captureStackTrace = "captureStackTrace" in Error ? Error.captureStackTrace : (..._args) => {
  };
  function isObject(data) {
    return typeof data === "object" && data !== null && !Array.isArray(data);
  }
  var allowsEval = /* @__PURE__ */ cached(() => {
    if (globalConfig.jitless) {
      return false;
    }
    if (typeof navigator !== "undefined" && navigator?.userAgent?.includes("Cloudflare")) {
      return false;
    }
    try {
      const F = Function;
      new F("");
      return true;
    } catch (_) {
      return false;
    }
  });
  function isPlainObject(o) {
    if (isObject(o) === false)
      return false;
    const ctor = o.constructor;
    if (ctor === void 0)
      return true;
    if (typeof ctor !== "function")
      return true;
    const prot = ctor.prototype;
    if (isObject(prot) === false)
      return false;
    if (Object.prototype.hasOwnProperty.call(prot, "isPrototypeOf") === false) {
      return false;
    }
    return true;
  }
  function shallowClone(o) {
    if (isPlainObject(o))
      return { ...o };
    if (Array.isArray(o))
      return [...o];
    if (o instanceof Map)
      return new Map(o);
    if (o instanceof Set)
      return new Set(o);
    return o;
  }
  function numKeys(data) {
    let keyCount = 0;
    for (const key in data) {
      if (Object.prototype.hasOwnProperty.call(data, key)) {
        keyCount++;
      }
    }
    return keyCount;
  }
  var getParsedType = (data) => {
    const t = typeof data;
    switch (t) {
      case "undefined":
        return "undefined";
      case "string":
        return "string";
      case "number":
        return Number.isNaN(data) ? "nan" : "number";
      case "boolean":
        return "boolean";
      case "function":
        return "function";
      case "bigint":
        return "bigint";
      case "symbol":
        return "symbol";
      case "object":
        if (Array.isArray(data)) {
          return "array";
        }
        if (data === null) {
          return "null";
        }
        if (data.then && typeof data.then === "function" && data.catch && typeof data.catch === "function") {
          return "promise";
        }
        if (typeof Map !== "undefined" && data instanceof Map) {
          return "map";
        }
        if (typeof Set !== "undefined" && data instanceof Set) {
          return "set";
        }
        if (typeof Date !== "undefined" && data instanceof Date) {
          return "date";
        }
        if (typeof File !== "undefined" && data instanceof File) {
          return "file";
        }
        return "object";
      default:
        throw new Error(`Unknown data type: ${t}`);
    }
  };
  var propertyKeyTypes = /* @__PURE__ */ new Set(["string", "number", "symbol"]);
  var primitiveTypes = /* @__PURE__ */ new Set([
    "string",
    "number",
    "bigint",
    "boolean",
    "symbol",
    "undefined"
  ]);
  function escapeRegex(str) {
    return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }
  function clone(inst, def, params) {
    const cl = new inst._zod.constr(def ?? inst._zod.def);
    if (!def || params?.parent)
      cl._zod.parent = inst;
    return cl;
  }
  function normalizeParams(_params) {
    const params = _params;
    if (!params)
      return {};
    if (typeof params === "string")
      return { error: () => params };
    if (params?.message !== void 0) {
      if (params?.error !== void 0)
        throw new Error("Cannot specify both `message` and `error` params");
      params.error = params.message;
    }
    delete params.message;
    if (typeof params.error === "string")
      return { ...params, error: () => params.error };
    return params;
  }
  function createTransparentProxy(getter) {
    let target;
    return new Proxy({}, {
      get(_, prop, receiver) {
        target ?? (target = getter());
        return Reflect.get(target, prop, receiver);
      },
      set(_, prop, value, receiver) {
        target ?? (target = getter());
        return Reflect.set(target, prop, value, receiver);
      },
      has(_, prop) {
        target ?? (target = getter());
        return Reflect.has(target, prop);
      },
      deleteProperty(_, prop) {
        target ?? (target = getter());
        return Reflect.deleteProperty(target, prop);
      },
      ownKeys(_) {
        target ?? (target = getter());
        return Reflect.ownKeys(target);
      },
      getOwnPropertyDescriptor(_, prop) {
        target ?? (target = getter());
        return Reflect.getOwnPropertyDescriptor(target, prop);
      },
      defineProperty(_, prop, descriptor) {
        target ?? (target = getter());
        return Reflect.defineProperty(target, prop, descriptor);
      }
    });
  }
  function stringifyPrimitive(value) {
    if (typeof value === "bigint")
      return value.toString() + "n";
    if (typeof value === "string")
      return `"${value}"`;
    return `${value}`;
  }
  function optionalKeys(shape) {
    return Object.keys(shape).filter((k) => {
      return shape[k]._zod.optin === "optional" && shape[k]._zod.optout === "optional";
    });
  }
  var NUMBER_FORMAT_RANGES = {
    safeint: [Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER],
    int32: [-2147483648, 2147483647],
    uint32: [0, 4294967295],
    float32: [-34028234663852886e22, 34028234663852886e22],
    float64: [-Number.MAX_VALUE, Number.MAX_VALUE]
  };
  var BIGINT_FORMAT_RANGES = {
    int64: [/* @__PURE__ */ BigInt("-9223372036854775808"), /* @__PURE__ */ BigInt("9223372036854775807")],
    uint64: [/* @__PURE__ */ BigInt(0), /* @__PURE__ */ BigInt("18446744073709551615")]
  };
  function pick(schema, mask) {
    const currDef = schema._zod.def;
    const checks = currDef.checks;
    const hasChecks = checks && checks.length > 0;
    if (hasChecks) {
      throw new Error(".pick() cannot be used on object schemas containing refinements");
    }
    const def = mergeDefs(schema._zod.def, {
      get shape() {
        const newShape = {};
        for (const key in mask) {
          if (!(key in currDef.shape)) {
            throw new Error(`Unrecognized key: "${key}"`);
          }
          if (!mask[key])
            continue;
          newShape[key] = currDef.shape[key];
        }
        assignProp(this, "shape", newShape);
        return newShape;
      },
      checks: []
    });
    return clone(schema, def);
  }
  function omit(schema, mask) {
    const currDef = schema._zod.def;
    const checks = currDef.checks;
    const hasChecks = checks && checks.length > 0;
    if (hasChecks) {
      throw new Error(".omit() cannot be used on object schemas containing refinements");
    }
    const def = mergeDefs(schema._zod.def, {
      get shape() {
        const newShape = { ...schema._zod.def.shape };
        for (const key in mask) {
          if (!(key in currDef.shape)) {
            throw new Error(`Unrecognized key: "${key}"`);
          }
          if (!mask[key])
            continue;
          delete newShape[key];
        }
        assignProp(this, "shape", newShape);
        return newShape;
      },
      checks: []
    });
    return clone(schema, def);
  }
  function extend(schema, shape) {
    if (!isPlainObject(shape)) {
      throw new Error("Invalid input to extend: expected a plain object");
    }
    const checks = schema._zod.def.checks;
    const hasChecks = checks && checks.length > 0;
    if (hasChecks) {
      const existingShape = schema._zod.def.shape;
      for (const key in shape) {
        if (Object.getOwnPropertyDescriptor(existingShape, key) !== void 0) {
          throw new Error("Cannot overwrite keys on object schemas containing refinements. Use `.safeExtend()` instead.");
        }
      }
    }
    const def = mergeDefs(schema._zod.def, {
      get shape() {
        const _shape = { ...schema._zod.def.shape, ...shape };
        assignProp(this, "shape", _shape);
        return _shape;
      }
    });
    return clone(schema, def);
  }
  function safeExtend(schema, shape) {
    if (!isPlainObject(shape)) {
      throw new Error("Invalid input to safeExtend: expected a plain object");
    }
    const def = mergeDefs(schema._zod.def, {
      get shape() {
        const _shape = { ...schema._zod.def.shape, ...shape };
        assignProp(this, "shape", _shape);
        return _shape;
      }
    });
    return clone(schema, def);
  }
  function merge(a, b) {
    if (a._zod.def.checks?.length) {
      throw new Error(".merge() cannot be used on object schemas containing refinements. Use .safeExtend() instead.");
    }
    const def = mergeDefs(a._zod.def, {
      get shape() {
        const _shape = { ...a._zod.def.shape, ...b._zod.def.shape };
        assignProp(this, "shape", _shape);
        return _shape;
      },
      get catchall() {
        return b._zod.def.catchall;
      },
      checks: b._zod.def.checks ?? []
    });
    return clone(a, def);
  }
  function partial(Class2, schema, mask) {
    const currDef = schema._zod.def;
    const checks = currDef.checks;
    const hasChecks = checks && checks.length > 0;
    if (hasChecks) {
      throw new Error(".partial() cannot be used on object schemas containing refinements");
    }
    const def = mergeDefs(schema._zod.def, {
      get shape() {
        const oldShape = schema._zod.def.shape;
        const shape = { ...oldShape };
        if (mask) {
          for (const key in mask) {
            if (!(key in oldShape)) {
              throw new Error(`Unrecognized key: "${key}"`);
            }
            if (!mask[key])
              continue;
            shape[key] = Class2 ? new Class2({
              type: "optional",
              innerType: oldShape[key]
            }) : oldShape[key];
          }
        } else {
          for (const key in oldShape) {
            shape[key] = Class2 ? new Class2({
              type: "optional",
              innerType: oldShape[key]
            }) : oldShape[key];
          }
        }
        assignProp(this, "shape", shape);
        return shape;
      },
      checks: []
    });
    return clone(schema, def);
  }
  function required(Class2, schema, mask) {
    const def = mergeDefs(schema._zod.def, {
      get shape() {
        const oldShape = schema._zod.def.shape;
        const shape = { ...oldShape };
        if (mask) {
          for (const key in mask) {
            if (!(key in shape)) {
              throw new Error(`Unrecognized key: "${key}"`);
            }
            if (!mask[key])
              continue;
            shape[key] = new Class2({
              type: "nonoptional",
              innerType: oldShape[key]
            });
          }
        } else {
          for (const key in oldShape) {
            shape[key] = new Class2({
              type: "nonoptional",
              innerType: oldShape[key]
            });
          }
        }
        assignProp(this, "shape", shape);
        return shape;
      }
    });
    return clone(schema, def);
  }
  function aborted(x, startIndex = 0) {
    if (x.aborted === true)
      return true;
    for (let i = startIndex; i < x.issues.length; i++) {
      if (x.issues[i]?.continue !== true) {
        return true;
      }
    }
    return false;
  }
  function explicitlyAborted(x, startIndex = 0) {
    if (x.aborted === true)
      return true;
    for (let i = startIndex; i < x.issues.length; i++) {
      if (x.issues[i]?.continue === false) {
        return true;
      }
    }
    return false;
  }
  function prefixIssues(path3, issues) {
    return issues.map((iss) => {
      var _a3;
      (_a3 = iss).path ?? (_a3.path = []);
      iss.path.unshift(path3);
      return iss;
    });
  }
  function unwrapMessage(message) {
    return typeof message === "string" ? message : message?.message;
  }
  function finalizeIssue(iss, ctx, config2) {
    const message = iss.message ? iss.message : unwrapMessage(iss.inst?._zod.def?.error?.(iss)) ?? unwrapMessage(ctx?.error?.(iss)) ?? unwrapMessage(config2.customError?.(iss)) ?? unwrapMessage(config2.localeError?.(iss)) ?? "Invalid input";
    const { inst: _inst, continue: _continue, input: _input, ...rest } = iss;
    rest.path ?? (rest.path = []);
    rest.message = message;
    if (ctx?.reportInput) {
      rest.input = _input;
    }
    return rest;
  }
  function getSizableOrigin(input) {
    if (input instanceof Set)
      return "set";
    if (input instanceof Map)
      return "map";
    if (input instanceof File)
      return "file";
    return "unknown";
  }
  function getLengthableOrigin(input) {
    if (Array.isArray(input))
      return "array";
    if (typeof input === "string")
      return "string";
    return "unknown";
  }
  function parsedType(data) {
    const t = typeof data;
    switch (t) {
      case "number": {
        return Number.isNaN(data) ? "nan" : "number";
      }
      case "object": {
        if (data === null) {
          return "null";
        }
        if (Array.isArray(data)) {
          return "array";
        }
        const obj = data;
        if (obj && Object.getPrototypeOf(obj) !== Object.prototype && "constructor" in obj && obj.constructor) {
          return obj.constructor.name;
        }
      }
    }
    return t;
  }
  function issue(...args) {
    const [iss, input, inst] = args;
    if (typeof iss === "string") {
      return {
        message: iss,
        code: "custom",
        input,
        inst
      };
    }
    return { ...iss };
  }
  function cleanEnum(obj) {
    return Object.entries(obj).filter(([k, _]) => {
      return Number.isNaN(Number.parseInt(k, 10));
    }).map((el) => el[1]);
  }
  function base64ToUint8Array(base643) {
    const binaryString = atob(base643);
    const bytes = new Uint8Array(binaryString.length);
    for (let i = 0; i < binaryString.length; i++) {
      bytes[i] = binaryString.charCodeAt(i);
    }
    return bytes;
  }
  function uint8ArrayToBase64(bytes) {
    let binaryString = "";
    for (let i = 0; i < bytes.length; i++) {
      binaryString += String.fromCharCode(bytes[i]);
    }
    return btoa(binaryString);
  }
  function base64urlToUint8Array(base64url3) {
    const base643 = base64url3.replace(/-/g, "+").replace(/_/g, "/");
    const padding = "=".repeat((4 - base643.length % 4) % 4);
    return base64ToUint8Array(base643 + padding);
  }
  function uint8ArrayToBase64url(bytes) {
    return uint8ArrayToBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
  }
  function hexToUint8Array(hex3) {
    const cleanHex = hex3.replace(/^0x/, "");
    if (cleanHex.length % 2 !== 0) {
      throw new Error("Invalid hex string length");
    }
    const bytes = new Uint8Array(cleanHex.length / 2);
    for (let i = 0; i < cleanHex.length; i += 2) {
      bytes[i / 2] = Number.parseInt(cleanHex.slice(i, i + 2), 16);
    }
    return bytes;
  }
  function uint8ArrayToHex(bytes) {
    return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
  }
  var Class = class {
    constructor(..._args) {
    }
  };

  // ThirdParty/REA/dependencies/zod/v4/core/errors.js
  var initializer = (inst, def) => {
    inst.name = "$ZodError";
    Object.defineProperty(inst, "_zod", {
      value: inst._zod,
      enumerable: false
    });
    Object.defineProperty(inst, "issues", {
      value: def,
      enumerable: false
    });
    inst.message = JSON.stringify(def, jsonStringifyReplacer, 2);
    Object.defineProperty(inst, "toString", {
      value: () => inst.message,
      enumerable: false
    });
  };
  var $ZodError = $constructor("$ZodError", initializer);
  var $ZodRealError = $constructor("$ZodError", initializer, { Parent: Error });
  function flattenError(error51, mapper = (issue2) => issue2.message) {
    const fieldErrors = {};
    const formErrors = [];
    for (const sub of error51.issues) {
      if (sub.path.length > 0) {
        fieldErrors[sub.path[0]] = fieldErrors[sub.path[0]] || [];
        fieldErrors[sub.path[0]].push(mapper(sub));
      } else {
        formErrors.push(mapper(sub));
      }
    }
    return { formErrors, fieldErrors };
  }
  function formatError(error51, mapper = (issue2) => issue2.message) {
    const fieldErrors = { _errors: [] };
    const processError = (error52, path3 = []) => {
      for (const issue2 of error52.issues) {
        if (issue2.code === "invalid_union" && issue2.errors.length) {
          issue2.errors.map((issues) => processError({ issues }, [...path3, ...issue2.path]));
        } else if (issue2.code === "invalid_key") {
          processError({ issues: issue2.issues }, [...path3, ...issue2.path]);
        } else if (issue2.code === "invalid_element") {
          processError({ issues: issue2.issues }, [...path3, ...issue2.path]);
        } else {
          const fullpath = [...path3, ...issue2.path];
          if (fullpath.length === 0) {
            fieldErrors._errors.push(mapper(issue2));
          } else {
            let curr = fieldErrors;
            let i = 0;
            while (i < fullpath.length) {
              const el = fullpath[i];
              const terminal = i === fullpath.length - 1;
              if (!terminal) {
                curr[el] = curr[el] || { _errors: [] };
              } else {
                curr[el] = curr[el] || { _errors: [] };
                curr[el]._errors.push(mapper(issue2));
              }
              curr = curr[el];
              i++;
            }
          }
        }
      }
    };
    processError(error51);
    return fieldErrors;
  }
  function treeifyError(error51, mapper = (issue2) => issue2.message) {
    const result = { errors: [] };
    const processError = (error52, path3 = []) => {
      var _a3, _b;
      for (const issue2 of error52.issues) {
        if (issue2.code === "invalid_union" && issue2.errors.length) {
          issue2.errors.map((issues) => processError({ issues }, [...path3, ...issue2.path]));
        } else if (issue2.code === "invalid_key") {
          processError({ issues: issue2.issues }, [...path3, ...issue2.path]);
        } else if (issue2.code === "invalid_element") {
          processError({ issues: issue2.issues }, [...path3, ...issue2.path]);
        } else {
          const fullpath = [...path3, ...issue2.path];
          if (fullpath.length === 0) {
            result.errors.push(mapper(issue2));
            continue;
          }
          let curr = result;
          let i = 0;
          while (i < fullpath.length) {
            const el = fullpath[i];
            const terminal = i === fullpath.length - 1;
            if (typeof el === "string") {
              curr.properties ?? (curr.properties = {});
              (_a3 = curr.properties)[el] ?? (_a3[el] = { errors: [] });
              curr = curr.properties[el];
            } else {
              curr.items ?? (curr.items = []);
              (_b = curr.items)[el] ?? (_b[el] = { errors: [] });
              curr = curr.items[el];
            }
            if (terminal) {
              curr.errors.push(mapper(issue2));
            }
            i++;
          }
        }
      }
    };
    processError(error51);
    return result;
  }
  function toDotPath(_path) {
    const segs = [];
    const path3 = _path.map((seg) => typeof seg === "object" ? seg.key : seg);
    for (const seg of path3) {
      if (typeof seg === "number")
        segs.push(`[${seg}]`);
      else if (typeof seg === "symbol")
        segs.push(`[${JSON.stringify(String(seg))}]`);
      else if (/[^\w$]/.test(seg))
        segs.push(`[${JSON.stringify(seg)}]`);
      else {
        if (segs.length)
          segs.push(".");
        segs.push(seg);
      }
    }
    return segs.join("");
  }
  function prettifyError(error51) {
    const lines = [];
    const issues = [...error51.issues].sort((a, b) => (a.path ?? []).length - (b.path ?? []).length);
    for (const issue2 of issues) {
      lines.push(`\u2716 ${issue2.message}`);
      if (issue2.path?.length)
        lines.push(`  \u2192 at ${toDotPath(issue2.path)}`);
    }
    return lines.join("\n");
  }

  // ThirdParty/REA/dependencies/zod/v4/core/parse.js
  var _parse = (_Err) => (schema, value, _ctx, _params) => {
    const ctx = _ctx ? { ..._ctx, async: false } : { async: false };
    const result = schema._zod.run({ value, issues: [] }, ctx);
    if (result instanceof Promise) {
      throw new $ZodAsyncError();
    }
    if (result.issues.length) {
      const e = new (_params?.Err ?? _Err)(result.issues.map((iss) => finalizeIssue(iss, ctx, config())));
      captureStackTrace(e, _params?.callee);
      throw e;
    }
    return result.value;
  };
  var parse = /* @__PURE__ */ _parse($ZodRealError);
  var _parseAsync = (_Err) => async (schema, value, _ctx, params) => {
    const ctx = _ctx ? { ..._ctx, async: true } : { async: true };
    let result = schema._zod.run({ value, issues: [] }, ctx);
    if (result instanceof Promise)
      result = await result;
    if (result.issues.length) {
      const e = new (params?.Err ?? _Err)(result.issues.map((iss) => finalizeIssue(iss, ctx, config())));
      captureStackTrace(e, params?.callee);
      throw e;
    }
    return result.value;
  };
  var parseAsync = /* @__PURE__ */ _parseAsync($ZodRealError);
  var _safeParse = (_Err) => (schema, value, _ctx) => {
    const ctx = _ctx ? { ..._ctx, async: false } : { async: false };
    const result = schema._zod.run({ value, issues: [] }, ctx);
    if (result instanceof Promise) {
      throw new $ZodAsyncError();
    }
    return result.issues.length ? {
      success: false,
      error: new (_Err ?? $ZodError)(result.issues.map((iss) => finalizeIssue(iss, ctx, config())))
    } : { success: true, data: result.value };
  };
  var safeParse = /* @__PURE__ */ _safeParse($ZodRealError);
  var _safeParseAsync = (_Err) => async (schema, value, _ctx) => {
    const ctx = _ctx ? { ..._ctx, async: true } : { async: true };
    let result = schema._zod.run({ value, issues: [] }, ctx);
    if (result instanceof Promise)
      result = await result;
    return result.issues.length ? {
      success: false,
      error: new _Err(result.issues.map((iss) => finalizeIssue(iss, ctx, config())))
    } : { success: true, data: result.value };
  };
  var safeParseAsync = /* @__PURE__ */ _safeParseAsync($ZodRealError);
  var _encode = (_Err) => (schema, value, _ctx) => {
    const ctx = _ctx ? { ..._ctx, direction: "backward" } : { direction: "backward" };
    return _parse(_Err)(schema, value, ctx);
  };
  var encode = /* @__PURE__ */ _encode($ZodRealError);
  var _decode = (_Err) => (schema, value, _ctx) => {
    return _parse(_Err)(schema, value, _ctx);
  };
  var decode = /* @__PURE__ */ _decode($ZodRealError);
  var _encodeAsync = (_Err) => async (schema, value, _ctx) => {
    const ctx = _ctx ? { ..._ctx, direction: "backward" } : { direction: "backward" };
    return _parseAsync(_Err)(schema, value, ctx);
  };
  var encodeAsync = /* @__PURE__ */ _encodeAsync($ZodRealError);
  var _decodeAsync = (_Err) => async (schema, value, _ctx) => {
    return _parseAsync(_Err)(schema, value, _ctx);
  };
  var decodeAsync = /* @__PURE__ */ _decodeAsync($ZodRealError);
  var _safeEncode = (_Err) => (schema, value, _ctx) => {
    const ctx = _ctx ? { ..._ctx, direction: "backward" } : { direction: "backward" };
    return _safeParse(_Err)(schema, value, ctx);
  };
  var safeEncode = /* @__PURE__ */ _safeEncode($ZodRealError);
  var _safeDecode = (_Err) => (schema, value, _ctx) => {
    return _safeParse(_Err)(schema, value, _ctx);
  };
  var safeDecode = /* @__PURE__ */ _safeDecode($ZodRealError);
  var _safeEncodeAsync = (_Err) => async (schema, value, _ctx) => {
    const ctx = _ctx ? { ..._ctx, direction: "backward" } : { direction: "backward" };
    return _safeParseAsync(_Err)(schema, value, ctx);
  };
  var safeEncodeAsync = /* @__PURE__ */ _safeEncodeAsync($ZodRealError);
  var _safeDecodeAsync = (_Err) => async (schema, value, _ctx) => {
    return _safeParseAsync(_Err)(schema, value, _ctx);
  };
  var safeDecodeAsync = /* @__PURE__ */ _safeDecodeAsync($ZodRealError);

  // ThirdParty/REA/dependencies/zod/v4/core/schemas.js
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/core/checks.js
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/core/regexes.js
  var regexes_exports = {};
  __export(regexes_exports, {
    base64: () => base64,
    base64url: () => base64url,
    bigint: () => bigint,
    boolean: () => boolean,
    browserEmail: () => browserEmail,
    cidrv4: () => cidrv4,
    cidrv6: () => cidrv6,
    cuid: () => cuid,
    cuid2: () => cuid2,
    date: () => date,
    datetime: () => datetime,
    domain: () => domain,
    duration: () => duration,
    e164: () => e164,
    email: () => email,
    emoji: () => emoji,
    extendedDuration: () => extendedDuration,
    guid: () => guid,
    hex: () => hex,
    hostname: () => hostname,
    html5Email: () => html5Email,
    httpProtocol: () => httpProtocol,
    idnEmail: () => idnEmail,
    integer: () => integer,
    ipv4: () => ipv4,
    ipv6: () => ipv6,
    ksuid: () => ksuid,
    lowercase: () => lowercase,
    mac: () => mac,
    md5_base64: () => md5_base64,
    md5_base64url: () => md5_base64url,
    md5_hex: () => md5_hex,
    nanoid: () => nanoid,
    null: () => _null,
    number: () => number,
    rfc5322Email: () => rfc5322Email,
    sha1_base64: () => sha1_base64,
    sha1_base64url: () => sha1_base64url,
    sha1_hex: () => sha1_hex,
    sha256_base64: () => sha256_base64,
    sha256_base64url: () => sha256_base64url,
    sha256_hex: () => sha256_hex,
    sha384_base64: () => sha384_base64,
    sha384_base64url: () => sha384_base64url,
    sha384_hex: () => sha384_hex,
    sha512_base64: () => sha512_base64,
    sha512_base64url: () => sha512_base64url,
    sha512_hex: () => sha512_hex,
    string: () => string,
    time: () => time,
    ulid: () => ulid,
    undefined: () => _undefined,
    unicodeEmail: () => unicodeEmail,
    uppercase: () => uppercase,
    uuid: () => uuid,
    uuid4: () => uuid4,
    uuid6: () => uuid6,
    uuid7: () => uuid7,
    xid: () => xid
  });
  init_runtime();
  var cuid = /^[cC][0-9a-z]{6,}$/;
  var cuid2 = /^[0-9a-z]+$/;
  var ulid = /^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{26}$/;
  var xid = /^[0-9a-vA-V]{20}$/;
  var ksuid = /^[A-Za-z0-9]{27}$/;
  var nanoid = /^[a-zA-Z0-9_-]{21}$/;
  var duration = /^P(?:(\d+W)|(?!.*W)(?=\d|T\d)(\d+Y)?(\d+M)?(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+([.,]\d+)?S)?)?)$/;
  var extendedDuration = /^[-+]?P(?!$)(?:(?:[-+]?\d+Y)|(?:[-+]?\d+[.,]\d+Y$))?(?:(?:[-+]?\d+M)|(?:[-+]?\d+[.,]\d+M$))?(?:(?:[-+]?\d+W)|(?:[-+]?\d+[.,]\d+W$))?(?:(?:[-+]?\d+D)|(?:[-+]?\d+[.,]\d+D$))?(?:T(?=[\d+-])(?:(?:[-+]?\d+H)|(?:[-+]?\d+[.,]\d+H$))?(?:(?:[-+]?\d+M)|(?:[-+]?\d+[.,]\d+M$))?(?:[-+]?\d+(?:[.,]\d+)?S)?)??$/;
  var guid = /^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$/;
  var uuid = (version2) => {
    if (!version2)
      return /^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$/;
    return new RegExp(`^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-${version2}[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})$`);
  };
  var uuid4 = /* @__PURE__ */ uuid(4);
  var uuid6 = /* @__PURE__ */ uuid(6);
  var uuid7 = /* @__PURE__ */ uuid(7);
  var email = /^(?!\.)(?!.*\.\.)([A-Za-z0-9_'+\-\.]*)[A-Za-z0-9_+-]@([A-Za-z0-9][A-Za-z0-9\-]*\.)+[A-Za-z]{2,}$/;
  var html5Email = /^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/;
  var rfc5322Email = /^(([^<>()\[\]\\.,;:\s@"]+(\.[^<>()\[\]\\.,;:\s@"]+)*)|(".+"))@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}])|(([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,}))$/;
  var unicodeEmail = /^[^\s@"]{1,64}@[^\s@]{1,255}$/u;
  var idnEmail = unicodeEmail;
  var browserEmail = /^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/;
  var _emoji = `^(\\p{Extended_Pictographic}|\\p{Emoji_Component})+$`;
  function emoji() {
    return new RegExp(_emoji, "u");
  }
  var ipv4 = /^(?:(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])$/;
  var ipv6 = /^(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:))$/;
  var mac = (delimiter) => {
    const escapedDelim = escapeRegex(delimiter ?? ":");
    return new RegExp(`^(?:[0-9A-F]{2}${escapedDelim}){5}[0-9A-F]{2}$|^(?:[0-9a-f]{2}${escapedDelim}){5}[0-9a-f]{2}$`);
  };
  var cidrv4 = /^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])\/([0-9]|[1-2][0-9]|3[0-2])$/;
  var cidrv6 = /^(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|::|([0-9a-fA-F]{1,4})?::([0-9a-fA-F]{1,4}:?){0,6})\/(12[0-8]|1[01][0-9]|[1-9]?[0-9])$/;
  var base64 = /^$|^(?:[0-9a-zA-Z+/]{4})*(?:(?:[0-9a-zA-Z+/]{2}==)|(?:[0-9a-zA-Z+/]{3}=))?$/;
  var base64url = /^[A-Za-z0-9_-]*$/;
  var hostname = /^(?=.{1,253}\.?$)[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[-0-9a-zA-Z]{0,61}[0-9a-zA-Z])?)*\.?$/;
  var domain = /^([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$/;
  var httpProtocol = /^https?$/;
  var e164 = /^\+[1-9]\d{6,14}$/;
  var dateSource = `(?:(?:\\d\\d[2468][048]|\\d\\d[13579][26]|\\d\\d0[48]|[02468][048]00|[13579][26]00)-02-29|\\d{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12]\\d|3[01])|(?:0[469]|11)-(?:0[1-9]|[12]\\d|30)|(?:02)-(?:0[1-9]|1\\d|2[0-8])))`;
  var date = /* @__PURE__ */ new RegExp(`^${dateSource}$`);
  function timeSource(args) {
    const hhmm = `(?:[01]\\d|2[0-3]):[0-5]\\d`;
    const regex = typeof args.precision === "number" ? args.precision === -1 ? `${hhmm}` : args.precision === 0 ? `${hhmm}:[0-5]\\d` : `${hhmm}:[0-5]\\d\\.\\d{${args.precision}}` : `${hhmm}(?::[0-5]\\d(?:\\.\\d+)?)?`;
    return regex;
  }
  function time(args) {
    return new RegExp(`^${timeSource(args)}$`);
  }
  function datetime(args) {
    const time3 = timeSource({ precision: args.precision });
    const opts = ["Z"];
    if (args.local)
      opts.push("");
    if (args.offset)
      opts.push(`([+-](?:[01]\\d|2[0-3]):[0-5]\\d)`);
    const timeRegex = `${time3}(?:${opts.join("|")})`;
    return new RegExp(`^${dateSource}T(?:${timeRegex})$`);
  }
  var string = (params) => {
    const regex = params ? `[\\s\\S]{${params?.minimum ?? 0},${params?.maximum ?? ""}}` : `[\\s\\S]*`;
    return new RegExp(`^${regex}$`);
  };
  var bigint = /^-?\d+n?$/;
  var integer = /^-?\d+$/;
  var number = /^-?\d+(?:\.\d+)?$/;
  var boolean = /^(?:true|false)$/i;
  var _null = /^null$/i;
  var _undefined = /^undefined$/i;
  var lowercase = /^[^A-Z]*$/;
  var uppercase = /^[^a-z]*$/;
  var hex = /^[0-9a-fA-F]*$/;
  function fixedBase64(bodyLength, padding) {
    return new RegExp(`^[A-Za-z0-9+/]{${bodyLength}}${padding}$`);
  }
  function fixedBase64url(length) {
    return new RegExp(`^[A-Za-z0-9_-]{${length}}$`);
  }
  var md5_hex = /^[0-9a-fA-F]{32}$/;
  var md5_base64 = /* @__PURE__ */ fixedBase64(22, "==");
  var md5_base64url = /* @__PURE__ */ fixedBase64url(22);
  var sha1_hex = /^[0-9a-fA-F]{40}$/;
  var sha1_base64 = /* @__PURE__ */ fixedBase64(27, "=");
  var sha1_base64url = /* @__PURE__ */ fixedBase64url(27);
  var sha256_hex = /^[0-9a-fA-F]{64}$/;
  var sha256_base64 = /* @__PURE__ */ fixedBase64(43, "=");
  var sha256_base64url = /* @__PURE__ */ fixedBase64url(43);
  var sha384_hex = /^[0-9a-fA-F]{96}$/;
  var sha384_base64 = /* @__PURE__ */ fixedBase64(64, "");
  var sha384_base64url = /* @__PURE__ */ fixedBase64url(64);
  var sha512_hex = /^[0-9a-fA-F]{128}$/;
  var sha512_base64 = /* @__PURE__ */ fixedBase64(86, "==");
  var sha512_base64url = /* @__PURE__ */ fixedBase64url(86);

  // ThirdParty/REA/dependencies/zod/v4/core/checks.js
  var $ZodCheck = /* @__PURE__ */ $constructor("$ZodCheck", (inst, def) => {
    var _a3;
    inst._zod ?? (inst._zod = {});
    inst._zod.def = def;
    (_a3 = inst._zod).onattach ?? (_a3.onattach = []);
  });
  var numericOriginMap = {
    number: "number",
    bigint: "bigint",
    object: "date"
  };
  var $ZodCheckLessThan = /* @__PURE__ */ $constructor("$ZodCheckLessThan", (inst, def) => {
    $ZodCheck.init(inst, def);
    const origin = numericOriginMap[typeof def.value];
    inst._zod.onattach.push((inst2) => {
      const bag = inst2._zod.bag;
      const curr = (def.inclusive ? bag.maximum : bag.exclusiveMaximum) ?? Number.POSITIVE_INFINITY;
      if (def.value < curr) {
        if (def.inclusive)
          bag.maximum = def.value;
        else
          bag.exclusiveMaximum = def.value;
      }
    });
    inst._zod.check = (payload) => {
      if (def.inclusive ? payload.value <= def.value : payload.value < def.value) {
        return;
      }
      payload.issues.push({
        origin,
        code: "too_big",
        maximum: typeof def.value === "object" ? def.value.getTime() : def.value,
        input: payload.value,
        inclusive: def.inclusive,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCheckGreaterThan = /* @__PURE__ */ $constructor("$ZodCheckGreaterThan", (inst, def) => {
    $ZodCheck.init(inst, def);
    const origin = numericOriginMap[typeof def.value];
    inst._zod.onattach.push((inst2) => {
      const bag = inst2._zod.bag;
      const curr = (def.inclusive ? bag.minimum : bag.exclusiveMinimum) ?? Number.NEGATIVE_INFINITY;
      if (def.value > curr) {
        if (def.inclusive)
          bag.minimum = def.value;
        else
          bag.exclusiveMinimum = def.value;
      }
    });
    inst._zod.check = (payload) => {
      if (def.inclusive ? payload.value >= def.value : payload.value > def.value) {
        return;
      }
      payload.issues.push({
        origin,
        code: "too_small",
        minimum: typeof def.value === "object" ? def.value.getTime() : def.value,
        input: payload.value,
        inclusive: def.inclusive,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCheckMultipleOf = /* @__PURE__ */ $constructor("$ZodCheckMultipleOf", (inst, def) => {
    $ZodCheck.init(inst, def);
    inst._zod.onattach.push((inst2) => {
      var _a3;
      (_a3 = inst2._zod.bag).multipleOf ?? (_a3.multipleOf = def.value);
    });
    inst._zod.check = (payload) => {
      if (typeof payload.value !== typeof def.value)
        throw new Error("Cannot mix number and bigint in multiple_of check.");
      const isMultiple = typeof payload.value === "bigint" ? payload.value % def.value === BigInt(0) : floatSafeRemainder(payload.value, def.value) === 0;
      if (isMultiple)
        return;
      payload.issues.push({
        origin: typeof payload.value,
        code: "not_multiple_of",
        divisor: def.value,
        input: payload.value,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCheckNumberFormat = /* @__PURE__ */ $constructor("$ZodCheckNumberFormat", (inst, def) => {
    $ZodCheck.init(inst, def);
    def.format = def.format || "float64";
    const isInt = def.format?.includes("int");
    const origin = isInt ? "int" : "number";
    const [minimum, maximum] = NUMBER_FORMAT_RANGES[def.format];
    inst._zod.onattach.push((inst2) => {
      const bag = inst2._zod.bag;
      bag.format = def.format;
      bag.minimum = minimum;
      bag.maximum = maximum;
      if (isInt)
        bag.pattern = integer;
    });
    inst._zod.check = (payload) => {
      const input = payload.value;
      if (isInt) {
        if (!Number.isInteger(input)) {
          payload.issues.push({
            expected: origin,
            format: def.format,
            code: "invalid_type",
            continue: false,
            input,
            inst
          });
          return;
        }
        if (!Number.isSafeInteger(input)) {
          if (input > 0) {
            payload.issues.push({
              input,
              code: "too_big",
              maximum: Number.MAX_SAFE_INTEGER,
              note: "Integers must be within the safe integer range.",
              inst,
              origin,
              inclusive: true,
              continue: !def.abort
            });
          } else {
            payload.issues.push({
              input,
              code: "too_small",
              minimum: Number.MIN_SAFE_INTEGER,
              note: "Integers must be within the safe integer range.",
              inst,
              origin,
              inclusive: true,
              continue: !def.abort
            });
          }
          return;
        }
      }
      if (input < minimum) {
        payload.issues.push({
          origin: "number",
          input,
          code: "too_small",
          minimum,
          inclusive: true,
          inst,
          continue: !def.abort
        });
      }
      if (input > maximum) {
        payload.issues.push({
          origin: "number",
          input,
          code: "too_big",
          maximum,
          inclusive: true,
          inst,
          continue: !def.abort
        });
      }
    };
  });
  var $ZodCheckBigIntFormat = /* @__PURE__ */ $constructor("$ZodCheckBigIntFormat", (inst, def) => {
    $ZodCheck.init(inst, def);
    const [minimum, maximum] = BIGINT_FORMAT_RANGES[def.format];
    inst._zod.onattach.push((inst2) => {
      const bag = inst2._zod.bag;
      bag.format = def.format;
      bag.minimum = minimum;
      bag.maximum = maximum;
    });
    inst._zod.check = (payload) => {
      const input = payload.value;
      if (input < minimum) {
        payload.issues.push({
          origin: "bigint",
          input,
          code: "too_small",
          minimum,
          inclusive: true,
          inst,
          continue: !def.abort
        });
      }
      if (input > maximum) {
        payload.issues.push({
          origin: "bigint",
          input,
          code: "too_big",
          maximum,
          inclusive: true,
          inst,
          continue: !def.abort
        });
      }
    };
  });
  var $ZodCheckMaxSize = /* @__PURE__ */ $constructor("$ZodCheckMaxSize", (inst, def) => {
    var _a3;
    $ZodCheck.init(inst, def);
    (_a3 = inst._zod.def).when ?? (_a3.when = (payload) => {
      const val = payload.value;
      return !nullish(val) && val.size !== void 0;
    });
    inst._zod.onattach.push((inst2) => {
      const curr = inst2._zod.bag.maximum ?? Number.POSITIVE_INFINITY;
      if (def.maximum < curr)
        inst2._zod.bag.maximum = def.maximum;
    });
    inst._zod.check = (payload) => {
      const input = payload.value;
      const size = input.size;
      if (size <= def.maximum)
        return;
      payload.issues.push({
        origin: getSizableOrigin(input),
        code: "too_big",
        maximum: def.maximum,
        inclusive: true,
        input,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCheckMinSize = /* @__PURE__ */ $constructor("$ZodCheckMinSize", (inst, def) => {
    var _a3;
    $ZodCheck.init(inst, def);
    (_a3 = inst._zod.def).when ?? (_a3.when = (payload) => {
      const val = payload.value;
      return !nullish(val) && val.size !== void 0;
    });
    inst._zod.onattach.push((inst2) => {
      const curr = inst2._zod.bag.minimum ?? Number.NEGATIVE_INFINITY;
      if (def.minimum > curr)
        inst2._zod.bag.minimum = def.minimum;
    });
    inst._zod.check = (payload) => {
      const input = payload.value;
      const size = input.size;
      if (size >= def.minimum)
        return;
      payload.issues.push({
        origin: getSizableOrigin(input),
        code: "too_small",
        minimum: def.minimum,
        inclusive: true,
        input,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCheckSizeEquals = /* @__PURE__ */ $constructor("$ZodCheckSizeEquals", (inst, def) => {
    var _a3;
    $ZodCheck.init(inst, def);
    (_a3 = inst._zod.def).when ?? (_a3.when = (payload) => {
      const val = payload.value;
      return !nullish(val) && val.size !== void 0;
    });
    inst._zod.onattach.push((inst2) => {
      const bag = inst2._zod.bag;
      bag.minimum = def.size;
      bag.maximum = def.size;
      bag.size = def.size;
    });
    inst._zod.check = (payload) => {
      const input = payload.value;
      const size = input.size;
      if (size === def.size)
        return;
      const tooBig = size > def.size;
      payload.issues.push({
        origin: getSizableOrigin(input),
        ...tooBig ? { code: "too_big", maximum: def.size } : { code: "too_small", minimum: def.size },
        inclusive: true,
        exact: true,
        input: payload.value,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCheckMaxLength = /* @__PURE__ */ $constructor("$ZodCheckMaxLength", (inst, def) => {
    var _a3;
    $ZodCheck.init(inst, def);
    (_a3 = inst._zod.def).when ?? (_a3.when = (payload) => {
      const val = payload.value;
      return !nullish(val) && val.length !== void 0;
    });
    inst._zod.onattach.push((inst2) => {
      const curr = inst2._zod.bag.maximum ?? Number.POSITIVE_INFINITY;
      if (def.maximum < curr)
        inst2._zod.bag.maximum = def.maximum;
    });
    inst._zod.check = (payload) => {
      const input = payload.value;
      const length = input.length;
      if (length <= def.maximum)
        return;
      const origin = getLengthableOrigin(input);
      payload.issues.push({
        origin,
        code: "too_big",
        maximum: def.maximum,
        inclusive: true,
        input,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCheckMinLength = /* @__PURE__ */ $constructor("$ZodCheckMinLength", (inst, def) => {
    var _a3;
    $ZodCheck.init(inst, def);
    (_a3 = inst._zod.def).when ?? (_a3.when = (payload) => {
      const val = payload.value;
      return !nullish(val) && val.length !== void 0;
    });
    inst._zod.onattach.push((inst2) => {
      const curr = inst2._zod.bag.minimum ?? Number.NEGATIVE_INFINITY;
      if (def.minimum > curr)
        inst2._zod.bag.minimum = def.minimum;
    });
    inst._zod.check = (payload) => {
      const input = payload.value;
      const length = input.length;
      if (length >= def.minimum)
        return;
      const origin = getLengthableOrigin(input);
      payload.issues.push({
        origin,
        code: "too_small",
        minimum: def.minimum,
        inclusive: true,
        input,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCheckLengthEquals = /* @__PURE__ */ $constructor("$ZodCheckLengthEquals", (inst, def) => {
    var _a3;
    $ZodCheck.init(inst, def);
    (_a3 = inst._zod.def).when ?? (_a3.when = (payload) => {
      const val = payload.value;
      return !nullish(val) && val.length !== void 0;
    });
    inst._zod.onattach.push((inst2) => {
      const bag = inst2._zod.bag;
      bag.minimum = def.length;
      bag.maximum = def.length;
      bag.length = def.length;
    });
    inst._zod.check = (payload) => {
      const input = payload.value;
      const length = input.length;
      if (length === def.length)
        return;
      const origin = getLengthableOrigin(input);
      const tooBig = length > def.length;
      payload.issues.push({
        origin,
        ...tooBig ? { code: "too_big", maximum: def.length } : { code: "too_small", minimum: def.length },
        inclusive: true,
        exact: true,
        input: payload.value,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCheckStringFormat = /* @__PURE__ */ $constructor("$ZodCheckStringFormat", (inst, def) => {
    var _a3, _b;
    $ZodCheck.init(inst, def);
    inst._zod.onattach.push((inst2) => {
      const bag = inst2._zod.bag;
      bag.format = def.format;
      if (def.pattern) {
        bag.patterns ?? (bag.patterns = /* @__PURE__ */ new Set());
        bag.patterns.add(def.pattern);
      }
    });
    if (def.pattern)
      (_a3 = inst._zod).check ?? (_a3.check = (payload) => {
        def.pattern.lastIndex = 0;
        if (def.pattern.test(payload.value))
          return;
        payload.issues.push({
          origin: "string",
          code: "invalid_format",
          format: def.format,
          input: payload.value,
          ...def.pattern ? { pattern: def.pattern.toString() } : {},
          inst,
          continue: !def.abort
        });
      });
    else
      (_b = inst._zod).check ?? (_b.check = () => {
      });
  });
  var $ZodCheckRegex = /* @__PURE__ */ $constructor("$ZodCheckRegex", (inst, def) => {
    $ZodCheckStringFormat.init(inst, def);
    inst._zod.check = (payload) => {
      def.pattern.lastIndex = 0;
      if (def.pattern.test(payload.value))
        return;
      payload.issues.push({
        origin: "string",
        code: "invalid_format",
        format: "regex",
        input: payload.value,
        pattern: def.pattern.toString(),
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCheckLowerCase = /* @__PURE__ */ $constructor("$ZodCheckLowerCase", (inst, def) => {
    def.pattern ?? (def.pattern = lowercase);
    $ZodCheckStringFormat.init(inst, def);
  });
  var $ZodCheckUpperCase = /* @__PURE__ */ $constructor("$ZodCheckUpperCase", (inst, def) => {
    def.pattern ?? (def.pattern = uppercase);
    $ZodCheckStringFormat.init(inst, def);
  });
  var $ZodCheckIncludes = /* @__PURE__ */ $constructor("$ZodCheckIncludes", (inst, def) => {
    $ZodCheck.init(inst, def);
    const escapedRegex = escapeRegex(def.includes);
    const pattern = new RegExp(typeof def.position === "number" ? `^.{${def.position}}${escapedRegex}` : escapedRegex);
    def.pattern = pattern;
    inst._zod.onattach.push((inst2) => {
      const bag = inst2._zod.bag;
      bag.patterns ?? (bag.patterns = /* @__PURE__ */ new Set());
      bag.patterns.add(pattern);
    });
    inst._zod.check = (payload) => {
      if (payload.value.includes(def.includes, def.position))
        return;
      payload.issues.push({
        origin: "string",
        code: "invalid_format",
        format: "includes",
        includes: def.includes,
        input: payload.value,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCheckStartsWith = /* @__PURE__ */ $constructor("$ZodCheckStartsWith", (inst, def) => {
    $ZodCheck.init(inst, def);
    const pattern = new RegExp(`^${escapeRegex(def.prefix)}.*`);
    def.pattern ?? (def.pattern = pattern);
    inst._zod.onattach.push((inst2) => {
      const bag = inst2._zod.bag;
      bag.patterns ?? (bag.patterns = /* @__PURE__ */ new Set());
      bag.patterns.add(pattern);
    });
    inst._zod.check = (payload) => {
      if (payload.value.startsWith(def.prefix))
        return;
      payload.issues.push({
        origin: "string",
        code: "invalid_format",
        format: "starts_with",
        prefix: def.prefix,
        input: payload.value,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCheckEndsWith = /* @__PURE__ */ $constructor("$ZodCheckEndsWith", (inst, def) => {
    $ZodCheck.init(inst, def);
    const pattern = new RegExp(`.*${escapeRegex(def.suffix)}$`);
    def.pattern ?? (def.pattern = pattern);
    inst._zod.onattach.push((inst2) => {
      const bag = inst2._zod.bag;
      bag.patterns ?? (bag.patterns = /* @__PURE__ */ new Set());
      bag.patterns.add(pattern);
    });
    inst._zod.check = (payload) => {
      if (payload.value.endsWith(def.suffix))
        return;
      payload.issues.push({
        origin: "string",
        code: "invalid_format",
        format: "ends_with",
        suffix: def.suffix,
        input: payload.value,
        inst,
        continue: !def.abort
      });
    };
  });
  function handleCheckPropertyResult(result, payload, property) {
    if (result.issues.length) {
      payload.issues.push(...prefixIssues(property, result.issues));
    }
  }
  var $ZodCheckProperty = /* @__PURE__ */ $constructor("$ZodCheckProperty", (inst, def) => {
    $ZodCheck.init(inst, def);
    inst._zod.check = (payload) => {
      const result = def.schema._zod.run({
        value: payload.value[def.property],
        issues: []
      }, {});
      if (result instanceof Promise) {
        return result.then((result2) => handleCheckPropertyResult(result2, payload, def.property));
      }
      handleCheckPropertyResult(result, payload, def.property);
      return;
    };
  });
  var $ZodCheckMimeType = /* @__PURE__ */ $constructor("$ZodCheckMimeType", (inst, def) => {
    $ZodCheck.init(inst, def);
    const mimeSet = new Set(def.mime);
    inst._zod.onattach.push((inst2) => {
      inst2._zod.bag.mime = def.mime;
    });
    inst._zod.check = (payload) => {
      if (mimeSet.has(payload.value.type))
        return;
      payload.issues.push({
        code: "invalid_value",
        values: def.mime,
        input: payload.value.type,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCheckOverwrite = /* @__PURE__ */ $constructor("$ZodCheckOverwrite", (inst, def) => {
    $ZodCheck.init(inst, def);
    inst._zod.check = (payload) => {
      payload.value = def.tx(payload.value);
    };
  });

  // ThirdParty/REA/dependencies/zod/v4/core/doc.js
  init_runtime();
  var Doc = class {
    constructor(args = []) {
      this.content = [];
      this.indent = 0;
      if (this)
        this.args = args;
    }
    indented(fn) {
      this.indent += 1;
      fn(this);
      this.indent -= 1;
    }
    write(arg) {
      if (typeof arg === "function") {
        arg(this, { execution: "sync" });
        arg(this, { execution: "async" });
        return;
      }
      const content = arg;
      const lines = content.split("\n").filter((x) => x);
      const minIndent = Math.min(...lines.map((x) => x.length - x.trimStart().length));
      const dedented = lines.map((x) => x.slice(minIndent)).map((x) => " ".repeat(this.indent * 2) + x);
      for (const line of dedented) {
        this.content.push(line);
      }
    }
    compile() {
      const F = Function;
      const args = this?.args;
      const content = this?.content ?? [``];
      const lines = [...content.map((x) => `  ${x}`)];
      return new F(...args, lines.join("\n"));
    }
  };

  // ThirdParty/REA/dependencies/zod/v4/core/versions.js
  init_runtime();
  var version = {
    major: 4,
    minor: 4,
    patch: 3
  };

  // ThirdParty/REA/dependencies/zod/v4/core/schemas.js
  var $ZodType = /* @__PURE__ */ $constructor("$ZodType", (inst, def) => {
    var _a3;
    inst ?? (inst = {});
    inst._zod.def = def;
    inst._zod.bag = inst._zod.bag || {};
    inst._zod.version = version;
    const checks = [...inst._zod.def.checks ?? []];
    if (inst._zod.traits.has("$ZodCheck")) {
      checks.unshift(inst);
    }
    for (const ch of checks) {
      for (const fn of ch._zod.onattach) {
        fn(inst);
      }
    }
    if (checks.length === 0) {
      (_a3 = inst._zod).deferred ?? (_a3.deferred = []);
      inst._zod.deferred?.push(() => {
        inst._zod.run = inst._zod.parse;
      });
    } else {
      const runChecks = (payload, checks2, ctx) => {
        let isAborted = aborted(payload);
        let asyncResult;
        for (const ch of checks2) {
          if (ch._zod.def.when) {
            if (explicitlyAborted(payload))
              continue;
            const shouldRun = ch._zod.def.when(payload);
            if (!shouldRun)
              continue;
          } else if (isAborted) {
            continue;
          }
          const currLen = payload.issues.length;
          const _ = ch._zod.check(payload);
          if (_ instanceof Promise && ctx?.async === false) {
            throw new $ZodAsyncError();
          }
          if (asyncResult || _ instanceof Promise) {
            asyncResult = (asyncResult ?? Promise.resolve()).then(async () => {
              await _;
              const nextLen = payload.issues.length;
              if (nextLen === currLen)
                return;
              if (!isAborted)
                isAborted = aborted(payload, currLen);
            });
          } else {
            const nextLen = payload.issues.length;
            if (nextLen === currLen)
              continue;
            if (!isAborted)
              isAborted = aborted(payload, currLen);
          }
        }
        if (asyncResult) {
          return asyncResult.then(() => {
            return payload;
          });
        }
        return payload;
      };
      const handleCanaryResult = (canary, payload, ctx) => {
        if (aborted(canary)) {
          canary.aborted = true;
          return canary;
        }
        const checkResult = runChecks(payload, checks, ctx);
        if (checkResult instanceof Promise) {
          if (ctx.async === false)
            throw new $ZodAsyncError();
          return checkResult.then((checkResult2) => inst._zod.parse(checkResult2, ctx));
        }
        return inst._zod.parse(checkResult, ctx);
      };
      inst._zod.run = (payload, ctx) => {
        if (ctx.skipChecks) {
          return inst._zod.parse(payload, ctx);
        }
        if (ctx.direction === "backward") {
          const canary = inst._zod.parse({ value: payload.value, issues: [] }, { ...ctx, skipChecks: true });
          if (canary instanceof Promise) {
            return canary.then((canary2) => {
              return handleCanaryResult(canary2, payload, ctx);
            });
          }
          return handleCanaryResult(canary, payload, ctx);
        }
        const result = inst._zod.parse(payload, ctx);
        if (result instanceof Promise) {
          if (ctx.async === false)
            throw new $ZodAsyncError();
          return result.then((result2) => runChecks(result2, checks, ctx));
        }
        return runChecks(result, checks, ctx);
      };
    }
    defineLazy(inst, "~standard", () => ({
      validate: (value) => {
        try {
          const r = safeParse(inst, value);
          return r.success ? { value: r.data } : { issues: r.error?.issues };
        } catch (_) {
          return safeParseAsync(inst, value).then((r) => r.success ? { value: r.data } : { issues: r.error?.issues });
        }
      },
      vendor: "zod",
      version: 1
    }));
  });
  var $ZodString = /* @__PURE__ */ $constructor("$ZodString", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.pattern = [...inst?._zod.bag?.patterns ?? []].pop() ?? string(inst._zod.bag);
    inst._zod.parse = (payload, _) => {
      if (def.coerce)
        try {
          payload.value = String(payload.value);
        } catch (_2) {
        }
      if (typeof payload.value === "string")
        return payload;
      payload.issues.push({
        expected: "string",
        code: "invalid_type",
        input: payload.value,
        inst
      });
      return payload;
    };
  });
  var $ZodStringFormat = /* @__PURE__ */ $constructor("$ZodStringFormat", (inst, def) => {
    $ZodCheckStringFormat.init(inst, def);
    $ZodString.init(inst, def);
  });
  var $ZodGUID = /* @__PURE__ */ $constructor("$ZodGUID", (inst, def) => {
    def.pattern ?? (def.pattern = guid);
    $ZodStringFormat.init(inst, def);
  });
  var $ZodUUID = /* @__PURE__ */ $constructor("$ZodUUID", (inst, def) => {
    if (def.version) {
      const versionMap = {
        v1: 1,
        v2: 2,
        v3: 3,
        v4: 4,
        v5: 5,
        v6: 6,
        v7: 7,
        v8: 8
      };
      const v = versionMap[def.version];
      if (v === void 0)
        throw new Error(`Invalid UUID version: "${def.version}"`);
      def.pattern ?? (def.pattern = uuid(v));
    } else
      def.pattern ?? (def.pattern = uuid());
    $ZodStringFormat.init(inst, def);
  });
  var $ZodEmail = /* @__PURE__ */ $constructor("$ZodEmail", (inst, def) => {
    def.pattern ?? (def.pattern = email);
    $ZodStringFormat.init(inst, def);
  });
  var $ZodURL = /* @__PURE__ */ $constructor("$ZodURL", (inst, def) => {
    $ZodStringFormat.init(inst, def);
    inst._zod.check = (payload) => {
      try {
        const trimmed = payload.value.trim();
        if (!def.normalize && def.protocol?.source === httpProtocol.source) {
          if (!/^https?:\/\//i.test(trimmed)) {
            payload.issues.push({
              code: "invalid_format",
              format: "url",
              note: "Invalid URL format",
              input: payload.value,
              inst,
              continue: !def.abort
            });
            return;
          }
        }
        const url2 = new URL(trimmed);
        if (def.hostname) {
          def.hostname.lastIndex = 0;
          if (!def.hostname.test(url2.hostname)) {
            payload.issues.push({
              code: "invalid_format",
              format: "url",
              note: "Invalid hostname",
              pattern: def.hostname.source,
              input: payload.value,
              inst,
              continue: !def.abort
            });
          }
        }
        if (def.protocol) {
          def.protocol.lastIndex = 0;
          if (!def.protocol.test(url2.protocol.endsWith(":") ? url2.protocol.slice(0, -1) : url2.protocol)) {
            payload.issues.push({
              code: "invalid_format",
              format: "url",
              note: "Invalid protocol",
              pattern: def.protocol.source,
              input: payload.value,
              inst,
              continue: !def.abort
            });
          }
        }
        if (def.normalize) {
          payload.value = url2.href;
        } else {
          payload.value = trimmed;
        }
        return;
      } catch (_) {
        payload.issues.push({
          code: "invalid_format",
          format: "url",
          input: payload.value,
          inst,
          continue: !def.abort
        });
      }
    };
  });
  var $ZodEmoji = /* @__PURE__ */ $constructor("$ZodEmoji", (inst, def) => {
    def.pattern ?? (def.pattern = emoji());
    $ZodStringFormat.init(inst, def);
  });
  var $ZodNanoID = /* @__PURE__ */ $constructor("$ZodNanoID", (inst, def) => {
    def.pattern ?? (def.pattern = nanoid);
    $ZodStringFormat.init(inst, def);
  });
  var $ZodCUID = /* @__PURE__ */ $constructor("$ZodCUID", (inst, def) => {
    def.pattern ?? (def.pattern = cuid);
    $ZodStringFormat.init(inst, def);
  });
  var $ZodCUID2 = /* @__PURE__ */ $constructor("$ZodCUID2", (inst, def) => {
    def.pattern ?? (def.pattern = cuid2);
    $ZodStringFormat.init(inst, def);
  });
  var $ZodULID = /* @__PURE__ */ $constructor("$ZodULID", (inst, def) => {
    def.pattern ?? (def.pattern = ulid);
    $ZodStringFormat.init(inst, def);
  });
  var $ZodXID = /* @__PURE__ */ $constructor("$ZodXID", (inst, def) => {
    def.pattern ?? (def.pattern = xid);
    $ZodStringFormat.init(inst, def);
  });
  var $ZodKSUID = /* @__PURE__ */ $constructor("$ZodKSUID", (inst, def) => {
    def.pattern ?? (def.pattern = ksuid);
    $ZodStringFormat.init(inst, def);
  });
  var $ZodISODateTime = /* @__PURE__ */ $constructor("$ZodISODateTime", (inst, def) => {
    def.pattern ?? (def.pattern = datetime(def));
    $ZodStringFormat.init(inst, def);
  });
  var $ZodISODate = /* @__PURE__ */ $constructor("$ZodISODate", (inst, def) => {
    def.pattern ?? (def.pattern = date);
    $ZodStringFormat.init(inst, def);
  });
  var $ZodISOTime = /* @__PURE__ */ $constructor("$ZodISOTime", (inst, def) => {
    def.pattern ?? (def.pattern = time(def));
    $ZodStringFormat.init(inst, def);
  });
  var $ZodISODuration = /* @__PURE__ */ $constructor("$ZodISODuration", (inst, def) => {
    def.pattern ?? (def.pattern = duration);
    $ZodStringFormat.init(inst, def);
  });
  var $ZodIPv4 = /* @__PURE__ */ $constructor("$ZodIPv4", (inst, def) => {
    def.pattern ?? (def.pattern = ipv4);
    $ZodStringFormat.init(inst, def);
    inst._zod.bag.format = `ipv4`;
  });
  var $ZodIPv6 = /* @__PURE__ */ $constructor("$ZodIPv6", (inst, def) => {
    def.pattern ?? (def.pattern = ipv6);
    $ZodStringFormat.init(inst, def);
    inst._zod.bag.format = `ipv6`;
    inst._zod.check = (payload) => {
      try {
        new URL(`http://[${payload.value}]`);
      } catch {
        payload.issues.push({
          code: "invalid_format",
          format: "ipv6",
          input: payload.value,
          inst,
          continue: !def.abort
        });
      }
    };
  });
  var $ZodMAC = /* @__PURE__ */ $constructor("$ZodMAC", (inst, def) => {
    def.pattern ?? (def.pattern = mac(def.delimiter));
    $ZodStringFormat.init(inst, def);
    inst._zod.bag.format = `mac`;
  });
  var $ZodCIDRv4 = /* @__PURE__ */ $constructor("$ZodCIDRv4", (inst, def) => {
    def.pattern ?? (def.pattern = cidrv4);
    $ZodStringFormat.init(inst, def);
  });
  var $ZodCIDRv6 = /* @__PURE__ */ $constructor("$ZodCIDRv6", (inst, def) => {
    def.pattern ?? (def.pattern = cidrv6);
    $ZodStringFormat.init(inst, def);
    inst._zod.check = (payload) => {
      const parts = payload.value.split("/");
      try {
        if (parts.length !== 2)
          throw new Error();
        const [address, prefix] = parts;
        if (!prefix)
          throw new Error();
        const prefixNum = Number(prefix);
        if (`${prefixNum}` !== prefix)
          throw new Error();
        if (prefixNum < 0 || prefixNum > 128)
          throw new Error();
        new URL(`http://[${address}]`);
      } catch {
        payload.issues.push({
          code: "invalid_format",
          format: "cidrv6",
          input: payload.value,
          inst,
          continue: !def.abort
        });
      }
    };
  });
  function isValidBase64(data) {
    if (data === "")
      return true;
    if (/\s/.test(data))
      return false;
    if (data.length % 4 !== 0)
      return false;
    try {
      atob(data);
      return true;
    } catch {
      return false;
    }
  }
  var $ZodBase64 = /* @__PURE__ */ $constructor("$ZodBase64", (inst, def) => {
    def.pattern ?? (def.pattern = base64);
    $ZodStringFormat.init(inst, def);
    inst._zod.bag.contentEncoding = "base64";
    inst._zod.check = (payload) => {
      if (isValidBase64(payload.value))
        return;
      payload.issues.push({
        code: "invalid_format",
        format: "base64",
        input: payload.value,
        inst,
        continue: !def.abort
      });
    };
  });
  function isValidBase64URL(data) {
    if (!base64url.test(data))
      return false;
    const base643 = data.replace(/[-_]/g, (c) => c === "-" ? "+" : "/");
    const padded = base643.padEnd(Math.ceil(base643.length / 4) * 4, "=");
    return isValidBase64(padded);
  }
  var $ZodBase64URL = /* @__PURE__ */ $constructor("$ZodBase64URL", (inst, def) => {
    def.pattern ?? (def.pattern = base64url);
    $ZodStringFormat.init(inst, def);
    inst._zod.bag.contentEncoding = "base64url";
    inst._zod.check = (payload) => {
      if (isValidBase64URL(payload.value))
        return;
      payload.issues.push({
        code: "invalid_format",
        format: "base64url",
        input: payload.value,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodE164 = /* @__PURE__ */ $constructor("$ZodE164", (inst, def) => {
    def.pattern ?? (def.pattern = e164);
    $ZodStringFormat.init(inst, def);
  });
  function isValidJWT(token, algorithm = null) {
    try {
      const tokensParts = token.split(".");
      if (tokensParts.length !== 3)
        return false;
      const [header] = tokensParts;
      if (!header)
        return false;
      const parsedHeader = JSON.parse(atob(header));
      if ("typ" in parsedHeader && parsedHeader?.typ !== "JWT")
        return false;
      if (!parsedHeader.alg)
        return false;
      if (algorithm && (!("alg" in parsedHeader) || parsedHeader.alg !== algorithm))
        return false;
      return true;
    } catch {
      return false;
    }
  }
  var $ZodJWT = /* @__PURE__ */ $constructor("$ZodJWT", (inst, def) => {
    $ZodStringFormat.init(inst, def);
    inst._zod.check = (payload) => {
      if (isValidJWT(payload.value, def.alg))
        return;
      payload.issues.push({
        code: "invalid_format",
        format: "jwt",
        input: payload.value,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodCustomStringFormat = /* @__PURE__ */ $constructor("$ZodCustomStringFormat", (inst, def) => {
    $ZodStringFormat.init(inst, def);
    inst._zod.check = (payload) => {
      if (def.fn(payload.value))
        return;
      payload.issues.push({
        code: "invalid_format",
        format: def.format,
        input: payload.value,
        inst,
        continue: !def.abort
      });
    };
  });
  var $ZodNumber = /* @__PURE__ */ $constructor("$ZodNumber", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.pattern = inst._zod.bag.pattern ?? number;
    inst._zod.parse = (payload, _ctx) => {
      if (def.coerce)
        try {
          payload.value = Number(payload.value);
        } catch (_) {
        }
      const input = payload.value;
      if (typeof input === "number" && !Number.isNaN(input) && Number.isFinite(input)) {
        return payload;
      }
      const received = typeof input === "number" ? Number.isNaN(input) ? "NaN" : !Number.isFinite(input) ? "Infinity" : void 0 : void 0;
      payload.issues.push({
        expected: "number",
        code: "invalid_type",
        input,
        inst,
        ...received ? { received } : {}
      });
      return payload;
    };
  });
  var $ZodNumberFormat = /* @__PURE__ */ $constructor("$ZodNumberFormat", (inst, def) => {
    $ZodCheckNumberFormat.init(inst, def);
    $ZodNumber.init(inst, def);
  });
  var $ZodBoolean = /* @__PURE__ */ $constructor("$ZodBoolean", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.pattern = boolean;
    inst._zod.parse = (payload, _ctx) => {
      if (def.coerce)
        try {
          payload.value = Boolean(payload.value);
        } catch (_) {
        }
      const input = payload.value;
      if (typeof input === "boolean")
        return payload;
      payload.issues.push({
        expected: "boolean",
        code: "invalid_type",
        input,
        inst
      });
      return payload;
    };
  });
  var $ZodBigInt = /* @__PURE__ */ $constructor("$ZodBigInt", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.pattern = bigint;
    inst._zod.parse = (payload, _ctx) => {
      if (def.coerce)
        try {
          payload.value = BigInt(payload.value);
        } catch (_) {
        }
      if (typeof payload.value === "bigint")
        return payload;
      payload.issues.push({
        expected: "bigint",
        code: "invalid_type",
        input: payload.value,
        inst
      });
      return payload;
    };
  });
  var $ZodBigIntFormat = /* @__PURE__ */ $constructor("$ZodBigIntFormat", (inst, def) => {
    $ZodCheckBigIntFormat.init(inst, def);
    $ZodBigInt.init(inst, def);
  });
  var $ZodSymbol = /* @__PURE__ */ $constructor("$ZodSymbol", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, _ctx) => {
      const input = payload.value;
      if (typeof input === "symbol")
        return payload;
      payload.issues.push({
        expected: "symbol",
        code: "invalid_type",
        input,
        inst
      });
      return payload;
    };
  });
  var $ZodUndefined = /* @__PURE__ */ $constructor("$ZodUndefined", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.pattern = _undefined;
    inst._zod.values = /* @__PURE__ */ new Set([void 0]);
    inst._zod.parse = (payload, _ctx) => {
      const input = payload.value;
      if (typeof input === "undefined")
        return payload;
      payload.issues.push({
        expected: "undefined",
        code: "invalid_type",
        input,
        inst
      });
      return payload;
    };
  });
  var $ZodNull = /* @__PURE__ */ $constructor("$ZodNull", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.pattern = _null;
    inst._zod.values = /* @__PURE__ */ new Set([null]);
    inst._zod.parse = (payload, _ctx) => {
      const input = payload.value;
      if (input === null)
        return payload;
      payload.issues.push({
        expected: "null",
        code: "invalid_type",
        input,
        inst
      });
      return payload;
    };
  });
  var $ZodAny = /* @__PURE__ */ $constructor("$ZodAny", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload) => payload;
  });
  var $ZodUnknown = /* @__PURE__ */ $constructor("$ZodUnknown", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload) => payload;
  });
  var $ZodNever = /* @__PURE__ */ $constructor("$ZodNever", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, _ctx) => {
      payload.issues.push({
        expected: "never",
        code: "invalid_type",
        input: payload.value,
        inst
      });
      return payload;
    };
  });
  var $ZodVoid = /* @__PURE__ */ $constructor("$ZodVoid", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, _ctx) => {
      const input = payload.value;
      if (typeof input === "undefined")
        return payload;
      payload.issues.push({
        expected: "void",
        code: "invalid_type",
        input,
        inst
      });
      return payload;
    };
  });
  var $ZodDate = /* @__PURE__ */ $constructor("$ZodDate", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, _ctx) => {
      if (def.coerce) {
        try {
          payload.value = new Date(payload.value);
        } catch (_err) {
        }
      }
      const input = payload.value;
      const isDate = input instanceof Date;
      const isValidDate = isDate && !Number.isNaN(input.getTime());
      if (isValidDate)
        return payload;
      payload.issues.push({
        expected: "date",
        code: "invalid_type",
        input,
        ...isDate ? { received: "Invalid Date" } : {},
        inst
      });
      return payload;
    };
  });
  function handleArrayResult(result, final, index) {
    if (result.issues.length) {
      final.issues.push(...prefixIssues(index, result.issues));
    }
    final.value[index] = result.value;
  }
  var $ZodArray = /* @__PURE__ */ $constructor("$ZodArray", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, ctx) => {
      const input = payload.value;
      if (!Array.isArray(input)) {
        payload.issues.push({
          expected: "array",
          code: "invalid_type",
          input,
          inst
        });
        return payload;
      }
      payload.value = Array(input.length);
      const proms = [];
      for (let i = 0; i < input.length; i++) {
        const item = input[i];
        const result = def.element._zod.run({
          value: item,
          issues: []
        }, ctx);
        if (result instanceof Promise) {
          proms.push(result.then((result2) => handleArrayResult(result2, payload, i)));
        } else {
          handleArrayResult(result, payload, i);
        }
      }
      if (proms.length) {
        return Promise.all(proms).then(() => payload);
      }
      return payload;
    };
  });
  function handlePropertyResult(result, final, key, input, isOptionalIn, isOptionalOut) {
    const isPresent = key in input;
    if (result.issues.length) {
      if (isOptionalIn && isOptionalOut && !isPresent) {
        return;
      }
      final.issues.push(...prefixIssues(key, result.issues));
    }
    if (!isPresent && !isOptionalIn) {
      if (!result.issues.length) {
        final.issues.push({
          code: "invalid_type",
          expected: "nonoptional",
          input: void 0,
          path: [key]
        });
      }
      return;
    }
    if (result.value === void 0) {
      if (isPresent) {
        final.value[key] = void 0;
      }
    } else {
      final.value[key] = result.value;
    }
  }
  function normalizeDef(def) {
    const keys = Object.keys(def.shape);
    for (const k of keys) {
      if (!def.shape?.[k]?._zod?.traits?.has("$ZodType")) {
        throw new Error(`Invalid element at key "${k}": expected a Zod schema`);
      }
    }
    const okeys = optionalKeys(def.shape);
    return {
      ...def,
      keys,
      keySet: new Set(keys),
      numKeys: keys.length,
      optionalKeys: new Set(okeys)
    };
  }
  function handleCatchall(proms, input, payload, ctx, def, inst) {
    const unrecognized = [];
    const keySet = def.keySet;
    const _catchall = def.catchall._zod;
    const t = _catchall.def.type;
    const isOptionalIn = _catchall.optin === "optional";
    const isOptionalOut = _catchall.optout === "optional";
    for (const key in input) {
      if (key === "__proto__")
        continue;
      if (keySet.has(key))
        continue;
      if (t === "never") {
        unrecognized.push(key);
        continue;
      }
      const r = _catchall.run({ value: input[key], issues: [] }, ctx);
      if (r instanceof Promise) {
        proms.push(r.then((r2) => handlePropertyResult(r2, payload, key, input, isOptionalIn, isOptionalOut)));
      } else {
        handlePropertyResult(r, payload, key, input, isOptionalIn, isOptionalOut);
      }
    }
    if (unrecognized.length) {
      payload.issues.push({
        code: "unrecognized_keys",
        keys: unrecognized,
        input,
        inst
      });
    }
    if (!proms.length)
      return payload;
    return Promise.all(proms).then(() => {
      return payload;
    });
  }
  var $ZodObject = /* @__PURE__ */ $constructor("$ZodObject", (inst, def) => {
    $ZodType.init(inst, def);
    const desc = Object.getOwnPropertyDescriptor(def, "shape");
    if (!desc?.get) {
      const sh = def.shape;
      Object.defineProperty(def, "shape", {
        get: () => {
          const newSh = { ...sh };
          Object.defineProperty(def, "shape", {
            value: newSh
          });
          return newSh;
        }
      });
    }
    const _normalized = cached(() => normalizeDef(def));
    defineLazy(inst._zod, "propValues", () => {
      const shape = def.shape;
      const propValues = {};
      for (const key in shape) {
        const field = shape[key]._zod;
        if (field.values) {
          propValues[key] ?? (propValues[key] = /* @__PURE__ */ new Set());
          for (const v of field.values)
            propValues[key].add(v);
        }
      }
      return propValues;
    });
    const isObject2 = isObject;
    const catchall = def.catchall;
    let value;
    inst._zod.parse = (payload, ctx) => {
      value ?? (value = _normalized.value);
      const input = payload.value;
      if (!isObject2(input)) {
        payload.issues.push({
          expected: "object",
          code: "invalid_type",
          input,
          inst
        });
        return payload;
      }
      payload.value = {};
      const proms = [];
      const shape = value.shape;
      for (const key of value.keys) {
        const el = shape[key];
        const isOptionalIn = el._zod.optin === "optional";
        const isOptionalOut = el._zod.optout === "optional";
        const r = el._zod.run({ value: input[key], issues: [] }, ctx);
        if (r instanceof Promise) {
          proms.push(r.then((r2) => handlePropertyResult(r2, payload, key, input, isOptionalIn, isOptionalOut)));
        } else {
          handlePropertyResult(r, payload, key, input, isOptionalIn, isOptionalOut);
        }
      }
      if (!catchall) {
        return proms.length ? Promise.all(proms).then(() => payload) : payload;
      }
      return handleCatchall(proms, input, payload, ctx, _normalized.value, inst);
    };
  });
  var $ZodObjectJIT = /* @__PURE__ */ $constructor("$ZodObjectJIT", (inst, def) => {
    $ZodObject.init(inst, def);
    const superParse = inst._zod.parse;
    const _normalized = cached(() => normalizeDef(def));
    const generateFastpass = (shape) => {
      const doc = new Doc(["shape", "payload", "ctx"]);
      const normalized = _normalized.value;
      const parseStr = (key) => {
        const k = esc(key);
        return `shape[${k}]._zod.run({ value: input[${k}], issues: [] }, ctx)`;
      };
      doc.write(`const input = payload.value;`);
      const ids = /* @__PURE__ */ Object.create(null);
      let counter = 0;
      for (const key of normalized.keys) {
        ids[key] = `key_${counter++}`;
      }
      doc.write(`const newResult = {};`);
      for (const key of normalized.keys) {
        const id = ids[key];
        const k = esc(key);
        const schema = shape[key];
        const isOptionalIn = schema?._zod?.optin === "optional";
        const isOptionalOut = schema?._zod?.optout === "optional";
        doc.write(`const ${id} = ${parseStr(key)};`);
        if (isOptionalIn && isOptionalOut) {
          doc.write(`
        if (${id}.issues.length) {
          if (${k} in input) {
            payload.issues = payload.issues.concat(${id}.issues.map(iss => ({
              ...iss,
              path: iss.path ? [${k}, ...iss.path] : [${k}]
            })));
          }
        }
        
        if (${id}.value === undefined) {
          if (${k} in input) {
            newResult[${k}] = undefined;
          }
        } else {
          newResult[${k}] = ${id}.value;
        }
        
      `);
        } else if (!isOptionalIn) {
          doc.write(`
        const ${id}_present = ${k} in input;
        if (${id}.issues.length) {
          payload.issues = payload.issues.concat(${id}.issues.map(iss => ({
            ...iss,
            path: iss.path ? [${k}, ...iss.path] : [${k}]
          })));
        }
        if (!${id}_present && !${id}.issues.length) {
          payload.issues.push({
            code: "invalid_type",
            expected: "nonoptional",
            input: undefined,
            path: [${k}]
          });
        }

        if (${id}_present) {
          if (${id}.value === undefined) {
            newResult[${k}] = undefined;
          } else {
            newResult[${k}] = ${id}.value;
          }
        }

      `);
        } else {
          doc.write(`
        if (${id}.issues.length) {
          payload.issues = payload.issues.concat(${id}.issues.map(iss => ({
            ...iss,
            path: iss.path ? [${k}, ...iss.path] : [${k}]
          })));
        }
        
        if (${id}.value === undefined) {
          if (${k} in input) {
            newResult[${k}] = undefined;
          }
        } else {
          newResult[${k}] = ${id}.value;
        }
        
      `);
        }
      }
      doc.write(`payload.value = newResult;`);
      doc.write(`return payload;`);
      const fn = doc.compile();
      return (payload, ctx) => fn(shape, payload, ctx);
    };
    let fastpass;
    const isObject2 = isObject;
    const jit = !globalConfig.jitless;
    const allowsEval2 = allowsEval;
    const fastEnabled = jit && allowsEval2.value;
    const catchall = def.catchall;
    let value;
    inst._zod.parse = (payload, ctx) => {
      value ?? (value = _normalized.value);
      const input = payload.value;
      if (!isObject2(input)) {
        payload.issues.push({
          expected: "object",
          code: "invalid_type",
          input,
          inst
        });
        return payload;
      }
      if (jit && fastEnabled && ctx?.async === false && ctx.jitless !== true) {
        if (!fastpass)
          fastpass = generateFastpass(def.shape);
        payload = fastpass(payload, ctx);
        if (!catchall)
          return payload;
        return handleCatchall([], input, payload, ctx, value, inst);
      }
      return superParse(payload, ctx);
    };
  });
  function handleUnionResults(results, final, inst, ctx) {
    for (const result of results) {
      if (result.issues.length === 0) {
        final.value = result.value;
        return final;
      }
    }
    const nonaborted = results.filter((r) => !aborted(r));
    if (nonaborted.length === 1) {
      final.value = nonaborted[0].value;
      return nonaborted[0];
    }
    final.issues.push({
      code: "invalid_union",
      input: final.value,
      inst,
      errors: results.map((result) => result.issues.map((iss) => finalizeIssue(iss, ctx, config())))
    });
    return final;
  }
  var $ZodUnion = /* @__PURE__ */ $constructor("$ZodUnion", (inst, def) => {
    $ZodType.init(inst, def);
    defineLazy(inst._zod, "optin", () => def.options.some((o) => o._zod.optin === "optional") ? "optional" : void 0);
    defineLazy(inst._zod, "optout", () => def.options.some((o) => o._zod.optout === "optional") ? "optional" : void 0);
    defineLazy(inst._zod, "values", () => {
      if (def.options.every((o) => o._zod.values)) {
        return new Set(def.options.flatMap((option) => Array.from(option._zod.values)));
      }
      return void 0;
    });
    defineLazy(inst._zod, "pattern", () => {
      if (def.options.every((o) => o._zod.pattern)) {
        const patterns = def.options.map((o) => o._zod.pattern);
        return new RegExp(`^(${patterns.map((p) => cleanRegex(p.source)).join("|")})$`);
      }
      return void 0;
    });
    const first = def.options.length === 1 ? def.options[0]._zod.run : null;
    inst._zod.parse = (payload, ctx) => {
      if (first) {
        return first(payload, ctx);
      }
      let async = false;
      const results = [];
      for (const option of def.options) {
        const result = option._zod.run({
          value: payload.value,
          issues: []
        }, ctx);
        if (result instanceof Promise) {
          results.push(result);
          async = true;
        } else {
          if (result.issues.length === 0)
            return result;
          results.push(result);
        }
      }
      if (!async)
        return handleUnionResults(results, payload, inst, ctx);
      return Promise.all(results).then((results2) => {
        return handleUnionResults(results2, payload, inst, ctx);
      });
    };
  });
  function handleExclusiveUnionResults(results, final, inst, ctx) {
    const successes = results.filter((r) => r.issues.length === 0);
    if (successes.length === 1) {
      final.value = successes[0].value;
      return final;
    }
    if (successes.length === 0) {
      final.issues.push({
        code: "invalid_union",
        input: final.value,
        inst,
        errors: results.map((result) => result.issues.map((iss) => finalizeIssue(iss, ctx, config())))
      });
    } else {
      final.issues.push({
        code: "invalid_union",
        input: final.value,
        inst,
        errors: [],
        inclusive: false
      });
    }
    return final;
  }
  var $ZodXor = /* @__PURE__ */ $constructor("$ZodXor", (inst, def) => {
    $ZodUnion.init(inst, def);
    def.inclusive = false;
    const first = def.options.length === 1 ? def.options[0]._zod.run : null;
    inst._zod.parse = (payload, ctx) => {
      if (first) {
        return first(payload, ctx);
      }
      let async = false;
      const results = [];
      for (const option of def.options) {
        const result = option._zod.run({
          value: payload.value,
          issues: []
        }, ctx);
        if (result instanceof Promise) {
          results.push(result);
          async = true;
        } else {
          results.push(result);
        }
      }
      if (!async)
        return handleExclusiveUnionResults(results, payload, inst, ctx);
      return Promise.all(results).then((results2) => {
        return handleExclusiveUnionResults(results2, payload, inst, ctx);
      });
    };
  });
  var $ZodDiscriminatedUnion = /* @__PURE__ */ $constructor("$ZodDiscriminatedUnion", (inst, def) => {
    def.inclusive = false;
    $ZodUnion.init(inst, def);
    const _super = inst._zod.parse;
    defineLazy(inst._zod, "propValues", () => {
      const propValues = {};
      for (const option of def.options) {
        const pv = option._zod.propValues;
        if (!pv || Object.keys(pv).length === 0)
          throw new Error(`Invalid discriminated union option at index "${def.options.indexOf(option)}"`);
        for (const [k, v] of Object.entries(pv)) {
          if (!propValues[k])
            propValues[k] = /* @__PURE__ */ new Set();
          for (const val of v) {
            propValues[k].add(val);
          }
        }
      }
      return propValues;
    });
    const disc = cached(() => {
      const opts = def.options;
      const map2 = /* @__PURE__ */ new Map();
      for (const o of opts) {
        const values = o._zod.propValues?.[def.discriminator];
        if (!values || values.size === 0)
          throw new Error(`Invalid discriminated union option at index "${def.options.indexOf(o)}"`);
        for (const v of values) {
          if (map2.has(v)) {
            throw new Error(`Duplicate discriminator value "${String(v)}"`);
          }
          map2.set(v, o);
        }
      }
      return map2;
    });
    inst._zod.parse = (payload, ctx) => {
      const input = payload.value;
      if (!isObject(input)) {
        payload.issues.push({
          code: "invalid_type",
          expected: "object",
          input,
          inst
        });
        return payload;
      }
      const opt = disc.value.get(input?.[def.discriminator]);
      if (opt) {
        return opt._zod.run(payload, ctx);
      }
      if (def.unionFallback || ctx.direction === "backward") {
        return _super(payload, ctx);
      }
      payload.issues.push({
        code: "invalid_union",
        errors: [],
        note: "No matching discriminator",
        discriminator: def.discriminator,
        options: Array.from(disc.value.keys()),
        input,
        path: [def.discriminator],
        inst
      });
      return payload;
    };
  });
  var $ZodIntersection = /* @__PURE__ */ $constructor("$ZodIntersection", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, ctx) => {
      const input = payload.value;
      const left = def.left._zod.run({ value: input, issues: [] }, ctx);
      const right = def.right._zod.run({ value: input, issues: [] }, ctx);
      const async = left instanceof Promise || right instanceof Promise;
      if (async) {
        return Promise.all([left, right]).then(([left2, right2]) => {
          return handleIntersectionResults(payload, left2, right2);
        });
      }
      return handleIntersectionResults(payload, left, right);
    };
  });
  function mergeValues(a, b) {
    if (a === b) {
      return { valid: true, data: a };
    }
    if (a instanceof Date && b instanceof Date && +a === +b) {
      return { valid: true, data: a };
    }
    if (isPlainObject(a) && isPlainObject(b)) {
      const bKeys = Object.keys(b);
      const sharedKeys = Object.keys(a).filter((key) => bKeys.indexOf(key) !== -1);
      const newObj = { ...a, ...b };
      for (const key of sharedKeys) {
        const sharedValue = mergeValues(a[key], b[key]);
        if (!sharedValue.valid) {
          return {
            valid: false,
            mergeErrorPath: [key, ...sharedValue.mergeErrorPath]
          };
        }
        newObj[key] = sharedValue.data;
      }
      return { valid: true, data: newObj };
    }
    if (Array.isArray(a) && Array.isArray(b)) {
      if (a.length !== b.length) {
        return { valid: false, mergeErrorPath: [] };
      }
      const newArray = [];
      for (let index = 0; index < a.length; index++) {
        const itemA = a[index];
        const itemB = b[index];
        const sharedValue = mergeValues(itemA, itemB);
        if (!sharedValue.valid) {
          return {
            valid: false,
            mergeErrorPath: [index, ...sharedValue.mergeErrorPath]
          };
        }
        newArray.push(sharedValue.data);
      }
      return { valid: true, data: newArray };
    }
    return { valid: false, mergeErrorPath: [] };
  }
  function handleIntersectionResults(result, left, right) {
    const unrecKeys = /* @__PURE__ */ new Map();
    let unrecIssue;
    for (const iss of left.issues) {
      if (iss.code === "unrecognized_keys") {
        unrecIssue ?? (unrecIssue = iss);
        for (const k of iss.keys) {
          if (!unrecKeys.has(k))
            unrecKeys.set(k, {});
          unrecKeys.get(k).l = true;
        }
      } else {
        result.issues.push(iss);
      }
    }
    for (const iss of right.issues) {
      if (iss.code === "unrecognized_keys") {
        for (const k of iss.keys) {
          if (!unrecKeys.has(k))
            unrecKeys.set(k, {});
          unrecKeys.get(k).r = true;
        }
      } else {
        result.issues.push(iss);
      }
    }
    const bothKeys = [...unrecKeys].filter(([, f]) => f.l && f.r).map(([k]) => k);
    if (bothKeys.length && unrecIssue) {
      result.issues.push({ ...unrecIssue, keys: bothKeys });
    }
    if (aborted(result))
      return result;
    const merged = mergeValues(left.value, right.value);
    if (!merged.valid) {
      throw new Error(`Unmergable intersection. Error path: ${JSON.stringify(merged.mergeErrorPath)}`);
    }
    result.value = merged.data;
    return result;
  }
  var $ZodTuple = /* @__PURE__ */ $constructor("$ZodTuple", (inst, def) => {
    $ZodType.init(inst, def);
    const items = def.items;
    inst._zod.parse = (payload, ctx) => {
      const input = payload.value;
      if (!Array.isArray(input)) {
        payload.issues.push({
          input,
          inst,
          expected: "tuple",
          code: "invalid_type"
        });
        return payload;
      }
      payload.value = [];
      const proms = [];
      const optinStart = getTupleOptStart(items, "optin");
      const optoutStart = getTupleOptStart(items, "optout");
      if (!def.rest) {
        if (input.length < optinStart) {
          payload.issues.push({
            code: "too_small",
            minimum: optinStart,
            inclusive: true,
            input,
            inst,
            origin: "array"
          });
          return payload;
        }
        if (input.length > items.length) {
          payload.issues.push({
            code: "too_big",
            maximum: items.length,
            inclusive: true,
            input,
            inst,
            origin: "array"
          });
        }
      }
      const itemResults = new Array(items.length);
      for (let i = 0; i < items.length; i++) {
        const r = items[i]._zod.run({ value: input[i], issues: [] }, ctx);
        if (r instanceof Promise) {
          proms.push(r.then((rr) => {
            itemResults[i] = rr;
          }));
        } else {
          itemResults[i] = r;
        }
      }
      if (def.rest) {
        let i = items.length - 1;
        const rest = input.slice(items.length);
        for (const el of rest) {
          i++;
          const result = def.rest._zod.run({ value: el, issues: [] }, ctx);
          if (result instanceof Promise) {
            proms.push(result.then((r) => handleTupleResult(r, payload, i)));
          } else {
            handleTupleResult(result, payload, i);
          }
        }
      }
      if (proms.length) {
        return Promise.all(proms).then(() => handleTupleResults(itemResults, payload, items, input, optoutStart));
      }
      return handleTupleResults(itemResults, payload, items, input, optoutStart);
    };
  });
  function getTupleOptStart(items, key) {
    for (let i = items.length - 1; i >= 0; i--) {
      if (items[i]._zod[key] !== "optional")
        return i + 1;
    }
    return 0;
  }
  function handleTupleResult(result, final, index) {
    if (result.issues.length) {
      final.issues.push(...prefixIssues(index, result.issues));
    }
    final.value[index] = result.value;
  }
  function handleTupleResults(itemResults, final, items, input, optoutStart) {
    for (let i = 0; i < items.length; i++) {
      const r = itemResults[i];
      const isPresent = i < input.length;
      if (r.issues.length) {
        if (!isPresent && i >= optoutStart) {
          final.value.length = i;
          break;
        }
        final.issues.push(...prefixIssues(i, r.issues));
      }
      final.value[i] = r.value;
    }
    for (let i = final.value.length - 1; i >= input.length; i--) {
      if (items[i]._zod.optout === "optional" && final.value[i] === void 0) {
        final.value.length = i;
      } else {
        break;
      }
    }
    return final;
  }
  var $ZodRecord = /* @__PURE__ */ $constructor("$ZodRecord", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, ctx) => {
      const input = payload.value;
      if (!isPlainObject(input)) {
        payload.issues.push({
          expected: "record",
          code: "invalid_type",
          input,
          inst
        });
        return payload;
      }
      const proms = [];
      const values = def.keyType._zod.values;
      if (values) {
        payload.value = {};
        const recordKeys = /* @__PURE__ */ new Set();
        for (const key of values) {
          if (typeof key === "string" || typeof key === "number" || typeof key === "symbol") {
            recordKeys.add(typeof key === "number" ? key.toString() : key);
            const keyResult = def.keyType._zod.run({ value: key, issues: [] }, ctx);
            if (keyResult instanceof Promise) {
              throw new Error("Async schemas not supported in object keys currently");
            }
            if (keyResult.issues.length) {
              payload.issues.push({
                code: "invalid_key",
                origin: "record",
                issues: keyResult.issues.map((iss) => finalizeIssue(iss, ctx, config())),
                input: key,
                path: [key],
                inst
              });
              continue;
            }
            const outKey = keyResult.value;
            const result = def.valueType._zod.run({ value: input[key], issues: [] }, ctx);
            if (result instanceof Promise) {
              proms.push(result.then((result2) => {
                if (result2.issues.length) {
                  payload.issues.push(...prefixIssues(key, result2.issues));
                }
                payload.value[outKey] = result2.value;
              }));
            } else {
              if (result.issues.length) {
                payload.issues.push(...prefixIssues(key, result.issues));
              }
              payload.value[outKey] = result.value;
            }
          }
        }
        let unrecognized;
        for (const key in input) {
          if (!recordKeys.has(key)) {
            unrecognized = unrecognized ?? [];
            unrecognized.push(key);
          }
        }
        if (unrecognized && unrecognized.length > 0) {
          payload.issues.push({
            code: "unrecognized_keys",
            input,
            inst,
            keys: unrecognized
          });
        }
      } else {
        payload.value = {};
        for (const key of Reflect.ownKeys(input)) {
          if (key === "__proto__")
            continue;
          if (!Object.prototype.propertyIsEnumerable.call(input, key))
            continue;
          let keyResult = def.keyType._zod.run({ value: key, issues: [] }, ctx);
          if (keyResult instanceof Promise) {
            throw new Error("Async schemas not supported in object keys currently");
          }
          const checkNumericKey = typeof key === "string" && number.test(key) && keyResult.issues.length;
          if (checkNumericKey) {
            const retryResult = def.keyType._zod.run({ value: Number(key), issues: [] }, ctx);
            if (retryResult instanceof Promise) {
              throw new Error("Async schemas not supported in object keys currently");
            }
            if (retryResult.issues.length === 0) {
              keyResult = retryResult;
            }
          }
          if (keyResult.issues.length) {
            if (def.mode === "loose") {
              payload.value[key] = input[key];
            } else {
              payload.issues.push({
                code: "invalid_key",
                origin: "record",
                issues: keyResult.issues.map((iss) => finalizeIssue(iss, ctx, config())),
                input: key,
                path: [key],
                inst
              });
            }
            continue;
          }
          const result = def.valueType._zod.run({ value: input[key], issues: [] }, ctx);
          if (result instanceof Promise) {
            proms.push(result.then((result2) => {
              if (result2.issues.length) {
                payload.issues.push(...prefixIssues(key, result2.issues));
              }
              payload.value[keyResult.value] = result2.value;
            }));
          } else {
            if (result.issues.length) {
              payload.issues.push(...prefixIssues(key, result.issues));
            }
            payload.value[keyResult.value] = result.value;
          }
        }
      }
      if (proms.length) {
        return Promise.all(proms).then(() => payload);
      }
      return payload;
    };
  });
  var $ZodMap = /* @__PURE__ */ $constructor("$ZodMap", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, ctx) => {
      const input = payload.value;
      if (!(input instanceof Map)) {
        payload.issues.push({
          expected: "map",
          code: "invalid_type",
          input,
          inst
        });
        return payload;
      }
      const proms = [];
      payload.value = /* @__PURE__ */ new Map();
      for (const [key, value] of input) {
        const keyResult = def.keyType._zod.run({ value: key, issues: [] }, ctx);
        const valueResult = def.valueType._zod.run({ value, issues: [] }, ctx);
        if (keyResult instanceof Promise || valueResult instanceof Promise) {
          proms.push(Promise.all([keyResult, valueResult]).then(([keyResult2, valueResult2]) => {
            handleMapResult(keyResult2, valueResult2, payload, key, input, inst, ctx);
          }));
        } else {
          handleMapResult(keyResult, valueResult, payload, key, input, inst, ctx);
        }
      }
      if (proms.length)
        return Promise.all(proms).then(() => payload);
      return payload;
    };
  });
  function handleMapResult(keyResult, valueResult, final, key, input, inst, ctx) {
    if (keyResult.issues.length) {
      if (propertyKeyTypes.has(typeof key)) {
        final.issues.push(...prefixIssues(key, keyResult.issues));
      } else {
        final.issues.push({
          code: "invalid_key",
          origin: "map",
          input,
          inst,
          issues: keyResult.issues.map((iss) => finalizeIssue(iss, ctx, config()))
        });
      }
    }
    if (valueResult.issues.length) {
      if (propertyKeyTypes.has(typeof key)) {
        final.issues.push(...prefixIssues(key, valueResult.issues));
      } else {
        final.issues.push({
          origin: "map",
          code: "invalid_element",
          input,
          inst,
          key,
          issues: valueResult.issues.map((iss) => finalizeIssue(iss, ctx, config()))
        });
      }
    }
    final.value.set(keyResult.value, valueResult.value);
  }
  var $ZodSet = /* @__PURE__ */ $constructor("$ZodSet", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, ctx) => {
      const input = payload.value;
      if (!(input instanceof Set)) {
        payload.issues.push({
          input,
          inst,
          expected: "set",
          code: "invalid_type"
        });
        return payload;
      }
      const proms = [];
      payload.value = /* @__PURE__ */ new Set();
      for (const item of input) {
        const result = def.valueType._zod.run({ value: item, issues: [] }, ctx);
        if (result instanceof Promise) {
          proms.push(result.then((result2) => handleSetResult(result2, payload)));
        } else
          handleSetResult(result, payload);
      }
      if (proms.length)
        return Promise.all(proms).then(() => payload);
      return payload;
    };
  });
  function handleSetResult(result, final) {
    if (result.issues.length) {
      final.issues.push(...result.issues);
    }
    final.value.add(result.value);
  }
  var $ZodEnum = /* @__PURE__ */ $constructor("$ZodEnum", (inst, def) => {
    $ZodType.init(inst, def);
    const values = getEnumValues(def.entries);
    const valuesSet = new Set(values);
    inst._zod.values = valuesSet;
    inst._zod.pattern = new RegExp(`^(${values.filter((k) => propertyKeyTypes.has(typeof k)).map((o) => typeof o === "string" ? escapeRegex(o) : o.toString()).join("|")})$`);
    inst._zod.parse = (payload, _ctx) => {
      const input = payload.value;
      if (valuesSet.has(input)) {
        return payload;
      }
      payload.issues.push({
        code: "invalid_value",
        values,
        input,
        inst
      });
      return payload;
    };
  });
  var $ZodLiteral = /* @__PURE__ */ $constructor("$ZodLiteral", (inst, def) => {
    $ZodType.init(inst, def);
    if (def.values.length === 0) {
      throw new Error("Cannot create literal schema with no valid values");
    }
    const values = new Set(def.values);
    inst._zod.values = values;
    inst._zod.pattern = new RegExp(`^(${def.values.map((o) => typeof o === "string" ? escapeRegex(o) : o ? escapeRegex(o.toString()) : String(o)).join("|")})$`);
    inst._zod.parse = (payload, _ctx) => {
      const input = payload.value;
      if (values.has(input)) {
        return payload;
      }
      payload.issues.push({
        code: "invalid_value",
        values: def.values,
        input,
        inst
      });
      return payload;
    };
  });
  var $ZodFile = /* @__PURE__ */ $constructor("$ZodFile", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, _ctx) => {
      const input = payload.value;
      if (input instanceof File)
        return payload;
      payload.issues.push({
        expected: "file",
        code: "invalid_type",
        input,
        inst
      });
      return payload;
    };
  });
  var $ZodTransform = /* @__PURE__ */ $constructor("$ZodTransform", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.optin = "optional";
    inst._zod.parse = (payload, ctx) => {
      if (ctx.direction === "backward") {
        throw new $ZodEncodeError(inst.constructor.name);
      }
      const _out = def.transform(payload.value, payload);
      if (ctx.async) {
        const output = _out instanceof Promise ? _out : Promise.resolve(_out);
        return output.then((output2) => {
          payload.value = output2;
          payload.fallback = true;
          return payload;
        });
      }
      if (_out instanceof Promise) {
        throw new $ZodAsyncError();
      }
      payload.value = _out;
      payload.fallback = true;
      return payload;
    };
  });
  function handleOptionalResult(result, input) {
    if (input === void 0 && (result.issues.length || result.fallback)) {
      return { issues: [], value: void 0 };
    }
    return result;
  }
  var $ZodOptional = /* @__PURE__ */ $constructor("$ZodOptional", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.optin = "optional";
    inst._zod.optout = "optional";
    defineLazy(inst._zod, "values", () => {
      return def.innerType._zod.values ? /* @__PURE__ */ new Set([...def.innerType._zod.values, void 0]) : void 0;
    });
    defineLazy(inst._zod, "pattern", () => {
      const pattern = def.innerType._zod.pattern;
      return pattern ? new RegExp(`^(${cleanRegex(pattern.source)})?$`) : void 0;
    });
    inst._zod.parse = (payload, ctx) => {
      if (def.innerType._zod.optin === "optional") {
        const input = payload.value;
        const result = def.innerType._zod.run(payload, ctx);
        if (result instanceof Promise)
          return result.then((r) => handleOptionalResult(r, input));
        return handleOptionalResult(result, input);
      }
      if (payload.value === void 0) {
        return payload;
      }
      return def.innerType._zod.run(payload, ctx);
    };
  });
  var $ZodExactOptional = /* @__PURE__ */ $constructor("$ZodExactOptional", (inst, def) => {
    $ZodOptional.init(inst, def);
    defineLazy(inst._zod, "values", () => def.innerType._zod.values);
    defineLazy(inst._zod, "pattern", () => def.innerType._zod.pattern);
    inst._zod.parse = (payload, ctx) => {
      return def.innerType._zod.run(payload, ctx);
    };
  });
  var $ZodNullable = /* @__PURE__ */ $constructor("$ZodNullable", (inst, def) => {
    $ZodType.init(inst, def);
    defineLazy(inst._zod, "optin", () => def.innerType._zod.optin);
    defineLazy(inst._zod, "optout", () => def.innerType._zod.optout);
    defineLazy(inst._zod, "pattern", () => {
      const pattern = def.innerType._zod.pattern;
      return pattern ? new RegExp(`^(${cleanRegex(pattern.source)}|null)$`) : void 0;
    });
    defineLazy(inst._zod, "values", () => {
      return def.innerType._zod.values ? /* @__PURE__ */ new Set([...def.innerType._zod.values, null]) : void 0;
    });
    inst._zod.parse = (payload, ctx) => {
      if (payload.value === null)
        return payload;
      return def.innerType._zod.run(payload, ctx);
    };
  });
  var $ZodDefault = /* @__PURE__ */ $constructor("$ZodDefault", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.optin = "optional";
    defineLazy(inst._zod, "values", () => def.innerType._zod.values);
    inst._zod.parse = (payload, ctx) => {
      if (ctx.direction === "backward") {
        return def.innerType._zod.run(payload, ctx);
      }
      if (payload.value === void 0) {
        payload.value = def.defaultValue;
        return payload;
      }
      const result = def.innerType._zod.run(payload, ctx);
      if (result instanceof Promise) {
        return result.then((result2) => handleDefaultResult(result2, def));
      }
      return handleDefaultResult(result, def);
    };
  });
  function handleDefaultResult(payload, def) {
    if (payload.value === void 0) {
      payload.value = def.defaultValue;
    }
    return payload;
  }
  var $ZodPrefault = /* @__PURE__ */ $constructor("$ZodPrefault", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.optin = "optional";
    defineLazy(inst._zod, "values", () => def.innerType._zod.values);
    inst._zod.parse = (payload, ctx) => {
      if (ctx.direction === "backward") {
        return def.innerType._zod.run(payload, ctx);
      }
      if (payload.value === void 0) {
        payload.value = def.defaultValue;
      }
      return def.innerType._zod.run(payload, ctx);
    };
  });
  var $ZodNonOptional = /* @__PURE__ */ $constructor("$ZodNonOptional", (inst, def) => {
    $ZodType.init(inst, def);
    defineLazy(inst._zod, "values", () => {
      const v = def.innerType._zod.values;
      return v ? new Set([...v].filter((x) => x !== void 0)) : void 0;
    });
    inst._zod.parse = (payload, ctx) => {
      const result = def.innerType._zod.run(payload, ctx);
      if (result instanceof Promise) {
        return result.then((result2) => handleNonOptionalResult(result2, inst));
      }
      return handleNonOptionalResult(result, inst);
    };
  });
  function handleNonOptionalResult(payload, inst) {
    if (!payload.issues.length && payload.value === void 0) {
      payload.issues.push({
        code: "invalid_type",
        expected: "nonoptional",
        input: payload.value,
        inst
      });
    }
    return payload;
  }
  var $ZodSuccess = /* @__PURE__ */ $constructor("$ZodSuccess", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, ctx) => {
      if (ctx.direction === "backward") {
        throw new $ZodEncodeError("ZodSuccess");
      }
      const result = def.innerType._zod.run(payload, ctx);
      if (result instanceof Promise) {
        return result.then((result2) => {
          payload.value = result2.issues.length === 0;
          return payload;
        });
      }
      payload.value = result.issues.length === 0;
      return payload;
    };
  });
  var $ZodCatch = /* @__PURE__ */ $constructor("$ZodCatch", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.optin = "optional";
    defineLazy(inst._zod, "optout", () => def.innerType._zod.optout);
    defineLazy(inst._zod, "values", () => def.innerType._zod.values);
    inst._zod.parse = (payload, ctx) => {
      if (ctx.direction === "backward") {
        return def.innerType._zod.run(payload, ctx);
      }
      const result = def.innerType._zod.run(payload, ctx);
      if (result instanceof Promise) {
        return result.then((result2) => {
          payload.value = result2.value;
          if (result2.issues.length) {
            payload.value = def.catchValue({
              ...payload,
              error: {
                issues: result2.issues.map((iss) => finalizeIssue(iss, ctx, config()))
              },
              input: payload.value
            });
            payload.issues = [];
            payload.fallback = true;
          }
          return payload;
        });
      }
      payload.value = result.value;
      if (result.issues.length) {
        payload.value = def.catchValue({
          ...payload,
          error: {
            issues: result.issues.map((iss) => finalizeIssue(iss, ctx, config()))
          },
          input: payload.value
        });
        payload.issues = [];
        payload.fallback = true;
      }
      return payload;
    };
  });
  var $ZodNaN = /* @__PURE__ */ $constructor("$ZodNaN", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, _ctx) => {
      if (typeof payload.value !== "number" || !Number.isNaN(payload.value)) {
        payload.issues.push({
          input: payload.value,
          inst,
          expected: "nan",
          code: "invalid_type"
        });
        return payload;
      }
      return payload;
    };
  });
  var $ZodPipe = /* @__PURE__ */ $constructor("$ZodPipe", (inst, def) => {
    $ZodType.init(inst, def);
    defineLazy(inst._zod, "values", () => def.in._zod.values);
    defineLazy(inst._zod, "optin", () => def.in._zod.optin);
    defineLazy(inst._zod, "optout", () => def.out._zod.optout);
    defineLazy(inst._zod, "propValues", () => def.in._zod.propValues);
    inst._zod.parse = (payload, ctx) => {
      if (ctx.direction === "backward") {
        const right = def.out._zod.run(payload, ctx);
        if (right instanceof Promise) {
          return right.then((right2) => handlePipeResult(right2, def.in, ctx));
        }
        return handlePipeResult(right, def.in, ctx);
      }
      const left = def.in._zod.run(payload, ctx);
      if (left instanceof Promise) {
        return left.then((left2) => handlePipeResult(left2, def.out, ctx));
      }
      return handlePipeResult(left, def.out, ctx);
    };
  });
  function handlePipeResult(left, next, ctx) {
    if (left.issues.length) {
      left.aborted = true;
      return left;
    }
    return next._zod.run({ value: left.value, issues: left.issues, fallback: left.fallback }, ctx);
  }
  var $ZodCodec = /* @__PURE__ */ $constructor("$ZodCodec", (inst, def) => {
    $ZodType.init(inst, def);
    defineLazy(inst._zod, "values", () => def.in._zod.values);
    defineLazy(inst._zod, "optin", () => def.in._zod.optin);
    defineLazy(inst._zod, "optout", () => def.out._zod.optout);
    defineLazy(inst._zod, "propValues", () => def.in._zod.propValues);
    inst._zod.parse = (payload, ctx) => {
      const direction = ctx.direction || "forward";
      if (direction === "forward") {
        const left = def.in._zod.run(payload, ctx);
        if (left instanceof Promise) {
          return left.then((left2) => handleCodecAResult(left2, def, ctx));
        }
        return handleCodecAResult(left, def, ctx);
      } else {
        const right = def.out._zod.run(payload, ctx);
        if (right instanceof Promise) {
          return right.then((right2) => handleCodecAResult(right2, def, ctx));
        }
        return handleCodecAResult(right, def, ctx);
      }
    };
  });
  function handleCodecAResult(result, def, ctx) {
    if (result.issues.length) {
      result.aborted = true;
      return result;
    }
    const direction = ctx.direction || "forward";
    if (direction === "forward") {
      const transformed = def.transform(result.value, result);
      if (transformed instanceof Promise) {
        return transformed.then((value) => handleCodecTxResult(result, value, def.out, ctx));
      }
      return handleCodecTxResult(result, transformed, def.out, ctx);
    } else {
      const transformed = def.reverseTransform(result.value, result);
      if (transformed instanceof Promise) {
        return transformed.then((value) => handleCodecTxResult(result, value, def.in, ctx));
      }
      return handleCodecTxResult(result, transformed, def.in, ctx);
    }
  }
  function handleCodecTxResult(left, value, nextSchema, ctx) {
    if (left.issues.length) {
      left.aborted = true;
      return left;
    }
    return nextSchema._zod.run({ value, issues: left.issues }, ctx);
  }
  var $ZodPreprocess = /* @__PURE__ */ $constructor("$ZodPreprocess", (inst, def) => {
    $ZodPipe.init(inst, def);
  });
  var $ZodReadonly = /* @__PURE__ */ $constructor("$ZodReadonly", (inst, def) => {
    $ZodType.init(inst, def);
    defineLazy(inst._zod, "propValues", () => def.innerType._zod.propValues);
    defineLazy(inst._zod, "values", () => def.innerType._zod.values);
    defineLazy(inst._zod, "optin", () => def.innerType?._zod?.optin);
    defineLazy(inst._zod, "optout", () => def.innerType?._zod?.optout);
    inst._zod.parse = (payload, ctx) => {
      if (ctx.direction === "backward") {
        return def.innerType._zod.run(payload, ctx);
      }
      const result = def.innerType._zod.run(payload, ctx);
      if (result instanceof Promise) {
        return result.then(handleReadonlyResult);
      }
      return handleReadonlyResult(result);
    };
  });
  function handleReadonlyResult(payload) {
    payload.value = Object.freeze(payload.value);
    return payload;
  }
  var $ZodTemplateLiteral = /* @__PURE__ */ $constructor("$ZodTemplateLiteral", (inst, def) => {
    $ZodType.init(inst, def);
    const regexParts = [];
    for (const part of def.parts) {
      if (typeof part === "object" && part !== null) {
        if (!part._zod.pattern) {
          throw new Error(`Invalid template literal part, no pattern found: ${[...part._zod.traits].shift()}`);
        }
        const source2 = part._zod.pattern instanceof RegExp ? part._zod.pattern.source : part._zod.pattern;
        if (!source2)
          throw new Error(`Invalid template literal part: ${part._zod.traits}`);
        const start = source2.startsWith("^") ? 1 : 0;
        const end = source2.endsWith("$") ? source2.length - 1 : source2.length;
        regexParts.push(source2.slice(start, end));
      } else if (part === null || primitiveTypes.has(typeof part)) {
        regexParts.push(escapeRegex(`${part}`));
      } else {
        throw new Error(`Invalid template literal part: ${part}`);
      }
    }
    inst._zod.pattern = new RegExp(`^${regexParts.join("")}$`);
    inst._zod.parse = (payload, _ctx) => {
      if (typeof payload.value !== "string") {
        payload.issues.push({
          input: payload.value,
          inst,
          expected: "string",
          code: "invalid_type"
        });
        return payload;
      }
      inst._zod.pattern.lastIndex = 0;
      if (!inst._zod.pattern.test(payload.value)) {
        payload.issues.push({
          input: payload.value,
          inst,
          code: "invalid_format",
          format: def.format ?? "template_literal",
          pattern: inst._zod.pattern.source
        });
        return payload;
      }
      return payload;
    };
  });
  var $ZodFunction = /* @__PURE__ */ $constructor("$ZodFunction", (inst, def) => {
    $ZodType.init(inst, def);
    inst._def = def;
    inst._zod.def = def;
    inst.implement = (func) => {
      if (typeof func !== "function") {
        throw new Error("implement() must be called with a function");
      }
      return function(...args) {
        const parsedArgs = inst._def.input ? parse(inst._def.input, args) : args;
        const result = Reflect.apply(func, this, parsedArgs);
        if (inst._def.output) {
          return parse(inst._def.output, result);
        }
        return result;
      };
    };
    inst.implementAsync = (func) => {
      if (typeof func !== "function") {
        throw new Error("implementAsync() must be called with a function");
      }
      return async function(...args) {
        const parsedArgs = inst._def.input ? await parseAsync(inst._def.input, args) : args;
        const result = await Reflect.apply(func, this, parsedArgs);
        if (inst._def.output) {
          return await parseAsync(inst._def.output, result);
        }
        return result;
      };
    };
    inst._zod.parse = (payload, _ctx) => {
      if (typeof payload.value !== "function") {
        payload.issues.push({
          code: "invalid_type",
          expected: "function",
          input: payload.value,
          inst
        });
        return payload;
      }
      const hasPromiseOutput = inst._def.output && inst._def.output._zod.def.type === "promise";
      if (hasPromiseOutput) {
        payload.value = inst.implementAsync(payload.value);
      } else {
        payload.value = inst.implement(payload.value);
      }
      return payload;
    };
    inst.input = (...args) => {
      const F = inst.constructor;
      if (Array.isArray(args[0])) {
        return new F({
          type: "function",
          input: new $ZodTuple({
            type: "tuple",
            items: args[0],
            rest: args[1]
          }),
          output: inst._def.output
        });
      }
      return new F({
        type: "function",
        input: args[0],
        output: inst._def.output
      });
    };
    inst.output = (output) => {
      const F = inst.constructor;
      return new F({
        type: "function",
        input: inst._def.input,
        output
      });
    };
    return inst;
  });
  var $ZodPromise = /* @__PURE__ */ $constructor("$ZodPromise", (inst, def) => {
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, ctx) => {
      return Promise.resolve(payload.value).then((inner) => def.innerType._zod.run({ value: inner, issues: [] }, ctx));
    };
  });
  var $ZodLazy = /* @__PURE__ */ $constructor("$ZodLazy", (inst, def) => {
    $ZodType.init(inst, def);
    defineLazy(inst._zod, "innerType", () => {
      const d = def;
      if (!d._cachedInner)
        d._cachedInner = def.getter();
      return d._cachedInner;
    });
    defineLazy(inst._zod, "pattern", () => inst._zod.innerType?._zod?.pattern);
    defineLazy(inst._zod, "propValues", () => inst._zod.innerType?._zod?.propValues);
    defineLazy(inst._zod, "optin", () => inst._zod.innerType?._zod?.optin ?? void 0);
    defineLazy(inst._zod, "optout", () => inst._zod.innerType?._zod?.optout ?? void 0);
    inst._zod.parse = (payload, ctx) => {
      const inner = inst._zod.innerType;
      return inner._zod.run(payload, ctx);
    };
  });
  var $ZodCustom = /* @__PURE__ */ $constructor("$ZodCustom", (inst, def) => {
    $ZodCheck.init(inst, def);
    $ZodType.init(inst, def);
    inst._zod.parse = (payload, _) => {
      return payload;
    };
    inst._zod.check = (payload) => {
      const input = payload.value;
      const r = def.fn(input);
      if (r instanceof Promise) {
        return r.then((r2) => handleRefineResult(r2, payload, input, inst));
      }
      handleRefineResult(r, payload, input, inst);
      return;
    };
  });
  function handleRefineResult(result, payload, input, inst) {
    if (!result) {
      const _iss = {
        code: "custom",
        input,
        inst,
        // incorporates params.error into issue reporting
        path: [...inst._zod.def.path ?? []],
        // incorporates params.error into issue reporting
        continue: !inst._zod.def.abort
        // params: inst._zod.def.params,
      };
      if (inst._zod.def.params)
        _iss.params = inst._zod.def.params;
      payload.issues.push(issue(_iss));
    }
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/index.js
  var locales_exports = {};
  __export(locales_exports, {
    ar: () => ar_default,
    az: () => az_default,
    be: () => be_default,
    bg: () => bg_default,
    ca: () => ca_default,
    cs: () => cs_default,
    da: () => da_default,
    de: () => de_default,
    el: () => el_default,
    en: () => en_default,
    eo: () => eo_default,
    es: () => es_default,
    fa: () => fa_default,
    fi: () => fi_default,
    fr: () => fr_default,
    frCA: () => fr_CA_default,
    he: () => he_default,
    hr: () => hr_default,
    hu: () => hu_default,
    hy: () => hy_default,
    id: () => id_default,
    is: () => is_default,
    it: () => it_default,
    ja: () => ja_default,
    ka: () => ka_default,
    kh: () => kh_default,
    km: () => km_default,
    ko: () => ko_default,
    lt: () => lt_default,
    mk: () => mk_default,
    ms: () => ms_default,
    nl: () => nl_default,
    no: () => no_default,
    ota: () => ota_default,
    pl: () => pl_default,
    ps: () => ps_default,
    pt: () => pt_default,
    ro: () => ro_default,
    ru: () => ru_default,
    sl: () => sl_default,
    sv: () => sv_default,
    ta: () => ta_default,
    th: () => th_default,
    tr: () => tr_default,
    ua: () => ua_default,
    uk: () => uk_default,
    ur: () => ur_default,
    uz: () => uz_default,
    vi: () => vi_default,
    yo: () => yo_default,
    zhCN: () => zh_CN_default,
    zhTW: () => zh_TW_default
  });
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/locales/ar.js
  init_runtime();
  var error = () => {
    const Sizable = {
      string: { unit: "\u062D\u0631\u0641", verb: "\u0623\u0646 \u064A\u062D\u0648\u064A" },
      file: { unit: "\u0628\u0627\u064A\u062A", verb: "\u0623\u0646 \u064A\u062D\u0648\u064A" },
      array: { unit: "\u0639\u0646\u0635\u0631", verb: "\u0623\u0646 \u064A\u062D\u0648\u064A" },
      set: { unit: "\u0639\u0646\u0635\u0631", verb: "\u0623\u0646 \u064A\u062D\u0648\u064A" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u0645\u062F\u062E\u0644",
      email: "\u0628\u0631\u064A\u062F \u0625\u0644\u0643\u062A\u0631\u0648\u0646\u064A",
      url: "\u0631\u0627\u0628\u0637",
      emoji: "\u0625\u064A\u0645\u0648\u062C\u064A",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "\u062A\u0627\u0631\u064A\u062E \u0648\u0648\u0642\u062A \u0628\u0645\u0639\u064A\u0627\u0631 ISO",
      date: "\u062A\u0627\u0631\u064A\u062E \u0628\u0645\u0639\u064A\u0627\u0631 ISO",
      time: "\u0648\u0642\u062A \u0628\u0645\u0639\u064A\u0627\u0631 ISO",
      duration: "\u0645\u062F\u0629 \u0628\u0645\u0639\u064A\u0627\u0631 ISO",
      ipv4: "\u0639\u0646\u0648\u0627\u0646 IPv4",
      ipv6: "\u0639\u0646\u0648\u0627\u0646 IPv6",
      cidrv4: "\u0645\u062F\u0649 \u0639\u0646\u0627\u0648\u064A\u0646 \u0628\u0635\u064A\u063A\u0629 IPv4",
      cidrv6: "\u0645\u062F\u0649 \u0639\u0646\u0627\u0648\u064A\u0646 \u0628\u0635\u064A\u063A\u0629 IPv6",
      base64: "\u0646\u064E\u0635 \u0628\u062A\u0631\u0645\u064A\u0632 base64-encoded",
      base64url: "\u0646\u064E\u0635 \u0628\u062A\u0631\u0645\u064A\u0632 base64url-encoded",
      json_string: "\u0646\u064E\u0635 \u0639\u0644\u0649 \u0647\u064A\u0626\u0629 JSON",
      e164: "\u0631\u0642\u0645 \u0647\u0627\u062A\u0641 \u0628\u0645\u0639\u064A\u0627\u0631 E.164",
      jwt: "JWT",
      template_literal: "\u0645\u062F\u062E\u0644"
    };
    const TypeDictionary = {
      nan: "NaN"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u0645\u062F\u062E\u0644\u0627\u062A \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644\u0629: \u064A\u0641\u062A\u0631\u0636 \u0625\u062F\u062E\u0627\u0644 instanceof ${issue2.expected}\u060C \u0648\u0644\u0643\u0646 \u062A\u0645 \u0625\u062F\u062E\u0627\u0644 ${received}`;
          }
          return `\u0645\u062F\u062E\u0644\u0627\u062A \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644\u0629: \u064A\u0641\u062A\u0631\u0636 \u0625\u062F\u062E\u0627\u0644 ${expected}\u060C \u0648\u0644\u0643\u0646 \u062A\u0645 \u0625\u062F\u062E\u0627\u0644 ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u0645\u062F\u062E\u0644\u0627\u062A \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644\u0629: \u064A\u0641\u062A\u0631\u0636 \u0625\u062F\u062E\u0627\u0644 ${stringifyPrimitive(issue2.values[0])}`;
          return `\u0627\u062E\u062A\u064A\u0627\u0631 \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644: \u064A\u062A\u0648\u0642\u0639 \u0627\u0646\u062A\u0642\u0627\u0621 \u0623\u062D\u062F \u0647\u0630\u0647 \u0627\u0644\u062E\u064A\u0627\u0631\u0627\u062A: ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return ` \u0623\u0643\u0628\u0631 \u0645\u0646 \u0627\u0644\u0644\u0627\u0632\u0645: \u064A\u0641\u062A\u0631\u0636 \u0623\u0646 \u062A\u0643\u0648\u0646 ${issue2.origin ?? "\u0627\u0644\u0642\u064A\u0645\u0629"} ${adj} ${issue2.maximum.toString()} ${sizing.unit ?? "\u0639\u0646\u0635\u0631"}`;
          return `\u0623\u0643\u0628\u0631 \u0645\u0646 \u0627\u0644\u0644\u0627\u0632\u0645: \u064A\u0641\u062A\u0631\u0636 \u0623\u0646 \u062A\u0643\u0648\u0646 ${issue2.origin ?? "\u0627\u0644\u0642\u064A\u0645\u0629"} ${adj} ${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u0623\u0635\u063A\u0631 \u0645\u0646 \u0627\u0644\u0644\u0627\u0632\u0645: \u064A\u0641\u062A\u0631\u0636 \u0644\u0640 ${issue2.origin} \u0623\u0646 \u064A\u0643\u0648\u0646 ${adj} ${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `\u0623\u0635\u063A\u0631 \u0645\u0646 \u0627\u0644\u0644\u0627\u0632\u0645: \u064A\u0641\u062A\u0631\u0636 \u0644\u0640 ${issue2.origin} \u0623\u0646 \u064A\u0643\u0648\u0646 ${adj} ${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `\u0646\u064E\u0635 \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644: \u064A\u062C\u0628 \u0623\u0646 \u064A\u0628\u062F\u0623 \u0628\u0640 "${issue2.prefix}"`;
          if (_issue.format === "ends_with")
            return `\u0646\u064E\u0635 \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644: \u064A\u062C\u0628 \u0623\u0646 \u064A\u0646\u062A\u0647\u064A \u0628\u0640 "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `\u0646\u064E\u0635 \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644: \u064A\u062C\u0628 \u0623\u0646 \u064A\u062A\u0636\u0645\u0651\u064E\u0646 "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u0646\u064E\u0635 \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644: \u064A\u062C\u0628 \u0623\u0646 \u064A\u0637\u0627\u0628\u0642 \u0627\u0644\u0646\u0645\u0637 ${_issue.pattern}`;
          return `${FormatDictionary[_issue.format] ?? issue2.format} \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644`;
        }
        case "not_multiple_of":
          return `\u0631\u0642\u0645 \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644: \u064A\u062C\u0628 \u0623\u0646 \u064A\u0643\u0648\u0646 \u0645\u0646 \u0645\u0636\u0627\u0639\u0641\u0627\u062A ${issue2.divisor}`;
        case "unrecognized_keys":
          return `\u0645\u0639\u0631\u0641${issue2.keys.length > 1 ? "\u0627\u062A" : ""} \u063A\u0631\u064A\u0628${issue2.keys.length > 1 ? "\u0629" : ""}: ${joinValues(issue2.keys, "\u060C ")}`;
        case "invalid_key":
          return `\u0645\u0639\u0631\u0641 \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644 \u0641\u064A ${issue2.origin}`;
        case "invalid_union":
          return "\u0645\u062F\u062E\u0644 \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644";
        case "invalid_element":
          return `\u0645\u062F\u062E\u0644 \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644 \u0641\u064A ${issue2.origin}`;
        default:
          return "\u0645\u062F\u062E\u0644 \u063A\u064A\u0631 \u0645\u0642\u0628\u0648\u0644";
      }
    };
  };
  function ar_default() {
    return {
      localeError: error()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/az.js
  init_runtime();
  var error2 = () => {
    const Sizable = {
      string: { unit: "simvol", verb: "olmal\u0131d\u0131r" },
      file: { unit: "bayt", verb: "olmal\u0131d\u0131r" },
      array: { unit: "element", verb: "olmal\u0131d\u0131r" },
      set: { unit: "element", verb: "olmal\u0131d\u0131r" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "input",
      email: "email address",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO datetime",
      date: "ISO date",
      time: "ISO time",
      duration: "ISO duration",
      ipv4: "IPv4 address",
      ipv6: "IPv6 address",
      cidrv4: "IPv4 range",
      cidrv6: "IPv6 range",
      base64: "base64-encoded string",
      base64url: "base64url-encoded string",
      json_string: "JSON string",
      e164: "E.164 number",
      jwt: "JWT",
      template_literal: "input"
    };
    const TypeDictionary = {
      nan: "NaN"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Yanl\u0131\u015F d\u0259y\u0259r: g\xF6zl\u0259nil\u0259n instanceof ${issue2.expected}, daxil olan ${received}`;
          }
          return `Yanl\u0131\u015F d\u0259y\u0259r: g\xF6zl\u0259nil\u0259n ${expected}, daxil olan ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Yanl\u0131\u015F d\u0259y\u0259r: g\xF6zl\u0259nil\u0259n ${stringifyPrimitive(issue2.values[0])}`;
          return `Yanl\u0131\u015F se\xE7im: a\u015Fa\u011F\u0131dak\u0131lardan biri olmal\u0131d\u0131r: ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\xC7ox b\xF6y\xFCk: g\xF6zl\u0259nil\u0259n ${issue2.origin ?? "d\u0259y\u0259r"} ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "element"}`;
          return `\xC7ox b\xF6y\xFCk: g\xF6zl\u0259nil\u0259n ${issue2.origin ?? "d\u0259y\u0259r"} ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\xC7ox ki\xE7ik: g\xF6zl\u0259nil\u0259n ${issue2.origin} ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          return `\xC7ox ki\xE7ik: g\xF6zl\u0259nil\u0259n ${issue2.origin} ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Yanl\u0131\u015F m\u0259tn: "${_issue.prefix}" il\u0259 ba\u015Flamal\u0131d\u0131r`;
          if (_issue.format === "ends_with")
            return `Yanl\u0131\u015F m\u0259tn: "${_issue.suffix}" il\u0259 bitm\u0259lidir`;
          if (_issue.format === "includes")
            return `Yanl\u0131\u015F m\u0259tn: "${_issue.includes}" daxil olmal\u0131d\u0131r`;
          if (_issue.format === "regex")
            return `Yanl\u0131\u015F m\u0259tn: ${_issue.pattern} \u015Fablonuna uy\u011Fun olmal\u0131d\u0131r`;
          return `Yanl\u0131\u015F ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Yanl\u0131\u015F \u0259d\u0259d: ${issue2.divisor} il\u0259 b\xF6l\xFCn\u0259 bil\u0259n olmal\u0131d\u0131r`;
        case "unrecognized_keys":
          return `Tan\u0131nmayan a\xE7ar${issue2.keys.length > 1 ? "lar" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `${issue2.origin} daxilind\u0259 yanl\u0131\u015F a\xE7ar`;
        case "invalid_union":
          return "Yanl\u0131\u015F d\u0259y\u0259r";
        case "invalid_element":
          return `${issue2.origin} daxilind\u0259 yanl\u0131\u015F d\u0259y\u0259r`;
        default:
          return `Yanl\u0131\u015F d\u0259y\u0259r`;
      }
    };
  };
  function az_default() {
    return {
      localeError: error2()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/be.js
  init_runtime();
  function getBelarusianPlural(count, one, few, many) {
    const absCount = Math.abs(count);
    const lastDigit = absCount % 10;
    const lastTwoDigits = absCount % 100;
    if (lastTwoDigits >= 11 && lastTwoDigits <= 19) {
      return many;
    }
    if (lastDigit === 1) {
      return one;
    }
    if (lastDigit >= 2 && lastDigit <= 4) {
      return few;
    }
    return many;
  }
  var error3 = () => {
    const Sizable = {
      string: {
        unit: {
          one: "\u0441\u0456\u043C\u0432\u0430\u043B",
          few: "\u0441\u0456\u043C\u0432\u0430\u043B\u044B",
          many: "\u0441\u0456\u043C\u0432\u0430\u043B\u0430\u045E"
        },
        verb: "\u043C\u0435\u0446\u044C"
      },
      array: {
        unit: {
          one: "\u044D\u043B\u0435\u043C\u0435\u043D\u0442",
          few: "\u044D\u043B\u0435\u043C\u0435\u043D\u0442\u044B",
          many: "\u044D\u043B\u0435\u043C\u0435\u043D\u0442\u0430\u045E"
        },
        verb: "\u043C\u0435\u0446\u044C"
      },
      set: {
        unit: {
          one: "\u044D\u043B\u0435\u043C\u0435\u043D\u0442",
          few: "\u044D\u043B\u0435\u043C\u0435\u043D\u0442\u044B",
          many: "\u044D\u043B\u0435\u043C\u0435\u043D\u0442\u0430\u045E"
        },
        verb: "\u043C\u0435\u0446\u044C"
      },
      file: {
        unit: {
          one: "\u0431\u0430\u0439\u0442",
          few: "\u0431\u0430\u0439\u0442\u044B",
          many: "\u0431\u0430\u0439\u0442\u0430\u045E"
        },
        verb: "\u043C\u0435\u0446\u044C"
      }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u0443\u0432\u043E\u0434",
      email: "email \u0430\u0434\u0440\u0430\u0441",
      url: "URL",
      emoji: "\u044D\u043C\u043E\u0434\u0437\u0456",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO \u0434\u0430\u0442\u0430 \u0456 \u0447\u0430\u0441",
      date: "ISO \u0434\u0430\u0442\u0430",
      time: "ISO \u0447\u0430\u0441",
      duration: "ISO \u043F\u0440\u0430\u0446\u044F\u0433\u043B\u0430\u0441\u0446\u044C",
      ipv4: "IPv4 \u0430\u0434\u0440\u0430\u0441",
      ipv6: "IPv6 \u0430\u0434\u0440\u0430\u0441",
      cidrv4: "IPv4 \u0434\u044B\u044F\u043F\u0430\u0437\u043E\u043D",
      cidrv6: "IPv6 \u0434\u044B\u044F\u043F\u0430\u0437\u043E\u043D",
      base64: "\u0440\u0430\u0434\u043E\u043A \u0443 \u0444\u0430\u0440\u043C\u0430\u0446\u0435 base64",
      base64url: "\u0440\u0430\u0434\u043E\u043A \u0443 \u0444\u0430\u0440\u043C\u0430\u0446\u0435 base64url",
      json_string: "JSON \u0440\u0430\u0434\u043E\u043A",
      e164: "\u043D\u0443\u043C\u0430\u0440 E.164",
      jwt: "JWT",
      template_literal: "\u0443\u0432\u043E\u0434"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u043B\u0456\u043A",
      array: "\u043C\u0430\u0441\u0456\u045E"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u044B \u045E\u0432\u043E\u0434: \u0447\u0430\u043A\u0430\u045E\u0441\u044F instanceof ${issue2.expected}, \u0430\u0442\u0440\u044B\u043C\u0430\u043D\u0430 ${received}`;
          }
          return `\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u044B \u045E\u0432\u043E\u0434: \u0447\u0430\u043A\u0430\u045E\u0441\u044F ${expected}, \u0430\u0442\u0440\u044B\u043C\u0430\u043D\u0430 ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u044B \u045E\u0432\u043E\u0434: \u0447\u0430\u043A\u0430\u043B\u0430\u0441\u044F ${stringifyPrimitive(issue2.values[0])}`;
          return `\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u044B \u0432\u0430\u0440\u044B\u044F\u043D\u0442: \u0447\u0430\u043A\u0430\u045E\u0441\u044F \u0430\u0434\u0437\u0456\u043D \u0437 ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            const maxValue = Number(issue2.maximum);
            const unit = getBelarusianPlural(maxValue, sizing.unit.one, sizing.unit.few, sizing.unit.many);
            return `\u0417\u0430\u043D\u0430\u0434\u0442\u0430 \u0432\u044F\u043B\u0456\u043A\u0456: \u0447\u0430\u043A\u0430\u043B\u0430\u0441\u044F, \u0448\u0442\u043E ${issue2.origin ?? "\u0437\u043D\u0430\u0447\u044D\u043D\u043D\u0435"} \u043F\u0430\u0432\u0456\u043D\u043D\u0430 ${sizing.verb} ${adj}${issue2.maximum.toString()} ${unit}`;
          }
          return `\u0417\u0430\u043D\u0430\u0434\u0442\u0430 \u0432\u044F\u043B\u0456\u043A\u0456: \u0447\u0430\u043A\u0430\u043B\u0430\u0441\u044F, \u0448\u0442\u043E ${issue2.origin ?? "\u0437\u043D\u0430\u0447\u044D\u043D\u043D\u0435"} \u043F\u0430\u0432\u0456\u043D\u043D\u0430 \u0431\u044B\u0446\u044C ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            const minValue = Number(issue2.minimum);
            const unit = getBelarusianPlural(minValue, sizing.unit.one, sizing.unit.few, sizing.unit.many);
            return `\u0417\u0430\u043D\u0430\u0434\u0442\u0430 \u043C\u0430\u043B\u044B: \u0447\u0430\u043A\u0430\u043B\u0430\u0441\u044F, \u0448\u0442\u043E ${issue2.origin} \u043F\u0430\u0432\u0456\u043D\u043D\u0430 ${sizing.verb} ${adj}${issue2.minimum.toString()} ${unit}`;
          }
          return `\u0417\u0430\u043D\u0430\u0434\u0442\u0430 \u043C\u0430\u043B\u044B: \u0447\u0430\u043A\u0430\u043B\u0430\u0441\u044F, \u0448\u0442\u043E ${issue2.origin} \u043F\u0430\u0432\u0456\u043D\u043D\u0430 \u0431\u044B\u0446\u044C ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u044B \u0440\u0430\u0434\u043E\u043A: \u043F\u0430\u0432\u0456\u043D\u0435\u043D \u043F\u0430\u0447\u044B\u043D\u0430\u0446\u0446\u0430 \u0437 "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u044B \u0440\u0430\u0434\u043E\u043A: \u043F\u0430\u0432\u0456\u043D\u0435\u043D \u0437\u0430\u043A\u0430\u043D\u0447\u0432\u0430\u0446\u0446\u0430 \u043D\u0430 "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u044B \u0440\u0430\u0434\u043E\u043A: \u043F\u0430\u0432\u0456\u043D\u0435\u043D \u0437\u043C\u044F\u0448\u0447\u0430\u0446\u044C "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u044B \u0440\u0430\u0434\u043E\u043A: \u043F\u0430\u0432\u0456\u043D\u0435\u043D \u0430\u0434\u043F\u0430\u0432\u044F\u0434\u0430\u0446\u044C \u0448\u0430\u0431\u043B\u043E\u043D\u0443 ${_issue.pattern}`;
          return `\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u044B ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u044B \u043B\u0456\u043A: \u043F\u0430\u0432\u0456\u043D\u0435\u043D \u0431\u044B\u0446\u044C \u043A\u0440\u0430\u0442\u043D\u044B\u043C ${issue2.divisor}`;
        case "unrecognized_keys":
          return `\u041D\u0435\u0440\u0430\u0441\u043F\u0430\u0437\u043D\u0430\u043D\u044B ${issue2.keys.length > 1 ? "\u043A\u043B\u044E\u0447\u044B" : "\u043A\u043B\u044E\u0447"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u044B \u043A\u043B\u044E\u0447 \u0443 ${issue2.origin}`;
        case "invalid_union":
          return "\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u044B \u045E\u0432\u043E\u0434";
        case "invalid_element":
          return `\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u0430\u0435 \u0437\u043D\u0430\u0447\u044D\u043D\u043D\u0435 \u045E ${issue2.origin}`;
        default:
          return `\u041D\u044F\u043F\u0440\u0430\u0432\u0456\u043B\u044C\u043D\u044B \u045E\u0432\u043E\u0434`;
      }
    };
  };
  function be_default() {
    return {
      localeError: error3()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/bg.js
  init_runtime();
  var error4 = () => {
    const Sizable = {
      string: { unit: "\u0441\u0438\u043C\u0432\u043E\u043B\u0430", verb: "\u0434\u0430 \u0441\u044A\u0434\u044A\u0440\u0436\u0430" },
      file: { unit: "\u0431\u0430\u0439\u0442\u0430", verb: "\u0434\u0430 \u0441\u044A\u0434\u044A\u0440\u0436\u0430" },
      array: { unit: "\u0435\u043B\u0435\u043C\u0435\u043D\u0442\u0430", verb: "\u0434\u0430 \u0441\u044A\u0434\u044A\u0440\u0436\u0430" },
      set: { unit: "\u0435\u043B\u0435\u043C\u0435\u043D\u0442\u0430", verb: "\u0434\u0430 \u0441\u044A\u0434\u044A\u0440\u0436\u0430" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u0432\u0445\u043E\u0434",
      email: "\u0438\u043C\u0435\u0439\u043B \u0430\u0434\u0440\u0435\u0441",
      url: "URL",
      emoji: "\u0435\u043C\u043E\u0434\u0436\u0438",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO \u0432\u0440\u0435\u043C\u0435",
      date: "ISO \u0434\u0430\u0442\u0430",
      time: "ISO \u0432\u0440\u0435\u043C\u0435",
      duration: "ISO \u043F\u0440\u043E\u0434\u044A\u043B\u0436\u0438\u0442\u0435\u043B\u043D\u043E\u0441\u0442",
      ipv4: "IPv4 \u0430\u0434\u0440\u0435\u0441",
      ipv6: "IPv6 \u0430\u0434\u0440\u0435\u0441",
      cidrv4: "IPv4 \u0434\u0438\u0430\u043F\u0430\u0437\u043E\u043D",
      cidrv6: "IPv6 \u0434\u0438\u0430\u043F\u0430\u0437\u043E\u043D",
      base64: "base64-\u043A\u043E\u0434\u0438\u0440\u0430\u043D \u043D\u0438\u0437",
      base64url: "base64url-\u043A\u043E\u0434\u0438\u0440\u0430\u043D \u043D\u0438\u0437",
      json_string: "JSON \u043D\u0438\u0437",
      e164: "E.164 \u043D\u043E\u043C\u0435\u0440",
      jwt: "JWT",
      template_literal: "\u0432\u0445\u043E\u0434"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u0447\u0438\u0441\u043B\u043E",
      array: "\u043C\u0430\u0441\u0438\u0432"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u0435\u043D \u0432\u0445\u043E\u0434: \u043E\u0447\u0430\u043A\u0432\u0430\u043D instanceof ${issue2.expected}, \u043F\u043E\u043B\u0443\u0447\u0435\u043D ${received}`;
          }
          return `\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u0435\u043D \u0432\u0445\u043E\u0434: \u043E\u0447\u0430\u043A\u0432\u0430\u043D ${expected}, \u043F\u043E\u043B\u0443\u0447\u0435\u043D ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u0435\u043D \u0432\u0445\u043E\u0434: \u043E\u0447\u0430\u043A\u0432\u0430\u043D ${stringifyPrimitive(issue2.values[0])}`;
          return `\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u043D\u0430 \u043E\u043F\u0446\u0438\u044F: \u043E\u0447\u0430\u043A\u0432\u0430\u043D\u043E \u0435\u0434\u043D\u043E \u043E\u0442 ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\u0422\u0432\u044A\u0440\u0434\u0435 \u0433\u043E\u043B\u044F\u043C\u043E: \u043E\u0447\u0430\u043A\u0432\u0430 \u0441\u0435 ${issue2.origin ?? "\u0441\u0442\u043E\u0439\u043D\u043E\u0441\u0442"} \u0434\u0430 \u0441\u044A\u0434\u044A\u0440\u0436\u0430 ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "\u0435\u043B\u0435\u043C\u0435\u043D\u0442\u0430"}`;
          return `\u0422\u0432\u044A\u0440\u0434\u0435 \u0433\u043E\u043B\u044F\u043C\u043E: \u043E\u0447\u0430\u043A\u0432\u0430 \u0441\u0435 ${issue2.origin ?? "\u0441\u0442\u043E\u0439\u043D\u043E\u0441\u0442"} \u0434\u0430 \u0431\u044A\u0434\u0435 ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u0422\u0432\u044A\u0440\u0434\u0435 \u043C\u0430\u043B\u043A\u043E: \u043E\u0447\u0430\u043A\u0432\u0430 \u0441\u0435 ${issue2.origin} \u0434\u0430 \u0441\u044A\u0434\u044A\u0440\u0436\u0430 ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `\u0422\u0432\u044A\u0440\u0434\u0435 \u043C\u0430\u043B\u043A\u043E: \u043E\u0447\u0430\u043A\u0432\u0430 \u0441\u0435 ${issue2.origin} \u0434\u0430 \u0431\u044A\u0434\u0435 ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u0435\u043D \u043D\u0438\u0437: \u0442\u0440\u044F\u0431\u0432\u0430 \u0434\u0430 \u0437\u0430\u043F\u043E\u0447\u0432\u0430 \u0441 "${_issue.prefix}"`;
          }
          if (_issue.format === "ends_with")
            return `\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u0435\u043D \u043D\u0438\u0437: \u0442\u0440\u044F\u0431\u0432\u0430 \u0434\u0430 \u0437\u0430\u0432\u044A\u0440\u0448\u0432\u0430 \u0441 "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u0435\u043D \u043D\u0438\u0437: \u0442\u0440\u044F\u0431\u0432\u0430 \u0434\u0430 \u0432\u043A\u043B\u044E\u0447\u0432\u0430 "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u0435\u043D \u043D\u0438\u0437: \u0442\u0440\u044F\u0431\u0432\u0430 \u0434\u0430 \u0441\u044A\u0432\u043F\u0430\u0434\u0430 \u0441 ${_issue.pattern}`;
          let invalid_adj = "\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u0435\u043D";
          if (_issue.format === "emoji")
            invalid_adj = "\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u043D\u043E";
          if (_issue.format === "datetime")
            invalid_adj = "\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u043D\u043E";
          if (_issue.format === "date")
            invalid_adj = "\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u043D\u0430";
          if (_issue.format === "time")
            invalid_adj = "\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u043D\u043E";
          if (_issue.format === "duration")
            invalid_adj = "\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u043D\u0430";
          return `${invalid_adj} ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u043D\u043E \u0447\u0438\u0441\u043B\u043E: \u0442\u0440\u044F\u0431\u0432\u0430 \u0434\u0430 \u0431\u044A\u0434\u0435 \u043A\u0440\u0430\u0442\u043D\u043E \u043D\u0430 ${issue2.divisor}`;
        case "unrecognized_keys":
          return `\u041D\u0435\u0440\u0430\u0437\u043F\u043E\u0437\u043D\u0430\u0442${issue2.keys.length > 1 ? "\u0438" : ""} \u043A\u043B\u044E\u0447${issue2.keys.length > 1 ? "\u043E\u0432\u0435" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u0435\u043D \u043A\u043B\u044E\u0447 \u0432 ${issue2.origin}`;
        case "invalid_union":
          return "\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u0435\u043D \u0432\u0445\u043E\u0434";
        case "invalid_element":
          return `\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u043D\u0430 \u0441\u0442\u043E\u0439\u043D\u043E\u0441\u0442 \u0432 ${issue2.origin}`;
        default:
          return `\u041D\u0435\u0432\u0430\u043B\u0438\u0434\u0435\u043D \u0432\u0445\u043E\u0434`;
      }
    };
  };
  function bg_default() {
    return {
      localeError: error4()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/ca.js
  init_runtime();
  var error5 = () => {
    const Sizable = {
      string: { unit: "car\xE0cters", verb: "contenir" },
      file: { unit: "bytes", verb: "contenir" },
      array: { unit: "elements", verb: "contenir" },
      set: { unit: "elements", verb: "contenir" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "entrada",
      email: "adre\xE7a electr\xF2nica",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "data i hora ISO",
      date: "data ISO",
      time: "hora ISO",
      duration: "durada ISO",
      ipv4: "adre\xE7a IPv4",
      ipv6: "adre\xE7a IPv6",
      cidrv4: "rang IPv4",
      cidrv6: "rang IPv6",
      base64: "cadena codificada en base64",
      base64url: "cadena codificada en base64url",
      json_string: "cadena JSON",
      e164: "n\xFAmero E.164",
      jwt: "JWT",
      template_literal: "entrada"
    };
    const TypeDictionary = {
      nan: "NaN"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Tipus inv\xE0lid: s'esperava instanceof ${issue2.expected}, s'ha rebut ${received}`;
          }
          return `Tipus inv\xE0lid: s'esperava ${expected}, s'ha rebut ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Valor inv\xE0lid: s'esperava ${stringifyPrimitive(issue2.values[0])}`;
          return `Opci\xF3 inv\xE0lida: s'esperava una de ${joinValues(issue2.values, " o ")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "com a m\xE0xim" : "menys de";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Massa gran: s'esperava que ${issue2.origin ?? "el valor"} contingu\xE9s ${adj} ${issue2.maximum.toString()} ${sizing.unit ?? "elements"}`;
          return `Massa gran: s'esperava que ${issue2.origin ?? "el valor"} fos ${adj} ${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? "com a m\xEDnim" : "m\xE9s de";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Massa petit: s'esperava que ${issue2.origin} contingu\xE9s ${adj} ${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Massa petit: s'esperava que ${issue2.origin} fos ${adj} ${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `Format inv\xE0lid: ha de comen\xE7ar amb "${_issue.prefix}"`;
          }
          if (_issue.format === "ends_with")
            return `Format inv\xE0lid: ha d'acabar amb "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Format inv\xE0lid: ha d'incloure "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Format inv\xE0lid: ha de coincidir amb el patr\xF3 ${_issue.pattern}`;
          return `Format inv\xE0lid per a ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `N\xFAmero inv\xE0lid: ha de ser m\xFAltiple de ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Clau${issue2.keys.length > 1 ? "s" : ""} no reconeguda${issue2.keys.length > 1 ? "s" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Clau inv\xE0lida a ${issue2.origin}`;
        case "invalid_union":
          return "Entrada inv\xE0lida";
        // Could also be "Tipus d'unió invàlid" but "Entrada invàlida" is more general
        case "invalid_element":
          return `Element inv\xE0lid a ${issue2.origin}`;
        default:
          return `Entrada inv\xE0lida`;
      }
    };
  };
  function ca_default() {
    return {
      localeError: error5()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/cs.js
  init_runtime();
  var error6 = () => {
    const Sizable = {
      string: { unit: "znak\u016F", verb: "m\xEDt" },
      file: { unit: "bajt\u016F", verb: "m\xEDt" },
      array: { unit: "prvk\u016F", verb: "m\xEDt" },
      set: { unit: "prvk\u016F", verb: "m\xEDt" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "regul\xE1rn\xED v\xFDraz",
      email: "e-mailov\xE1 adresa",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "datum a \u010Das ve form\xE1tu ISO",
      date: "datum ve form\xE1tu ISO",
      time: "\u010Das ve form\xE1tu ISO",
      duration: "doba trv\xE1n\xED ISO",
      ipv4: "IPv4 adresa",
      ipv6: "IPv6 adresa",
      cidrv4: "rozsah IPv4",
      cidrv6: "rozsah IPv6",
      base64: "\u0159et\u011Bzec zak\xF3dovan\xFD ve form\xE1tu base64",
      base64url: "\u0159et\u011Bzec zak\xF3dovan\xFD ve form\xE1tu base64url",
      json_string: "\u0159et\u011Bzec ve form\xE1tu JSON",
      e164: "\u010D\xEDslo E.164",
      jwt: "JWT",
      template_literal: "vstup"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u010D\xEDslo",
      string: "\u0159et\u011Bzec",
      function: "funkce",
      array: "pole"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Neplatn\xFD vstup: o\u010Dek\xE1v\xE1no instanceof ${issue2.expected}, obdr\u017Eeno ${received}`;
          }
          return `Neplatn\xFD vstup: o\u010Dek\xE1v\xE1no ${expected}, obdr\u017Eeno ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Neplatn\xFD vstup: o\u010Dek\xE1v\xE1no ${stringifyPrimitive(issue2.values[0])}`;
          return `Neplatn\xE1 mo\u017Enost: o\u010Dek\xE1v\xE1na jedna z hodnot ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Hodnota je p\u0159\xEDli\u0161 velk\xE1: ${issue2.origin ?? "hodnota"} mus\xED m\xEDt ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "prvk\u016F"}`;
          }
          return `Hodnota je p\u0159\xEDli\u0161 velk\xE1: ${issue2.origin ?? "hodnota"} mus\xED b\xFDt ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Hodnota je p\u0159\xEDli\u0161 mal\xE1: ${issue2.origin ?? "hodnota"} mus\xED m\xEDt ${adj}${issue2.minimum.toString()} ${sizing.unit ?? "prvk\u016F"}`;
          }
          return `Hodnota je p\u0159\xEDli\u0161 mal\xE1: ${issue2.origin ?? "hodnota"} mus\xED b\xFDt ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Neplatn\xFD \u0159et\u011Bzec: mus\xED za\u010D\xEDnat na "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `Neplatn\xFD \u0159et\u011Bzec: mus\xED kon\u010Dit na "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Neplatn\xFD \u0159et\u011Bzec: mus\xED obsahovat "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Neplatn\xFD \u0159et\u011Bzec: mus\xED odpov\xEDdat vzoru ${_issue.pattern}`;
          return `Neplatn\xFD form\xE1t ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Neplatn\xE9 \u010D\xEDslo: mus\xED b\xFDt n\xE1sobkem ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Nezn\xE1m\xE9 kl\xED\u010De: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Neplatn\xFD kl\xED\u010D v ${issue2.origin}`;
        case "invalid_union":
          return "Neplatn\xFD vstup";
        case "invalid_element":
          return `Neplatn\xE1 hodnota v ${issue2.origin}`;
        default:
          return `Neplatn\xFD vstup`;
      }
    };
  };
  function cs_default() {
    return {
      localeError: error6()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/da.js
  init_runtime();
  var error7 = () => {
    const Sizable = {
      string: { unit: "tegn", verb: "havde" },
      file: { unit: "bytes", verb: "havde" },
      array: { unit: "elementer", verb: "indeholdt" },
      set: { unit: "elementer", verb: "indeholdt" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "input",
      email: "e-mailadresse",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO dato- og klokkesl\xE6t",
      date: "ISO-dato",
      time: "ISO-klokkesl\xE6t",
      duration: "ISO-varighed",
      ipv4: "IPv4-omr\xE5de",
      ipv6: "IPv6-omr\xE5de",
      cidrv4: "IPv4-spektrum",
      cidrv6: "IPv6-spektrum",
      base64: "base64-kodet streng",
      base64url: "base64url-kodet streng",
      json_string: "JSON-streng",
      e164: "E.164-nummer",
      jwt: "JWT",
      template_literal: "input"
    };
    const TypeDictionary = {
      nan: "NaN",
      string: "streng",
      number: "tal",
      boolean: "boolean",
      array: "liste",
      object: "objekt",
      set: "s\xE6t",
      file: "fil"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Ugyldigt input: forventede instanceof ${issue2.expected}, fik ${received}`;
          }
          return `Ugyldigt input: forventede ${expected}, fik ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Ugyldig v\xE6rdi: forventede ${stringifyPrimitive(issue2.values[0])}`;
          return `Ugyldigt valg: forventede en af f\xF8lgende ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          const origin = TypeDictionary[issue2.origin] ?? issue2.origin;
          if (sizing)
            return `For stor: forventede ${origin ?? "value"} ${sizing.verb} ${adj} ${issue2.maximum.toString()} ${sizing.unit ?? "elementer"}`;
          return `For stor: forventede ${origin ?? "value"} havde ${adj} ${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          const origin = TypeDictionary[issue2.origin] ?? issue2.origin;
          if (sizing) {
            return `For lille: forventede ${origin} ${sizing.verb} ${adj} ${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `For lille: forventede ${origin} havde ${adj} ${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Ugyldig streng: skal starte med "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `Ugyldig streng: skal ende med "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Ugyldig streng: skal indeholde "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Ugyldig streng: skal matche m\xF8nsteret ${_issue.pattern}`;
          return `Ugyldig ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Ugyldigt tal: skal v\xE6re deleligt med ${issue2.divisor}`;
        case "unrecognized_keys":
          return `${issue2.keys.length > 1 ? "Ukendte n\xF8gler" : "Ukendt n\xF8gle"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Ugyldig n\xF8gle i ${issue2.origin}`;
        case "invalid_union":
          return "Ugyldigt input: matcher ingen af de tilladte typer";
        case "invalid_element":
          return `Ugyldig v\xE6rdi i ${issue2.origin}`;
        default:
          return `Ugyldigt input`;
      }
    };
  };
  function da_default() {
    return {
      localeError: error7()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/de.js
  init_runtime();
  var error8 = () => {
    const Sizable = {
      string: { unit: "Zeichen", verb: "zu haben" },
      file: { unit: "Bytes", verb: "zu haben" },
      array: { unit: "Elemente", verb: "zu haben" },
      set: { unit: "Elemente", verb: "zu haben" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "Eingabe",
      email: "E-Mail-Adresse",
      url: "URL",
      emoji: "Emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO-Datum und -Uhrzeit",
      date: "ISO-Datum",
      time: "ISO-Uhrzeit",
      duration: "ISO-Dauer",
      ipv4: "IPv4-Adresse",
      ipv6: "IPv6-Adresse",
      cidrv4: "IPv4-Bereich",
      cidrv6: "IPv6-Bereich",
      base64: "Base64-codierter String",
      base64url: "Base64-URL-codierter String",
      json_string: "JSON-String",
      e164: "E.164-Nummer",
      jwt: "JWT",
      template_literal: "Eingabe"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "Zahl",
      array: "Array"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Ung\xFCltige Eingabe: erwartet instanceof ${issue2.expected}, erhalten ${received}`;
          }
          return `Ung\xFCltige Eingabe: erwartet ${expected}, erhalten ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Ung\xFCltige Eingabe: erwartet ${stringifyPrimitive(issue2.values[0])}`;
          return `Ung\xFCltige Option: erwartet eine von ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Zu gro\xDF: erwartet, dass ${issue2.origin ?? "Wert"} ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "Elemente"} hat`;
          return `Zu gro\xDF: erwartet, dass ${issue2.origin ?? "Wert"} ${adj}${issue2.maximum.toString()} ist`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Zu klein: erwartet, dass ${issue2.origin} ${adj}${issue2.minimum.toString()} ${sizing.unit} hat`;
          }
          return `Zu klein: erwartet, dass ${issue2.origin} ${adj}${issue2.minimum.toString()} ist`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Ung\xFCltiger String: muss mit "${_issue.prefix}" beginnen`;
          if (_issue.format === "ends_with")
            return `Ung\xFCltiger String: muss mit "${_issue.suffix}" enden`;
          if (_issue.format === "includes")
            return `Ung\xFCltiger String: muss "${_issue.includes}" enthalten`;
          if (_issue.format === "regex")
            return `Ung\xFCltiger String: muss dem Muster ${_issue.pattern} entsprechen`;
          return `Ung\xFCltig: ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Ung\xFCltige Zahl: muss ein Vielfaches von ${issue2.divisor} sein`;
        case "unrecognized_keys":
          return `${issue2.keys.length > 1 ? "Unbekannte Schl\xFCssel" : "Unbekannter Schl\xFCssel"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Ung\xFCltiger Schl\xFCssel in ${issue2.origin}`;
        case "invalid_union":
          return "Ung\xFCltige Eingabe";
        case "invalid_element":
          return `Ung\xFCltiger Wert in ${issue2.origin}`;
        default:
          return `Ung\xFCltige Eingabe`;
      }
    };
  };
  function de_default() {
    return {
      localeError: error8()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/el.js
  init_runtime();
  var error9 = () => {
    const Sizable = {
      string: { unit: "\u03C7\u03B1\u03C1\u03B1\u03BA\u03C4\u03AE\u03C1\u03B5\u03C2", verb: "\u03BD\u03B1 \u03AD\u03C7\u03B5\u03B9" },
      file: { unit: "bytes", verb: "\u03BD\u03B1 \u03AD\u03C7\u03B5\u03B9" },
      array: { unit: "\u03C3\u03C4\u03BF\u03B9\u03C7\u03B5\u03AF\u03B1", verb: "\u03BD\u03B1 \u03AD\u03C7\u03B5\u03B9" },
      set: { unit: "\u03C3\u03C4\u03BF\u03B9\u03C7\u03B5\u03AF\u03B1", verb: "\u03BD\u03B1 \u03AD\u03C7\u03B5\u03B9" },
      map: { unit: "\u03BA\u03B1\u03C4\u03B1\u03C7\u03C9\u03C1\u03AE\u03C3\u03B5\u03B9\u03C2", verb: "\u03BD\u03B1 \u03AD\u03C7\u03B5\u03B9" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u03B5\u03AF\u03C3\u03BF\u03B4\u03BF\u03C2",
      email: "\u03B4\u03B9\u03B5\u03CD\u03B8\u03C5\u03BD\u03C3\u03B7 email",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO \u03B7\u03BC\u03B5\u03C1\u03BF\u03BC\u03B7\u03BD\u03AF\u03B1 \u03BA\u03B1\u03B9 \u03CE\u03C1\u03B1",
      date: "ISO \u03B7\u03BC\u03B5\u03C1\u03BF\u03BC\u03B7\u03BD\u03AF\u03B1",
      time: "ISO \u03CE\u03C1\u03B1",
      duration: "ISO \u03B4\u03B9\u03AC\u03C1\u03BA\u03B5\u03B9\u03B1",
      ipv4: "\u03B4\u03B9\u03B5\u03CD\u03B8\u03C5\u03BD\u03C3\u03B7 IPv4",
      ipv6: "\u03B4\u03B9\u03B5\u03CD\u03B8\u03C5\u03BD\u03C3\u03B7 IPv6",
      mac: "\u03B4\u03B9\u03B5\u03CD\u03B8\u03C5\u03BD\u03C3\u03B7 MAC",
      cidrv4: "\u03B5\u03CD\u03C1\u03BF\u03C2 IPv4",
      cidrv6: "\u03B5\u03CD\u03C1\u03BF\u03C2 IPv6",
      base64: "\u03C3\u03C5\u03BC\u03B2\u03BF\u03BB\u03BF\u03C3\u03B5\u03B9\u03C1\u03AC \u03BA\u03C9\u03B4\u03B9\u03BA\u03BF\u03C0\u03BF\u03B9\u03B7\u03BC\u03AD\u03BD\u03B7 \u03C3\u03B5 base64",
      base64url: "\u03C3\u03C5\u03BC\u03B2\u03BF\u03BB\u03BF\u03C3\u03B5\u03B9\u03C1\u03AC \u03BA\u03C9\u03B4\u03B9\u03BA\u03BF\u03C0\u03BF\u03B9\u03B7\u03BC\u03AD\u03BD\u03B7 \u03C3\u03B5 base64url",
      json_string: "\u03C3\u03C5\u03BC\u03B2\u03BF\u03BB\u03BF\u03C3\u03B5\u03B9\u03C1\u03AC JSON",
      e164: "\u03B1\u03C1\u03B9\u03B8\u03BC\u03CC\u03C2 E.164",
      jwt: "JWT",
      template_literal: "\u03B5\u03AF\u03C3\u03BF\u03B4\u03BF\u03C2"
    };
    const TypeDictionary = {
      nan: "NaN"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (typeof issue2.expected === "string" && /^[A-Z]/.test(issue2.expected)) {
            return `\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03B7 \u03B5\u03AF\u03C3\u03BF\u03B4\u03BF\u03C2: \u03B1\u03BD\u03B1\u03BC\u03B5\u03BD\u03CC\u03C4\u03B1\u03BD instanceof ${issue2.expected}, \u03BB\u03AE\u03C6\u03B8\u03B7\u03BA\u03B5 ${received}`;
          }
          return `\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03B7 \u03B5\u03AF\u03C3\u03BF\u03B4\u03BF\u03C2: \u03B1\u03BD\u03B1\u03BC\u03B5\u03BD\u03CC\u03C4\u03B1\u03BD ${expected}, \u03BB\u03AE\u03C6\u03B8\u03B7\u03BA\u03B5 ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03B7 \u03B5\u03AF\u03C3\u03BF\u03B4\u03BF\u03C2: \u03B1\u03BD\u03B1\u03BC\u03B5\u03BD\u03CC\u03C4\u03B1\u03BD ${stringifyPrimitive(issue2.values[0])}`;
          return `\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03B7 \u03B5\u03C0\u03B9\u03BB\u03BF\u03B3\u03AE: \u03B1\u03BD\u03B1\u03BC\u03B5\u03BD\u03CC\u03C4\u03B1\u03BD \u03AD\u03BD\u03B1 \u03B1\u03C0\u03CC ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\u03A0\u03BF\u03BB\u03CD \u03BC\u03B5\u03B3\u03AC\u03BB\u03BF: \u03B1\u03BD\u03B1\u03BC\u03B5\u03BD\u03CC\u03C4\u03B1\u03BD ${issue2.origin ?? "\u03C4\u03B9\u03BC\u03AE"} \u03BD\u03B1 \u03AD\u03C7\u03B5\u03B9 ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "\u03C3\u03C4\u03BF\u03B9\u03C7\u03B5\u03AF\u03B1"}`;
          return `\u03A0\u03BF\u03BB\u03CD \u03BC\u03B5\u03B3\u03AC\u03BB\u03BF: \u03B1\u03BD\u03B1\u03BC\u03B5\u03BD\u03CC\u03C4\u03B1\u03BD ${issue2.origin ?? "\u03C4\u03B9\u03BC\u03AE"} \u03BD\u03B1 \u03B5\u03AF\u03BD\u03B1\u03B9 ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u03A0\u03BF\u03BB\u03CD \u03BC\u03B9\u03BA\u03C1\u03CC: \u03B1\u03BD\u03B1\u03BC\u03B5\u03BD\u03CC\u03C4\u03B1\u03BD ${issue2.origin} \u03BD\u03B1 \u03AD\u03C7\u03B5\u03B9 ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `\u03A0\u03BF\u03BB\u03CD \u03BC\u03B9\u03BA\u03C1\u03CC: \u03B1\u03BD\u03B1\u03BC\u03B5\u03BD\u03CC\u03C4\u03B1\u03BD ${issue2.origin} \u03BD\u03B1 \u03B5\u03AF\u03BD\u03B1\u03B9 ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03B7 \u03C3\u03C5\u03BC\u03B2\u03BF\u03BB\u03BF\u03C3\u03B5\u03B9\u03C1\u03AC: \u03C0\u03C1\u03AD\u03C0\u03B5\u03B9 \u03BD\u03B1 \u03BE\u03B5\u03BA\u03B9\u03BD\u03AC \u03BC\u03B5 "${_issue.prefix}"`;
          }
          if (_issue.format === "ends_with")
            return `\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03B7 \u03C3\u03C5\u03BC\u03B2\u03BF\u03BB\u03BF\u03C3\u03B5\u03B9\u03C1\u03AC: \u03C0\u03C1\u03AD\u03C0\u03B5\u03B9 \u03BD\u03B1 \u03C4\u03B5\u03BB\u03B5\u03B9\u03CE\u03BD\u03B5\u03B9 \u03BC\u03B5 "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03B7 \u03C3\u03C5\u03BC\u03B2\u03BF\u03BB\u03BF\u03C3\u03B5\u03B9\u03C1\u03AC: \u03C0\u03C1\u03AD\u03C0\u03B5\u03B9 \u03BD\u03B1 \u03C0\u03B5\u03C1\u03B9\u03AD\u03C7\u03B5\u03B9 "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03B7 \u03C3\u03C5\u03BC\u03B2\u03BF\u03BB\u03BF\u03C3\u03B5\u03B9\u03C1\u03AC: \u03C0\u03C1\u03AD\u03C0\u03B5\u03B9 \u03BD\u03B1 \u03C4\u03B1\u03B9\u03C1\u03B9\u03AC\u03B6\u03B5\u03B9 \u03BC\u03B5 \u03C4\u03BF \u03BC\u03BF\u03C4\u03AF\u03B2\u03BF ${_issue.pattern}`;
          return `\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03BF: ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03BF\u03C2 \u03B1\u03C1\u03B9\u03B8\u03BC\u03CC\u03C2: \u03C0\u03C1\u03AD\u03C0\u03B5\u03B9 \u03BD\u03B1 \u03B5\u03AF\u03BD\u03B1\u03B9 \u03C0\u03BF\u03BB\u03BB\u03B1\u03C0\u03BB\u03AC\u03C3\u03B9\u03BF \u03C4\u03BF\u03C5 ${issue2.divisor}`;
        case "unrecognized_keys":
          return `\u0386\u03B3\u03BD\u03C9\u03C3\u03C4${issue2.keys.length > 1 ? "\u03B1" : "\u03BF"} \u03BA\u03BB\u03B5\u03B9\u03B4${issue2.keys.length > 1 ? "\u03B9\u03AC" : "\u03AF"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03BF \u03BA\u03BB\u03B5\u03B9\u03B4\u03AF \u03C3\u03C4\u03BF ${issue2.origin}`;
        case "invalid_union":
          return "\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03B7 \u03B5\u03AF\u03C3\u03BF\u03B4\u03BF\u03C2";
        case "invalid_element":
          return `\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03B7 \u03C4\u03B9\u03BC\u03AE \u03C3\u03C4\u03BF ${issue2.origin}`;
        default:
          return `\u039C\u03B7 \u03AD\u03B3\u03BA\u03C5\u03C1\u03B7 \u03B5\u03AF\u03C3\u03BF\u03B4\u03BF\u03C2`;
      }
    };
  };
  function el_default() {
    return {
      localeError: error9()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/en.js
  init_runtime();
  var error10 = () => {
    const Sizable = {
      string: { unit: "characters", verb: "to have" },
      file: { unit: "bytes", verb: "to have" },
      array: { unit: "items", verb: "to have" },
      set: { unit: "items", verb: "to have" },
      map: { unit: "entries", verb: "to have" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "input",
      email: "email address",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO datetime",
      date: "ISO date",
      time: "ISO time",
      duration: "ISO duration",
      ipv4: "IPv4 address",
      ipv6: "IPv6 address",
      mac: "MAC address",
      cidrv4: "IPv4 range",
      cidrv6: "IPv6 range",
      base64: "base64-encoded string",
      base64url: "base64url-encoded string",
      json_string: "JSON string",
      e164: "E.164 number",
      jwt: "JWT",
      template_literal: "input"
    };
    const TypeDictionary = {
      // Compatibility: "nan" -> "NaN" for display
      nan: "NaN"
      // All other type names omitted - they fall back to raw values via ?? operator
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          return `Invalid input: expected ${expected}, received ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Invalid input: expected ${stringifyPrimitive(issue2.values[0])}`;
          return `Invalid option: expected one of ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Too big: expected ${issue2.origin ?? "value"} to have ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elements"}`;
          return `Too big: expected ${issue2.origin ?? "value"} to be ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Too small: expected ${issue2.origin} to have ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Too small: expected ${issue2.origin} to be ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `Invalid string: must start with "${_issue.prefix}"`;
          }
          if (_issue.format === "ends_with")
            return `Invalid string: must end with "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Invalid string: must include "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Invalid string: must match pattern ${_issue.pattern}`;
          return `Invalid ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Invalid number: must be a multiple of ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Unrecognized key${issue2.keys.length > 1 ? "s" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Invalid key in ${issue2.origin}`;
        case "invalid_union":
          if (issue2.options && Array.isArray(issue2.options) && issue2.options.length > 0) {
            const opts = issue2.options.map((o) => `'${o}'`).join(" | ");
            return `Invalid discriminator value. Expected ${opts}`;
          }
          return "Invalid input";
        case "invalid_element":
          return `Invalid value in ${issue2.origin}`;
        default:
          return `Invalid input`;
      }
    };
  };
  function en_default() {
    return {
      localeError: error10()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/eo.js
  init_runtime();
  var error11 = () => {
    const Sizable = {
      string: { unit: "karaktrojn", verb: "havi" },
      file: { unit: "bajtojn", verb: "havi" },
      array: { unit: "elementojn", verb: "havi" },
      set: { unit: "elementojn", verb: "havi" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "enigo",
      email: "retadreso",
      url: "URL",
      emoji: "emo\u011Dio",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO-datotempo",
      date: "ISO-dato",
      time: "ISO-tempo",
      duration: "ISO-da\u016Dro",
      ipv4: "IPv4-adreso",
      ipv6: "IPv6-adreso",
      cidrv4: "IPv4-rango",
      cidrv6: "IPv6-rango",
      base64: "64-ume kodita karaktraro",
      base64url: "URL-64-ume kodita karaktraro",
      json_string: "JSON-karaktraro",
      e164: "E.164-nombro",
      jwt: "JWT",
      template_literal: "enigo"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "nombro",
      array: "tabelo",
      null: "senvalora"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Nevalida enigo: atendi\u011Dis instanceof ${issue2.expected}, ricevi\u011Dis ${received}`;
          }
          return `Nevalida enigo: atendi\u011Dis ${expected}, ricevi\u011Dis ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Nevalida enigo: atendi\u011Dis ${stringifyPrimitive(issue2.values[0])}`;
          return `Nevalida opcio: atendi\u011Dis unu el ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Tro granda: atendi\u011Dis ke ${issue2.origin ?? "valoro"} havu ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elementojn"}`;
          return `Tro granda: atendi\u011Dis ke ${issue2.origin ?? "valoro"} havu ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Tro malgranda: atendi\u011Dis ke ${issue2.origin} havu ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Tro malgranda: atendi\u011Dis ke ${issue2.origin} estu ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Nevalida karaktraro: devas komenci\u011Di per "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `Nevalida karaktraro: devas fini\u011Di per "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Nevalida karaktraro: devas inkluzivi "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Nevalida karaktraro: devas kongrui kun la modelo ${_issue.pattern}`;
          return `Nevalida ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Nevalida nombro: devas esti oblo de ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Nekonata${issue2.keys.length > 1 ? "j" : ""} \u015Dlosilo${issue2.keys.length > 1 ? "j" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Nevalida \u015Dlosilo en ${issue2.origin}`;
        case "invalid_union":
          return "Nevalida enigo";
        case "invalid_element":
          return `Nevalida valoro en ${issue2.origin}`;
        default:
          return `Nevalida enigo`;
      }
    };
  };
  function eo_default() {
    return {
      localeError: error11()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/es.js
  init_runtime();
  var error12 = () => {
    const Sizable = {
      string: { unit: "caracteres", verb: "tener" },
      file: { unit: "bytes", verb: "tener" },
      array: { unit: "elementos", verb: "tener" },
      set: { unit: "elementos", verb: "tener" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "entrada",
      email: "direcci\xF3n de correo electr\xF3nico",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "fecha y hora ISO",
      date: "fecha ISO",
      time: "hora ISO",
      duration: "duraci\xF3n ISO",
      ipv4: "direcci\xF3n IPv4",
      ipv6: "direcci\xF3n IPv6",
      cidrv4: "rango IPv4",
      cidrv6: "rango IPv6",
      base64: "cadena codificada en base64",
      base64url: "URL codificada en base64",
      json_string: "cadena JSON",
      e164: "n\xFAmero E.164",
      jwt: "JWT",
      template_literal: "entrada"
    };
    const TypeDictionary = {
      nan: "NaN",
      string: "texto",
      number: "n\xFAmero",
      boolean: "booleano",
      array: "arreglo",
      object: "objeto",
      set: "conjunto",
      file: "archivo",
      date: "fecha",
      bigint: "n\xFAmero grande",
      symbol: "s\xEDmbolo",
      undefined: "indefinido",
      null: "nulo",
      function: "funci\xF3n",
      map: "mapa",
      record: "registro",
      tuple: "tupla",
      enum: "enumeraci\xF3n",
      union: "uni\xF3n",
      literal: "literal",
      promise: "promesa",
      void: "vac\xEDo",
      never: "nunca",
      unknown: "desconocido",
      any: "cualquiera"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Entrada inv\xE1lida: se esperaba instanceof ${issue2.expected}, recibido ${received}`;
          }
          return `Entrada inv\xE1lida: se esperaba ${expected}, recibido ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Entrada inv\xE1lida: se esperaba ${stringifyPrimitive(issue2.values[0])}`;
          return `Opci\xF3n inv\xE1lida: se esperaba una de ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          const origin = TypeDictionary[issue2.origin] ?? issue2.origin;
          if (sizing)
            return `Demasiado grande: se esperaba que ${origin ?? "valor"} tuviera ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elementos"}`;
          return `Demasiado grande: se esperaba que ${origin ?? "valor"} fuera ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          const origin = TypeDictionary[issue2.origin] ?? issue2.origin;
          if (sizing) {
            return `Demasiado peque\xF1o: se esperaba que ${origin} tuviera ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Demasiado peque\xF1o: se esperaba que ${origin} fuera ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Cadena inv\xE1lida: debe comenzar con "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `Cadena inv\xE1lida: debe terminar en "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Cadena inv\xE1lida: debe incluir "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Cadena inv\xE1lida: debe coincidir con el patr\xF3n ${_issue.pattern}`;
          return `Inv\xE1lido ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `N\xFAmero inv\xE1lido: debe ser m\xFAltiplo de ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Llave${issue2.keys.length > 1 ? "s" : ""} desconocida${issue2.keys.length > 1 ? "s" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Llave inv\xE1lida en ${TypeDictionary[issue2.origin] ?? issue2.origin}`;
        case "invalid_union":
          return "Entrada inv\xE1lida";
        case "invalid_element":
          return `Valor inv\xE1lido en ${TypeDictionary[issue2.origin] ?? issue2.origin}`;
        default:
          return `Entrada inv\xE1lida`;
      }
    };
  };
  function es_default() {
    return {
      localeError: error12()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/fa.js
  init_runtime();
  var error13 = () => {
    const Sizable = {
      string: { unit: "\u06A9\u0627\u0631\u0627\u06A9\u062A\u0631", verb: "\u062F\u0627\u0634\u062A\u0647 \u0628\u0627\u0634\u062F" },
      file: { unit: "\u0628\u0627\u06CC\u062A", verb: "\u062F\u0627\u0634\u062A\u0647 \u0628\u0627\u0634\u062F" },
      array: { unit: "\u0622\u06CC\u062A\u0645", verb: "\u062F\u0627\u0634\u062A\u0647 \u0628\u0627\u0634\u062F" },
      set: { unit: "\u0622\u06CC\u062A\u0645", verb: "\u062F\u0627\u0634\u062A\u0647 \u0628\u0627\u0634\u062F" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u0648\u0631\u0648\u062F\u06CC",
      email: "\u0622\u062F\u0631\u0633 \u0627\u06CC\u0645\u06CC\u0644",
      url: "URL",
      emoji: "\u0627\u06CC\u0645\u0648\u062C\u06CC",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "\u062A\u0627\u0631\u06CC\u062E \u0648 \u0632\u0645\u0627\u0646 \u0627\u06CC\u0632\u0648",
      date: "\u062A\u0627\u0631\u06CC\u062E \u0627\u06CC\u0632\u0648",
      time: "\u0632\u0645\u0627\u0646 \u0627\u06CC\u0632\u0648",
      duration: "\u0645\u062F\u062A \u0632\u0645\u0627\u0646 \u0627\u06CC\u0632\u0648",
      ipv4: "IPv4 \u0622\u062F\u0631\u0633",
      ipv6: "IPv6 \u0622\u062F\u0631\u0633",
      cidrv4: "IPv4 \u062F\u0627\u0645\u0646\u0647",
      cidrv6: "IPv6 \u062F\u0627\u0645\u0646\u0647",
      base64: "base64-encoded \u0631\u0634\u062A\u0647",
      base64url: "base64url-encoded \u0631\u0634\u062A\u0647",
      json_string: "JSON \u0631\u0634\u062A\u0647",
      e164: "E.164 \u0639\u062F\u062F",
      jwt: "JWT",
      template_literal: "\u0648\u0631\u0648\u062F\u06CC"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u0639\u062F\u062F",
      array: "\u0622\u0631\u0627\u06CC\u0647"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u0648\u0631\u0648\u062F\u06CC \u0646\u0627\u0645\u0639\u062A\u0628\u0631: \u0645\u06CC\u200C\u0628\u0627\u06CC\u0633\u062A instanceof ${issue2.expected} \u0645\u06CC\u200C\u0628\u0648\u062F\u060C ${received} \u062F\u0631\u06CC\u0627\u0641\u062A \u0634\u062F`;
          }
          return `\u0648\u0631\u0648\u062F\u06CC \u0646\u0627\u0645\u0639\u062A\u0628\u0631: \u0645\u06CC\u200C\u0628\u0627\u06CC\u0633\u062A ${expected} \u0645\u06CC\u200C\u0628\u0648\u062F\u060C ${received} \u062F\u0631\u06CC\u0627\u0641\u062A \u0634\u062F`;
        }
        case "invalid_value":
          if (issue2.values.length === 1) {
            return `\u0648\u0631\u0648\u062F\u06CC \u0646\u0627\u0645\u0639\u062A\u0628\u0631: \u0645\u06CC\u200C\u0628\u0627\u06CC\u0633\u062A ${stringifyPrimitive(issue2.values[0])} \u0645\u06CC\u200C\u0628\u0648\u062F`;
          }
          return `\u06AF\u0632\u06CC\u0646\u0647 \u0646\u0627\u0645\u0639\u062A\u0628\u0631: \u0645\u06CC\u200C\u0628\u0627\u06CC\u0633\u062A \u06CC\u06A9\u06CC \u0627\u0632 ${joinValues(issue2.values, "|")} \u0645\u06CC\u200C\u0628\u0648\u062F`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u062E\u06CC\u0644\u06CC \u0628\u0632\u0631\u06AF: ${issue2.origin ?? "\u0645\u0642\u062F\u0627\u0631"} \u0628\u0627\u06CC\u062F ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "\u0639\u0646\u0635\u0631"} \u0628\u0627\u0634\u062F`;
          }
          return `\u062E\u06CC\u0644\u06CC \u0628\u0632\u0631\u06AF: ${issue2.origin ?? "\u0645\u0642\u062F\u0627\u0631"} \u0628\u0627\u06CC\u062F ${adj}${issue2.maximum.toString()} \u0628\u0627\u0634\u062F`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u062E\u06CC\u0644\u06CC \u06A9\u0648\u0686\u06A9: ${issue2.origin} \u0628\u0627\u06CC\u062F ${adj}${issue2.minimum.toString()} ${sizing.unit} \u0628\u0627\u0634\u062F`;
          }
          return `\u062E\u06CC\u0644\u06CC \u06A9\u0648\u0686\u06A9: ${issue2.origin} \u0628\u0627\u06CC\u062F ${adj}${issue2.minimum.toString()} \u0628\u0627\u0634\u062F`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `\u0631\u0634\u062A\u0647 \u0646\u0627\u0645\u0639\u062A\u0628\u0631: \u0628\u0627\u06CC\u062F \u0628\u0627 "${_issue.prefix}" \u0634\u0631\u0648\u0639 \u0634\u0648\u062F`;
          }
          if (_issue.format === "ends_with") {
            return `\u0631\u0634\u062A\u0647 \u0646\u0627\u0645\u0639\u062A\u0628\u0631: \u0628\u0627\u06CC\u062F \u0628\u0627 "${_issue.suffix}" \u062A\u0645\u0627\u0645 \u0634\u0648\u062F`;
          }
          if (_issue.format === "includes") {
            return `\u0631\u0634\u062A\u0647 \u0646\u0627\u0645\u0639\u062A\u0628\u0631: \u0628\u0627\u06CC\u062F \u0634\u0627\u0645\u0644 "${_issue.includes}" \u0628\u0627\u0634\u062F`;
          }
          if (_issue.format === "regex") {
            return `\u0631\u0634\u062A\u0647 \u0646\u0627\u0645\u0639\u062A\u0628\u0631: \u0628\u0627\u06CC\u062F \u0628\u0627 \u0627\u0644\u06AF\u0648\u06CC ${_issue.pattern} \u0645\u0637\u0627\u0628\u0642\u062A \u062F\u0627\u0634\u062A\u0647 \u0628\u0627\u0634\u062F`;
          }
          return `${FormatDictionary[_issue.format] ?? issue2.format} \u0646\u0627\u0645\u0639\u062A\u0628\u0631`;
        }
        case "not_multiple_of":
          return `\u0639\u062F\u062F \u0646\u0627\u0645\u0639\u062A\u0628\u0631: \u0628\u0627\u06CC\u062F \u0645\u0636\u0631\u0628 ${issue2.divisor} \u0628\u0627\u0634\u062F`;
        case "unrecognized_keys":
          return `\u06A9\u0644\u06CC\u062F${issue2.keys.length > 1 ? "\u0647\u0627\u06CC" : ""} \u0646\u0627\u0634\u0646\u0627\u0633: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\u06A9\u0644\u06CC\u062F \u0646\u0627\u0634\u0646\u0627\u0633 \u062F\u0631 ${issue2.origin}`;
        case "invalid_union":
          return `\u0648\u0631\u0648\u062F\u06CC \u0646\u0627\u0645\u0639\u062A\u0628\u0631`;
        case "invalid_element":
          return `\u0645\u0642\u062F\u0627\u0631 \u0646\u0627\u0645\u0639\u062A\u0628\u0631 \u062F\u0631 ${issue2.origin}`;
        default:
          return `\u0648\u0631\u0648\u062F\u06CC \u0646\u0627\u0645\u0639\u062A\u0628\u0631`;
      }
    };
  };
  function fa_default() {
    return {
      localeError: error13()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/fi.js
  init_runtime();
  var error14 = () => {
    const Sizable = {
      string: { unit: "merkki\xE4", subject: "merkkijonon" },
      file: { unit: "tavua", subject: "tiedoston" },
      array: { unit: "alkiota", subject: "listan" },
      set: { unit: "alkiota", subject: "joukon" },
      number: { unit: "", subject: "luvun" },
      bigint: { unit: "", subject: "suuren kokonaisluvun" },
      int: { unit: "", subject: "kokonaisluvun" },
      date: { unit: "", subject: "p\xE4iv\xE4m\xE4\xE4r\xE4n" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "s\xE4\xE4nn\xF6llinen lauseke",
      email: "s\xE4hk\xF6postiosoite",
      url: "URL-osoite",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO-aikaleima",
      date: "ISO-p\xE4iv\xE4m\xE4\xE4r\xE4",
      time: "ISO-aika",
      duration: "ISO-kesto",
      ipv4: "IPv4-osoite",
      ipv6: "IPv6-osoite",
      cidrv4: "IPv4-alue",
      cidrv6: "IPv6-alue",
      base64: "base64-koodattu merkkijono",
      base64url: "base64url-koodattu merkkijono",
      json_string: "JSON-merkkijono",
      e164: "E.164-luku",
      jwt: "JWT",
      template_literal: "templaattimerkkijono"
    };
    const TypeDictionary = {
      nan: "NaN"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Virheellinen tyyppi: odotettiin instanceof ${issue2.expected}, oli ${received}`;
          }
          return `Virheellinen tyyppi: odotettiin ${expected}, oli ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Virheellinen sy\xF6te: t\xE4ytyy olla ${stringifyPrimitive(issue2.values[0])}`;
          return `Virheellinen valinta: t\xE4ytyy olla yksi seuraavista: ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Liian suuri: ${sizing.subject} t\xE4ytyy olla ${adj}${issue2.maximum.toString()} ${sizing.unit}`.trim();
          }
          return `Liian suuri: arvon t\xE4ytyy olla ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Liian pieni: ${sizing.subject} t\xE4ytyy olla ${adj}${issue2.minimum.toString()} ${sizing.unit}`.trim();
          }
          return `Liian pieni: arvon t\xE4ytyy olla ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Virheellinen sy\xF6te: t\xE4ytyy alkaa "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `Virheellinen sy\xF6te: t\xE4ytyy loppua "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Virheellinen sy\xF6te: t\xE4ytyy sis\xE4lt\xE4\xE4 "${_issue.includes}"`;
          if (_issue.format === "regex") {
            return `Virheellinen sy\xF6te: t\xE4ytyy vastata s\xE4\xE4nn\xF6llist\xE4 lauseketta ${_issue.pattern}`;
          }
          return `Virheellinen ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Virheellinen luku: t\xE4ytyy olla luvun ${issue2.divisor} monikerta`;
        case "unrecognized_keys":
          return `${issue2.keys.length > 1 ? "Tuntemattomat avaimet" : "Tuntematon avain"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return "Virheellinen avain tietueessa";
        case "invalid_union":
          return "Virheellinen unioni";
        case "invalid_element":
          return "Virheellinen arvo joukossa";
        default:
          return `Virheellinen sy\xF6te`;
      }
    };
  };
  function fi_default() {
    return {
      localeError: error14()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/fr.js
  init_runtime();
  var error15 = () => {
    const Sizable = {
      string: { unit: "caract\xE8res", verb: "avoir" },
      file: { unit: "octets", verb: "avoir" },
      array: { unit: "\xE9l\xE9ments", verb: "avoir" },
      set: { unit: "\xE9l\xE9ments", verb: "avoir" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "entr\xE9e",
      email: "adresse e-mail",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "date et heure ISO",
      date: "date ISO",
      time: "heure ISO",
      duration: "dur\xE9e ISO",
      ipv4: "adresse IPv4",
      ipv6: "adresse IPv6",
      cidrv4: "plage IPv4",
      cidrv6: "plage IPv6",
      base64: "cha\xEEne encod\xE9e en base64",
      base64url: "cha\xEEne encod\xE9e en base64url",
      json_string: "cha\xEEne JSON",
      e164: "num\xE9ro E.164",
      jwt: "JWT",
      template_literal: "entr\xE9e"
    };
    const TypeDictionary = {
      string: "cha\xEEne",
      number: "nombre",
      int: "entier",
      boolean: "bool\xE9en",
      bigint: "grand entier",
      symbol: "symbole",
      undefined: "ind\xE9fini",
      null: "null",
      never: "jamais",
      void: "vide",
      date: "date",
      array: "tableau",
      object: "objet",
      tuple: "tuple",
      record: "enregistrement",
      map: "carte",
      set: "ensemble",
      file: "fichier",
      nonoptional: "non-optionnel",
      nan: "NaN",
      function: "fonction"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Entr\xE9e invalide : instanceof ${issue2.expected} attendu, ${received} re\xE7u`;
          }
          return `Entr\xE9e invalide : ${expected} attendu, ${received} re\xE7u`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Entr\xE9e invalide : ${stringifyPrimitive(issue2.values[0])} attendu`;
          return `Option invalide : une valeur parmi ${joinValues(issue2.values, "|")} attendue`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Trop grand : ${TypeDictionary[issue2.origin] ?? "valeur"} doit ${sizing.verb} ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "\xE9l\xE9ment(s)"}`;
          return `Trop grand : ${TypeDictionary[issue2.origin] ?? "valeur"} doit \xEAtre ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Trop petit : ${TypeDictionary[issue2.origin] ?? "valeur"} doit ${sizing.verb} ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          return `Trop petit : ${TypeDictionary[issue2.origin] ?? "valeur"} doit \xEAtre ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Cha\xEEne invalide : doit commencer par "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `Cha\xEEne invalide : doit se terminer par "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Cha\xEEne invalide : doit inclure "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Cha\xEEne invalide : doit correspondre au mod\xE8le ${_issue.pattern}`;
          return `${FormatDictionary[_issue.format] ?? issue2.format} invalide`;
        }
        case "not_multiple_of":
          return `Nombre invalide : doit \xEAtre un multiple de ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Cl\xE9${issue2.keys.length > 1 ? "s" : ""} non reconnue${issue2.keys.length > 1 ? "s" : ""} : ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Cl\xE9 invalide dans ${issue2.origin}`;
        case "invalid_union":
          return "Entr\xE9e invalide";
        case "invalid_element":
          return `Valeur invalide dans ${issue2.origin}`;
        default:
          return `Entr\xE9e invalide`;
      }
    };
  };
  function fr_default() {
    return {
      localeError: error15()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/fr-CA.js
  init_runtime();
  var error16 = () => {
    const Sizable = {
      string: { unit: "caract\xE8res", verb: "avoir" },
      file: { unit: "octets", verb: "avoir" },
      array: { unit: "\xE9l\xE9ments", verb: "avoir" },
      set: { unit: "\xE9l\xE9ments", verb: "avoir" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "entr\xE9e",
      email: "adresse courriel",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "date-heure ISO",
      date: "date ISO",
      time: "heure ISO",
      duration: "dur\xE9e ISO",
      ipv4: "adresse IPv4",
      ipv6: "adresse IPv6",
      cidrv4: "plage IPv4",
      cidrv6: "plage IPv6",
      base64: "cha\xEEne encod\xE9e en base64",
      base64url: "cha\xEEne encod\xE9e en base64url",
      json_string: "cha\xEEne JSON",
      e164: "num\xE9ro E.164",
      jwt: "JWT",
      template_literal: "entr\xE9e"
    };
    const TypeDictionary = {
      nan: "NaN"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Entr\xE9e invalide : attendu instanceof ${issue2.expected}, re\xE7u ${received}`;
          }
          return `Entr\xE9e invalide : attendu ${expected}, re\xE7u ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Entr\xE9e invalide : attendu ${stringifyPrimitive(issue2.values[0])}`;
          return `Option invalide : attendu l'une des valeurs suivantes ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "\u2264" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Trop grand : attendu que ${issue2.origin ?? "la valeur"} ait ${adj}${issue2.maximum.toString()} ${sizing.unit}`;
          return `Trop grand : attendu que ${issue2.origin ?? "la valeur"} soit ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? "\u2265" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Trop petit : attendu que ${issue2.origin} ait ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Trop petit : attendu que ${issue2.origin} soit ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `Cha\xEEne invalide : doit commencer par "${_issue.prefix}"`;
          }
          if (_issue.format === "ends_with")
            return `Cha\xEEne invalide : doit se terminer par "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Cha\xEEne invalide : doit inclure "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Cha\xEEne invalide : doit correspondre au motif ${_issue.pattern}`;
          return `${FormatDictionary[_issue.format] ?? issue2.format} invalide`;
        }
        case "not_multiple_of":
          return `Nombre invalide : doit \xEAtre un multiple de ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Cl\xE9${issue2.keys.length > 1 ? "s" : ""} non reconnue${issue2.keys.length > 1 ? "s" : ""} : ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Cl\xE9 invalide dans ${issue2.origin}`;
        case "invalid_union":
          return "Entr\xE9e invalide";
        case "invalid_element":
          return `Valeur invalide dans ${issue2.origin}`;
        default:
          return `Entr\xE9e invalide`;
      }
    };
  };
  function fr_CA_default() {
    return {
      localeError: error16()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/he.js
  init_runtime();
  var error17 = () => {
    const TypeNames = {
      string: { label: "\u05DE\u05D7\u05E8\u05D5\u05D6\u05EA", gender: "f" },
      number: { label: "\u05DE\u05E1\u05E4\u05E8", gender: "m" },
      boolean: { label: "\u05E2\u05E8\u05DA \u05D1\u05D5\u05DC\u05D9\u05D0\u05E0\u05D9", gender: "m" },
      bigint: { label: "BigInt", gender: "m" },
      date: { label: "\u05EA\u05D0\u05E8\u05D9\u05DA", gender: "m" },
      array: { label: "\u05DE\u05E2\u05E8\u05DA", gender: "m" },
      object: { label: "\u05D0\u05D5\u05D1\u05D9\u05D9\u05E7\u05D8", gender: "m" },
      null: { label: "\u05E2\u05E8\u05DA \u05E8\u05D9\u05E7 (null)", gender: "m" },
      undefined: { label: "\u05E2\u05E8\u05DA \u05DC\u05D0 \u05DE\u05D5\u05D2\u05D3\u05E8 (undefined)", gender: "m" },
      symbol: { label: "\u05E1\u05D9\u05DE\u05D1\u05D5\u05DC (Symbol)", gender: "m" },
      function: { label: "\u05E4\u05D5\u05E0\u05E7\u05E6\u05D9\u05D4", gender: "f" },
      map: { label: "\u05DE\u05E4\u05D4 (Map)", gender: "f" },
      set: { label: "\u05E7\u05D1\u05D5\u05E6\u05D4 (Set)", gender: "f" },
      file: { label: "\u05E7\u05D5\u05D1\u05E5", gender: "m" },
      promise: { label: "Promise", gender: "m" },
      NaN: { label: "NaN", gender: "m" },
      unknown: { label: "\u05E2\u05E8\u05DA \u05DC\u05D0 \u05D9\u05D3\u05D5\u05E2", gender: "m" },
      value: { label: "\u05E2\u05E8\u05DA", gender: "m" }
    };
    const Sizable = {
      string: { unit: "\u05EA\u05D5\u05D5\u05D9\u05DD", shortLabel: "\u05E7\u05E6\u05E8", longLabel: "\u05D0\u05E8\u05D5\u05DA" },
      file: { unit: "\u05D1\u05D9\u05D9\u05D8\u05D9\u05DD", shortLabel: "\u05E7\u05D8\u05DF", longLabel: "\u05D2\u05D3\u05D5\u05DC" },
      array: { unit: "\u05E4\u05E8\u05D9\u05D8\u05D9\u05DD", shortLabel: "\u05E7\u05D8\u05DF", longLabel: "\u05D2\u05D3\u05D5\u05DC" },
      set: { unit: "\u05E4\u05E8\u05D9\u05D8\u05D9\u05DD", shortLabel: "\u05E7\u05D8\u05DF", longLabel: "\u05D2\u05D3\u05D5\u05DC" },
      number: { unit: "", shortLabel: "\u05E7\u05D8\u05DF", longLabel: "\u05D2\u05D3\u05D5\u05DC" }
      // no unit
    };
    const typeEntry = (t) => t ? TypeNames[t] : void 0;
    const typeLabel = (t) => {
      const e = typeEntry(t);
      if (e)
        return e.label;
      return t ?? TypeNames.unknown.label;
    };
    const withDefinite = (t) => `\u05D4${typeLabel(t)}`;
    const verbFor = (t) => {
      const e = typeEntry(t);
      const gender = e?.gender ?? "m";
      return gender === "f" ? "\u05E6\u05E8\u05D9\u05DB\u05D4 \u05DC\u05D4\u05D9\u05D5\u05EA" : "\u05E6\u05E8\u05D9\u05DA \u05DC\u05D4\u05D9\u05D5\u05EA";
    };
    const getSizing = (origin) => {
      if (!origin)
        return null;
      return Sizable[origin] ?? null;
    };
    const FormatDictionary = {
      regex: { label: "\u05E7\u05DC\u05D8", gender: "m" },
      email: { label: "\u05DB\u05EA\u05D5\u05D1\u05EA \u05D0\u05D9\u05DE\u05D9\u05D9\u05DC", gender: "f" },
      url: { label: "\u05DB\u05EA\u05D5\u05D1\u05EA \u05E8\u05E9\u05EA", gender: "f" },
      emoji: { label: "\u05D0\u05D9\u05DE\u05D5\u05D2'\u05D9", gender: "m" },
      uuid: { label: "UUID", gender: "m" },
      nanoid: { label: "nanoid", gender: "m" },
      guid: { label: "GUID", gender: "m" },
      cuid: { label: "cuid", gender: "m" },
      cuid2: { label: "cuid2", gender: "m" },
      ulid: { label: "ULID", gender: "m" },
      xid: { label: "XID", gender: "m" },
      ksuid: { label: "KSUID", gender: "m" },
      datetime: { label: "\u05EA\u05D0\u05E8\u05D9\u05DA \u05D5\u05D6\u05DE\u05DF ISO", gender: "m" },
      date: { label: "\u05EA\u05D0\u05E8\u05D9\u05DA ISO", gender: "m" },
      time: { label: "\u05D6\u05DE\u05DF ISO", gender: "m" },
      duration: { label: "\u05DE\u05E9\u05DA \u05D6\u05DE\u05DF ISO", gender: "m" },
      ipv4: { label: "\u05DB\u05EA\u05D5\u05D1\u05EA IPv4", gender: "f" },
      ipv6: { label: "\u05DB\u05EA\u05D5\u05D1\u05EA IPv6", gender: "f" },
      cidrv4: { label: "\u05D8\u05D5\u05D5\u05D7 IPv4", gender: "m" },
      cidrv6: { label: "\u05D8\u05D5\u05D5\u05D7 IPv6", gender: "m" },
      base64: { label: "\u05DE\u05D7\u05E8\u05D5\u05D6\u05EA \u05D1\u05D1\u05E1\u05D9\u05E1 64", gender: "f" },
      base64url: { label: "\u05DE\u05D7\u05E8\u05D5\u05D6\u05EA \u05D1\u05D1\u05E1\u05D9\u05E1 64 \u05DC\u05DB\u05EA\u05D5\u05D1\u05D5\u05EA \u05E8\u05E9\u05EA", gender: "f" },
      json_string: { label: "\u05DE\u05D7\u05E8\u05D5\u05D6\u05EA JSON", gender: "f" },
      e164: { label: "\u05DE\u05E1\u05E4\u05E8 E.164", gender: "m" },
      jwt: { label: "JWT", gender: "m" },
      ends_with: { label: "\u05E7\u05DC\u05D8", gender: "m" },
      includes: { label: "\u05E7\u05DC\u05D8", gender: "m" },
      lowercase: { label: "\u05E7\u05DC\u05D8", gender: "m" },
      starts_with: { label: "\u05E7\u05DC\u05D8", gender: "m" },
      uppercase: { label: "\u05E7\u05DC\u05D8", gender: "m" }
    };
    const TypeDictionary = {
      nan: "NaN"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expectedKey = issue2.expected;
          const expected = TypeDictionary[expectedKey ?? ""] ?? typeLabel(expectedKey);
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? TypeNames[receivedType]?.label ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u05E7\u05DC\u05D8 \u05DC\u05D0 \u05EA\u05E7\u05D9\u05DF: \u05E6\u05E8\u05D9\u05DA \u05DC\u05D4\u05D9\u05D5\u05EA instanceof ${issue2.expected}, \u05D4\u05EA\u05E7\u05D1\u05DC ${received}`;
          }
          return `\u05E7\u05DC\u05D8 \u05DC\u05D0 \u05EA\u05E7\u05D9\u05DF: \u05E6\u05E8\u05D9\u05DA \u05DC\u05D4\u05D9\u05D5\u05EA ${expected}, \u05D4\u05EA\u05E7\u05D1\u05DC ${received}`;
        }
        case "invalid_value": {
          if (issue2.values.length === 1) {
            return `\u05E2\u05E8\u05DA \u05DC\u05D0 \u05EA\u05E7\u05D9\u05DF: \u05D4\u05E2\u05E8\u05DA \u05D7\u05D9\u05D9\u05D1 \u05DC\u05D4\u05D9\u05D5\u05EA ${stringifyPrimitive(issue2.values[0])}`;
          }
          const stringified = issue2.values.map((v) => stringifyPrimitive(v));
          if (issue2.values.length === 2) {
            return `\u05E2\u05E8\u05DA \u05DC\u05D0 \u05EA\u05E7\u05D9\u05DF: \u05D4\u05D0\u05E4\u05E9\u05E8\u05D5\u05D9\u05D5\u05EA \u05D4\u05DE\u05EA\u05D0\u05D9\u05DE\u05D5\u05EA \u05D4\u05DF ${stringified[0]} \u05D0\u05D5 ${stringified[1]}`;
          }
          const lastValue = stringified[stringified.length - 1];
          const restValues = stringified.slice(0, -1).join(", ");
          return `\u05E2\u05E8\u05DA \u05DC\u05D0 \u05EA\u05E7\u05D9\u05DF: \u05D4\u05D0\u05E4\u05E9\u05E8\u05D5\u05D9\u05D5\u05EA \u05D4\u05DE\u05EA\u05D0\u05D9\u05DE\u05D5\u05EA \u05D4\u05DF ${restValues} \u05D0\u05D5 ${lastValue}`;
        }
        case "too_big": {
          const sizing = getSizing(issue2.origin);
          const subject = withDefinite(issue2.origin ?? "value");
          if (issue2.origin === "string") {
            return `${sizing?.longLabel ?? "\u05D0\u05E8\u05D5\u05DA"} \u05DE\u05D3\u05D9: ${subject} \u05E6\u05E8\u05D9\u05DB\u05D4 \u05DC\u05D4\u05DB\u05D9\u05DC ${issue2.maximum.toString()} ${sizing?.unit ?? ""} ${issue2.inclusive ? "\u05D0\u05D5 \u05E4\u05D7\u05D5\u05EA" : "\u05DC\u05DB\u05DC \u05D4\u05D9\u05D5\u05EA\u05E8"}`.trim();
          }
          if (issue2.origin === "number") {
            const comparison = issue2.inclusive ? `\u05E7\u05D8\u05DF \u05D0\u05D5 \u05E9\u05D5\u05D5\u05D4 \u05DC-${issue2.maximum}` : `\u05E7\u05D8\u05DF \u05DE-${issue2.maximum}`;
            return `\u05D2\u05D3\u05D5\u05DC \u05DE\u05D3\u05D9: ${subject} \u05E6\u05E8\u05D9\u05DA \u05DC\u05D4\u05D9\u05D5\u05EA ${comparison}`;
          }
          if (issue2.origin === "array" || issue2.origin === "set") {
            const verb = issue2.origin === "set" ? "\u05E6\u05E8\u05D9\u05DB\u05D4" : "\u05E6\u05E8\u05D9\u05DA";
            const comparison = issue2.inclusive ? `${issue2.maximum} ${sizing?.unit ?? ""} \u05D0\u05D5 \u05E4\u05D7\u05D5\u05EA` : `\u05E4\u05D7\u05D5\u05EA \u05DE-${issue2.maximum} ${sizing?.unit ?? ""}`;
            return `\u05D2\u05D3\u05D5\u05DC \u05DE\u05D3\u05D9: ${subject} ${verb} \u05DC\u05D4\u05DB\u05D9\u05DC ${comparison}`.trim();
          }
          const adj = issue2.inclusive ? "<=" : "<";
          const be = verbFor(issue2.origin ?? "value");
          if (sizing?.unit) {
            return `${sizing.longLabel} \u05DE\u05D3\u05D9: ${subject} ${be} ${adj}${issue2.maximum.toString()} ${sizing.unit}`;
          }
          return `${sizing?.longLabel ?? "\u05D2\u05D3\u05D5\u05DC"} \u05DE\u05D3\u05D9: ${subject} ${be} ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const sizing = getSizing(issue2.origin);
          const subject = withDefinite(issue2.origin ?? "value");
          if (issue2.origin === "string") {
            return `${sizing?.shortLabel ?? "\u05E7\u05E6\u05E8"} \u05DE\u05D3\u05D9: ${subject} \u05E6\u05E8\u05D9\u05DB\u05D4 \u05DC\u05D4\u05DB\u05D9\u05DC ${issue2.minimum.toString()} ${sizing?.unit ?? ""} ${issue2.inclusive ? "\u05D0\u05D5 \u05D9\u05D5\u05EA\u05E8" : "\u05DC\u05E4\u05D7\u05D5\u05EA"}`.trim();
          }
          if (issue2.origin === "number") {
            const comparison = issue2.inclusive ? `\u05D2\u05D3\u05D5\u05DC \u05D0\u05D5 \u05E9\u05D5\u05D5\u05D4 \u05DC-${issue2.minimum}` : `\u05D2\u05D3\u05D5\u05DC \u05DE-${issue2.minimum}`;
            return `\u05E7\u05D8\u05DF \u05DE\u05D3\u05D9: ${subject} \u05E6\u05E8\u05D9\u05DA \u05DC\u05D4\u05D9\u05D5\u05EA ${comparison}`;
          }
          if (issue2.origin === "array" || issue2.origin === "set") {
            const verb = issue2.origin === "set" ? "\u05E6\u05E8\u05D9\u05DB\u05D4" : "\u05E6\u05E8\u05D9\u05DA";
            if (issue2.minimum === 1 && issue2.inclusive) {
              const singularPhrase = issue2.origin === "set" ? "\u05DC\u05E4\u05D7\u05D5\u05EA \u05E4\u05E8\u05D9\u05D8 \u05D0\u05D7\u05D3" : "\u05DC\u05E4\u05D7\u05D5\u05EA \u05E4\u05E8\u05D9\u05D8 \u05D0\u05D7\u05D3";
              return `\u05E7\u05D8\u05DF \u05DE\u05D3\u05D9: ${subject} ${verb} \u05DC\u05D4\u05DB\u05D9\u05DC ${singularPhrase}`;
            }
            const comparison = issue2.inclusive ? `${issue2.minimum} ${sizing?.unit ?? ""} \u05D0\u05D5 \u05D9\u05D5\u05EA\u05E8` : `\u05D9\u05D5\u05EA\u05E8 \u05DE-${issue2.minimum} ${sizing?.unit ?? ""}`;
            return `\u05E7\u05D8\u05DF \u05DE\u05D3\u05D9: ${subject} ${verb} \u05DC\u05D4\u05DB\u05D9\u05DC ${comparison}`.trim();
          }
          const adj = issue2.inclusive ? ">=" : ">";
          const be = verbFor(issue2.origin ?? "value");
          if (sizing?.unit) {
            return `${sizing.shortLabel} \u05DE\u05D3\u05D9: ${subject} ${be} ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `${sizing?.shortLabel ?? "\u05E7\u05D8\u05DF"} \u05DE\u05D3\u05D9: ${subject} ${be} ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `\u05D4\u05DE\u05D7\u05E8\u05D5\u05D6\u05EA \u05D7\u05D9\u05D9\u05D1\u05EA \u05DC\u05D4\u05EA\u05D7\u05D9\u05DC \u05D1 "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `\u05D4\u05DE\u05D7\u05E8\u05D5\u05D6\u05EA \u05D7\u05D9\u05D9\u05D1\u05EA \u05DC\u05D4\u05E1\u05EA\u05D9\u05D9\u05DD \u05D1 "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `\u05D4\u05DE\u05D7\u05E8\u05D5\u05D6\u05EA \u05D7\u05D9\u05D9\u05D1\u05EA \u05DC\u05DB\u05DC\u05D5\u05DC "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u05D4\u05DE\u05D7\u05E8\u05D5\u05D6\u05EA \u05D7\u05D9\u05D9\u05D1\u05EA \u05DC\u05D4\u05EA\u05D0\u05D9\u05DD \u05DC\u05EA\u05D1\u05E0\u05D9\u05EA ${_issue.pattern}`;
          const nounEntry = FormatDictionary[_issue.format];
          const noun = nounEntry?.label ?? _issue.format;
          const gender = nounEntry?.gender ?? "m";
          const adjective = gender === "f" ? "\u05EA\u05E7\u05D9\u05E0\u05D4" : "\u05EA\u05E7\u05D9\u05DF";
          return `${noun} \u05DC\u05D0 ${adjective}`;
        }
        case "not_multiple_of":
          return `\u05DE\u05E1\u05E4\u05E8 \u05DC\u05D0 \u05EA\u05E7\u05D9\u05DF: \u05D7\u05D9\u05D9\u05D1 \u05DC\u05D4\u05D9\u05D5\u05EA \u05DE\u05DB\u05E4\u05DC\u05D4 \u05E9\u05DC ${issue2.divisor}`;
        case "unrecognized_keys":
          return `\u05DE\u05E4\u05EA\u05D7${issue2.keys.length > 1 ? "\u05D5\u05EA" : ""} \u05DC\u05D0 \u05DE\u05D6\u05D5\u05D4${issue2.keys.length > 1 ? "\u05D9\u05DD" : "\u05D4"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key": {
          return `\u05E9\u05D3\u05D4 \u05DC\u05D0 \u05EA\u05E7\u05D9\u05DF \u05D1\u05D0\u05D5\u05D1\u05D9\u05D9\u05E7\u05D8`;
        }
        case "invalid_union":
          return "\u05E7\u05DC\u05D8 \u05DC\u05D0 \u05EA\u05E7\u05D9\u05DF";
        case "invalid_element": {
          const place = withDefinite(issue2.origin ?? "array");
          return `\u05E2\u05E8\u05DA \u05DC\u05D0 \u05EA\u05E7\u05D9\u05DF \u05D1${place}`;
        }
        default:
          return `\u05E7\u05DC\u05D8 \u05DC\u05D0 \u05EA\u05E7\u05D9\u05DF`;
      }
    };
  };
  function he_default() {
    return {
      localeError: error17()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/hr.js
  init_runtime();
  var error18 = () => {
    const Sizable = {
      string: { unit: "znakova", verb: "imati" },
      file: { unit: "bajtova", verb: "imati" },
      array: { unit: "stavki", verb: "imati" },
      set: { unit: "stavki", verb: "imati" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "unos",
      email: "email adresa",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO datum i vrijeme",
      date: "ISO datum",
      time: "ISO vrijeme",
      duration: "ISO trajanje",
      ipv4: "IPv4 adresa",
      ipv6: "IPv6 adresa",
      cidrv4: "IPv4 raspon",
      cidrv6: "IPv6 raspon",
      base64: "base64 kodirani tekst",
      base64url: "base64url kodirani tekst",
      json_string: "JSON tekst",
      e164: "E.164 broj",
      jwt: "JWT",
      template_literal: "unos"
    };
    const TypeDictionary = {
      nan: "NaN",
      string: "tekst",
      number: "broj",
      boolean: "boolean",
      array: "niz",
      object: "objekt",
      set: "skup",
      file: "datoteka",
      date: "datum",
      bigint: "bigint",
      symbol: "simbol",
      undefined: "undefined",
      null: "null",
      function: "funkcija",
      map: "mapa"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Neispravan unos: o\u010Dekuje se instanceof ${issue2.expected}, a primljeno je ${received}`;
          }
          return `Neispravan unos: o\u010Dekuje se ${expected}, a primljeno je ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Neispravna vrijednost: o\u010Dekivano ${stringifyPrimitive(issue2.values[0])}`;
          return `Neispravna opcija: o\u010Dekivano jedno od ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          const origin = TypeDictionary[issue2.origin] ?? issue2.origin;
          if (sizing)
            return `Preveliko: o\u010Dekivano da ${origin ?? "vrijednost"} ima ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elemenata"}`;
          return `Preveliko: o\u010Dekivano da ${origin ?? "vrijednost"} bude ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          const origin = TypeDictionary[issue2.origin] ?? issue2.origin;
          if (sizing) {
            return `Premalo: o\u010Dekivano da ${origin} ima ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Premalo: o\u010Dekivano da ${origin} bude ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Neispravan tekst: mora zapo\u010Dinjati s "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `Neispravan tekst: mora zavr\u0161avati s "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Neispravan tekst: mora sadr\u017Eavati "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Neispravan tekst: mora odgovarati uzorku ${_issue.pattern}`;
          return `Neispravna ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Neispravan broj: mora biti vi\u0161ekratnik od ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Neprepoznat${issue2.keys.length > 1 ? "i klju\u010Devi" : " klju\u010D"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Neispravan klju\u010D u ${TypeDictionary[issue2.origin] ?? issue2.origin}`;
        case "invalid_union":
          return "Neispravan unos";
        case "invalid_element":
          return `Neispravna vrijednost u ${TypeDictionary[issue2.origin] ?? issue2.origin}`;
        default:
          return `Neispravan unos`;
      }
    };
  };
  function hr_default() {
    return {
      localeError: error18()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/hu.js
  init_runtime();
  var error19 = () => {
    const Sizable = {
      string: { unit: "karakter", verb: "legyen" },
      file: { unit: "byte", verb: "legyen" },
      array: { unit: "elem", verb: "legyen" },
      set: { unit: "elem", verb: "legyen" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "bemenet",
      email: "email c\xEDm",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO id\u0151b\xE9lyeg",
      date: "ISO d\xE1tum",
      time: "ISO id\u0151",
      duration: "ISO id\u0151intervallum",
      ipv4: "IPv4 c\xEDm",
      ipv6: "IPv6 c\xEDm",
      cidrv4: "IPv4 tartom\xE1ny",
      cidrv6: "IPv6 tartom\xE1ny",
      base64: "base64-k\xF3dolt string",
      base64url: "base64url-k\xF3dolt string",
      json_string: "JSON string",
      e164: "E.164 sz\xE1m",
      jwt: "JWT",
      template_literal: "bemenet"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "sz\xE1m",
      array: "t\xF6mb"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\xC9rv\xE9nytelen bemenet: a v\xE1rt \xE9rt\xE9k instanceof ${issue2.expected}, a kapott \xE9rt\xE9k ${received}`;
          }
          return `\xC9rv\xE9nytelen bemenet: a v\xE1rt \xE9rt\xE9k ${expected}, a kapott \xE9rt\xE9k ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\xC9rv\xE9nytelen bemenet: a v\xE1rt \xE9rt\xE9k ${stringifyPrimitive(issue2.values[0])}`;
          return `\xC9rv\xE9nytelen opci\xF3: valamelyik \xE9rt\xE9k v\xE1rt ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `T\xFAl nagy: ${issue2.origin ?? "\xE9rt\xE9k"} m\xE9rete t\xFAl nagy ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elem"}`;
          return `T\xFAl nagy: a bemeneti \xE9rt\xE9k ${issue2.origin ?? "\xE9rt\xE9k"} t\xFAl nagy: ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `T\xFAl kicsi: a bemeneti \xE9rt\xE9k ${issue2.origin} m\xE9rete t\xFAl kicsi ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `T\xFAl kicsi: a bemeneti \xE9rt\xE9k ${issue2.origin} t\xFAl kicsi ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `\xC9rv\xE9nytelen string: "${_issue.prefix}" \xE9rt\xE9kkel kell kezd\u0151dnie`;
          if (_issue.format === "ends_with")
            return `\xC9rv\xE9nytelen string: "${_issue.suffix}" \xE9rt\xE9kkel kell v\xE9gz\u0151dnie`;
          if (_issue.format === "includes")
            return `\xC9rv\xE9nytelen string: "${_issue.includes}" \xE9rt\xE9ket kell tartalmaznia`;
          if (_issue.format === "regex")
            return `\xC9rv\xE9nytelen string: ${_issue.pattern} mint\xE1nak kell megfelelnie`;
          return `\xC9rv\xE9nytelen ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\xC9rv\xE9nytelen sz\xE1m: ${issue2.divisor} t\xF6bbsz\xF6r\xF6s\xE9nek kell lennie`;
        case "unrecognized_keys":
          return `Ismeretlen kulcs${issue2.keys.length > 1 ? "s" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\xC9rv\xE9nytelen kulcs ${issue2.origin}`;
        case "invalid_union":
          return "\xC9rv\xE9nytelen bemenet";
        case "invalid_element":
          return `\xC9rv\xE9nytelen \xE9rt\xE9k: ${issue2.origin}`;
        default:
          return `\xC9rv\xE9nytelen bemenet`;
      }
    };
  };
  function hu_default() {
    return {
      localeError: error19()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/hy.js
  init_runtime();
  function getArmenianPlural(count, one, many) {
    return Math.abs(count) === 1 ? one : many;
  }
  function withDefiniteArticle(word) {
    if (!word)
      return "";
    const vowels = ["\u0561", "\u0565", "\u0568", "\u056B", "\u0578", "\u0578\u0582", "\u0585"];
    const lastChar = word[word.length - 1];
    return word + (vowels.includes(lastChar) ? "\u0576" : "\u0568");
  }
  var error20 = () => {
    const Sizable = {
      string: {
        unit: {
          one: "\u0576\u0577\u0561\u0576",
          many: "\u0576\u0577\u0561\u0576\u0576\u0565\u0580"
        },
        verb: "\u0578\u0582\u0576\u0565\u0576\u0561\u056C"
      },
      file: {
        unit: {
          one: "\u0562\u0561\u0575\u0569",
          many: "\u0562\u0561\u0575\u0569\u0565\u0580"
        },
        verb: "\u0578\u0582\u0576\u0565\u0576\u0561\u056C"
      },
      array: {
        unit: {
          one: "\u057F\u0561\u0580\u0580",
          many: "\u057F\u0561\u0580\u0580\u0565\u0580"
        },
        verb: "\u0578\u0582\u0576\u0565\u0576\u0561\u056C"
      },
      set: {
        unit: {
          one: "\u057F\u0561\u0580\u0580",
          many: "\u057F\u0561\u0580\u0580\u0565\u0580"
        },
        verb: "\u0578\u0582\u0576\u0565\u0576\u0561\u056C"
      }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u0574\u0578\u0582\u057F\u0584",
      email: "\u0567\u056C. \u0570\u0561\u057D\u0581\u0565",
      url: "URL",
      emoji: "\u0567\u0574\u0578\u057B\u056B",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO \u0561\u0574\u057D\u0561\u0569\u056B\u057E \u0587 \u056A\u0561\u0574",
      date: "ISO \u0561\u0574\u057D\u0561\u0569\u056B\u057E",
      time: "ISO \u056A\u0561\u0574",
      duration: "ISO \u057F\u0587\u0578\u0572\u0578\u0582\u0569\u0575\u0578\u0582\u0576",
      ipv4: "IPv4 \u0570\u0561\u057D\u0581\u0565",
      ipv6: "IPv6 \u0570\u0561\u057D\u0581\u0565",
      cidrv4: "IPv4 \u0574\u056B\u057B\u0561\u056F\u0561\u0575\u0584",
      cidrv6: "IPv6 \u0574\u056B\u057B\u0561\u056F\u0561\u0575\u0584",
      base64: "base64 \u0571\u0587\u0561\u0579\u0561\u0583\u0578\u057E \u057F\u0578\u0572",
      base64url: "base64url \u0571\u0587\u0561\u0579\u0561\u0583\u0578\u057E \u057F\u0578\u0572",
      json_string: "JSON \u057F\u0578\u0572",
      e164: "E.164 \u0570\u0561\u0574\u0561\u0580",
      jwt: "JWT",
      template_literal: "\u0574\u0578\u0582\u057F\u0584"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u0569\u056B\u057E",
      array: "\u0566\u0561\u0576\u0563\u057E\u0561\u056E"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u054D\u056D\u0561\u056C \u0574\u0578\u0582\u057F\u0584\u0561\u0563\u0580\u0578\u0582\u0574\u2024 \u057D\u057A\u0561\u057D\u057E\u0578\u0582\u0574 \u0567\u0580 instanceof ${issue2.expected}, \u057D\u057F\u0561\u0581\u057E\u0565\u056C \u0567 ${received}`;
          }
          return `\u054D\u056D\u0561\u056C \u0574\u0578\u0582\u057F\u0584\u0561\u0563\u0580\u0578\u0582\u0574\u2024 \u057D\u057A\u0561\u057D\u057E\u0578\u0582\u0574 \u0567\u0580 ${expected}, \u057D\u057F\u0561\u0581\u057E\u0565\u056C \u0567 ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u054D\u056D\u0561\u056C \u0574\u0578\u0582\u057F\u0584\u0561\u0563\u0580\u0578\u0582\u0574\u2024 \u057D\u057A\u0561\u057D\u057E\u0578\u0582\u0574 \u0567\u0580 ${stringifyPrimitive(issue2.values[1])}`;
          return `\u054D\u056D\u0561\u056C \u057F\u0561\u0580\u0562\u0565\u0580\u0561\u056F\u2024 \u057D\u057A\u0561\u057D\u057E\u0578\u0582\u0574 \u0567\u0580 \u0570\u0565\u057F\u0587\u0575\u0561\u056C\u0576\u0565\u0580\u056B\u0581 \u0574\u0565\u056F\u0568\u055D ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            const maxValue = Number(issue2.maximum);
            const unit = getArmenianPlural(maxValue, sizing.unit.one, sizing.unit.many);
            return `\u0549\u0561\u0583\u0561\u0566\u0561\u0576\u0581 \u0574\u0565\u056E \u0561\u0580\u056A\u0565\u0584\u2024 \u057D\u057A\u0561\u057D\u057E\u0578\u0582\u0574 \u0567, \u0578\u0580 ${withDefiniteArticle(issue2.origin ?? "\u0561\u0580\u056A\u0565\u0584")} \u056F\u0578\u0582\u0576\u0565\u0576\u0561 ${adj}${issue2.maximum.toString()} ${unit}`;
          }
          return `\u0549\u0561\u0583\u0561\u0566\u0561\u0576\u0581 \u0574\u0565\u056E \u0561\u0580\u056A\u0565\u0584\u2024 \u057D\u057A\u0561\u057D\u057E\u0578\u0582\u0574 \u0567, \u0578\u0580 ${withDefiniteArticle(issue2.origin ?? "\u0561\u0580\u056A\u0565\u0584")} \u056C\u056B\u0576\u056B ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            const minValue = Number(issue2.minimum);
            const unit = getArmenianPlural(minValue, sizing.unit.one, sizing.unit.many);
            return `\u0549\u0561\u0583\u0561\u0566\u0561\u0576\u0581 \u0583\u0578\u0584\u0580 \u0561\u0580\u056A\u0565\u0584\u2024 \u057D\u057A\u0561\u057D\u057E\u0578\u0582\u0574 \u0567, \u0578\u0580 ${withDefiniteArticle(issue2.origin)} \u056F\u0578\u0582\u0576\u0565\u0576\u0561 ${adj}${issue2.minimum.toString()} ${unit}`;
          }
          return `\u0549\u0561\u0583\u0561\u0566\u0561\u0576\u0581 \u0583\u0578\u0584\u0580 \u0561\u0580\u056A\u0565\u0584\u2024 \u057D\u057A\u0561\u057D\u057E\u0578\u0582\u0574 \u0567, \u0578\u0580 ${withDefiniteArticle(issue2.origin)} \u056C\u056B\u0576\u056B ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `\u054D\u056D\u0561\u056C \u057F\u0578\u0572\u2024 \u057A\u0565\u057F\u0584 \u0567 \u057D\u056F\u057D\u057E\u056B "${_issue.prefix}"-\u0578\u057E`;
          if (_issue.format === "ends_with")
            return `\u054D\u056D\u0561\u056C \u057F\u0578\u0572\u2024 \u057A\u0565\u057F\u0584 \u0567 \u0561\u057E\u0561\u0580\u057F\u057E\u056B "${_issue.suffix}"-\u0578\u057E`;
          if (_issue.format === "includes")
            return `\u054D\u056D\u0561\u056C \u057F\u0578\u0572\u2024 \u057A\u0565\u057F\u0584 \u0567 \u057A\u0561\u0580\u0578\u0582\u0576\u0561\u056F\u056B "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u054D\u056D\u0561\u056C \u057F\u0578\u0572\u2024 \u057A\u0565\u057F\u0584 \u0567 \u0570\u0561\u0574\u0561\u057A\u0561\u057F\u0561\u057D\u056D\u0561\u0576\u056B ${_issue.pattern} \u0571\u0587\u0561\u0579\u0561\u0583\u056B\u0576`;
          return `\u054D\u056D\u0561\u056C ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u054D\u056D\u0561\u056C \u0569\u056B\u057E\u2024 \u057A\u0565\u057F\u0584 \u0567 \u0562\u0561\u0566\u0574\u0561\u057A\u0561\u057F\u056B\u056F \u056C\u056B\u0576\u056B ${issue2.divisor}-\u056B`;
        case "unrecognized_keys":
          return `\u0549\u0573\u0561\u0576\u0561\u0579\u057E\u0561\u056E \u0562\u0561\u0576\u0561\u056C\u056B${issue2.keys.length > 1 ? "\u0576\u0565\u0580" : ""}. ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\u054D\u056D\u0561\u056C \u0562\u0561\u0576\u0561\u056C\u056B ${withDefiniteArticle(issue2.origin)}-\u0578\u0582\u0574`;
        case "invalid_union":
          return "\u054D\u056D\u0561\u056C \u0574\u0578\u0582\u057F\u0584\u0561\u0563\u0580\u0578\u0582\u0574";
        case "invalid_element":
          return `\u054D\u056D\u0561\u056C \u0561\u0580\u056A\u0565\u0584 ${withDefiniteArticle(issue2.origin)}-\u0578\u0582\u0574`;
        default:
          return `\u054D\u056D\u0561\u056C \u0574\u0578\u0582\u057F\u0584\u0561\u0563\u0580\u0578\u0582\u0574`;
      }
    };
  };
  function hy_default() {
    return {
      localeError: error20()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/id.js
  init_runtime();
  var error21 = () => {
    const Sizable = {
      string: { unit: "karakter", verb: "memiliki" },
      file: { unit: "byte", verb: "memiliki" },
      array: { unit: "item", verb: "memiliki" },
      set: { unit: "item", verb: "memiliki" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "input",
      email: "alamat email",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "tanggal dan waktu format ISO",
      date: "tanggal format ISO",
      time: "jam format ISO",
      duration: "durasi format ISO",
      ipv4: "alamat IPv4",
      ipv6: "alamat IPv6",
      cidrv4: "rentang alamat IPv4",
      cidrv6: "rentang alamat IPv6",
      base64: "string dengan enkode base64",
      base64url: "string dengan enkode base64url",
      json_string: "string JSON",
      e164: "angka E.164",
      jwt: "JWT",
      template_literal: "input"
    };
    const TypeDictionary = {
      nan: "NaN"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Input tidak valid: diharapkan instanceof ${issue2.expected}, diterima ${received}`;
          }
          return `Input tidak valid: diharapkan ${expected}, diterima ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Input tidak valid: diharapkan ${stringifyPrimitive(issue2.values[0])}`;
          return `Pilihan tidak valid: diharapkan salah satu dari ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Terlalu besar: diharapkan ${issue2.origin ?? "value"} memiliki ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elemen"}`;
          return `Terlalu besar: diharapkan ${issue2.origin ?? "value"} menjadi ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Terlalu kecil: diharapkan ${issue2.origin} memiliki ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Terlalu kecil: diharapkan ${issue2.origin} menjadi ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `String tidak valid: harus dimulai dengan "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `String tidak valid: harus berakhir dengan "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `String tidak valid: harus menyertakan "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `String tidak valid: harus sesuai pola ${_issue.pattern}`;
          return `${FormatDictionary[_issue.format] ?? issue2.format} tidak valid`;
        }
        case "not_multiple_of":
          return `Angka tidak valid: harus kelipatan dari ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Kunci tidak dikenali ${issue2.keys.length > 1 ? "s" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Kunci tidak valid di ${issue2.origin}`;
        case "invalid_union":
          return "Input tidak valid";
        case "invalid_element":
          return `Nilai tidak valid di ${issue2.origin}`;
        default:
          return `Input tidak valid`;
      }
    };
  };
  function id_default() {
    return {
      localeError: error21()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/is.js
  init_runtime();
  var error22 = () => {
    const Sizable = {
      string: { unit: "stafi", verb: "a\xF0 hafa" },
      file: { unit: "b\xE6ti", verb: "a\xF0 hafa" },
      array: { unit: "hluti", verb: "a\xF0 hafa" },
      set: { unit: "hluti", verb: "a\xF0 hafa" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "gildi",
      email: "netfang",
      url: "vefsl\xF3\xF0",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO dagsetning og t\xEDmi",
      date: "ISO dagsetning",
      time: "ISO t\xEDmi",
      duration: "ISO t\xEDmalengd",
      ipv4: "IPv4 address",
      ipv6: "IPv6 address",
      cidrv4: "IPv4 range",
      cidrv6: "IPv6 range",
      base64: "base64-encoded strengur",
      base64url: "base64url-encoded strengur",
      json_string: "JSON strengur",
      e164: "E.164 t\xF6lugildi",
      jwt: "JWT",
      template_literal: "gildi"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "n\xFAmer",
      array: "fylki"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Rangt gildi: \xDE\xFA sl\xF3st inn ${received} \xFEar sem \xE1 a\xF0 vera instanceof ${issue2.expected}`;
          }
          return `Rangt gildi: \xDE\xFA sl\xF3st inn ${received} \xFEar sem \xE1 a\xF0 vera ${expected}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Rangt gildi: gert r\xE1\xF0 fyrir ${stringifyPrimitive(issue2.values[0])}`;
          return `\xD3gilt val: m\xE1 vera eitt af eftirfarandi ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Of st\xF3rt: gert er r\xE1\xF0 fyrir a\xF0 ${issue2.origin ?? "gildi"} hafi ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "hluti"}`;
          return `Of st\xF3rt: gert er r\xE1\xF0 fyrir a\xF0 ${issue2.origin ?? "gildi"} s\xE9 ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Of l\xEDti\xF0: gert er r\xE1\xF0 fyrir a\xF0 ${issue2.origin} hafi ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Of l\xEDti\xF0: gert er r\xE1\xF0 fyrir a\xF0 ${issue2.origin} s\xE9 ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `\xD3gildur strengur: ver\xF0ur a\xF0 byrja \xE1 "${_issue.prefix}"`;
          }
          if (_issue.format === "ends_with")
            return `\xD3gildur strengur: ver\xF0ur a\xF0 enda \xE1 "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `\xD3gildur strengur: ver\xF0ur a\xF0 innihalda "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\xD3gildur strengur: ver\xF0ur a\xF0 fylgja mynstri ${_issue.pattern}`;
          return `Rangt ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `R\xF6ng tala: ver\xF0ur a\xF0 vera margfeldi af ${issue2.divisor}`;
        case "unrecognized_keys":
          return `\xD3\xFEekkt ${issue2.keys.length > 1 ? "ir lyklar" : "ur lykill"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Rangur lykill \xED ${issue2.origin}`;
        case "invalid_union":
          return "Rangt gildi";
        case "invalid_element":
          return `Rangt gildi \xED ${issue2.origin}`;
        default:
          return `Rangt gildi`;
      }
    };
  };
  function is_default() {
    return {
      localeError: error22()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/it.js
  init_runtime();
  var error23 = () => {
    const Sizable = {
      string: { unit: "caratteri", verb: "avere" },
      file: { unit: "byte", verb: "avere" },
      array: { unit: "elementi", verb: "avere" },
      set: { unit: "elementi", verb: "avere" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "input",
      email: "indirizzo email",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "data e ora ISO",
      date: "data ISO",
      time: "ora ISO",
      duration: "durata ISO",
      ipv4: "indirizzo IPv4",
      ipv6: "indirizzo IPv6",
      cidrv4: "intervallo IPv4",
      cidrv6: "intervallo IPv6",
      base64: "stringa codificata in base64",
      base64url: "URL codificata in base64",
      json_string: "stringa JSON",
      e164: "numero E.164",
      jwt: "JWT",
      template_literal: "input"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "numero",
      array: "vettore"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Input non valido: atteso instanceof ${issue2.expected}, ricevuto ${received}`;
          }
          return `Input non valido: atteso ${expected}, ricevuto ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Input non valido: atteso ${stringifyPrimitive(issue2.values[0])}`;
          return `Opzione non valida: atteso uno tra ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Troppo grande: ${issue2.origin ?? "valore"} deve avere ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elementi"}`;
          return `Troppo grande: ${issue2.origin ?? "valore"} deve essere ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Troppo piccolo: ${issue2.origin} deve avere ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Troppo piccolo: ${issue2.origin} deve essere ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Stringa non valida: deve iniziare con "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `Stringa non valida: deve terminare con "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Stringa non valida: deve includere "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Stringa non valida: deve corrispondere al pattern ${_issue.pattern}`;
          return `Input non valido: ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Numero non valido: deve essere un multiplo di ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Chiav${issue2.keys.length > 1 ? "i" : "e"} non riconosciut${issue2.keys.length > 1 ? "e" : "a"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Chiave non valida in ${issue2.origin}`;
        case "invalid_union":
          return "Input non valido";
        case "invalid_element":
          return `Valore non valido in ${issue2.origin}`;
        default:
          return `Input non valido`;
      }
    };
  };
  function it_default() {
    return {
      localeError: error23()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/ja.js
  init_runtime();
  var error24 = () => {
    const Sizable = {
      string: { unit: "\u6587\u5B57", verb: "\u3067\u3042\u308B" },
      file: { unit: "\u30D0\u30A4\u30C8", verb: "\u3067\u3042\u308B" },
      array: { unit: "\u8981\u7D20", verb: "\u3067\u3042\u308B" },
      set: { unit: "\u8981\u7D20", verb: "\u3067\u3042\u308B" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u5165\u529B\u5024",
      email: "\u30E1\u30FC\u30EB\u30A2\u30C9\u30EC\u30B9",
      url: "URL",
      emoji: "\u7D75\u6587\u5B57",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO\u65E5\u6642",
      date: "ISO\u65E5\u4ED8",
      time: "ISO\u6642\u523B",
      duration: "ISO\u671F\u9593",
      ipv4: "IPv4\u30A2\u30C9\u30EC\u30B9",
      ipv6: "IPv6\u30A2\u30C9\u30EC\u30B9",
      cidrv4: "IPv4\u7BC4\u56F2",
      cidrv6: "IPv6\u7BC4\u56F2",
      base64: "base64\u30A8\u30F3\u30B3\u30FC\u30C9\u6587\u5B57\u5217",
      base64url: "base64url\u30A8\u30F3\u30B3\u30FC\u30C9\u6587\u5B57\u5217",
      json_string: "JSON\u6587\u5B57\u5217",
      e164: "E.164\u756A\u53F7",
      jwt: "JWT",
      template_literal: "\u5165\u529B\u5024"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u6570\u5024",
      array: "\u914D\u5217"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u7121\u52B9\u306A\u5165\u529B: instanceof ${issue2.expected}\u304C\u671F\u5F85\u3055\u308C\u307E\u3057\u305F\u304C\u3001${received}\u304C\u5165\u529B\u3055\u308C\u307E\u3057\u305F`;
          }
          return `\u7121\u52B9\u306A\u5165\u529B: ${expected}\u304C\u671F\u5F85\u3055\u308C\u307E\u3057\u305F\u304C\u3001${received}\u304C\u5165\u529B\u3055\u308C\u307E\u3057\u305F`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u7121\u52B9\u306A\u5165\u529B: ${stringifyPrimitive(issue2.values[0])}\u304C\u671F\u5F85\u3055\u308C\u307E\u3057\u305F`;
          return `\u7121\u52B9\u306A\u9078\u629E: ${joinValues(issue2.values, "\u3001")}\u306E\u3044\u305A\u308C\u304B\u3067\u3042\u308B\u5FC5\u8981\u304C\u3042\u308A\u307E\u3059`;
        case "too_big": {
          const adj = issue2.inclusive ? "\u4EE5\u4E0B\u3067\u3042\u308B" : "\u3088\u308A\u5C0F\u3055\u3044";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\u5927\u304D\u3059\u304E\u308B\u5024: ${issue2.origin ?? "\u5024"}\u306F${issue2.maximum.toString()}${sizing.unit ?? "\u8981\u7D20"}${adj}\u5FC5\u8981\u304C\u3042\u308A\u307E\u3059`;
          return `\u5927\u304D\u3059\u304E\u308B\u5024: ${issue2.origin ?? "\u5024"}\u306F${issue2.maximum.toString()}${adj}\u5FC5\u8981\u304C\u3042\u308A\u307E\u3059`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? "\u4EE5\u4E0A\u3067\u3042\u308B" : "\u3088\u308A\u5927\u304D\u3044";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\u5C0F\u3055\u3059\u304E\u308B\u5024: ${issue2.origin}\u306F${issue2.minimum.toString()}${sizing.unit}${adj}\u5FC5\u8981\u304C\u3042\u308A\u307E\u3059`;
          return `\u5C0F\u3055\u3059\u304E\u308B\u5024: ${issue2.origin}\u306F${issue2.minimum.toString()}${adj}\u5FC5\u8981\u304C\u3042\u308A\u307E\u3059`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `\u7121\u52B9\u306A\u6587\u5B57\u5217: "${_issue.prefix}"\u3067\u59CB\u307E\u308B\u5FC5\u8981\u304C\u3042\u308A\u307E\u3059`;
          if (_issue.format === "ends_with")
            return `\u7121\u52B9\u306A\u6587\u5B57\u5217: "${_issue.suffix}"\u3067\u7D42\u308F\u308B\u5FC5\u8981\u304C\u3042\u308A\u307E\u3059`;
          if (_issue.format === "includes")
            return `\u7121\u52B9\u306A\u6587\u5B57\u5217: "${_issue.includes}"\u3092\u542B\u3080\u5FC5\u8981\u304C\u3042\u308A\u307E\u3059`;
          if (_issue.format === "regex")
            return `\u7121\u52B9\u306A\u6587\u5B57\u5217: \u30D1\u30BF\u30FC\u30F3${_issue.pattern}\u306B\u4E00\u81F4\u3059\u308B\u5FC5\u8981\u304C\u3042\u308A\u307E\u3059`;
          return `\u7121\u52B9\u306A${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u7121\u52B9\u306A\u6570\u5024: ${issue2.divisor}\u306E\u500D\u6570\u3067\u3042\u308B\u5FC5\u8981\u304C\u3042\u308A\u307E\u3059`;
        case "unrecognized_keys":
          return `\u8A8D\u8B58\u3055\u308C\u3066\u3044\u306A\u3044\u30AD\u30FC${issue2.keys.length > 1 ? "\u7FA4" : ""}: ${joinValues(issue2.keys, "\u3001")}`;
        case "invalid_key":
          return `${issue2.origin}\u5185\u306E\u7121\u52B9\u306A\u30AD\u30FC`;
        case "invalid_union":
          return "\u7121\u52B9\u306A\u5165\u529B";
        case "invalid_element":
          return `${issue2.origin}\u5185\u306E\u7121\u52B9\u306A\u5024`;
        default:
          return `\u7121\u52B9\u306A\u5165\u529B`;
      }
    };
  };
  function ja_default() {
    return {
      localeError: error24()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/ka.js
  init_runtime();
  var error25 = () => {
    const Sizable = {
      string: { unit: "\u10E1\u10D8\u10DB\u10D1\u10DD\u10DA\u10DD", verb: "\u10E3\u10DC\u10D3\u10D0 \u10E8\u10D4\u10D8\u10EA\u10D0\u10D5\u10D3\u10D4\u10E1" },
      file: { unit: "\u10D1\u10D0\u10D8\u10E2\u10D8", verb: "\u10E3\u10DC\u10D3\u10D0 \u10E8\u10D4\u10D8\u10EA\u10D0\u10D5\u10D3\u10D4\u10E1" },
      array: { unit: "\u10D4\u10DA\u10D4\u10DB\u10D4\u10DC\u10E2\u10D8", verb: "\u10E3\u10DC\u10D3\u10D0 \u10E8\u10D4\u10D8\u10EA\u10D0\u10D5\u10D3\u10D4\u10E1" },
      set: { unit: "\u10D4\u10DA\u10D4\u10DB\u10D4\u10DC\u10E2\u10D8", verb: "\u10E3\u10DC\u10D3\u10D0 \u10E8\u10D4\u10D8\u10EA\u10D0\u10D5\u10D3\u10D4\u10E1" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u10E8\u10D4\u10E7\u10D5\u10D0\u10DC\u10D0",
      email: "\u10D4\u10DA-\u10E4\u10DD\u10E1\u10E2\u10D8\u10E1 \u10DB\u10D8\u10E1\u10D0\u10DB\u10D0\u10E0\u10D7\u10D8",
      url: "URL",
      emoji: "\u10D4\u10DB\u10DD\u10EF\u10D8",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "\u10D7\u10D0\u10E0\u10D8\u10E6\u10D8-\u10D3\u10E0\u10DD",
      date: "\u10D7\u10D0\u10E0\u10D8\u10E6\u10D8",
      time: "\u10D3\u10E0\u10DD",
      duration: "\u10EE\u10D0\u10DC\u10D2\u10E0\u10EB\u10DA\u10D8\u10D5\u10DD\u10D1\u10D0",
      ipv4: "IPv4 \u10DB\u10D8\u10E1\u10D0\u10DB\u10D0\u10E0\u10D7\u10D8",
      ipv6: "IPv6 \u10DB\u10D8\u10E1\u10D0\u10DB\u10D0\u10E0\u10D7\u10D8",
      cidrv4: "IPv4 \u10D3\u10D8\u10D0\u10DE\u10D0\u10D6\u10DD\u10DC\u10D8",
      cidrv6: "IPv6 \u10D3\u10D8\u10D0\u10DE\u10D0\u10D6\u10DD\u10DC\u10D8",
      base64: "base64-\u10D9\u10DD\u10D3\u10D8\u10E0\u10D4\u10D1\u10E3\u10DA\u10D8 \u10D5\u10D4\u10DA\u10D8",
      base64url: "base64url-\u10D9\u10DD\u10D3\u10D8\u10E0\u10D4\u10D1\u10E3\u10DA\u10D8 \u10D5\u10D4\u10DA\u10D8",
      json_string: "JSON \u10D5\u10D4\u10DA\u10D8",
      e164: "E.164 \u10DC\u10DD\u10DB\u10D4\u10E0\u10D8",
      jwt: "JWT",
      template_literal: "\u10E8\u10D4\u10E7\u10D5\u10D0\u10DC\u10D0"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u10E0\u10D8\u10EA\u10EE\u10D5\u10D8",
      string: "\u10D5\u10D4\u10DA\u10D8",
      boolean: "\u10D1\u10E3\u10DA\u10D4\u10D0\u10DC\u10D8",
      function: "\u10E4\u10E3\u10DC\u10E5\u10EA\u10D8\u10D0",
      array: "\u10DB\u10D0\u10E1\u10D8\u10D5\u10D8"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 \u10E8\u10D4\u10E7\u10D5\u10D0\u10DC\u10D0: \u10DB\u10DD\u10E1\u10D0\u10DA\u10DD\u10D3\u10DC\u10D4\u10DA\u10D8 instanceof ${issue2.expected}, \u10DB\u10D8\u10E6\u10D4\u10D1\u10E3\u10DA\u10D8 ${received}`;
          }
          return `\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 \u10E8\u10D4\u10E7\u10D5\u10D0\u10DC\u10D0: \u10DB\u10DD\u10E1\u10D0\u10DA\u10DD\u10D3\u10DC\u10D4\u10DA\u10D8 ${expected}, \u10DB\u10D8\u10E6\u10D4\u10D1\u10E3\u10DA\u10D8 ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 \u10E8\u10D4\u10E7\u10D5\u10D0\u10DC\u10D0: \u10DB\u10DD\u10E1\u10D0\u10DA\u10DD\u10D3\u10DC\u10D4\u10DA\u10D8 ${stringifyPrimitive(issue2.values[0])}`;
          return `\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 \u10D5\u10D0\u10E0\u10D8\u10D0\u10DC\u10E2\u10D8: \u10DB\u10DD\u10E1\u10D0\u10DA\u10DD\u10D3\u10DC\u10D4\u10DA\u10D8\u10D0 \u10D4\u10E0\u10D7-\u10D4\u10E0\u10D7\u10D8 ${joinValues(issue2.values, "|")}-\u10D3\u10D0\u10DC`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\u10D6\u10D4\u10D3\u10DB\u10D4\u10E2\u10D0\u10D3 \u10D3\u10D8\u10D3\u10D8: \u10DB\u10DD\u10E1\u10D0\u10DA\u10DD\u10D3\u10DC\u10D4\u10DA\u10D8 ${issue2.origin ?? "\u10DB\u10DC\u10D8\u10E8\u10D5\u10DC\u10D4\u10DA\u10DD\u10D1\u10D0"} ${sizing.verb} ${adj}${issue2.maximum.toString()} ${sizing.unit}`;
          return `\u10D6\u10D4\u10D3\u10DB\u10D4\u10E2\u10D0\u10D3 \u10D3\u10D8\u10D3\u10D8: \u10DB\u10DD\u10E1\u10D0\u10DA\u10DD\u10D3\u10DC\u10D4\u10DA\u10D8 ${issue2.origin ?? "\u10DB\u10DC\u10D8\u10E8\u10D5\u10DC\u10D4\u10DA\u10DD\u10D1\u10D0"} \u10D8\u10E7\u10DD\u10E1 ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u10D6\u10D4\u10D3\u10DB\u10D4\u10E2\u10D0\u10D3 \u10DE\u10D0\u10E2\u10D0\u10E0\u10D0: \u10DB\u10DD\u10E1\u10D0\u10DA\u10DD\u10D3\u10DC\u10D4\u10DA\u10D8 ${issue2.origin} ${sizing.verb} ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `\u10D6\u10D4\u10D3\u10DB\u10D4\u10E2\u10D0\u10D3 \u10DE\u10D0\u10E2\u10D0\u10E0\u10D0: \u10DB\u10DD\u10E1\u10D0\u10DA\u10DD\u10D3\u10DC\u10D4\u10DA\u10D8 ${issue2.origin} \u10D8\u10E7\u10DD\u10E1 ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 \u10D5\u10D4\u10DA\u10D8: \u10E3\u10DC\u10D3\u10D0 \u10D8\u10EC\u10E7\u10D4\u10D1\u10DD\u10D3\u10D4\u10E1 "${_issue.prefix}"-\u10D8\u10D7`;
          }
          if (_issue.format === "ends_with")
            return `\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 \u10D5\u10D4\u10DA\u10D8: \u10E3\u10DC\u10D3\u10D0 \u10DB\u10D7\u10D0\u10D5\u10E0\u10D3\u10D4\u10D1\u10DD\u10D3\u10D4\u10E1 "${_issue.suffix}"-\u10D8\u10D7`;
          if (_issue.format === "includes")
            return `\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 \u10D5\u10D4\u10DA\u10D8: \u10E3\u10DC\u10D3\u10D0 \u10E8\u10D4\u10D8\u10EA\u10D0\u10D5\u10D3\u10D4\u10E1 "${_issue.includes}"-\u10E1`;
          if (_issue.format === "regex")
            return `\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 \u10D5\u10D4\u10DA\u10D8: \u10E3\u10DC\u10D3\u10D0 \u10E8\u10D4\u10D4\u10E1\u10D0\u10D1\u10D0\u10DB\u10D4\u10D1\u10DD\u10D3\u10D4\u10E1 \u10E8\u10D0\u10D1\u10DA\u10DD\u10DC\u10E1 ${_issue.pattern}`;
          return `\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 \u10E0\u10D8\u10EA\u10EE\u10D5\u10D8: \u10E3\u10DC\u10D3\u10D0 \u10D8\u10E7\u10DD\u10E1 ${issue2.divisor}-\u10D8\u10E1 \u10EF\u10D4\u10E0\u10D0\u10D3\u10D8`;
        case "unrecognized_keys":
          return `\u10E3\u10EA\u10DC\u10DD\u10D1\u10D8 \u10D2\u10D0\u10E1\u10D0\u10E6\u10D4\u10D1${issue2.keys.length > 1 ? "\u10D4\u10D1\u10D8" : "\u10D8"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 \u10D2\u10D0\u10E1\u10D0\u10E6\u10D4\u10D1\u10D8 ${issue2.origin}-\u10E8\u10D8`;
        case "invalid_union":
          return "\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 \u10E8\u10D4\u10E7\u10D5\u10D0\u10DC\u10D0";
        case "invalid_element":
          return `\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 \u10DB\u10DC\u10D8\u10E8\u10D5\u10DC\u10D4\u10DA\u10DD\u10D1\u10D0 ${issue2.origin}-\u10E8\u10D8`;
        default:
          return `\u10D0\u10E0\u10D0\u10E1\u10EC\u10DD\u10E0\u10D8 \u10E8\u10D4\u10E7\u10D5\u10D0\u10DC\u10D0`;
      }
    };
  };
  function ka_default() {
    return {
      localeError: error25()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/kh.js
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/locales/km.js
  init_runtime();
  var error26 = () => {
    const Sizable = {
      string: { unit: "\u178F\u17BD\u17A2\u1780\u17D2\u179F\u179A", verb: "\u1782\u17BD\u179A\u1798\u17B6\u1793" },
      file: { unit: "\u1794\u17C3", verb: "\u1782\u17BD\u179A\u1798\u17B6\u1793" },
      array: { unit: "\u1792\u17B6\u178F\u17BB", verb: "\u1782\u17BD\u179A\u1798\u17B6\u1793" },
      set: { unit: "\u1792\u17B6\u178F\u17BB", verb: "\u1782\u17BD\u179A\u1798\u17B6\u1793" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u1791\u17B7\u1793\u17D2\u1793\u1793\u17D0\u1799\u1794\u1789\u17D2\u1785\u17BC\u179B",
      email: "\u17A2\u17B6\u179F\u1799\u178A\u17D2\u178B\u17B6\u1793\u17A2\u17CA\u17B8\u1798\u17C2\u179B",
      url: "URL",
      emoji: "\u179F\u1789\u17D2\u1789\u17B6\u17A2\u17B6\u179A\u1798\u17D2\u1798\u178E\u17CD",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "\u1780\u17B6\u179B\u1794\u179A\u17B7\u1785\u17D2\u1786\u17C1\u1791 \u1793\u17B7\u1784\u1798\u17C9\u17C4\u1784 ISO",
      date: "\u1780\u17B6\u179B\u1794\u179A\u17B7\u1785\u17D2\u1786\u17C1\u1791 ISO",
      time: "\u1798\u17C9\u17C4\u1784 ISO",
      duration: "\u179A\u1799\u17C8\u1796\u17C1\u179B ISO",
      ipv4: "\u17A2\u17B6\u179F\u1799\u178A\u17D2\u178B\u17B6\u1793 IPv4",
      ipv6: "\u17A2\u17B6\u179F\u1799\u178A\u17D2\u178B\u17B6\u1793 IPv6",
      cidrv4: "\u178A\u17C2\u1793\u17A2\u17B6\u179F\u1799\u178A\u17D2\u178B\u17B6\u1793 IPv4",
      cidrv6: "\u178A\u17C2\u1793\u17A2\u17B6\u179F\u1799\u178A\u17D2\u178B\u17B6\u1793 IPv6",
      base64: "\u1781\u17D2\u179F\u17C2\u17A2\u1780\u17D2\u179F\u179A\u17A2\u17CA\u17B7\u1780\u17BC\u178A base64",
      base64url: "\u1781\u17D2\u179F\u17C2\u17A2\u1780\u17D2\u179F\u179A\u17A2\u17CA\u17B7\u1780\u17BC\u178A base64url",
      json_string: "\u1781\u17D2\u179F\u17C2\u17A2\u1780\u17D2\u179F\u179A JSON",
      e164: "\u179B\u17C1\u1781 E.164",
      jwt: "JWT",
      template_literal: "\u1791\u17B7\u1793\u17D2\u1793\u1793\u17D0\u1799\u1794\u1789\u17D2\u1785\u17BC\u179B"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u179B\u17C1\u1781",
      array: "\u17A2\u17B6\u179A\u17C1 (Array)",
      null: "\u1782\u17D2\u1798\u17B6\u1793\u178F\u1798\u17D2\u179B\u17C3 (null)"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u1791\u17B7\u1793\u17D2\u1793\u1793\u17D0\u1799\u1794\u1789\u17D2\u1785\u17BC\u179B\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C\u17D6 \u178F\u17D2\u179A\u17BC\u179C\u1780\u17B6\u179A instanceof ${issue2.expected} \u1794\u17C9\u17BB\u1793\u17D2\u178F\u17C2\u1791\u1791\u17BD\u179B\u1794\u17B6\u1793 ${received}`;
          }
          return `\u1791\u17B7\u1793\u17D2\u1793\u1793\u17D0\u1799\u1794\u1789\u17D2\u1785\u17BC\u179B\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C\u17D6 \u178F\u17D2\u179A\u17BC\u179C\u1780\u17B6\u179A ${expected} \u1794\u17C9\u17BB\u1793\u17D2\u178F\u17C2\u1791\u1791\u17BD\u179B\u1794\u17B6\u1793 ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u1791\u17B7\u1793\u17D2\u1793\u1793\u17D0\u1799\u1794\u1789\u17D2\u1785\u17BC\u179B\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C\u17D6 \u178F\u17D2\u179A\u17BC\u179C\u1780\u17B6\u179A ${stringifyPrimitive(issue2.values[0])}`;
          return `\u1787\u1798\u17D2\u179A\u17BE\u179F\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C\u17D6 \u178F\u17D2\u179A\u17BC\u179C\u1787\u17B6\u1798\u17BD\u1799\u1780\u17D2\u1793\u17BB\u1784\u1785\u17C6\u178E\u17C4\u1798 ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\u1792\u17C6\u1796\u17C1\u1780\u17D6 \u178F\u17D2\u179A\u17BC\u179C\u1780\u17B6\u179A ${issue2.origin ?? "\u178F\u1798\u17D2\u179B\u17C3"} ${adj} ${issue2.maximum.toString()} ${sizing.unit ?? "\u1792\u17B6\u178F\u17BB"}`;
          return `\u1792\u17C6\u1796\u17C1\u1780\u17D6 \u178F\u17D2\u179A\u17BC\u179C\u1780\u17B6\u179A ${issue2.origin ?? "\u178F\u1798\u17D2\u179B\u17C3"} ${adj} ${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u178F\u17BC\u1785\u1796\u17C1\u1780\u17D6 \u178F\u17D2\u179A\u17BC\u179C\u1780\u17B6\u179A ${issue2.origin} ${adj} ${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `\u178F\u17BC\u1785\u1796\u17C1\u1780\u17D6 \u178F\u17D2\u179A\u17BC\u179C\u1780\u17B6\u179A ${issue2.origin} ${adj} ${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `\u1781\u17D2\u179F\u17C2\u17A2\u1780\u17D2\u179F\u179A\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C\u17D6 \u178F\u17D2\u179A\u17BC\u179C\u1785\u17B6\u1794\u17CB\u1795\u17D2\u178F\u17BE\u1798\u178A\u17C4\u1799 "${_issue.prefix}"`;
          }
          if (_issue.format === "ends_with")
            return `\u1781\u17D2\u179F\u17C2\u17A2\u1780\u17D2\u179F\u179A\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C\u17D6 \u178F\u17D2\u179A\u17BC\u179C\u1794\u1789\u17D2\u1785\u1794\u17CB\u178A\u17C4\u1799 "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `\u1781\u17D2\u179F\u17C2\u17A2\u1780\u17D2\u179F\u179A\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C\u17D6 \u178F\u17D2\u179A\u17BC\u179C\u1798\u17B6\u1793 "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u1781\u17D2\u179F\u17C2\u17A2\u1780\u17D2\u179F\u179A\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C\u17D6 \u178F\u17D2\u179A\u17BC\u179C\u178F\u17C2\u1795\u17D2\u1782\u17BC\u1795\u17D2\u1782\u1784\u1793\u17B9\u1784\u1791\u1798\u17D2\u179A\u1784\u17CB\u178A\u17C2\u179B\u1794\u17B6\u1793\u1780\u17C6\u178E\u178F\u17CB ${_issue.pattern}`;
          return `\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C\u17D6 ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u179B\u17C1\u1781\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C\u17D6 \u178F\u17D2\u179A\u17BC\u179C\u178F\u17C2\u1787\u17B6\u1796\u17A0\u17BB\u1782\u17BB\u178E\u1793\u17C3 ${issue2.divisor}`;
        case "unrecognized_keys":
          return `\u179A\u1780\u1783\u17BE\u1789\u179F\u17C4\u1798\u17B7\u1793\u179F\u17D2\u1782\u17B6\u179B\u17CB\u17D6 ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\u179F\u17C4\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C\u1793\u17C5\u1780\u17D2\u1793\u17BB\u1784 ${issue2.origin}`;
        case "invalid_union":
          return `\u1791\u17B7\u1793\u17D2\u1793\u1793\u17D0\u1799\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C`;
        case "invalid_element":
          return `\u1791\u17B7\u1793\u17D2\u1793\u1793\u17D0\u1799\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C\u1793\u17C5\u1780\u17D2\u1793\u17BB\u1784 ${issue2.origin}`;
        default:
          return `\u1791\u17B7\u1793\u17D2\u1793\u1793\u17D0\u1799\u1798\u17B7\u1793\u178F\u17D2\u179A\u17B9\u1798\u178F\u17D2\u179A\u17BC\u179C`;
      }
    };
  };
  function km_default() {
    return {
      localeError: error26()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/kh.js
  function kh_default() {
    return km_default();
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/ko.js
  init_runtime();
  var error27 = () => {
    const Sizable = {
      string: { unit: "\uBB38\uC790", verb: "to have" },
      file: { unit: "\uBC14\uC774\uD2B8", verb: "to have" },
      array: { unit: "\uAC1C", verb: "to have" },
      set: { unit: "\uAC1C", verb: "to have" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\uC785\uB825",
      email: "\uC774\uBA54\uC77C \uC8FC\uC18C",
      url: "URL",
      emoji: "\uC774\uBAA8\uC9C0",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO \uB0A0\uC9DC\uC2DC\uAC04",
      date: "ISO \uB0A0\uC9DC",
      time: "ISO \uC2DC\uAC04",
      duration: "ISO \uAE30\uAC04",
      ipv4: "IPv4 \uC8FC\uC18C",
      ipv6: "IPv6 \uC8FC\uC18C",
      cidrv4: "IPv4 \uBC94\uC704",
      cidrv6: "IPv6 \uBC94\uC704",
      base64: "base64 \uC778\uCF54\uB529 \uBB38\uC790\uC5F4",
      base64url: "base64url \uC778\uCF54\uB529 \uBB38\uC790\uC5F4",
      json_string: "JSON \uBB38\uC790\uC5F4",
      e164: "E.164 \uBC88\uD638",
      jwt: "JWT",
      template_literal: "\uC785\uB825"
    };
    const TypeDictionary = {
      nan: "NaN"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\uC798\uBABB\uB41C \uC785\uB825: \uC608\uC0C1 \uD0C0\uC785\uC740 instanceof ${issue2.expected}, \uBC1B\uC740 \uD0C0\uC785\uC740 ${received}\uC785\uB2C8\uB2E4`;
          }
          return `\uC798\uBABB\uB41C \uC785\uB825: \uC608\uC0C1 \uD0C0\uC785\uC740 ${expected}, \uBC1B\uC740 \uD0C0\uC785\uC740 ${received}\uC785\uB2C8\uB2E4`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\uC798\uBABB\uB41C \uC785\uB825: \uAC12\uC740 ${stringifyPrimitive(issue2.values[0])} \uC774\uC5B4\uC57C \uD569\uB2C8\uB2E4`;
          return `\uC798\uBABB\uB41C \uC635\uC158: ${joinValues(issue2.values, "\uB610\uB294 ")} \uC911 \uD558\uB098\uC5EC\uC57C \uD569\uB2C8\uB2E4`;
        case "too_big": {
          const adj = issue2.inclusive ? "\uC774\uD558" : "\uBBF8\uB9CC";
          const suffix = adj === "\uBBF8\uB9CC" ? "\uC774\uC5B4\uC57C \uD569\uB2C8\uB2E4" : "\uC5EC\uC57C \uD569\uB2C8\uB2E4";
          const sizing = getSizing(issue2.origin);
          const unit = sizing?.unit ?? "\uC694\uC18C";
          if (sizing)
            return `${issue2.origin ?? "\uAC12"}\uC774 \uB108\uBB34 \uD07D\uB2C8\uB2E4: ${issue2.maximum.toString()}${unit} ${adj}${suffix}`;
          return `${issue2.origin ?? "\uAC12"}\uC774 \uB108\uBB34 \uD07D\uB2C8\uB2E4: ${issue2.maximum.toString()} ${adj}${suffix}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? "\uC774\uC0C1" : "\uCD08\uACFC";
          const suffix = adj === "\uC774\uC0C1" ? "\uC774\uC5B4\uC57C \uD569\uB2C8\uB2E4" : "\uC5EC\uC57C \uD569\uB2C8\uB2E4";
          const sizing = getSizing(issue2.origin);
          const unit = sizing?.unit ?? "\uC694\uC18C";
          if (sizing) {
            return `${issue2.origin ?? "\uAC12"}\uC774 \uB108\uBB34 \uC791\uC2B5\uB2C8\uB2E4: ${issue2.minimum.toString()}${unit} ${adj}${suffix}`;
          }
          return `${issue2.origin ?? "\uAC12"}\uC774 \uB108\uBB34 \uC791\uC2B5\uB2C8\uB2E4: ${issue2.minimum.toString()} ${adj}${suffix}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `\uC798\uBABB\uB41C \uBB38\uC790\uC5F4: "${_issue.prefix}"(\uC73C)\uB85C \uC2DC\uC791\uD574\uC57C \uD569\uB2C8\uB2E4`;
          }
          if (_issue.format === "ends_with")
            return `\uC798\uBABB\uB41C \uBB38\uC790\uC5F4: "${_issue.suffix}"(\uC73C)\uB85C \uB05D\uB098\uC57C \uD569\uB2C8\uB2E4`;
          if (_issue.format === "includes")
            return `\uC798\uBABB\uB41C \uBB38\uC790\uC5F4: "${_issue.includes}"\uC744(\uB97C) \uD3EC\uD568\uD574\uC57C \uD569\uB2C8\uB2E4`;
          if (_issue.format === "regex")
            return `\uC798\uBABB\uB41C \uBB38\uC790\uC5F4: \uC815\uADDC\uC2DD ${_issue.pattern} \uD328\uD134\uACFC \uC77C\uCE58\uD574\uC57C \uD569\uB2C8\uB2E4`;
          return `\uC798\uBABB\uB41C ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\uC798\uBABB\uB41C \uC22B\uC790: ${issue2.divisor}\uC758 \uBC30\uC218\uC5EC\uC57C \uD569\uB2C8\uB2E4`;
        case "unrecognized_keys":
          return `\uC778\uC2DD\uD560 \uC218 \uC5C6\uB294 \uD0A4: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\uC798\uBABB\uB41C \uD0A4: ${issue2.origin}`;
        case "invalid_union":
          return `\uC798\uBABB\uB41C \uC785\uB825`;
        case "invalid_element":
          return `\uC798\uBABB\uB41C \uAC12: ${issue2.origin}`;
        default:
          return `\uC798\uBABB\uB41C \uC785\uB825`;
      }
    };
  };
  function ko_default() {
    return {
      localeError: error27()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/lt.js
  init_runtime();
  var capitalizeFirstCharacter = (text) => {
    return text.charAt(0).toUpperCase() + text.slice(1);
  };
  function getUnitTypeFromNumber(number4) {
    const abs = Math.abs(number4);
    const last = abs % 10;
    const last2 = abs % 100;
    if (last2 >= 11 && last2 <= 19 || last === 0)
      return "many";
    if (last === 1)
      return "one";
    return "few";
  }
  var error28 = () => {
    const Sizable = {
      string: {
        unit: {
          one: "simbolis",
          few: "simboliai",
          many: "simboli\u0173"
        },
        verb: {
          smaller: {
            inclusive: "turi b\u016Bti ne ilgesn\u0117 kaip",
            notInclusive: "turi b\u016Bti trumpesn\u0117 kaip"
          },
          bigger: {
            inclusive: "turi b\u016Bti ne trumpesn\u0117 kaip",
            notInclusive: "turi b\u016Bti ilgesn\u0117 kaip"
          }
        }
      },
      file: {
        unit: {
          one: "baitas",
          few: "baitai",
          many: "bait\u0173"
        },
        verb: {
          smaller: {
            inclusive: "turi b\u016Bti ne didesnis kaip",
            notInclusive: "turi b\u016Bti ma\u017Eesnis kaip"
          },
          bigger: {
            inclusive: "turi b\u016Bti ne ma\u017Eesnis kaip",
            notInclusive: "turi b\u016Bti didesnis kaip"
          }
        }
      },
      array: {
        unit: {
          one: "element\u0105",
          few: "elementus",
          many: "element\u0173"
        },
        verb: {
          smaller: {
            inclusive: "turi tur\u0117ti ne daugiau kaip",
            notInclusive: "turi tur\u0117ti ma\u017Eiau kaip"
          },
          bigger: {
            inclusive: "turi tur\u0117ti ne ma\u017Eiau kaip",
            notInclusive: "turi tur\u0117ti daugiau kaip"
          }
        }
      },
      set: {
        unit: {
          one: "element\u0105",
          few: "elementus",
          many: "element\u0173"
        },
        verb: {
          smaller: {
            inclusive: "turi tur\u0117ti ne daugiau kaip",
            notInclusive: "turi tur\u0117ti ma\u017Eiau kaip"
          },
          bigger: {
            inclusive: "turi tur\u0117ti ne ma\u017Eiau kaip",
            notInclusive: "turi tur\u0117ti daugiau kaip"
          }
        }
      }
    };
    function getSizing(origin, unitType, inclusive, targetShouldBe) {
      const result = Sizable[origin] ?? null;
      if (result === null)
        return result;
      return {
        unit: result.unit[unitType],
        verb: result.verb[targetShouldBe][inclusive ? "inclusive" : "notInclusive"]
      };
    }
    const FormatDictionary = {
      regex: "\u012Fvestis",
      email: "el. pa\u0161to adresas",
      url: "URL",
      emoji: "jaustukas",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO data ir laikas",
      date: "ISO data",
      time: "ISO laikas",
      duration: "ISO trukm\u0117",
      ipv4: "IPv4 adresas",
      ipv6: "IPv6 adresas",
      cidrv4: "IPv4 tinklo prefiksas (CIDR)",
      cidrv6: "IPv6 tinklo prefiksas (CIDR)",
      base64: "base64 u\u017Ekoduota eilut\u0117",
      base64url: "base64url u\u017Ekoduota eilut\u0117",
      json_string: "JSON eilut\u0117",
      e164: "E.164 numeris",
      jwt: "JWT",
      template_literal: "\u012Fvestis"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "skai\u010Dius",
      bigint: "sveikasis skai\u010Dius",
      string: "eilut\u0117",
      boolean: "login\u0117 reik\u0161m\u0117",
      undefined: "neapibr\u0117\u017Eta reik\u0161m\u0117",
      function: "funkcija",
      symbol: "simbolis",
      array: "masyvas",
      object: "objektas",
      null: "nulin\u0117 reik\u0161m\u0117"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Gautas tipas ${received}, o tik\u0117tasi - instanceof ${issue2.expected}`;
          }
          return `Gautas tipas ${received}, o tik\u0117tasi - ${expected}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Privalo b\u016Bti ${stringifyPrimitive(issue2.values[0])}`;
          return `Privalo b\u016Bti vienas i\u0161 ${joinValues(issue2.values, "|")} pasirinkim\u0173`;
        case "too_big": {
          const origin = TypeDictionary[issue2.origin] ?? issue2.origin;
          const sizing = getSizing(issue2.origin, getUnitTypeFromNumber(Number(issue2.maximum)), issue2.inclusive ?? false, "smaller");
          if (sizing?.verb)
            return `${capitalizeFirstCharacter(origin ?? issue2.origin ?? "reik\u0161m\u0117")} ${sizing.verb} ${issue2.maximum.toString()} ${sizing.unit ?? "element\u0173"}`;
          const adj = issue2.inclusive ? "ne didesnis kaip" : "ma\u017Eesnis kaip";
          return `${capitalizeFirstCharacter(origin ?? issue2.origin ?? "reik\u0161m\u0117")} turi b\u016Bti ${adj} ${issue2.maximum.toString()} ${sizing?.unit}`;
        }
        case "too_small": {
          const origin = TypeDictionary[issue2.origin] ?? issue2.origin;
          const sizing = getSizing(issue2.origin, getUnitTypeFromNumber(Number(issue2.minimum)), issue2.inclusive ?? false, "bigger");
          if (sizing?.verb)
            return `${capitalizeFirstCharacter(origin ?? issue2.origin ?? "reik\u0161m\u0117")} ${sizing.verb} ${issue2.minimum.toString()} ${sizing.unit ?? "element\u0173"}`;
          const adj = issue2.inclusive ? "ne ma\u017Eesnis kaip" : "didesnis kaip";
          return `${capitalizeFirstCharacter(origin ?? issue2.origin ?? "reik\u0161m\u0117")} turi b\u016Bti ${adj} ${issue2.minimum.toString()} ${sizing?.unit}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `Eilut\u0117 privalo prasid\u0117ti "${_issue.prefix}"`;
          }
          if (_issue.format === "ends_with")
            return `Eilut\u0117 privalo pasibaigti "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Eilut\u0117 privalo \u012Ftraukti "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Eilut\u0117 privalo atitikti ${_issue.pattern}`;
          return `Neteisingas ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Skai\u010Dius privalo b\u016Bti ${issue2.divisor} kartotinis.`;
        case "unrecognized_keys":
          return `Neatpa\u017Eint${issue2.keys.length > 1 ? "i" : "as"} rakt${issue2.keys.length > 1 ? "ai" : "as"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return "Rastas klaidingas raktas";
        case "invalid_union":
          return "Klaidinga \u012Fvestis";
        case "invalid_element": {
          const origin = TypeDictionary[issue2.origin] ?? issue2.origin;
          return `${capitalizeFirstCharacter(origin ?? issue2.origin ?? "reik\u0161m\u0117")} turi klaiding\u0105 \u012Fvest\u012F`;
        }
        default:
          return "Klaidinga \u012Fvestis";
      }
    };
  };
  function lt_default() {
    return {
      localeError: error28()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/mk.js
  init_runtime();
  var error29 = () => {
    const Sizable = {
      string: { unit: "\u0437\u043D\u0430\u0446\u0438", verb: "\u0434\u0430 \u0438\u043C\u0430\u0430\u0442" },
      file: { unit: "\u0431\u0430\u0458\u0442\u0438", verb: "\u0434\u0430 \u0438\u043C\u0430\u0430\u0442" },
      array: { unit: "\u0441\u0442\u0430\u0432\u043A\u0438", verb: "\u0434\u0430 \u0438\u043C\u0430\u0430\u0442" },
      set: { unit: "\u0441\u0442\u0430\u0432\u043A\u0438", verb: "\u0434\u0430 \u0438\u043C\u0430\u0430\u0442" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u0432\u043D\u0435\u0441",
      email: "\u0430\u0434\u0440\u0435\u0441\u0430 \u043D\u0430 \u0435-\u043F\u043E\u0448\u0442\u0430",
      url: "URL",
      emoji: "\u0435\u043C\u043E\u045F\u0438",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO \u0434\u0430\u0442\u0443\u043C \u0438 \u0432\u0440\u0435\u043C\u0435",
      date: "ISO \u0434\u0430\u0442\u0443\u043C",
      time: "ISO \u0432\u0440\u0435\u043C\u0435",
      duration: "ISO \u0432\u0440\u0435\u043C\u0435\u0442\u0440\u0430\u0435\u045A\u0435",
      ipv4: "IPv4 \u0430\u0434\u0440\u0435\u0441\u0430",
      ipv6: "IPv6 \u0430\u0434\u0440\u0435\u0441\u0430",
      cidrv4: "IPv4 \u043E\u043F\u0441\u0435\u0433",
      cidrv6: "IPv6 \u043E\u043F\u0441\u0435\u0433",
      base64: "base64-\u0435\u043D\u043A\u043E\u0434\u0438\u0440\u0430\u043D\u0430 \u043D\u0438\u0437\u0430",
      base64url: "base64url-\u0435\u043D\u043A\u043E\u0434\u0438\u0440\u0430\u043D\u0430 \u043D\u0438\u0437\u0430",
      json_string: "JSON \u043D\u0438\u0437\u0430",
      e164: "E.164 \u0431\u0440\u043E\u0458",
      jwt: "JWT",
      template_literal: "\u0432\u043D\u0435\u0441"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u0431\u0440\u043E\u0458",
      array: "\u043D\u0438\u0437\u0430"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u0413\u0440\u0435\u0448\u0435\u043D \u0432\u043D\u0435\u0441: \u0441\u0435 \u043E\u0447\u0435\u043A\u0443\u0432\u0430 instanceof ${issue2.expected}, \u043F\u0440\u0438\u043C\u0435\u043D\u043E ${received}`;
          }
          return `\u0413\u0440\u0435\u0448\u0435\u043D \u0432\u043D\u0435\u0441: \u0441\u0435 \u043E\u0447\u0435\u043A\u0443\u0432\u0430 ${expected}, \u043F\u0440\u0438\u043C\u0435\u043D\u043E ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Invalid input: expected ${stringifyPrimitive(issue2.values[0])}`;
          return `\u0413\u0440\u0435\u0448\u0430\u043D\u0430 \u043E\u043F\u0446\u0438\u0458\u0430: \u0441\u0435 \u043E\u0447\u0435\u043A\u0443\u0432\u0430 \u0435\u0434\u043D\u0430 ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\u041F\u0440\u0435\u043C\u043D\u043E\u0433\u0443 \u0433\u043E\u043B\u0435\u043C: \u0441\u0435 \u043E\u0447\u0435\u043A\u0443\u0432\u0430 ${issue2.origin ?? "\u0432\u0440\u0435\u0434\u043D\u043E\u0441\u0442\u0430"} \u0434\u0430 \u0438\u043C\u0430 ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "\u0435\u043B\u0435\u043C\u0435\u043D\u0442\u0438"}`;
          return `\u041F\u0440\u0435\u043C\u043D\u043E\u0433\u0443 \u0433\u043E\u043B\u0435\u043C: \u0441\u0435 \u043E\u0447\u0435\u043A\u0443\u0432\u0430 ${issue2.origin ?? "\u0432\u0440\u0435\u0434\u043D\u043E\u0441\u0442\u0430"} \u0434\u0430 \u0431\u0438\u0434\u0435 ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u041F\u0440\u0435\u043C\u043D\u043E\u0433\u0443 \u043C\u0430\u043B: \u0441\u0435 \u043E\u0447\u0435\u043A\u0443\u0432\u0430 ${issue2.origin} \u0434\u0430 \u0438\u043C\u0430 ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `\u041F\u0440\u0435\u043C\u043D\u043E\u0433\u0443 \u043C\u0430\u043B: \u0441\u0435 \u043E\u0447\u0435\u043A\u0443\u0432\u0430 ${issue2.origin} \u0434\u0430 \u0431\u0438\u0434\u0435 ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `\u041D\u0435\u0432\u0430\u0436\u0435\u0447\u043A\u0430 \u043D\u0438\u0437\u0430: \u043C\u043E\u0440\u0430 \u0434\u0430 \u0437\u0430\u043F\u043E\u0447\u043D\u0443\u0432\u0430 \u0441\u043E "${_issue.prefix}"`;
          }
          if (_issue.format === "ends_with")
            return `\u041D\u0435\u0432\u0430\u0436\u0435\u0447\u043A\u0430 \u043D\u0438\u0437\u0430: \u043C\u043E\u0440\u0430 \u0434\u0430 \u0437\u0430\u0432\u0440\u0448\u0443\u0432\u0430 \u0441\u043E "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `\u041D\u0435\u0432\u0430\u0436\u0435\u0447\u043A\u0430 \u043D\u0438\u0437\u0430: \u043C\u043E\u0440\u0430 \u0434\u0430 \u0432\u043A\u043B\u0443\u0447\u0443\u0432\u0430 "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u041D\u0435\u0432\u0430\u0436\u0435\u0447\u043A\u0430 \u043D\u0438\u0437\u0430: \u043C\u043E\u0440\u0430 \u0434\u0430 \u043E\u0434\u0433\u043E\u0430\u0440\u0430 \u043D\u0430 \u043F\u0430\u0442\u0435\u0440\u043D\u043E\u0442 ${_issue.pattern}`;
          return `Invalid ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u0413\u0440\u0435\u0448\u0435\u043D \u0431\u0440\u043E\u0458: \u043C\u043E\u0440\u0430 \u0434\u0430 \u0431\u0438\u0434\u0435 \u0434\u0435\u043B\u0438\u0432 \u0441\u043E ${issue2.divisor}`;
        case "unrecognized_keys":
          return `${issue2.keys.length > 1 ? "\u041D\u0435\u043F\u0440\u0435\u043F\u043E\u0437\u043D\u0430\u0435\u043D\u0438 \u043A\u043B\u0443\u0447\u0435\u0432\u0438" : "\u041D\u0435\u043F\u0440\u0435\u043F\u043E\u0437\u043D\u0430\u0435\u043D \u043A\u043B\u0443\u0447"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\u0413\u0440\u0435\u0448\u0435\u043D \u043A\u043B\u0443\u0447 \u0432\u043E ${issue2.origin}`;
        case "invalid_union":
          return "\u0413\u0440\u0435\u0448\u0435\u043D \u0432\u043D\u0435\u0441";
        case "invalid_element":
          return `\u0413\u0440\u0435\u0448\u043D\u0430 \u0432\u0440\u0435\u0434\u043D\u043E\u0441\u0442 \u0432\u043E ${issue2.origin}`;
        default:
          return `\u0413\u0440\u0435\u0448\u0435\u043D \u0432\u043D\u0435\u0441`;
      }
    };
  };
  function mk_default() {
    return {
      localeError: error29()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/ms.js
  init_runtime();
  var error30 = () => {
    const Sizable = {
      string: { unit: "aksara", verb: "mempunyai" },
      file: { unit: "bait", verb: "mempunyai" },
      array: { unit: "elemen", verb: "mempunyai" },
      set: { unit: "elemen", verb: "mempunyai" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "input",
      email: "alamat e-mel",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "tarikh masa ISO",
      date: "tarikh ISO",
      time: "masa ISO",
      duration: "tempoh ISO",
      ipv4: "alamat IPv4",
      ipv6: "alamat IPv6",
      cidrv4: "julat IPv4",
      cidrv6: "julat IPv6",
      base64: "string dikodkan base64",
      base64url: "string dikodkan base64url",
      json_string: "string JSON",
      e164: "nombor E.164",
      jwt: "JWT",
      template_literal: "input"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "nombor"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Input tidak sah: dijangka instanceof ${issue2.expected}, diterima ${received}`;
          }
          return `Input tidak sah: dijangka ${expected}, diterima ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Input tidak sah: dijangka ${stringifyPrimitive(issue2.values[0])}`;
          return `Pilihan tidak sah: dijangka salah satu daripada ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Terlalu besar: dijangka ${issue2.origin ?? "nilai"} ${sizing.verb} ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elemen"}`;
          return `Terlalu besar: dijangka ${issue2.origin ?? "nilai"} adalah ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Terlalu kecil: dijangka ${issue2.origin} ${sizing.verb} ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Terlalu kecil: dijangka ${issue2.origin} adalah ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `String tidak sah: mesti bermula dengan "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `String tidak sah: mesti berakhir dengan "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `String tidak sah: mesti mengandungi "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `String tidak sah: mesti sepadan dengan corak ${_issue.pattern}`;
          return `${FormatDictionary[_issue.format] ?? issue2.format} tidak sah`;
        }
        case "not_multiple_of":
          return `Nombor tidak sah: perlu gandaan ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Kunci tidak dikenali: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Kunci tidak sah dalam ${issue2.origin}`;
        case "invalid_union":
          return "Input tidak sah";
        case "invalid_element":
          return `Nilai tidak sah dalam ${issue2.origin}`;
        default:
          return `Input tidak sah`;
      }
    };
  };
  function ms_default() {
    return {
      localeError: error30()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/nl.js
  init_runtime();
  var error31 = () => {
    const Sizable = {
      string: { unit: "tekens", verb: "heeft" },
      file: { unit: "bytes", verb: "heeft" },
      array: { unit: "elementen", verb: "heeft" },
      set: { unit: "elementen", verb: "heeft" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "invoer",
      email: "emailadres",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO datum en tijd",
      date: "ISO datum",
      time: "ISO tijd",
      duration: "ISO duur",
      ipv4: "IPv4-adres",
      ipv6: "IPv6-adres",
      cidrv4: "IPv4-bereik",
      cidrv6: "IPv6-bereik",
      base64: "base64-gecodeerde tekst",
      base64url: "base64 URL-gecodeerde tekst",
      json_string: "JSON string",
      e164: "E.164-nummer",
      jwt: "JWT",
      template_literal: "invoer"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "getal"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Ongeldige invoer: verwacht instanceof ${issue2.expected}, ontving ${received}`;
          }
          return `Ongeldige invoer: verwacht ${expected}, ontving ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Ongeldige invoer: verwacht ${stringifyPrimitive(issue2.values[0])}`;
          return `Ongeldige optie: verwacht \xE9\xE9n van ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          const longName = issue2.origin === "date" ? "laat" : issue2.origin === "string" ? "lang" : "groot";
          if (sizing)
            return `Te ${longName}: verwacht dat ${issue2.origin ?? "waarde"} ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elementen"} ${sizing.verb}`;
          return `Te ${longName}: verwacht dat ${issue2.origin ?? "waarde"} ${adj}${issue2.maximum.toString()} is`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          const shortName = issue2.origin === "date" ? "vroeg" : issue2.origin === "string" ? "kort" : "klein";
          if (sizing) {
            return `Te ${shortName}: verwacht dat ${issue2.origin} ${adj}${issue2.minimum.toString()} ${sizing.unit} ${sizing.verb}`;
          }
          return `Te ${shortName}: verwacht dat ${issue2.origin} ${adj}${issue2.minimum.toString()} is`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `Ongeldige tekst: moet met "${_issue.prefix}" beginnen`;
          }
          if (_issue.format === "ends_with")
            return `Ongeldige tekst: moet op "${_issue.suffix}" eindigen`;
          if (_issue.format === "includes")
            return `Ongeldige tekst: moet "${_issue.includes}" bevatten`;
          if (_issue.format === "regex")
            return `Ongeldige tekst: moet overeenkomen met patroon ${_issue.pattern}`;
          return `Ongeldig: ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Ongeldig getal: moet een veelvoud van ${issue2.divisor} zijn`;
        case "unrecognized_keys":
          return `Onbekende key${issue2.keys.length > 1 ? "s" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Ongeldige key in ${issue2.origin}`;
        case "invalid_union":
          return "Ongeldige invoer";
        case "invalid_element":
          return `Ongeldige waarde in ${issue2.origin}`;
        default:
          return `Ongeldige invoer`;
      }
    };
  };
  function nl_default() {
    return {
      localeError: error31()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/no.js
  init_runtime();
  var error32 = () => {
    const Sizable = {
      string: { unit: "tegn", verb: "\xE5 ha" },
      file: { unit: "bytes", verb: "\xE5 ha" },
      array: { unit: "elementer", verb: "\xE5 inneholde" },
      set: { unit: "elementer", verb: "\xE5 inneholde" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "input",
      email: "e-postadresse",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO dato- og klokkeslett",
      date: "ISO-dato",
      time: "ISO-klokkeslett",
      duration: "ISO-varighet",
      ipv4: "IPv4-omr\xE5de",
      ipv6: "IPv6-omr\xE5de",
      cidrv4: "IPv4-spekter",
      cidrv6: "IPv6-spekter",
      base64: "base64-enkodet streng",
      base64url: "base64url-enkodet streng",
      json_string: "JSON-streng",
      e164: "E.164-nummer",
      jwt: "JWT",
      template_literal: "input"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "tall",
      array: "liste"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Ugyldig input: forventet instanceof ${issue2.expected}, fikk ${received}`;
          }
          return `Ugyldig input: forventet ${expected}, fikk ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Ugyldig verdi: forventet ${stringifyPrimitive(issue2.values[0])}`;
          return `Ugyldig valg: forventet en av ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `For stor(t): forventet ${issue2.origin ?? "value"} til \xE5 ha ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elementer"}`;
          return `For stor(t): forventet ${issue2.origin ?? "value"} til \xE5 ha ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `For lite(n): forventet ${issue2.origin} til \xE5 ha ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `For lite(n): forventet ${issue2.origin} til \xE5 ha ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Ugyldig streng: m\xE5 starte med "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `Ugyldig streng: m\xE5 ende med "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Ugyldig streng: m\xE5 inneholde "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Ugyldig streng: m\xE5 matche m\xF8nsteret ${_issue.pattern}`;
          return `Ugyldig ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Ugyldig tall: m\xE5 v\xE6re et multiplum av ${issue2.divisor}`;
        case "unrecognized_keys":
          return `${issue2.keys.length > 1 ? "Ukjente n\xF8kler" : "Ukjent n\xF8kkel"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Ugyldig n\xF8kkel i ${issue2.origin}`;
        case "invalid_union":
          return "Ugyldig input";
        case "invalid_element":
          return `Ugyldig verdi i ${issue2.origin}`;
        default:
          return `Ugyldig input`;
      }
    };
  };
  function no_default() {
    return {
      localeError: error32()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/ota.js
  init_runtime();
  var error33 = () => {
    const Sizable = {
      string: { unit: "harf", verb: "olmal\u0131d\u0131r" },
      file: { unit: "bayt", verb: "olmal\u0131d\u0131r" },
      array: { unit: "unsur", verb: "olmal\u0131d\u0131r" },
      set: { unit: "unsur", verb: "olmal\u0131d\u0131r" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "giren",
      email: "epostag\xE2h",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO heng\xE2m\u0131",
      date: "ISO tarihi",
      time: "ISO zaman\u0131",
      duration: "ISO m\xFCddeti",
      ipv4: "IPv4 ni\u015F\xE2n\u0131",
      ipv6: "IPv6 ni\u015F\xE2n\u0131",
      cidrv4: "IPv4 menzili",
      cidrv6: "IPv6 menzili",
      base64: "base64-\u015Fifreli metin",
      base64url: "base64url-\u015Fifreli metin",
      json_string: "JSON metin",
      e164: "E.164 say\u0131s\u0131",
      jwt: "JWT",
      template_literal: "giren"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "numara",
      array: "saf",
      null: "gayb"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `F\xE2sit giren: umulan instanceof ${issue2.expected}, al\u0131nan ${received}`;
          }
          return `F\xE2sit giren: umulan ${expected}, al\u0131nan ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `F\xE2sit giren: umulan ${stringifyPrimitive(issue2.values[0])}`;
          return `F\xE2sit tercih: m\xFBteberler ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Fazla b\xFCy\xFCk: ${issue2.origin ?? "value"}, ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elements"} sahip olmal\u0131yd\u0131.`;
          return `Fazla b\xFCy\xFCk: ${issue2.origin ?? "value"}, ${adj}${issue2.maximum.toString()} olmal\u0131yd\u0131.`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Fazla k\xFC\xE7\xFCk: ${issue2.origin}, ${adj}${issue2.minimum.toString()} ${sizing.unit} sahip olmal\u0131yd\u0131.`;
          }
          return `Fazla k\xFC\xE7\xFCk: ${issue2.origin}, ${adj}${issue2.minimum.toString()} olmal\u0131yd\u0131.`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `F\xE2sit metin: "${_issue.prefix}" ile ba\u015Flamal\u0131.`;
          if (_issue.format === "ends_with")
            return `F\xE2sit metin: "${_issue.suffix}" ile bitmeli.`;
          if (_issue.format === "includes")
            return `F\xE2sit metin: "${_issue.includes}" ihtiv\xE2 etmeli.`;
          if (_issue.format === "regex")
            return `F\xE2sit metin: ${_issue.pattern} nak\u015F\u0131na uymal\u0131.`;
          return `F\xE2sit ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `F\xE2sit say\u0131: ${issue2.divisor} kat\u0131 olmal\u0131yd\u0131.`;
        case "unrecognized_keys":
          return `Tan\u0131nmayan anahtar ${issue2.keys.length > 1 ? "s" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `${issue2.origin} i\xE7in tan\u0131nmayan anahtar var.`;
        case "invalid_union":
          return "Giren tan\u0131namad\u0131.";
        case "invalid_element":
          return `${issue2.origin} i\xE7in tan\u0131nmayan k\u0131ymet var.`;
        default:
          return `K\u0131ymet tan\u0131namad\u0131.`;
      }
    };
  };
  function ota_default() {
    return {
      localeError: error33()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/ps.js
  init_runtime();
  var error34 = () => {
    const Sizable = {
      string: { unit: "\u062A\u0648\u06A9\u064A", verb: "\u0648\u0644\u0631\u064A" },
      file: { unit: "\u0628\u0627\u06CC\u067C\u0633", verb: "\u0648\u0644\u0631\u064A" },
      array: { unit: "\u062A\u0648\u06A9\u064A", verb: "\u0648\u0644\u0631\u064A" },
      set: { unit: "\u062A\u0648\u06A9\u064A", verb: "\u0648\u0644\u0631\u064A" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u0648\u0631\u0648\u062F\u064A",
      email: "\u0628\u0631\u06CC\u069A\u0646\u0627\u0644\u06CC\u06A9",
      url: "\u06CC\u0648 \u0622\u0631 \u0627\u0644",
      emoji: "\u0627\u06CC\u0645\u0648\u062C\u064A",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "\u0646\u06CC\u067C\u0647 \u0627\u0648 \u0648\u062E\u062A",
      date: "\u0646\u06D0\u067C\u0647",
      time: "\u0648\u062E\u062A",
      duration: "\u0645\u0648\u062F\u0647",
      ipv4: "\u062F IPv4 \u067E\u062A\u0647",
      ipv6: "\u062F IPv6 \u067E\u062A\u0647",
      cidrv4: "\u062F IPv4 \u0633\u0627\u062D\u0647",
      cidrv6: "\u062F IPv6 \u0633\u0627\u062D\u0647",
      base64: "base64-encoded \u0645\u062A\u0646",
      base64url: "base64url-encoded \u0645\u062A\u0646",
      json_string: "JSON \u0645\u062A\u0646",
      e164: "\u062F E.164 \u0634\u0645\u06D0\u0631\u0647",
      jwt: "JWT",
      template_literal: "\u0648\u0631\u0648\u062F\u064A"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u0639\u062F\u062F",
      array: "\u0627\u0631\u06D0"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u0646\u0627\u0633\u0645 \u0648\u0631\u0648\u062F\u064A: \u0628\u0627\u06CC\u062F instanceof ${issue2.expected} \u0648\u0627\u06CC, \u0645\u06AB\u0631 ${received} \u062A\u0631\u0644\u0627\u0633\u0647 \u0634\u0648`;
          }
          return `\u0646\u0627\u0633\u0645 \u0648\u0631\u0648\u062F\u064A: \u0628\u0627\u06CC\u062F ${expected} \u0648\u0627\u06CC, \u0645\u06AB\u0631 ${received} \u062A\u0631\u0644\u0627\u0633\u0647 \u0634\u0648`;
        }
        case "invalid_value":
          if (issue2.values.length === 1) {
            return `\u0646\u0627\u0633\u0645 \u0648\u0631\u0648\u062F\u064A: \u0628\u0627\u06CC\u062F ${stringifyPrimitive(issue2.values[0])} \u0648\u0627\u06CC`;
          }
          return `\u0646\u0627\u0633\u0645 \u0627\u0646\u062A\u062E\u0627\u0628: \u0628\u0627\u06CC\u062F \u06CC\u0648 \u0644\u0647 ${joinValues(issue2.values, "|")} \u0685\u062E\u0647 \u0648\u0627\u06CC`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u0689\u06CC\u0631 \u0644\u0648\u06CC: ${issue2.origin ?? "\u0627\u0631\u0632\u069A\u062A"} \u0628\u0627\u06CC\u062F ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "\u0639\u0646\u0635\u0631\u0648\u0646\u0647"} \u0648\u0644\u0631\u064A`;
          }
          return `\u0689\u06CC\u0631 \u0644\u0648\u06CC: ${issue2.origin ?? "\u0627\u0631\u0632\u069A\u062A"} \u0628\u0627\u06CC\u062F ${adj}${issue2.maximum.toString()} \u0648\u064A`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u0689\u06CC\u0631 \u06A9\u0648\u0686\u0646\u06CC: ${issue2.origin} \u0628\u0627\u06CC\u062F ${adj}${issue2.minimum.toString()} ${sizing.unit} \u0648\u0644\u0631\u064A`;
          }
          return `\u0689\u06CC\u0631 \u06A9\u0648\u0686\u0646\u06CC: ${issue2.origin} \u0628\u0627\u06CC\u062F ${adj}${issue2.minimum.toString()} \u0648\u064A`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `\u0646\u0627\u0633\u0645 \u0645\u062A\u0646: \u0628\u0627\u06CC\u062F \u062F "${_issue.prefix}" \u0633\u0631\u0647 \u067E\u06CC\u0644 \u0634\u064A`;
          }
          if (_issue.format === "ends_with") {
            return `\u0646\u0627\u0633\u0645 \u0645\u062A\u0646: \u0628\u0627\u06CC\u062F \u062F "${_issue.suffix}" \u0633\u0631\u0647 \u067E\u0627\u06CC \u062A\u0647 \u0648\u0631\u0633\u064A\u0696\u064A`;
          }
          if (_issue.format === "includes") {
            return `\u0646\u0627\u0633\u0645 \u0645\u062A\u0646: \u0628\u0627\u06CC\u062F "${_issue.includes}" \u0648\u0644\u0631\u064A`;
          }
          if (_issue.format === "regex") {
            return `\u0646\u0627\u0633\u0645 \u0645\u062A\u0646: \u0628\u0627\u06CC\u062F \u062F ${_issue.pattern} \u0633\u0631\u0647 \u0645\u0637\u0627\u0628\u0642\u062A \u0648\u0644\u0631\u064A`;
          }
          return `${FormatDictionary[_issue.format] ?? issue2.format} \u0646\u0627\u0633\u0645 \u062F\u06CC`;
        }
        case "not_multiple_of":
          return `\u0646\u0627\u0633\u0645 \u0639\u062F\u062F: \u0628\u0627\u06CC\u062F \u062F ${issue2.divisor} \u0645\u0636\u0631\u0628 \u0648\u064A`;
        case "unrecognized_keys":
          return `\u0646\u0627\u0633\u0645 ${issue2.keys.length > 1 ? "\u06A9\u0644\u06CC\u0689\u0648\u0646\u0647" : "\u06A9\u0644\u06CC\u0689"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\u0646\u0627\u0633\u0645 \u06A9\u0644\u06CC\u0689 \u067E\u0647 ${issue2.origin} \u06A9\u06D0`;
        case "invalid_union":
          return `\u0646\u0627\u0633\u0645\u0647 \u0648\u0631\u0648\u062F\u064A`;
        case "invalid_element":
          return `\u0646\u0627\u0633\u0645 \u0639\u0646\u0635\u0631 \u067E\u0647 ${issue2.origin} \u06A9\u06D0`;
        default:
          return `\u0646\u0627\u0633\u0645\u0647 \u0648\u0631\u0648\u062F\u064A`;
      }
    };
  };
  function ps_default() {
    return {
      localeError: error34()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/pl.js
  init_runtime();
  var error35 = () => {
    const Sizable = {
      string: { unit: "znak\xF3w", verb: "mie\u0107" },
      file: { unit: "bajt\xF3w", verb: "mie\u0107" },
      array: { unit: "element\xF3w", verb: "mie\u0107" },
      set: { unit: "element\xF3w", verb: "mie\u0107" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "wyra\u017Cenie",
      email: "adres email",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "data i godzina w formacie ISO",
      date: "data w formacie ISO",
      time: "godzina w formacie ISO",
      duration: "czas trwania ISO",
      ipv4: "adres IPv4",
      ipv6: "adres IPv6",
      cidrv4: "zakres IPv4",
      cidrv6: "zakres IPv6",
      base64: "ci\u0105g znak\xF3w zakodowany w formacie base64",
      base64url: "ci\u0105g znak\xF3w zakodowany w formacie base64url",
      json_string: "ci\u0105g znak\xF3w w formacie JSON",
      e164: "liczba E.164",
      jwt: "JWT",
      template_literal: "wej\u015Bcie"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "liczba",
      array: "tablica"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Nieprawid\u0142owe dane wej\u015Bciowe: oczekiwano instanceof ${issue2.expected}, otrzymano ${received}`;
          }
          return `Nieprawid\u0142owe dane wej\u015Bciowe: oczekiwano ${expected}, otrzymano ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Nieprawid\u0142owe dane wej\u015Bciowe: oczekiwano ${stringifyPrimitive(issue2.values[0])}`;
          return `Nieprawid\u0142owa opcja: oczekiwano jednej z warto\u015Bci ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Za du\u017Ca warto\u015B\u0107: oczekiwano, \u017Ce ${issue2.origin ?? "warto\u015B\u0107"} b\u0119dzie mie\u0107 ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "element\xF3w"}`;
          }
          return `Zbyt du\u017C(y/a/e): oczekiwano, \u017Ce ${issue2.origin ?? "warto\u015B\u0107"} b\u0119dzie wynosi\u0107 ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Za ma\u0142a warto\u015B\u0107: oczekiwano, \u017Ce ${issue2.origin ?? "warto\u015B\u0107"} b\u0119dzie mie\u0107 ${adj}${issue2.minimum.toString()} ${sizing.unit ?? "element\xF3w"}`;
          }
          return `Zbyt ma\u0142(y/a/e): oczekiwano, \u017Ce ${issue2.origin ?? "warto\u015B\u0107"} b\u0119dzie wynosi\u0107 ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Nieprawid\u0142owy ci\u0105g znak\xF3w: musi zaczyna\u0107 si\u0119 od "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `Nieprawid\u0142owy ci\u0105g znak\xF3w: musi ko\u0144czy\u0107 si\u0119 na "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Nieprawid\u0142owy ci\u0105g znak\xF3w: musi zawiera\u0107 "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Nieprawid\u0142owy ci\u0105g znak\xF3w: musi odpowiada\u0107 wzorcowi ${_issue.pattern}`;
          return `Nieprawid\u0142ow(y/a/e) ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Nieprawid\u0142owa liczba: musi by\u0107 wielokrotno\u015Bci\u0105 ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Nierozpoznane klucze${issue2.keys.length > 1 ? "s" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Nieprawid\u0142owy klucz w ${issue2.origin}`;
        case "invalid_union":
          return "Nieprawid\u0142owe dane wej\u015Bciowe";
        case "invalid_element":
          return `Nieprawid\u0142owa warto\u015B\u0107 w ${issue2.origin}`;
        default:
          return `Nieprawid\u0142owe dane wej\u015Bciowe`;
      }
    };
  };
  function pl_default() {
    return {
      localeError: error35()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/pt.js
  init_runtime();
  var error36 = () => {
    const Sizable = {
      string: { unit: "caracteres", verb: "ter" },
      file: { unit: "bytes", verb: "ter" },
      array: { unit: "itens", verb: "ter" },
      set: { unit: "itens", verb: "ter" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "padr\xE3o",
      email: "endere\xE7o de e-mail",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "data e hora ISO",
      date: "data ISO",
      time: "hora ISO",
      duration: "dura\xE7\xE3o ISO",
      ipv4: "endere\xE7o IPv4",
      ipv6: "endere\xE7o IPv6",
      cidrv4: "faixa de IPv4",
      cidrv6: "faixa de IPv6",
      base64: "texto codificado em base64",
      base64url: "URL codificada em base64",
      json_string: "texto JSON",
      e164: "n\xFAmero E.164",
      jwt: "JWT",
      template_literal: "entrada"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "n\xFAmero",
      null: "nulo"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Tipo inv\xE1lido: esperado instanceof ${issue2.expected}, recebido ${received}`;
          }
          return `Tipo inv\xE1lido: esperado ${expected}, recebido ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Entrada inv\xE1lida: esperado ${stringifyPrimitive(issue2.values[0])}`;
          return `Op\xE7\xE3o inv\xE1lida: esperada uma das ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Muito grande: esperado que ${issue2.origin ?? "valor"} tivesse ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elementos"}`;
          return `Muito grande: esperado que ${issue2.origin ?? "valor"} fosse ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Muito pequeno: esperado que ${issue2.origin} tivesse ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Muito pequeno: esperado que ${issue2.origin} fosse ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Texto inv\xE1lido: deve come\xE7ar com "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `Texto inv\xE1lido: deve terminar com "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Texto inv\xE1lido: deve incluir "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Texto inv\xE1lido: deve corresponder ao padr\xE3o ${_issue.pattern}`;
          return `${FormatDictionary[_issue.format] ?? issue2.format} inv\xE1lido`;
        }
        case "not_multiple_of":
          return `N\xFAmero inv\xE1lido: deve ser m\xFAltiplo de ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Chave${issue2.keys.length > 1 ? "s" : ""} desconhecida${issue2.keys.length > 1 ? "s" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Chave inv\xE1lida em ${issue2.origin}`;
        case "invalid_union":
          return "Entrada inv\xE1lida";
        case "invalid_element":
          return `Valor inv\xE1lido em ${issue2.origin}`;
        default:
          return `Campo inv\xE1lido`;
      }
    };
  };
  function pt_default() {
    return {
      localeError: error36()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/ro.js
  init_runtime();
  var error37 = () => {
    const Sizable = {
      string: { unit: "caractere", verb: "s\u0103 aib\u0103" },
      file: { unit: "octe\u021Bi", verb: "s\u0103 aib\u0103" },
      array: { unit: "elemente", verb: "s\u0103 aib\u0103" },
      set: { unit: "elemente", verb: "s\u0103 aib\u0103" },
      map: { unit: "intr\u0103ri", verb: "s\u0103 aib\u0103" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "intrare",
      email: "adres\u0103 de email",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "dat\u0103 \u0219i or\u0103 ISO",
      date: "dat\u0103 ISO",
      time: "or\u0103 ISO",
      duration: "durat\u0103 ISO",
      ipv4: "adres\u0103 IPv4",
      ipv6: "adres\u0103 IPv6",
      mac: "adres\u0103 MAC",
      cidrv4: "interval IPv4",
      cidrv6: "interval IPv6",
      base64: "\u0219ir codat base64",
      base64url: "\u0219ir codat base64url",
      json_string: "\u0219ir JSON",
      e164: "num\u0103r E.164",
      jwt: "JWT",
      template_literal: "intrare"
    };
    const TypeDictionary = {
      nan: "NaN",
      string: "\u0219ir",
      number: "num\u0103r",
      boolean: "boolean",
      function: "func\u021Bie",
      array: "matrice",
      object: "obiect",
      undefined: "nedefinit",
      symbol: "simbol",
      bigint: "num\u0103r mare",
      void: "void",
      never: "never",
      map: "hart\u0103",
      set: "set"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          return `Intrare invalid\u0103: a\u0219teptat ${expected}, primit ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Intrare invalid\u0103: a\u0219teptat ${stringifyPrimitive(issue2.values[0])}`;
          return `Op\u021Biune invalid\u0103: a\u0219teptat una dintre ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Prea mare: a\u0219teptat ca ${issue2.origin ?? "valoarea"} ${sizing.verb} ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elemente"}`;
          return `Prea mare: a\u0219teptat ca ${issue2.origin ?? "valoarea"} s\u0103 fie ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Prea mic: a\u0219teptat ca ${issue2.origin} ${sizing.verb} ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Prea mic: a\u0219teptat ca ${issue2.origin} s\u0103 fie ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `\u0218ir invalid: trebuie s\u0103 \xEEnceap\u0103 cu "${_issue.prefix}"`;
          }
          if (_issue.format === "ends_with")
            return `\u0218ir invalid: trebuie s\u0103 se termine cu "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `\u0218ir invalid: trebuie s\u0103 includ\u0103 "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u0218ir invalid: trebuie s\u0103 se potriveasc\u0103 cu modelul ${_issue.pattern}`;
          return `Format invalid: ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Num\u0103r invalid: trebuie s\u0103 fie multiplu de ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Chei nerecunoscute: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Cheie invalid\u0103 \xEEn ${issue2.origin}`;
        case "invalid_union":
          return "Intrare invalid\u0103";
        case "invalid_element":
          return `Valoare invalid\u0103 \xEEn ${issue2.origin}`;
        default:
          return `Intrare invalid\u0103`;
      }
    };
  };
  function ro_default() {
    return {
      localeError: error37()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/ru.js
  init_runtime();
  function getRussianPlural(count, one, few, many) {
    const absCount = Math.abs(count);
    const lastDigit = absCount % 10;
    const lastTwoDigits = absCount % 100;
    if (lastTwoDigits >= 11 && lastTwoDigits <= 19) {
      return many;
    }
    if (lastDigit === 1) {
      return one;
    }
    if (lastDigit >= 2 && lastDigit <= 4) {
      return few;
    }
    return many;
  }
  var error38 = () => {
    const Sizable = {
      string: {
        unit: {
          one: "\u0441\u0438\u043C\u0432\u043E\u043B",
          few: "\u0441\u0438\u043C\u0432\u043E\u043B\u0430",
          many: "\u0441\u0438\u043C\u0432\u043E\u043B\u043E\u0432"
        },
        verb: "\u0438\u043C\u0435\u0442\u044C"
      },
      file: {
        unit: {
          one: "\u0431\u0430\u0439\u0442",
          few: "\u0431\u0430\u0439\u0442\u0430",
          many: "\u0431\u0430\u0439\u0442"
        },
        verb: "\u0438\u043C\u0435\u0442\u044C"
      },
      array: {
        unit: {
          one: "\u044D\u043B\u0435\u043C\u0435\u043D\u0442",
          few: "\u044D\u043B\u0435\u043C\u0435\u043D\u0442\u0430",
          many: "\u044D\u043B\u0435\u043C\u0435\u043D\u0442\u043E\u0432"
        },
        verb: "\u0438\u043C\u0435\u0442\u044C"
      },
      set: {
        unit: {
          one: "\u044D\u043B\u0435\u043C\u0435\u043D\u0442",
          few: "\u044D\u043B\u0435\u043C\u0435\u043D\u0442\u0430",
          many: "\u044D\u043B\u0435\u043C\u0435\u043D\u0442\u043E\u0432"
        },
        verb: "\u0438\u043C\u0435\u0442\u044C"
      }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u0432\u0432\u043E\u0434",
      email: "email \u0430\u0434\u0440\u0435\u0441",
      url: "URL",
      emoji: "\u044D\u043C\u043E\u0434\u0437\u0438",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO \u0434\u0430\u0442\u0430 \u0438 \u0432\u0440\u0435\u043C\u044F",
      date: "ISO \u0434\u0430\u0442\u0430",
      time: "ISO \u0432\u0440\u0435\u043C\u044F",
      duration: "ISO \u0434\u043B\u0438\u0442\u0435\u043B\u044C\u043D\u043E\u0441\u0442\u044C",
      ipv4: "IPv4 \u0430\u0434\u0440\u0435\u0441",
      ipv6: "IPv6 \u0430\u0434\u0440\u0435\u0441",
      cidrv4: "IPv4 \u0434\u0438\u0430\u043F\u0430\u0437\u043E\u043D",
      cidrv6: "IPv6 \u0434\u0438\u0430\u043F\u0430\u0437\u043E\u043D",
      base64: "\u0441\u0442\u0440\u043E\u043A\u0430 \u0432 \u0444\u043E\u0440\u043C\u0430\u0442\u0435 base64",
      base64url: "\u0441\u0442\u0440\u043E\u043A\u0430 \u0432 \u0444\u043E\u0440\u043C\u0430\u0442\u0435 base64url",
      json_string: "JSON \u0441\u0442\u0440\u043E\u043A\u0430",
      e164: "\u043D\u043E\u043C\u0435\u0440 E.164",
      jwt: "JWT",
      template_literal: "\u0432\u0432\u043E\u0434"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u0447\u0438\u0441\u043B\u043E",
      array: "\u043C\u0430\u0441\u0441\u0438\u0432"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u041D\u0435\u0432\u0435\u0440\u043D\u044B\u0439 \u0432\u0432\u043E\u0434: \u043E\u0436\u0438\u0434\u0430\u043B\u043E\u0441\u044C instanceof ${issue2.expected}, \u043F\u043E\u043B\u0443\u0447\u0435\u043D\u043E ${received}`;
          }
          return `\u041D\u0435\u0432\u0435\u0440\u043D\u044B\u0439 \u0432\u0432\u043E\u0434: \u043E\u0436\u0438\u0434\u0430\u043B\u043E\u0441\u044C ${expected}, \u043F\u043E\u043B\u0443\u0447\u0435\u043D\u043E ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u041D\u0435\u0432\u0435\u0440\u043D\u044B\u0439 \u0432\u0432\u043E\u0434: \u043E\u0436\u0438\u0434\u0430\u043B\u043E\u0441\u044C ${stringifyPrimitive(issue2.values[0])}`;
          return `\u041D\u0435\u0432\u0435\u0440\u043D\u044B\u0439 \u0432\u0430\u0440\u0438\u0430\u043D\u0442: \u043E\u0436\u0438\u0434\u0430\u043B\u043E\u0441\u044C \u043E\u0434\u043D\u043E \u0438\u0437 ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            const maxValue = Number(issue2.maximum);
            const unit = getRussianPlural(maxValue, sizing.unit.one, sizing.unit.few, sizing.unit.many);
            return `\u0421\u043B\u0438\u0448\u043A\u043E\u043C \u0431\u043E\u043B\u044C\u0448\u043E\u0435 \u0437\u043D\u0430\u0447\u0435\u043D\u0438\u0435: \u043E\u0436\u0438\u0434\u0430\u043B\u043E\u0441\u044C, \u0447\u0442\u043E ${issue2.origin ?? "\u0437\u043D\u0430\u0447\u0435\u043D\u0438\u0435"} \u0431\u0443\u0434\u0435\u0442 \u0438\u043C\u0435\u0442\u044C ${adj}${issue2.maximum.toString()} ${unit}`;
          }
          return `\u0421\u043B\u0438\u0448\u043A\u043E\u043C \u0431\u043E\u043B\u044C\u0448\u043E\u0435 \u0437\u043D\u0430\u0447\u0435\u043D\u0438\u0435: \u043E\u0436\u0438\u0434\u0430\u043B\u043E\u0441\u044C, \u0447\u0442\u043E ${issue2.origin ?? "\u0437\u043D\u0430\u0447\u0435\u043D\u0438\u0435"} \u0431\u0443\u0434\u0435\u0442 ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            const minValue = Number(issue2.minimum);
            const unit = getRussianPlural(minValue, sizing.unit.one, sizing.unit.few, sizing.unit.many);
            return `\u0421\u043B\u0438\u0448\u043A\u043E\u043C \u043C\u0430\u043B\u0435\u043D\u044C\u043A\u043E\u0435 \u0437\u043D\u0430\u0447\u0435\u043D\u0438\u0435: \u043E\u0436\u0438\u0434\u0430\u043B\u043E\u0441\u044C, \u0447\u0442\u043E ${issue2.origin} \u0431\u0443\u0434\u0435\u0442 \u0438\u043C\u0435\u0442\u044C ${adj}${issue2.minimum.toString()} ${unit}`;
          }
          return `\u0421\u043B\u0438\u0448\u043A\u043E\u043C \u043C\u0430\u043B\u0435\u043D\u044C\u043A\u043E\u0435 \u0437\u043D\u0430\u0447\u0435\u043D\u0438\u0435: \u043E\u0436\u0438\u0434\u0430\u043B\u043E\u0441\u044C, \u0447\u0442\u043E ${issue2.origin} \u0431\u0443\u0434\u0435\u0442 ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `\u041D\u0435\u0432\u0435\u0440\u043D\u0430\u044F \u0441\u0442\u0440\u043E\u043A\u0430: \u0434\u043E\u043B\u0436\u043D\u0430 \u043D\u0430\u0447\u0438\u043D\u0430\u0442\u044C\u0441\u044F \u0441 "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `\u041D\u0435\u0432\u0435\u0440\u043D\u0430\u044F \u0441\u0442\u0440\u043E\u043A\u0430: \u0434\u043E\u043B\u0436\u043D\u0430 \u0437\u0430\u043A\u0430\u043D\u0447\u0438\u0432\u0430\u0442\u044C\u0441\u044F \u043D\u0430 "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `\u041D\u0435\u0432\u0435\u0440\u043D\u0430\u044F \u0441\u0442\u0440\u043E\u043A\u0430: \u0434\u043E\u043B\u0436\u043D\u0430 \u0441\u043E\u0434\u0435\u0440\u0436\u0430\u0442\u044C "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u041D\u0435\u0432\u0435\u0440\u043D\u0430\u044F \u0441\u0442\u0440\u043E\u043A\u0430: \u0434\u043E\u043B\u0436\u043D\u0430 \u0441\u043E\u043E\u0442\u0432\u0435\u0442\u0441\u0442\u0432\u043E\u0432\u0430\u0442\u044C \u0448\u0430\u0431\u043B\u043E\u043D\u0443 ${_issue.pattern}`;
          return `\u041D\u0435\u0432\u0435\u0440\u043D\u044B\u0439 ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u041D\u0435\u0432\u0435\u0440\u043D\u043E\u0435 \u0447\u0438\u0441\u043B\u043E: \u0434\u043E\u043B\u0436\u043D\u043E \u0431\u044B\u0442\u044C \u043A\u0440\u0430\u0442\u043D\u044B\u043C ${issue2.divisor}`;
        case "unrecognized_keys":
          return `\u041D\u0435\u0440\u0430\u0441\u043F\u043E\u0437\u043D\u0430\u043D\u043D${issue2.keys.length > 1 ? "\u044B\u0435" : "\u044B\u0439"} \u043A\u043B\u044E\u0447${issue2.keys.length > 1 ? "\u0438" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\u041D\u0435\u0432\u0435\u0440\u043D\u044B\u0439 \u043A\u043B\u044E\u0447 \u0432 ${issue2.origin}`;
        case "invalid_union":
          return "\u041D\u0435\u0432\u0435\u0440\u043D\u044B\u0435 \u0432\u0445\u043E\u0434\u043D\u044B\u0435 \u0434\u0430\u043D\u043D\u044B\u0435";
        case "invalid_element":
          return `\u041D\u0435\u0432\u0435\u0440\u043D\u043E\u0435 \u0437\u043D\u0430\u0447\u0435\u043D\u0438\u0435 \u0432 ${issue2.origin}`;
        default:
          return `\u041D\u0435\u0432\u0435\u0440\u043D\u044B\u0435 \u0432\u0445\u043E\u0434\u043D\u044B\u0435 \u0434\u0430\u043D\u043D\u044B\u0435`;
      }
    };
  };
  function ru_default() {
    return {
      localeError: error38()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/sl.js
  init_runtime();
  var error39 = () => {
    const Sizable = {
      string: { unit: "znakov", verb: "imeti" },
      file: { unit: "bajtov", verb: "imeti" },
      array: { unit: "elementov", verb: "imeti" },
      set: { unit: "elementov", verb: "imeti" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "vnos",
      email: "e-po\u0161tni naslov",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO datum in \u010Das",
      date: "ISO datum",
      time: "ISO \u010Das",
      duration: "ISO trajanje",
      ipv4: "IPv4 naslov",
      ipv6: "IPv6 naslov",
      cidrv4: "obseg IPv4",
      cidrv6: "obseg IPv6",
      base64: "base64 kodiran niz",
      base64url: "base64url kodiran niz",
      json_string: "JSON niz",
      e164: "E.164 \u0161tevilka",
      jwt: "JWT",
      template_literal: "vnos"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u0161tevilo",
      array: "tabela"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Neveljaven vnos: pri\u010Dakovano instanceof ${issue2.expected}, prejeto ${received}`;
          }
          return `Neveljaven vnos: pri\u010Dakovano ${expected}, prejeto ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Neveljaven vnos: pri\u010Dakovano ${stringifyPrimitive(issue2.values[0])}`;
          return `Neveljavna mo\u017Enost: pri\u010Dakovano eno izmed ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Preveliko: pri\u010Dakovano, da bo ${issue2.origin ?? "vrednost"} imelo ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "elementov"}`;
          return `Preveliko: pri\u010Dakovano, da bo ${issue2.origin ?? "vrednost"} ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Premajhno: pri\u010Dakovano, da bo ${issue2.origin} imelo ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Premajhno: pri\u010Dakovano, da bo ${issue2.origin} ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `Neveljaven niz: mora se za\u010Deti z "${_issue.prefix}"`;
          }
          if (_issue.format === "ends_with")
            return `Neveljaven niz: mora se kon\u010Dati z "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Neveljaven niz: mora vsebovati "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Neveljaven niz: mora ustrezati vzorcu ${_issue.pattern}`;
          return `Neveljaven ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Neveljavno \u0161tevilo: mora biti ve\u010Dkratnik ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Neprepoznan${issue2.keys.length > 1 ? "i klju\u010Di" : " klju\u010D"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Neveljaven klju\u010D v ${issue2.origin}`;
        case "invalid_union":
          return "Neveljaven vnos";
        case "invalid_element":
          return `Neveljavna vrednost v ${issue2.origin}`;
        default:
          return "Neveljaven vnos";
      }
    };
  };
  function sl_default() {
    return {
      localeError: error39()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/sv.js
  init_runtime();
  var error40 = () => {
    const Sizable = {
      string: { unit: "tecken", verb: "att ha" },
      file: { unit: "bytes", verb: "att ha" },
      array: { unit: "objekt", verb: "att inneh\xE5lla" },
      set: { unit: "objekt", verb: "att inneh\xE5lla" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "regulj\xE4rt uttryck",
      email: "e-postadress",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO-datum och tid",
      date: "ISO-datum",
      time: "ISO-tid",
      duration: "ISO-varaktighet",
      ipv4: "IPv4-intervall",
      ipv6: "IPv6-intervall",
      cidrv4: "IPv4-spektrum",
      cidrv6: "IPv6-spektrum",
      base64: "base64-kodad str\xE4ng",
      base64url: "base64url-kodad str\xE4ng",
      json_string: "JSON-str\xE4ng",
      e164: "E.164-nummer",
      jwt: "JWT",
      template_literal: "mall-literal"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "antal",
      array: "lista"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Ogiltig inmatning: f\xF6rv\xE4ntat instanceof ${issue2.expected}, fick ${received}`;
          }
          return `Ogiltig inmatning: f\xF6rv\xE4ntat ${expected}, fick ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Ogiltig inmatning: f\xF6rv\xE4ntat ${stringifyPrimitive(issue2.values[0])}`;
          return `Ogiltigt val: f\xF6rv\xE4ntade en av ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `F\xF6r stor(t): f\xF6rv\xE4ntade ${issue2.origin ?? "v\xE4rdet"} att ha ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "element"}`;
          }
          return `F\xF6r stor(t): f\xF6rv\xE4ntat ${issue2.origin ?? "v\xE4rdet"} att ha ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `F\xF6r lite(t): f\xF6rv\xE4ntade ${issue2.origin ?? "v\xE4rdet"} att ha ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `F\xF6r lite(t): f\xF6rv\xE4ntade ${issue2.origin ?? "v\xE4rdet"} att ha ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `Ogiltig str\xE4ng: m\xE5ste b\xF6rja med "${_issue.prefix}"`;
          }
          if (_issue.format === "ends_with")
            return `Ogiltig str\xE4ng: m\xE5ste sluta med "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Ogiltig str\xE4ng: m\xE5ste inneh\xE5lla "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Ogiltig str\xE4ng: m\xE5ste matcha m\xF6nstret "${_issue.pattern}"`;
          return `Ogiltig(t) ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Ogiltigt tal: m\xE5ste vara en multipel av ${issue2.divisor}`;
        case "unrecognized_keys":
          return `${issue2.keys.length > 1 ? "Ok\xE4nda nycklar" : "Ok\xE4nd nyckel"}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Ogiltig nyckel i ${issue2.origin ?? "v\xE4rdet"}`;
        case "invalid_union":
          return "Ogiltig input";
        case "invalid_element":
          return `Ogiltigt v\xE4rde i ${issue2.origin ?? "v\xE4rdet"}`;
        default:
          return `Ogiltig input`;
      }
    };
  };
  function sv_default() {
    return {
      localeError: error40()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/ta.js
  init_runtime();
  var error41 = () => {
    const Sizable = {
      string: { unit: "\u0B8E\u0BB4\u0BC1\u0BA4\u0BCD\u0BA4\u0BC1\u0B95\u0BCD\u0B95\u0BB3\u0BCD", verb: "\u0B95\u0BCA\u0BA3\u0BCD\u0B9F\u0BBF\u0BB0\u0BC1\u0B95\u0BCD\u0B95 \u0BB5\u0BC7\u0BA3\u0BCD\u0B9F\u0BC1\u0BAE\u0BCD" },
      file: { unit: "\u0BAA\u0BC8\u0B9F\u0BCD\u0B9F\u0BC1\u0B95\u0BB3\u0BCD", verb: "\u0B95\u0BCA\u0BA3\u0BCD\u0B9F\u0BBF\u0BB0\u0BC1\u0B95\u0BCD\u0B95 \u0BB5\u0BC7\u0BA3\u0BCD\u0B9F\u0BC1\u0BAE\u0BCD" },
      array: { unit: "\u0B89\u0BB1\u0BC1\u0BAA\u0BCD\u0BAA\u0BC1\u0B95\u0BB3\u0BCD", verb: "\u0B95\u0BCA\u0BA3\u0BCD\u0B9F\u0BBF\u0BB0\u0BC1\u0B95\u0BCD\u0B95 \u0BB5\u0BC7\u0BA3\u0BCD\u0B9F\u0BC1\u0BAE\u0BCD" },
      set: { unit: "\u0B89\u0BB1\u0BC1\u0BAA\u0BCD\u0BAA\u0BC1\u0B95\u0BB3\u0BCD", verb: "\u0B95\u0BCA\u0BA3\u0BCD\u0B9F\u0BBF\u0BB0\u0BC1\u0B95\u0BCD\u0B95 \u0BB5\u0BC7\u0BA3\u0BCD\u0B9F\u0BC1\u0BAE\u0BCD" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u0B89\u0BB3\u0BCD\u0BB3\u0BC0\u0B9F\u0BC1",
      email: "\u0BAE\u0BBF\u0BA9\u0BCD\u0BA9\u0B9E\u0BCD\u0B9A\u0BB2\u0BCD \u0BAE\u0BC1\u0B95\u0BB5\u0BB0\u0BBF",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO \u0BA4\u0BC7\u0BA4\u0BBF \u0BA8\u0BC7\u0BB0\u0BAE\u0BCD",
      date: "ISO \u0BA4\u0BC7\u0BA4\u0BBF",
      time: "ISO \u0BA8\u0BC7\u0BB0\u0BAE\u0BCD",
      duration: "ISO \u0B95\u0BBE\u0BB2 \u0B85\u0BB3\u0BB5\u0BC1",
      ipv4: "IPv4 \u0BAE\u0BC1\u0B95\u0BB5\u0BB0\u0BBF",
      ipv6: "IPv6 \u0BAE\u0BC1\u0B95\u0BB5\u0BB0\u0BBF",
      cidrv4: "IPv4 \u0BB5\u0BB0\u0BAE\u0BCD\u0BAA\u0BC1",
      cidrv6: "IPv6 \u0BB5\u0BB0\u0BAE\u0BCD\u0BAA\u0BC1",
      base64: "base64-encoded \u0B9A\u0BB0\u0BAE\u0BCD",
      base64url: "base64url-encoded \u0B9A\u0BB0\u0BAE\u0BCD",
      json_string: "JSON \u0B9A\u0BB0\u0BAE\u0BCD",
      e164: "E.164 \u0B8E\u0BA3\u0BCD",
      jwt: "JWT",
      template_literal: "input"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u0B8E\u0BA3\u0BCD",
      array: "\u0B85\u0BA3\u0BBF",
      null: "\u0BB5\u0BC6\u0BB1\u0BC1\u0BAE\u0BC8"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 \u0B89\u0BB3\u0BCD\u0BB3\u0BC0\u0B9F\u0BC1: \u0B8E\u0BA4\u0BBF\u0BB0\u0BCD\u0BAA\u0BBE\u0BB0\u0BCD\u0B95\u0BCD\u0B95\u0BAA\u0BCD\u0BAA\u0B9F\u0BCD\u0B9F\u0BA4\u0BC1 instanceof ${issue2.expected}, \u0BAA\u0BC6\u0BB1\u0BAA\u0BCD\u0BAA\u0B9F\u0BCD\u0B9F\u0BA4\u0BC1 ${received}`;
          }
          return `\u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 \u0B89\u0BB3\u0BCD\u0BB3\u0BC0\u0B9F\u0BC1: \u0B8E\u0BA4\u0BBF\u0BB0\u0BCD\u0BAA\u0BBE\u0BB0\u0BCD\u0B95\u0BCD\u0B95\u0BAA\u0BCD\u0BAA\u0B9F\u0BCD\u0B9F\u0BA4\u0BC1 ${expected}, \u0BAA\u0BC6\u0BB1\u0BAA\u0BCD\u0BAA\u0B9F\u0BCD\u0B9F\u0BA4\u0BC1 ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 \u0B89\u0BB3\u0BCD\u0BB3\u0BC0\u0B9F\u0BC1: \u0B8E\u0BA4\u0BBF\u0BB0\u0BCD\u0BAA\u0BBE\u0BB0\u0BCD\u0B95\u0BCD\u0B95\u0BAA\u0BCD\u0BAA\u0B9F\u0BCD\u0B9F\u0BA4\u0BC1 ${stringifyPrimitive(issue2.values[0])}`;
          return `\u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 \u0BB5\u0BBF\u0BB0\u0BC1\u0BAA\u0BCD\u0BAA\u0BAE\u0BCD: \u0B8E\u0BA4\u0BBF\u0BB0\u0BCD\u0BAA\u0BBE\u0BB0\u0BCD\u0B95\u0BCD\u0B95\u0BAA\u0BCD\u0BAA\u0B9F\u0BCD\u0B9F\u0BA4\u0BC1 ${joinValues(issue2.values, "|")} \u0B87\u0BB2\u0BCD \u0B92\u0BA9\u0BCD\u0BB1\u0BC1`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u0BAE\u0BBF\u0B95 \u0BAA\u0BC6\u0BB0\u0BBF\u0BAF\u0BA4\u0BC1: \u0B8E\u0BA4\u0BBF\u0BB0\u0BCD\u0BAA\u0BBE\u0BB0\u0BCD\u0B95\u0BCD\u0B95\u0BAA\u0BCD\u0BAA\u0B9F\u0BCD\u0B9F\u0BA4\u0BC1 ${issue2.origin ?? "\u0BAE\u0BA4\u0BBF\u0BAA\u0BCD\u0BAA\u0BC1"} ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "\u0B89\u0BB1\u0BC1\u0BAA\u0BCD\u0BAA\u0BC1\u0B95\u0BB3\u0BCD"} \u0B86\u0B95 \u0B87\u0BB0\u0BC1\u0B95\u0BCD\u0B95 \u0BB5\u0BC7\u0BA3\u0BCD\u0B9F\u0BC1\u0BAE\u0BCD`;
          }
          return `\u0BAE\u0BBF\u0B95 \u0BAA\u0BC6\u0BB0\u0BBF\u0BAF\u0BA4\u0BC1: \u0B8E\u0BA4\u0BBF\u0BB0\u0BCD\u0BAA\u0BBE\u0BB0\u0BCD\u0B95\u0BCD\u0B95\u0BAA\u0BCD\u0BAA\u0B9F\u0BCD\u0B9F\u0BA4\u0BC1 ${issue2.origin ?? "\u0BAE\u0BA4\u0BBF\u0BAA\u0BCD\u0BAA\u0BC1"} ${adj}${issue2.maximum.toString()} \u0B86\u0B95 \u0B87\u0BB0\u0BC1\u0B95\u0BCD\u0B95 \u0BB5\u0BC7\u0BA3\u0BCD\u0B9F\u0BC1\u0BAE\u0BCD`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u0BAE\u0BBF\u0B95\u0B9A\u0BCD \u0B9A\u0BBF\u0BB1\u0BBF\u0BAF\u0BA4\u0BC1: \u0B8E\u0BA4\u0BBF\u0BB0\u0BCD\u0BAA\u0BBE\u0BB0\u0BCD\u0B95\u0BCD\u0B95\u0BAA\u0BCD\u0BAA\u0B9F\u0BCD\u0B9F\u0BA4\u0BC1 ${issue2.origin} ${adj}${issue2.minimum.toString()} ${sizing.unit} \u0B86\u0B95 \u0B87\u0BB0\u0BC1\u0B95\u0BCD\u0B95 \u0BB5\u0BC7\u0BA3\u0BCD\u0B9F\u0BC1\u0BAE\u0BCD`;
          }
          return `\u0BAE\u0BBF\u0B95\u0B9A\u0BCD \u0B9A\u0BBF\u0BB1\u0BBF\u0BAF\u0BA4\u0BC1: \u0B8E\u0BA4\u0BBF\u0BB0\u0BCD\u0BAA\u0BBE\u0BB0\u0BCD\u0B95\u0BCD\u0B95\u0BAA\u0BCD\u0BAA\u0B9F\u0BCD\u0B9F\u0BA4\u0BC1 ${issue2.origin} ${adj}${issue2.minimum.toString()} \u0B86\u0B95 \u0B87\u0BB0\u0BC1\u0B95\u0BCD\u0B95 \u0BB5\u0BC7\u0BA3\u0BCD\u0B9F\u0BC1\u0BAE\u0BCD`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `\u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 \u0B9A\u0BB0\u0BAE\u0BCD: "${_issue.prefix}" \u0B87\u0BB2\u0BCD \u0BA4\u0BCA\u0B9F\u0B99\u0BCD\u0B95 \u0BB5\u0BC7\u0BA3\u0BCD\u0B9F\u0BC1\u0BAE\u0BCD`;
          if (_issue.format === "ends_with")
            return `\u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 \u0B9A\u0BB0\u0BAE\u0BCD: "${_issue.suffix}" \u0B87\u0BB2\u0BCD \u0BAE\u0BC1\u0B9F\u0BBF\u0BB5\u0B9F\u0BC8\u0BAF \u0BB5\u0BC7\u0BA3\u0BCD\u0B9F\u0BC1\u0BAE\u0BCD`;
          if (_issue.format === "includes")
            return `\u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 \u0B9A\u0BB0\u0BAE\u0BCD: "${_issue.includes}" \u0B90 \u0B89\u0BB3\u0BCD\u0BB3\u0B9F\u0B95\u0BCD\u0B95 \u0BB5\u0BC7\u0BA3\u0BCD\u0B9F\u0BC1\u0BAE\u0BCD`;
          if (_issue.format === "regex")
            return `\u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 \u0B9A\u0BB0\u0BAE\u0BCD: ${_issue.pattern} \u0BAE\u0BC1\u0BB1\u0BC8\u0BAA\u0BBE\u0B9F\u0BCD\u0B9F\u0BC1\u0B9F\u0BA9\u0BCD \u0BAA\u0BCA\u0BB0\u0BC1\u0BA8\u0BCD\u0BA4 \u0BB5\u0BC7\u0BA3\u0BCD\u0B9F\u0BC1\u0BAE\u0BCD`;
          return `\u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 \u0B8E\u0BA3\u0BCD: ${issue2.divisor} \u0B87\u0BA9\u0BCD \u0BAA\u0BB2\u0BAE\u0BBE\u0B95 \u0B87\u0BB0\u0BC1\u0B95\u0BCD\u0B95 \u0BB5\u0BC7\u0BA3\u0BCD\u0B9F\u0BC1\u0BAE\u0BCD`;
        case "unrecognized_keys":
          return `\u0B85\u0B9F\u0BC8\u0BAF\u0BBE\u0BB3\u0BAE\u0BCD \u0BA4\u0BC6\u0BB0\u0BBF\u0BAF\u0BBE\u0BA4 \u0BB5\u0BBF\u0B9A\u0BC8${issue2.keys.length > 1 ? "\u0B95\u0BB3\u0BCD" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `${issue2.origin} \u0B87\u0BB2\u0BCD \u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 \u0BB5\u0BBF\u0B9A\u0BC8`;
        case "invalid_union":
          return "\u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 \u0B89\u0BB3\u0BCD\u0BB3\u0BC0\u0B9F\u0BC1";
        case "invalid_element":
          return `${issue2.origin} \u0B87\u0BB2\u0BCD \u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 \u0BAE\u0BA4\u0BBF\u0BAA\u0BCD\u0BAA\u0BC1`;
        default:
          return `\u0BA4\u0BB5\u0BB1\u0BBE\u0BA9 \u0B89\u0BB3\u0BCD\u0BB3\u0BC0\u0B9F\u0BC1`;
      }
    };
  };
  function ta_default() {
    return {
      localeError: error41()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/th.js
  init_runtime();
  var error42 = () => {
    const Sizable = {
      string: { unit: "\u0E15\u0E31\u0E27\u0E2D\u0E31\u0E01\u0E29\u0E23", verb: "\u0E04\u0E27\u0E23\u0E21\u0E35" },
      file: { unit: "\u0E44\u0E1A\u0E15\u0E4C", verb: "\u0E04\u0E27\u0E23\u0E21\u0E35" },
      array: { unit: "\u0E23\u0E32\u0E22\u0E01\u0E32\u0E23", verb: "\u0E04\u0E27\u0E23\u0E21\u0E35" },
      set: { unit: "\u0E23\u0E32\u0E22\u0E01\u0E32\u0E23", verb: "\u0E04\u0E27\u0E23\u0E21\u0E35" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u0E02\u0E49\u0E2D\u0E21\u0E39\u0E25\u0E17\u0E35\u0E48\u0E1B\u0E49\u0E2D\u0E19",
      email: "\u0E17\u0E35\u0E48\u0E2D\u0E22\u0E39\u0E48\u0E2D\u0E35\u0E40\u0E21\u0E25",
      url: "URL",
      emoji: "\u0E2D\u0E34\u0E42\u0E21\u0E08\u0E34",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "\u0E27\u0E31\u0E19\u0E17\u0E35\u0E48\u0E40\u0E27\u0E25\u0E32\u0E41\u0E1A\u0E1A ISO",
      date: "\u0E27\u0E31\u0E19\u0E17\u0E35\u0E48\u0E41\u0E1A\u0E1A ISO",
      time: "\u0E40\u0E27\u0E25\u0E32\u0E41\u0E1A\u0E1A ISO",
      duration: "\u0E0A\u0E48\u0E27\u0E07\u0E40\u0E27\u0E25\u0E32\u0E41\u0E1A\u0E1A ISO",
      ipv4: "\u0E17\u0E35\u0E48\u0E2D\u0E22\u0E39\u0E48 IPv4",
      ipv6: "\u0E17\u0E35\u0E48\u0E2D\u0E22\u0E39\u0E48 IPv6",
      cidrv4: "\u0E0A\u0E48\u0E27\u0E07 IP \u0E41\u0E1A\u0E1A IPv4",
      cidrv6: "\u0E0A\u0E48\u0E27\u0E07 IP \u0E41\u0E1A\u0E1A IPv6",
      base64: "\u0E02\u0E49\u0E2D\u0E04\u0E27\u0E32\u0E21\u0E41\u0E1A\u0E1A Base64",
      base64url: "\u0E02\u0E49\u0E2D\u0E04\u0E27\u0E32\u0E21\u0E41\u0E1A\u0E1A Base64 \u0E2A\u0E33\u0E2B\u0E23\u0E31\u0E1A URL",
      json_string: "\u0E02\u0E49\u0E2D\u0E04\u0E27\u0E32\u0E21\u0E41\u0E1A\u0E1A JSON",
      e164: "\u0E40\u0E1A\u0E2D\u0E23\u0E4C\u0E42\u0E17\u0E23\u0E28\u0E31\u0E1E\u0E17\u0E4C\u0E23\u0E30\u0E2B\u0E27\u0E48\u0E32\u0E07\u0E1B\u0E23\u0E30\u0E40\u0E17\u0E28 (E.164)",
      jwt: "\u0E42\u0E17\u0E40\u0E04\u0E19 JWT",
      template_literal: "\u0E02\u0E49\u0E2D\u0E21\u0E39\u0E25\u0E17\u0E35\u0E48\u0E1B\u0E49\u0E2D\u0E19"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u0E15\u0E31\u0E27\u0E40\u0E25\u0E02",
      array: "\u0E2D\u0E32\u0E23\u0E4C\u0E40\u0E23\u0E22\u0E4C (Array)",
      null: "\u0E44\u0E21\u0E48\u0E21\u0E35\u0E04\u0E48\u0E32 (null)"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u0E1B\u0E23\u0E30\u0E40\u0E20\u0E17\u0E02\u0E49\u0E2D\u0E21\u0E39\u0E25\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07: \u0E04\u0E27\u0E23\u0E40\u0E1B\u0E47\u0E19 instanceof ${issue2.expected} \u0E41\u0E15\u0E48\u0E44\u0E14\u0E49\u0E23\u0E31\u0E1A ${received}`;
          }
          return `\u0E1B\u0E23\u0E30\u0E40\u0E20\u0E17\u0E02\u0E49\u0E2D\u0E21\u0E39\u0E25\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07: \u0E04\u0E27\u0E23\u0E40\u0E1B\u0E47\u0E19 ${expected} \u0E41\u0E15\u0E48\u0E44\u0E14\u0E49\u0E23\u0E31\u0E1A ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u0E04\u0E48\u0E32\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07: \u0E04\u0E27\u0E23\u0E40\u0E1B\u0E47\u0E19 ${stringifyPrimitive(issue2.values[0])}`;
          return `\u0E15\u0E31\u0E27\u0E40\u0E25\u0E37\u0E2D\u0E01\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07: \u0E04\u0E27\u0E23\u0E40\u0E1B\u0E47\u0E19\u0E2B\u0E19\u0E36\u0E48\u0E07\u0E43\u0E19 ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "\u0E44\u0E21\u0E48\u0E40\u0E01\u0E34\u0E19" : "\u0E19\u0E49\u0E2D\u0E22\u0E01\u0E27\u0E48\u0E32";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\u0E40\u0E01\u0E34\u0E19\u0E01\u0E33\u0E2B\u0E19\u0E14: ${issue2.origin ?? "\u0E04\u0E48\u0E32"} \u0E04\u0E27\u0E23\u0E21\u0E35${adj} ${issue2.maximum.toString()} ${sizing.unit ?? "\u0E23\u0E32\u0E22\u0E01\u0E32\u0E23"}`;
          return `\u0E40\u0E01\u0E34\u0E19\u0E01\u0E33\u0E2B\u0E19\u0E14: ${issue2.origin ?? "\u0E04\u0E48\u0E32"} \u0E04\u0E27\u0E23\u0E21\u0E35${adj} ${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? "\u0E2D\u0E22\u0E48\u0E32\u0E07\u0E19\u0E49\u0E2D\u0E22" : "\u0E21\u0E32\u0E01\u0E01\u0E27\u0E48\u0E32";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u0E19\u0E49\u0E2D\u0E22\u0E01\u0E27\u0E48\u0E32\u0E01\u0E33\u0E2B\u0E19\u0E14: ${issue2.origin} \u0E04\u0E27\u0E23\u0E21\u0E35${adj} ${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `\u0E19\u0E49\u0E2D\u0E22\u0E01\u0E27\u0E48\u0E32\u0E01\u0E33\u0E2B\u0E19\u0E14: ${issue2.origin} \u0E04\u0E27\u0E23\u0E21\u0E35${adj} ${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `\u0E23\u0E39\u0E1B\u0E41\u0E1A\u0E1A\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07: \u0E02\u0E49\u0E2D\u0E04\u0E27\u0E32\u0E21\u0E15\u0E49\u0E2D\u0E07\u0E02\u0E36\u0E49\u0E19\u0E15\u0E49\u0E19\u0E14\u0E49\u0E27\u0E22 "${_issue.prefix}"`;
          }
          if (_issue.format === "ends_with")
            return `\u0E23\u0E39\u0E1B\u0E41\u0E1A\u0E1A\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07: \u0E02\u0E49\u0E2D\u0E04\u0E27\u0E32\u0E21\u0E15\u0E49\u0E2D\u0E07\u0E25\u0E07\u0E17\u0E49\u0E32\u0E22\u0E14\u0E49\u0E27\u0E22 "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `\u0E23\u0E39\u0E1B\u0E41\u0E1A\u0E1A\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07: \u0E02\u0E49\u0E2D\u0E04\u0E27\u0E32\u0E21\u0E15\u0E49\u0E2D\u0E07\u0E21\u0E35 "${_issue.includes}" \u0E2D\u0E22\u0E39\u0E48\u0E43\u0E19\u0E02\u0E49\u0E2D\u0E04\u0E27\u0E32\u0E21`;
          if (_issue.format === "regex")
            return `\u0E23\u0E39\u0E1B\u0E41\u0E1A\u0E1A\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07: \u0E15\u0E49\u0E2D\u0E07\u0E15\u0E23\u0E07\u0E01\u0E31\u0E1A\u0E23\u0E39\u0E1B\u0E41\u0E1A\u0E1A\u0E17\u0E35\u0E48\u0E01\u0E33\u0E2B\u0E19\u0E14 ${_issue.pattern}`;
          return `\u0E23\u0E39\u0E1B\u0E41\u0E1A\u0E1A\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07: ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u0E15\u0E31\u0E27\u0E40\u0E25\u0E02\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07: \u0E15\u0E49\u0E2D\u0E07\u0E40\u0E1B\u0E47\u0E19\u0E08\u0E33\u0E19\u0E27\u0E19\u0E17\u0E35\u0E48\u0E2B\u0E32\u0E23\u0E14\u0E49\u0E27\u0E22 ${issue2.divisor} \u0E44\u0E14\u0E49\u0E25\u0E07\u0E15\u0E31\u0E27`;
        case "unrecognized_keys":
          return `\u0E1E\u0E1A\u0E04\u0E35\u0E22\u0E4C\u0E17\u0E35\u0E48\u0E44\u0E21\u0E48\u0E23\u0E39\u0E49\u0E08\u0E31\u0E01: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\u0E04\u0E35\u0E22\u0E4C\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07\u0E43\u0E19 ${issue2.origin}`;
        case "invalid_union":
          return "\u0E02\u0E49\u0E2D\u0E21\u0E39\u0E25\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07: \u0E44\u0E21\u0E48\u0E15\u0E23\u0E07\u0E01\u0E31\u0E1A\u0E23\u0E39\u0E1B\u0E41\u0E1A\u0E1A\u0E22\u0E39\u0E40\u0E19\u0E35\u0E22\u0E19\u0E17\u0E35\u0E48\u0E01\u0E33\u0E2B\u0E19\u0E14\u0E44\u0E27\u0E49";
        case "invalid_element":
          return `\u0E02\u0E49\u0E2D\u0E21\u0E39\u0E25\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07\u0E43\u0E19 ${issue2.origin}`;
        default:
          return `\u0E02\u0E49\u0E2D\u0E21\u0E39\u0E25\u0E44\u0E21\u0E48\u0E16\u0E39\u0E01\u0E15\u0E49\u0E2D\u0E07`;
      }
    };
  };
  function th_default() {
    return {
      localeError: error42()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/tr.js
  init_runtime();
  var error43 = () => {
    const Sizable = {
      string: { unit: "karakter", verb: "olmal\u0131" },
      file: { unit: "bayt", verb: "olmal\u0131" },
      array: { unit: "\xF6\u011Fe", verb: "olmal\u0131" },
      set: { unit: "\xF6\u011Fe", verb: "olmal\u0131" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "girdi",
      email: "e-posta adresi",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO tarih ve saat",
      date: "ISO tarih",
      time: "ISO saat",
      duration: "ISO s\xFCre",
      ipv4: "IPv4 adresi",
      ipv6: "IPv6 adresi",
      cidrv4: "IPv4 aral\u0131\u011F\u0131",
      cidrv6: "IPv6 aral\u0131\u011F\u0131",
      base64: "base64 ile \u015Fifrelenmi\u015F metin",
      base64url: "base64url ile \u015Fifrelenmi\u015F metin",
      json_string: "JSON dizesi",
      e164: "E.164 say\u0131s\u0131",
      jwt: "JWT",
      template_literal: "\u015Eablon dizesi"
    };
    const TypeDictionary = {
      nan: "NaN"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Ge\xE7ersiz de\u011Fer: beklenen instanceof ${issue2.expected}, al\u0131nan ${received}`;
          }
          return `Ge\xE7ersiz de\u011Fer: beklenen ${expected}, al\u0131nan ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Ge\xE7ersiz de\u011Fer: beklenen ${stringifyPrimitive(issue2.values[0])}`;
          return `Ge\xE7ersiz se\xE7enek: a\u015Fa\u011F\u0131dakilerden biri olmal\u0131: ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\xC7ok b\xFCy\xFCk: beklenen ${issue2.origin ?? "de\u011Fer"} ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "\xF6\u011Fe"}`;
          return `\xC7ok b\xFCy\xFCk: beklenen ${issue2.origin ?? "de\u011Fer"} ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\xC7ok k\xFC\xE7\xFCk: beklenen ${issue2.origin} ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          return `\xC7ok k\xFC\xE7\xFCk: beklenen ${issue2.origin} ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Ge\xE7ersiz metin: "${_issue.prefix}" ile ba\u015Flamal\u0131`;
          if (_issue.format === "ends_with")
            return `Ge\xE7ersiz metin: "${_issue.suffix}" ile bitmeli`;
          if (_issue.format === "includes")
            return `Ge\xE7ersiz metin: "${_issue.includes}" i\xE7ermeli`;
          if (_issue.format === "regex")
            return `Ge\xE7ersiz metin: ${_issue.pattern} desenine uymal\u0131`;
          return `Ge\xE7ersiz ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Ge\xE7ersiz say\u0131: ${issue2.divisor} ile tam b\xF6l\xFCnebilmeli`;
        case "unrecognized_keys":
          return `Tan\u0131nmayan anahtar${issue2.keys.length > 1 ? "lar" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `${issue2.origin} i\xE7inde ge\xE7ersiz anahtar`;
        case "invalid_union":
          return "Ge\xE7ersiz de\u011Fer";
        case "invalid_element":
          return `${issue2.origin} i\xE7inde ge\xE7ersiz de\u011Fer`;
        default:
          return `Ge\xE7ersiz de\u011Fer`;
      }
    };
  };
  function tr_default() {
    return {
      localeError: error43()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/ua.js
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/locales/uk.js
  init_runtime();
  var error44 = () => {
    const Sizable = {
      string: { unit: "\u0441\u0438\u043C\u0432\u043E\u043B\u0456\u0432", verb: "\u043C\u0430\u0442\u0438\u043C\u0435" },
      file: { unit: "\u0431\u0430\u0439\u0442\u0456\u0432", verb: "\u043C\u0430\u0442\u0438\u043C\u0435" },
      array: { unit: "\u0435\u043B\u0435\u043C\u0435\u043D\u0442\u0456\u0432", verb: "\u043C\u0430\u0442\u0438\u043C\u0435" },
      set: { unit: "\u0435\u043B\u0435\u043C\u0435\u043D\u0442\u0456\u0432", verb: "\u043C\u0430\u0442\u0438\u043C\u0435" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u0432\u0445\u0456\u0434\u043D\u0456 \u0434\u0430\u043D\u0456",
      email: "\u0430\u0434\u0440\u0435\u0441\u0430 \u0435\u043B\u0435\u043A\u0442\u0440\u043E\u043D\u043D\u043E\u0457 \u043F\u043E\u0448\u0442\u0438",
      url: "URL",
      emoji: "\u0435\u043C\u043E\u0434\u0437\u0456",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "\u0434\u0430\u0442\u0430 \u0442\u0430 \u0447\u0430\u0441 ISO",
      date: "\u0434\u0430\u0442\u0430 ISO",
      time: "\u0447\u0430\u0441 ISO",
      duration: "\u0442\u0440\u0438\u0432\u0430\u043B\u0456\u0441\u0442\u044C ISO",
      ipv4: "\u0430\u0434\u0440\u0435\u0441\u0430 IPv4",
      ipv6: "\u0430\u0434\u0440\u0435\u0441\u0430 IPv6",
      cidrv4: "\u0434\u0456\u0430\u043F\u0430\u0437\u043E\u043D IPv4",
      cidrv6: "\u0434\u0456\u0430\u043F\u0430\u0437\u043E\u043D IPv6",
      base64: "\u0440\u044F\u0434\u043E\u043A \u0443 \u043A\u043E\u0434\u0443\u0432\u0430\u043D\u043D\u0456 base64",
      base64url: "\u0440\u044F\u0434\u043E\u043A \u0443 \u043A\u043E\u0434\u0443\u0432\u0430\u043D\u043D\u0456 base64url",
      json_string: "\u0440\u044F\u0434\u043E\u043A JSON",
      e164: "\u043D\u043E\u043C\u0435\u0440 E.164",
      jwt: "JWT",
      template_literal: "\u0432\u0445\u0456\u0434\u043D\u0456 \u0434\u0430\u043D\u0456"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u0447\u0438\u0441\u043B\u043E",
      array: "\u043C\u0430\u0441\u0438\u0432"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0456 \u0432\u0445\u0456\u0434\u043D\u0456 \u0434\u0430\u043D\u0456: \u043E\u0447\u0456\u043A\u0443\u0454\u0442\u044C\u0441\u044F instanceof ${issue2.expected}, \u043E\u0442\u0440\u0438\u043C\u0430\u043D\u043E ${received}`;
          }
          return `\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0456 \u0432\u0445\u0456\u0434\u043D\u0456 \u0434\u0430\u043D\u0456: \u043E\u0447\u0456\u043A\u0443\u0454\u0442\u044C\u0441\u044F ${expected}, \u043E\u0442\u0440\u0438\u043C\u0430\u043D\u043E ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0456 \u0432\u0445\u0456\u0434\u043D\u0456 \u0434\u0430\u043D\u0456: \u043E\u0447\u0456\u043A\u0443\u0454\u0442\u044C\u0441\u044F ${stringifyPrimitive(issue2.values[0])}`;
          return `\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0430 \u043E\u043F\u0446\u0456\u044F: \u043E\u0447\u0456\u043A\u0443\u0454\u0442\u044C\u0441\u044F \u043E\u0434\u043D\u0435 \u0437 ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\u0417\u0430\u043D\u0430\u0434\u0442\u043E \u0432\u0435\u043B\u0438\u043A\u0435: \u043E\u0447\u0456\u043A\u0443\u0454\u0442\u044C\u0441\u044F, \u0449\u043E ${issue2.origin ?? "\u0437\u043D\u0430\u0447\u0435\u043D\u043D\u044F"} ${sizing.verb} ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "\u0435\u043B\u0435\u043C\u0435\u043D\u0442\u0456\u0432"}`;
          return `\u0417\u0430\u043D\u0430\u0434\u0442\u043E \u0432\u0435\u043B\u0438\u043A\u0435: \u043E\u0447\u0456\u043A\u0443\u0454\u0442\u044C\u0441\u044F, \u0449\u043E ${issue2.origin ?? "\u0437\u043D\u0430\u0447\u0435\u043D\u043D\u044F"} \u0431\u0443\u0434\u0435 ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u0417\u0430\u043D\u0430\u0434\u0442\u043E \u043C\u0430\u043B\u0435: \u043E\u0447\u0456\u043A\u0443\u0454\u0442\u044C\u0441\u044F, \u0449\u043E ${issue2.origin} ${sizing.verb} ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `\u0417\u0430\u043D\u0430\u0434\u0442\u043E \u043C\u0430\u043B\u0435: \u043E\u0447\u0456\u043A\u0443\u0454\u0442\u044C\u0441\u044F, \u0449\u043E ${issue2.origin} \u0431\u0443\u0434\u0435 ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0438\u0439 \u0440\u044F\u0434\u043E\u043A: \u043F\u043E\u0432\u0438\u043D\u0435\u043D \u043F\u043E\u0447\u0438\u043D\u0430\u0442\u0438\u0441\u044F \u0437 "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0438\u0439 \u0440\u044F\u0434\u043E\u043A: \u043F\u043E\u0432\u0438\u043D\u0435\u043D \u0437\u0430\u043A\u0456\u043D\u0447\u0443\u0432\u0430\u0442\u0438\u0441\u044F \u043D\u0430 "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0438\u0439 \u0440\u044F\u0434\u043E\u043A: \u043F\u043E\u0432\u0438\u043D\u0435\u043D \u043C\u0456\u0441\u0442\u0438\u0442\u0438 "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0438\u0439 \u0440\u044F\u0434\u043E\u043A: \u043F\u043E\u0432\u0438\u043D\u0435\u043D \u0432\u0456\u0434\u043F\u043E\u0432\u0456\u0434\u0430\u0442\u0438 \u0448\u0430\u0431\u043B\u043E\u043D\u0443 ${_issue.pattern}`;
          return `\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0438\u0439 ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0435 \u0447\u0438\u0441\u043B\u043E: \u043F\u043E\u0432\u0438\u043D\u043D\u043E \u0431\u0443\u0442\u0438 \u043A\u0440\u0430\u0442\u043D\u0438\u043C ${issue2.divisor}`;
        case "unrecognized_keys":
          return `\u041D\u0435\u0440\u043E\u0437\u043F\u0456\u0437\u043D\u0430\u043D\u0438\u0439 \u043A\u043B\u044E\u0447${issue2.keys.length > 1 ? "\u0456" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0438\u0439 \u043A\u043B\u044E\u0447 \u0443 ${issue2.origin}`;
        case "invalid_union":
          return "\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0456 \u0432\u0445\u0456\u0434\u043D\u0456 \u0434\u0430\u043D\u0456";
        case "invalid_element":
          return `\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0435 \u0437\u043D\u0430\u0447\u0435\u043D\u043D\u044F \u0443 ${issue2.origin}`;
        default:
          return `\u041D\u0435\u043F\u0440\u0430\u0432\u0438\u043B\u044C\u043D\u0456 \u0432\u0445\u0456\u0434\u043D\u0456 \u0434\u0430\u043D\u0456`;
      }
    };
  };
  function uk_default() {
    return {
      localeError: error44()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/ua.js
  function ua_default() {
    return uk_default();
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/ur.js
  init_runtime();
  var error45 = () => {
    const Sizable = {
      string: { unit: "\u062D\u0631\u0648\u0641", verb: "\u06C1\u0648\u0646\u0627" },
      file: { unit: "\u0628\u0627\u0626\u0679\u0633", verb: "\u06C1\u0648\u0646\u0627" },
      array: { unit: "\u0622\u0626\u0679\u0645\u0632", verb: "\u06C1\u0648\u0646\u0627" },
      set: { unit: "\u0622\u0626\u0679\u0645\u0632", verb: "\u06C1\u0648\u0646\u0627" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u0627\u0646 \u067E\u0679",
      email: "\u0627\u06CC \u0645\u06CC\u0644 \u0627\u06CC\u0688\u0631\u06CC\u0633",
      url: "\u06CC\u0648 \u0622\u0631 \u0627\u06CC\u0644",
      emoji: "\u0627\u06CC\u0645\u0648\u062C\u06CC",
      uuid: "\u06CC\u0648 \u06CC\u0648 \u0622\u0626\u06CC \u0688\u06CC",
      uuidv4: "\u06CC\u0648 \u06CC\u0648 \u0622\u0626\u06CC \u0688\u06CC \u0648\u06CC 4",
      uuidv6: "\u06CC\u0648 \u06CC\u0648 \u0622\u0626\u06CC \u0688\u06CC \u0648\u06CC 6",
      nanoid: "\u0646\u06CC\u0646\u0648 \u0622\u0626\u06CC \u0688\u06CC",
      guid: "\u062C\u06CC \u06CC\u0648 \u0622\u0626\u06CC \u0688\u06CC",
      cuid: "\u0633\u06CC \u06CC\u0648 \u0622\u0626\u06CC \u0688\u06CC",
      cuid2: "\u0633\u06CC \u06CC\u0648 \u0622\u0626\u06CC \u0688\u06CC 2",
      ulid: "\u06CC\u0648 \u0627\u06CC\u0644 \u0622\u0626\u06CC \u0688\u06CC",
      xid: "\u0627\u06CC\u06A9\u0633 \u0622\u0626\u06CC \u0688\u06CC",
      ksuid: "\u06A9\u06D2 \u0627\u06CC\u0633 \u06CC\u0648 \u0622\u0626\u06CC \u0688\u06CC",
      datetime: "\u0622\u0626\u06CC \u0627\u06CC\u0633 \u0627\u0648 \u0688\u06CC\u0679 \u0679\u0627\u0626\u0645",
      date: "\u0622\u0626\u06CC \u0627\u06CC\u0633 \u0627\u0648 \u062A\u0627\u0631\u06CC\u062E",
      time: "\u0622\u0626\u06CC \u0627\u06CC\u0633 \u0627\u0648 \u0648\u0642\u062A",
      duration: "\u0622\u0626\u06CC \u0627\u06CC\u0633 \u0627\u0648 \u0645\u062F\u062A",
      ipv4: "\u0622\u0626\u06CC \u067E\u06CC \u0648\u06CC 4 \u0627\u06CC\u0688\u0631\u06CC\u0633",
      ipv6: "\u0622\u0626\u06CC \u067E\u06CC \u0648\u06CC 6 \u0627\u06CC\u0688\u0631\u06CC\u0633",
      cidrv4: "\u0622\u0626\u06CC \u067E\u06CC \u0648\u06CC 4 \u0631\u06CC\u0646\u062C",
      cidrv6: "\u0622\u0626\u06CC \u067E\u06CC \u0648\u06CC 6 \u0631\u06CC\u0646\u062C",
      base64: "\u0628\u06CC\u0633 64 \u0627\u0646 \u06A9\u0648\u0688\u0688 \u0633\u0679\u0631\u0646\u06AF",
      base64url: "\u0628\u06CC\u0633 64 \u06CC\u0648 \u0622\u0631 \u0627\u06CC\u0644 \u0627\u0646 \u06A9\u0648\u0688\u0688 \u0633\u0679\u0631\u0646\u06AF",
      json_string: "\u062C\u06D2 \u0627\u06CC\u0633 \u0627\u0648 \u0627\u06CC\u0646 \u0633\u0679\u0631\u0646\u06AF",
      e164: "\u0627\u06CC 164 \u0646\u0645\u0628\u0631",
      jwt: "\u062C\u06D2 \u0688\u0628\u0644\u06CC\u0648 \u0679\u06CC",
      template_literal: "\u0627\u0646 \u067E\u0679"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u0646\u0645\u0628\u0631",
      array: "\u0622\u0631\u06D2",
      null: "\u0646\u0644"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u063A\u0644\u0637 \u0627\u0646 \u067E\u0679: instanceof ${issue2.expected} \u0645\u062A\u0648\u0642\u0639 \u062A\u06BE\u0627\u060C ${received} \u0645\u0648\u0635\u0648\u0644 \u06C1\u0648\u0627`;
          }
          return `\u063A\u0644\u0637 \u0627\u0646 \u067E\u0679: ${expected} \u0645\u062A\u0648\u0642\u0639 \u062A\u06BE\u0627\u060C ${received} \u0645\u0648\u0635\u0648\u0644 \u06C1\u0648\u0627`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u063A\u0644\u0637 \u0627\u0646 \u067E\u0679: ${stringifyPrimitive(issue2.values[0])} \u0645\u062A\u0648\u0642\u0639 \u062A\u06BE\u0627`;
          return `\u063A\u0644\u0637 \u0622\u067E\u0634\u0646: ${joinValues(issue2.values, "|")} \u0645\u06CC\u06BA \u0633\u06D2 \u0627\u06CC\u06A9 \u0645\u062A\u0648\u0642\u0639 \u062A\u06BE\u0627`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\u0628\u06C1\u062A \u0628\u0691\u0627: ${issue2.origin ?? "\u0648\u06CC\u0644\u06CC\u0648"} \u06A9\u06D2 ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "\u0639\u0646\u0627\u0635\u0631"} \u06C1\u0648\u0646\u06D2 \u0645\u062A\u0648\u0642\u0639 \u062A\u06BE\u06D2`;
          return `\u0628\u06C1\u062A \u0628\u0691\u0627: ${issue2.origin ?? "\u0648\u06CC\u0644\u06CC\u0648"} \u06A9\u0627 ${adj}${issue2.maximum.toString()} \u06C1\u0648\u0646\u0627 \u0645\u062A\u0648\u0642\u0639 \u062A\u06BE\u0627`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u0628\u06C1\u062A \u0686\u06BE\u0648\u0679\u0627: ${issue2.origin} \u06A9\u06D2 ${adj}${issue2.minimum.toString()} ${sizing.unit} \u06C1\u0648\u0646\u06D2 \u0645\u062A\u0648\u0642\u0639 \u062A\u06BE\u06D2`;
          }
          return `\u0628\u06C1\u062A \u0686\u06BE\u0648\u0679\u0627: ${issue2.origin} \u06A9\u0627 ${adj}${issue2.minimum.toString()} \u06C1\u0648\u0646\u0627 \u0645\u062A\u0648\u0642\u0639 \u062A\u06BE\u0627`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `\u063A\u0644\u0637 \u0633\u0679\u0631\u0646\u06AF: "${_issue.prefix}" \u0633\u06D2 \u0634\u0631\u0648\u0639 \u06C1\u0648\u0646\u0627 \u0686\u0627\u06C1\u06CC\u06D2`;
          }
          if (_issue.format === "ends_with")
            return `\u063A\u0644\u0637 \u0633\u0679\u0631\u0646\u06AF: "${_issue.suffix}" \u067E\u0631 \u062E\u062A\u0645 \u06C1\u0648\u0646\u0627 \u0686\u0627\u06C1\u06CC\u06D2`;
          if (_issue.format === "includes")
            return `\u063A\u0644\u0637 \u0633\u0679\u0631\u0646\u06AF: "${_issue.includes}" \u0634\u0627\u0645\u0644 \u06C1\u0648\u0646\u0627 \u0686\u0627\u06C1\u06CC\u06D2`;
          if (_issue.format === "regex")
            return `\u063A\u0644\u0637 \u0633\u0679\u0631\u0646\u06AF: \u067E\u06CC\u0679\u0631\u0646 ${_issue.pattern} \u0633\u06D2 \u0645\u06CC\u0686 \u06C1\u0648\u0646\u0627 \u0686\u0627\u06C1\u06CC\u06D2`;
          return `\u063A\u0644\u0637 ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u063A\u0644\u0637 \u0646\u0645\u0628\u0631: ${issue2.divisor} \u06A9\u0627 \u0645\u0636\u0627\u0639\u0641 \u06C1\u0648\u0646\u0627 \u0686\u0627\u06C1\u06CC\u06D2`;
        case "unrecognized_keys":
          return `\u063A\u06CC\u0631 \u062A\u0633\u0644\u06CC\u0645 \u0634\u062F\u06C1 \u06A9\u06CC${issue2.keys.length > 1 ? "\u0632" : ""}: ${joinValues(issue2.keys, "\u060C ")}`;
        case "invalid_key":
          return `${issue2.origin} \u0645\u06CC\u06BA \u063A\u0644\u0637 \u06A9\u06CC`;
        case "invalid_union":
          return "\u063A\u0644\u0637 \u0627\u0646 \u067E\u0679";
        case "invalid_element":
          return `${issue2.origin} \u0645\u06CC\u06BA \u063A\u0644\u0637 \u0648\u06CC\u0644\u06CC\u0648`;
        default:
          return `\u063A\u0644\u0637 \u0627\u0646 \u067E\u0679`;
      }
    };
  };
  function ur_default() {
    return {
      localeError: error45()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/uz.js
  init_runtime();
  var error46 = () => {
    const Sizable = {
      string: { unit: "belgi", verb: "bo\u2018lishi kerak" },
      file: { unit: "bayt", verb: "bo\u2018lishi kerak" },
      array: { unit: "element", verb: "bo\u2018lishi kerak" },
      set: { unit: "element", verb: "bo\u2018lishi kerak" },
      map: { unit: "yozuv", verb: "bo\u2018lishi kerak" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "kirish",
      email: "elektron pochta manzili",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO sana va vaqti",
      date: "ISO sana",
      time: "ISO vaqt",
      duration: "ISO davomiylik",
      ipv4: "IPv4 manzil",
      ipv6: "IPv6 manzil",
      mac: "MAC manzil",
      cidrv4: "IPv4 diapazon",
      cidrv6: "IPv6 diapazon",
      base64: "base64 kodlangan satr",
      base64url: "base64url kodlangan satr",
      json_string: "JSON satr",
      e164: "E.164 raqam",
      jwt: "JWT",
      template_literal: "kirish"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "raqam",
      array: "massiv"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `Noto\u2018g\u2018ri kirish: kutilgan instanceof ${issue2.expected}, qabul qilingan ${received}`;
          }
          return `Noto\u2018g\u2018ri kirish: kutilgan ${expected}, qabul qilingan ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `Noto\u2018g\u2018ri kirish: kutilgan ${stringifyPrimitive(issue2.values[0])}`;
          return `Noto\u2018g\u2018ri variant: quyidagilardan biri kutilgan ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Juda katta: kutilgan ${issue2.origin ?? "qiymat"} ${adj}${issue2.maximum.toString()} ${sizing.unit} ${sizing.verb}`;
          return `Juda katta: kutilgan ${issue2.origin ?? "qiymat"} ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Juda kichik: kutilgan ${issue2.origin} ${adj}${issue2.minimum.toString()} ${sizing.unit} ${sizing.verb}`;
          }
          return `Juda kichik: kutilgan ${issue2.origin} ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Noto\u2018g\u2018ri satr: "${_issue.prefix}" bilan boshlanishi kerak`;
          if (_issue.format === "ends_with")
            return `Noto\u2018g\u2018ri satr: "${_issue.suffix}" bilan tugashi kerak`;
          if (_issue.format === "includes")
            return `Noto\u2018g\u2018ri satr: "${_issue.includes}" ni o\u2018z ichiga olishi kerak`;
          if (_issue.format === "regex")
            return `Noto\u2018g\u2018ri satr: ${_issue.pattern} shabloniga mos kelishi kerak`;
          return `Noto\u2018g\u2018ri ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `Noto\u2018g\u2018ri raqam: ${issue2.divisor} ning karralisi bo\u2018lishi kerak`;
        case "unrecognized_keys":
          return `Noma\u2019lum kalit${issue2.keys.length > 1 ? "lar" : ""}: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `${issue2.origin} dagi kalit noto\u2018g\u2018ri`;
        case "invalid_union":
          return "Noto\u2018g\u2018ri kirish";
        case "invalid_element":
          return `${issue2.origin} da noto\u2018g\u2018ri qiymat`;
        default:
          return `Noto\u2018g\u2018ri kirish`;
      }
    };
  };
  function uz_default() {
    return {
      localeError: error46()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/vi.js
  init_runtime();
  var error47 = () => {
    const Sizable = {
      string: { unit: "k\xFD t\u1EF1", verb: "c\xF3" },
      file: { unit: "byte", verb: "c\xF3" },
      array: { unit: "ph\u1EA7n t\u1EED", verb: "c\xF3" },
      set: { unit: "ph\u1EA7n t\u1EED", verb: "c\xF3" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u0111\u1EA7u v\xE0o",
      email: "\u0111\u1ECBa ch\u1EC9 email",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ng\xE0y gi\u1EDD ISO",
      date: "ng\xE0y ISO",
      time: "gi\u1EDD ISO",
      duration: "kho\u1EA3ng th\u1EDDi gian ISO",
      ipv4: "\u0111\u1ECBa ch\u1EC9 IPv4",
      ipv6: "\u0111\u1ECBa ch\u1EC9 IPv6",
      cidrv4: "d\u1EA3i IPv4",
      cidrv6: "d\u1EA3i IPv6",
      base64: "chu\u1ED7i m\xE3 h\xF3a base64",
      base64url: "chu\u1ED7i m\xE3 h\xF3a base64url",
      json_string: "chu\u1ED7i JSON",
      e164: "s\u1ED1 E.164",
      jwt: "JWT",
      template_literal: "\u0111\u1EA7u v\xE0o"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "s\u1ED1",
      array: "m\u1EA3ng"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u0110\u1EA7u v\xE0o kh\xF4ng h\u1EE3p l\u1EC7: mong \u0111\u1EE3i instanceof ${issue2.expected}, nh\u1EADn \u0111\u01B0\u1EE3c ${received}`;
          }
          return `\u0110\u1EA7u v\xE0o kh\xF4ng h\u1EE3p l\u1EC7: mong \u0111\u1EE3i ${expected}, nh\u1EADn \u0111\u01B0\u1EE3c ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u0110\u1EA7u v\xE0o kh\xF4ng h\u1EE3p l\u1EC7: mong \u0111\u1EE3i ${stringifyPrimitive(issue2.values[0])}`;
          return `T\xF9y ch\u1ECDn kh\xF4ng h\u1EE3p l\u1EC7: mong \u0111\u1EE3i m\u1ED9t trong c\xE1c gi\xE1 tr\u1ECB ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `Qu\xE1 l\u1EDBn: mong \u0111\u1EE3i ${issue2.origin ?? "gi\xE1 tr\u1ECB"} ${sizing.verb} ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "ph\u1EA7n t\u1EED"}`;
          return `Qu\xE1 l\u1EDBn: mong \u0111\u1EE3i ${issue2.origin ?? "gi\xE1 tr\u1ECB"} ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `Qu\xE1 nh\u1ECF: mong \u0111\u1EE3i ${issue2.origin} ${sizing.verb} ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `Qu\xE1 nh\u1ECF: mong \u0111\u1EE3i ${issue2.origin} ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `Chu\u1ED7i kh\xF4ng h\u1EE3p l\u1EC7: ph\u1EA3i b\u1EAFt \u0111\u1EA7u b\u1EB1ng "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `Chu\u1ED7i kh\xF4ng h\u1EE3p l\u1EC7: ph\u1EA3i k\u1EBFt th\xFAc b\u1EB1ng "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `Chu\u1ED7i kh\xF4ng h\u1EE3p l\u1EC7: ph\u1EA3i bao g\u1ED3m "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `Chu\u1ED7i kh\xF4ng h\u1EE3p l\u1EC7: ph\u1EA3i kh\u1EDBp v\u1EDBi m\u1EABu ${_issue.pattern}`;
          return `${FormatDictionary[_issue.format] ?? issue2.format} kh\xF4ng h\u1EE3p l\u1EC7`;
        }
        case "not_multiple_of":
          return `S\u1ED1 kh\xF4ng h\u1EE3p l\u1EC7: ph\u1EA3i l\xE0 b\u1ED9i s\u1ED1 c\u1EE7a ${issue2.divisor}`;
        case "unrecognized_keys":
          return `Kh\xF3a kh\xF4ng \u0111\u01B0\u1EE3c nh\u1EADn d\u1EA1ng: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `Kh\xF3a kh\xF4ng h\u1EE3p l\u1EC7 trong ${issue2.origin}`;
        case "invalid_union":
          return "\u0110\u1EA7u v\xE0o kh\xF4ng h\u1EE3p l\u1EC7";
        case "invalid_element":
          return `Gi\xE1 tr\u1ECB kh\xF4ng h\u1EE3p l\u1EC7 trong ${issue2.origin}`;
        default:
          return `\u0110\u1EA7u v\xE0o kh\xF4ng h\u1EE3p l\u1EC7`;
      }
    };
  };
  function vi_default() {
    return {
      localeError: error47()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/zh-CN.js
  init_runtime();
  var error48 = () => {
    const Sizable = {
      string: { unit: "\u5B57\u7B26", verb: "\u5305\u542B" },
      file: { unit: "\u5B57\u8282", verb: "\u5305\u542B" },
      array: { unit: "\u9879", verb: "\u5305\u542B" },
      set: { unit: "\u9879", verb: "\u5305\u542B" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u8F93\u5165",
      email: "\u7535\u5B50\u90AE\u4EF6",
      url: "URL",
      emoji: "\u8868\u60C5\u7B26\u53F7",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO\u65E5\u671F\u65F6\u95F4",
      date: "ISO\u65E5\u671F",
      time: "ISO\u65F6\u95F4",
      duration: "ISO\u65F6\u957F",
      ipv4: "IPv4\u5730\u5740",
      ipv6: "IPv6\u5730\u5740",
      cidrv4: "IPv4\u7F51\u6BB5",
      cidrv6: "IPv6\u7F51\u6BB5",
      base64: "base64\u7F16\u7801\u5B57\u7B26\u4E32",
      base64url: "base64url\u7F16\u7801\u5B57\u7B26\u4E32",
      json_string: "JSON\u5B57\u7B26\u4E32",
      e164: "E.164\u53F7\u7801",
      jwt: "JWT",
      template_literal: "\u8F93\u5165"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "\u6570\u5B57",
      array: "\u6570\u7EC4",
      null: "\u7A7A\u503C(null)"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u65E0\u6548\u8F93\u5165\uFF1A\u671F\u671B instanceof ${issue2.expected}\uFF0C\u5B9E\u9645\u63A5\u6536 ${received}`;
          }
          return `\u65E0\u6548\u8F93\u5165\uFF1A\u671F\u671B ${expected}\uFF0C\u5B9E\u9645\u63A5\u6536 ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u65E0\u6548\u8F93\u5165\uFF1A\u671F\u671B ${stringifyPrimitive(issue2.values[0])}`;
          return `\u65E0\u6548\u9009\u9879\uFF1A\u671F\u671B\u4EE5\u4E0B\u4E4B\u4E00 ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\u6570\u503C\u8FC7\u5927\uFF1A\u671F\u671B ${issue2.origin ?? "\u503C"} ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "\u4E2A\u5143\u7D20"}`;
          return `\u6570\u503C\u8FC7\u5927\uFF1A\u671F\u671B ${issue2.origin ?? "\u503C"} ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u6570\u503C\u8FC7\u5C0F\uFF1A\u671F\u671B ${issue2.origin} ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `\u6570\u503C\u8FC7\u5C0F\uFF1A\u671F\u671B ${issue2.origin} ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `\u65E0\u6548\u5B57\u7B26\u4E32\uFF1A\u5FC5\u987B\u4EE5 "${_issue.prefix}" \u5F00\u5934`;
          if (_issue.format === "ends_with")
            return `\u65E0\u6548\u5B57\u7B26\u4E32\uFF1A\u5FC5\u987B\u4EE5 "${_issue.suffix}" \u7ED3\u5C3E`;
          if (_issue.format === "includes")
            return `\u65E0\u6548\u5B57\u7B26\u4E32\uFF1A\u5FC5\u987B\u5305\u542B "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u65E0\u6548\u5B57\u7B26\u4E32\uFF1A\u5FC5\u987B\u6EE1\u8DB3\u6B63\u5219\u8868\u8FBE\u5F0F ${_issue.pattern}`;
          return `\u65E0\u6548${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u65E0\u6548\u6570\u5B57\uFF1A\u5FC5\u987B\u662F ${issue2.divisor} \u7684\u500D\u6570`;
        case "unrecognized_keys":
          return `\u51FA\u73B0\u672A\u77E5\u7684\u952E(key): ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `${issue2.origin} \u4E2D\u7684\u952E(key)\u65E0\u6548`;
        case "invalid_union":
          return "\u65E0\u6548\u8F93\u5165";
        case "invalid_element":
          return `${issue2.origin} \u4E2D\u5305\u542B\u65E0\u6548\u503C(value)`;
        default:
          return `\u65E0\u6548\u8F93\u5165`;
      }
    };
  };
  function zh_CN_default() {
    return {
      localeError: error48()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/zh-TW.js
  init_runtime();
  var error49 = () => {
    const Sizable = {
      string: { unit: "\u5B57\u5143", verb: "\u64C1\u6709" },
      file: { unit: "\u4F4D\u5143\u7D44", verb: "\u64C1\u6709" },
      array: { unit: "\u9805\u76EE", verb: "\u64C1\u6709" },
      set: { unit: "\u9805\u76EE", verb: "\u64C1\u6709" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u8F38\u5165",
      email: "\u90F5\u4EF6\u5730\u5740",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "ISO \u65E5\u671F\u6642\u9593",
      date: "ISO \u65E5\u671F",
      time: "ISO \u6642\u9593",
      duration: "ISO \u671F\u9593",
      ipv4: "IPv4 \u4F4D\u5740",
      ipv6: "IPv6 \u4F4D\u5740",
      cidrv4: "IPv4 \u7BC4\u570D",
      cidrv6: "IPv6 \u7BC4\u570D",
      base64: "base64 \u7DE8\u78BC\u5B57\u4E32",
      base64url: "base64url \u7DE8\u78BC\u5B57\u4E32",
      json_string: "JSON \u5B57\u4E32",
      e164: "E.164 \u6578\u503C",
      jwt: "JWT",
      template_literal: "\u8F38\u5165"
    };
    const TypeDictionary = {
      nan: "NaN"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\u7121\u6548\u7684\u8F38\u5165\u503C\uFF1A\u9810\u671F\u70BA instanceof ${issue2.expected}\uFF0C\u4F46\u6536\u5230 ${received}`;
          }
          return `\u7121\u6548\u7684\u8F38\u5165\u503C\uFF1A\u9810\u671F\u70BA ${expected}\uFF0C\u4F46\u6536\u5230 ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\u7121\u6548\u7684\u8F38\u5165\u503C\uFF1A\u9810\u671F\u70BA ${stringifyPrimitive(issue2.values[0])}`;
          return `\u7121\u6548\u7684\u9078\u9805\uFF1A\u9810\u671F\u70BA\u4EE5\u4E0B\u5176\u4E2D\u4E4B\u4E00 ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `\u6578\u503C\u904E\u5927\uFF1A\u9810\u671F ${issue2.origin ?? "\u503C"} \u61C9\u70BA ${adj}${issue2.maximum.toString()} ${sizing.unit ?? "\u500B\u5143\u7D20"}`;
          return `\u6578\u503C\u904E\u5927\uFF1A\u9810\u671F ${issue2.origin ?? "\u503C"} \u61C9\u70BA ${adj}${issue2.maximum.toString()}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing) {
            return `\u6578\u503C\u904E\u5C0F\uFF1A\u9810\u671F ${issue2.origin} \u61C9\u70BA ${adj}${issue2.minimum.toString()} ${sizing.unit}`;
          }
          return `\u6578\u503C\u904E\u5C0F\uFF1A\u9810\u671F ${issue2.origin} \u61C9\u70BA ${adj}${issue2.minimum.toString()}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with") {
            return `\u7121\u6548\u7684\u5B57\u4E32\uFF1A\u5FC5\u9808\u4EE5 "${_issue.prefix}" \u958B\u982D`;
          }
          if (_issue.format === "ends_with")
            return `\u7121\u6548\u7684\u5B57\u4E32\uFF1A\u5FC5\u9808\u4EE5 "${_issue.suffix}" \u7D50\u5C3E`;
          if (_issue.format === "includes")
            return `\u7121\u6548\u7684\u5B57\u4E32\uFF1A\u5FC5\u9808\u5305\u542B "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u7121\u6548\u7684\u5B57\u4E32\uFF1A\u5FC5\u9808\u7B26\u5408\u683C\u5F0F ${_issue.pattern}`;
          return `\u7121\u6548\u7684 ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `\u7121\u6548\u7684\u6578\u5B57\uFF1A\u5FC5\u9808\u70BA ${issue2.divisor} \u7684\u500D\u6578`;
        case "unrecognized_keys":
          return `\u7121\u6CD5\u8B58\u5225\u7684\u9375\u503C${issue2.keys.length > 1 ? "\u5011" : ""}\uFF1A${joinValues(issue2.keys, "\u3001")}`;
        case "invalid_key":
          return `${issue2.origin} \u4E2D\u6709\u7121\u6548\u7684\u9375\u503C`;
        case "invalid_union":
          return "\u7121\u6548\u7684\u8F38\u5165\u503C";
        case "invalid_element":
          return `${issue2.origin} \u4E2D\u6709\u7121\u6548\u7684\u503C`;
        default:
          return `\u7121\u6548\u7684\u8F38\u5165\u503C`;
      }
    };
  };
  function zh_TW_default() {
    return {
      localeError: error49()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/locales/yo.js
  init_runtime();
  var error50 = () => {
    const Sizable = {
      string: { unit: "\xE0mi", verb: "n\xED" },
      file: { unit: "bytes", verb: "n\xED" },
      array: { unit: "nkan", verb: "n\xED" },
      set: { unit: "nkan", verb: "n\xED" }
    };
    function getSizing(origin) {
      return Sizable[origin] ?? null;
    }
    const FormatDictionary = {
      regex: "\u1EB9\u0300r\u1ECD \xECb\xE1w\u1ECDl\xE9",
      email: "\xE0d\xEDr\u1EB9\u0301s\xEC \xECm\u1EB9\u0301l\xEC",
      url: "URL",
      emoji: "emoji",
      uuid: "UUID",
      uuidv4: "UUIDv4",
      uuidv6: "UUIDv6",
      nanoid: "nanoid",
      guid: "GUID",
      cuid: "cuid",
      cuid2: "cuid2",
      ulid: "ULID",
      xid: "XID",
      ksuid: "KSUID",
      datetime: "\xE0k\xF3k\xF2 ISO",
      date: "\u1ECDj\u1ECD\u0301 ISO",
      time: "\xE0k\xF3k\xF2 ISO",
      duration: "\xE0k\xF3k\xF2 t\xF3 p\xE9 ISO",
      ipv4: "\xE0d\xEDr\u1EB9\u0301s\xEC IPv4",
      ipv6: "\xE0d\xEDr\u1EB9\u0301s\xEC IPv6",
      cidrv4: "\xE0gb\xE8gb\xE8 IPv4",
      cidrv6: "\xE0gb\xE8gb\xE8 IPv6",
      base64: "\u1ECD\u0300r\u1ECD\u0300 t\xED a k\u1ECD\u0301 n\xED base64",
      base64url: "\u1ECD\u0300r\u1ECD\u0300 base64url",
      json_string: "\u1ECD\u0300r\u1ECD\u0300 JSON",
      e164: "n\u1ECD\u0301mb\xE0 E.164",
      jwt: "JWT",
      template_literal: "\u1EB9\u0300r\u1ECD \xECb\xE1w\u1ECDl\xE9"
    };
    const TypeDictionary = {
      nan: "NaN",
      number: "n\u1ECD\u0301mb\xE0",
      array: "akop\u1ECD"
    };
    return (issue2) => {
      switch (issue2.code) {
        case "invalid_type": {
          const expected = TypeDictionary[issue2.expected] ?? issue2.expected;
          const receivedType = parsedType(issue2.input);
          const received = TypeDictionary[receivedType] ?? receivedType;
          if (/^[A-Z]/.test(issue2.expected)) {
            return `\xCCb\xE1w\u1ECDl\xE9 a\u1E63\xEC\u1E63e: a n\xED l\xE1ti fi instanceof ${issue2.expected}, \xE0m\u1ECD\u0300 a r\xED ${received}`;
          }
          return `\xCCb\xE1w\u1ECDl\xE9 a\u1E63\xEC\u1E63e: a n\xED l\xE1ti fi ${expected}, \xE0m\u1ECD\u0300 a r\xED ${received}`;
        }
        case "invalid_value":
          if (issue2.values.length === 1)
            return `\xCCb\xE1w\u1ECDl\xE9 a\u1E63\xEC\u1E63e: a n\xED l\xE1ti fi ${stringifyPrimitive(issue2.values[0])}`;
          return `\xC0\u1E63\xE0y\xE0n a\u1E63\xEC\u1E63e: yan \u1ECD\u0300kan l\xE1ra ${joinValues(issue2.values, "|")}`;
        case "too_big": {
          const adj = issue2.inclusive ? "<=" : "<";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `T\xF3 p\u1ECD\u0300 j\xF9: a n\xED l\xE1ti j\u1EB9\u0301 p\xE9 ${issue2.origin ?? "iye"} ${sizing.verb} ${adj}${issue2.maximum} ${sizing.unit}`;
          return `T\xF3 p\u1ECD\u0300 j\xF9: a n\xED l\xE1ti j\u1EB9\u0301 ${adj}${issue2.maximum}`;
        }
        case "too_small": {
          const adj = issue2.inclusive ? ">=" : ">";
          const sizing = getSizing(issue2.origin);
          if (sizing)
            return `K\xE9r\xE9 ju: a n\xED l\xE1ti j\u1EB9\u0301 p\xE9 ${issue2.origin} ${sizing.verb} ${adj}${issue2.minimum} ${sizing.unit}`;
          return `K\xE9r\xE9 ju: a n\xED l\xE1ti j\u1EB9\u0301 ${adj}${issue2.minimum}`;
        }
        case "invalid_format": {
          const _issue = issue2;
          if (_issue.format === "starts_with")
            return `\u1ECC\u0300r\u1ECD\u0300 a\u1E63\xEC\u1E63e: gb\u1ECD\u0301d\u1ECD\u0300 b\u1EB9\u0300r\u1EB9\u0300 p\u1EB9\u0300l\xFA "${_issue.prefix}"`;
          if (_issue.format === "ends_with")
            return `\u1ECC\u0300r\u1ECD\u0300 a\u1E63\xEC\u1E63e: gb\u1ECD\u0301d\u1ECD\u0300 par\xED p\u1EB9\u0300l\xFA "${_issue.suffix}"`;
          if (_issue.format === "includes")
            return `\u1ECC\u0300r\u1ECD\u0300 a\u1E63\xEC\u1E63e: gb\u1ECD\u0301d\u1ECD\u0300 n\xED "${_issue.includes}"`;
          if (_issue.format === "regex")
            return `\u1ECC\u0300r\u1ECD\u0300 a\u1E63\xEC\u1E63e: gb\u1ECD\u0301d\u1ECD\u0300 b\xE1 \xE0p\u1EB9\u1EB9r\u1EB9 mu ${_issue.pattern}`;
          return `A\u1E63\xEC\u1E63e: ${FormatDictionary[_issue.format] ?? issue2.format}`;
        }
        case "not_multiple_of":
          return `N\u1ECD\u0301mb\xE0 a\u1E63\xEC\u1E63e: gb\u1ECD\u0301d\u1ECD\u0300 j\u1EB9\u0301 \xE8y\xE0 p\xEDp\xEDn ti ${issue2.divisor}`;
        case "unrecognized_keys":
          return `B\u1ECDt\xECn\xEC \xE0\xECm\u1ECD\u0300: ${joinValues(issue2.keys, ", ")}`;
        case "invalid_key":
          return `B\u1ECDt\xECn\xEC a\u1E63\xEC\u1E63e n\xEDn\xFA ${issue2.origin}`;
        case "invalid_union":
          return "\xCCb\xE1w\u1ECDl\xE9 a\u1E63\xEC\u1E63e";
        case "invalid_element":
          return `Iye a\u1E63\xEC\u1E63e n\xEDn\xFA ${issue2.origin}`;
        default:
          return "\xCCb\xE1w\u1ECDl\xE9 a\u1E63\xEC\u1E63e";
      }
    };
  };
  function yo_default() {
    return {
      localeError: error50()
    };
  }

  // ThirdParty/REA/dependencies/zod/v4/core/registries.js
  init_runtime();
  var _a2;
  var $output = /* @__PURE__ */ Symbol("ZodOutput");
  var $input = /* @__PURE__ */ Symbol("ZodInput");
  var $ZodRegistry = class {
    constructor() {
      this._map = /* @__PURE__ */ new WeakMap();
      this._idmap = /* @__PURE__ */ new Map();
    }
    add(schema, ..._meta) {
      const meta3 = _meta[0];
      this._map.set(schema, meta3);
      if (meta3 && typeof meta3 === "object" && "id" in meta3) {
        this._idmap.set(meta3.id, schema);
      }
      return this;
    }
    clear() {
      this._map = /* @__PURE__ */ new WeakMap();
      this._idmap = /* @__PURE__ */ new Map();
      return this;
    }
    remove(schema) {
      const meta3 = this._map.get(schema);
      if (meta3 && typeof meta3 === "object" && "id" in meta3) {
        this._idmap.delete(meta3.id);
      }
      this._map.delete(schema);
      return this;
    }
    get(schema) {
      const p = schema._zod.parent;
      if (p) {
        const pm = { ...this.get(p) ?? {} };
        delete pm.id;
        const f = { ...pm, ...this._map.get(schema) };
        return Object.keys(f).length ? f : void 0;
      }
      return this._map.get(schema);
    }
    has(schema) {
      return this._map.has(schema);
    }
  };
  function registry() {
    return new $ZodRegistry();
  }
  (_a2 = globalThis).__zod_globalRegistry ?? (_a2.__zod_globalRegistry = registry());
  var globalRegistry = globalThis.__zod_globalRegistry;

  // ThirdParty/REA/dependencies/zod/v4/core/api.js
  init_runtime();
  // @__NO_SIDE_EFFECTS__
  function _string(Class2, params) {
    return new Class2({
      type: "string",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _coercedString(Class2, params) {
    return new Class2({
      type: "string",
      coerce: true,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _email(Class2, params) {
    return new Class2({
      type: "string",
      format: "email",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _guid(Class2, params) {
    return new Class2({
      type: "string",
      format: "guid",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _uuid(Class2, params) {
    return new Class2({
      type: "string",
      format: "uuid",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _uuidv4(Class2, params) {
    return new Class2({
      type: "string",
      format: "uuid",
      check: "string_format",
      abort: false,
      version: "v4",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _uuidv6(Class2, params) {
    return new Class2({
      type: "string",
      format: "uuid",
      check: "string_format",
      abort: false,
      version: "v6",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _uuidv7(Class2, params) {
    return new Class2({
      type: "string",
      format: "uuid",
      check: "string_format",
      abort: false,
      version: "v7",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _url(Class2, params) {
    return new Class2({
      type: "string",
      format: "url",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _emoji2(Class2, params) {
    return new Class2({
      type: "string",
      format: "emoji",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _nanoid(Class2, params) {
    return new Class2({
      type: "string",
      format: "nanoid",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _cuid(Class2, params) {
    return new Class2({
      type: "string",
      format: "cuid",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _cuid2(Class2, params) {
    return new Class2({
      type: "string",
      format: "cuid2",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _ulid(Class2, params) {
    return new Class2({
      type: "string",
      format: "ulid",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _xid(Class2, params) {
    return new Class2({
      type: "string",
      format: "xid",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _ksuid(Class2, params) {
    return new Class2({
      type: "string",
      format: "ksuid",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _ipv4(Class2, params) {
    return new Class2({
      type: "string",
      format: "ipv4",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _ipv6(Class2, params) {
    return new Class2({
      type: "string",
      format: "ipv6",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _mac(Class2, params) {
    return new Class2({
      type: "string",
      format: "mac",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _cidrv4(Class2, params) {
    return new Class2({
      type: "string",
      format: "cidrv4",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _cidrv6(Class2, params) {
    return new Class2({
      type: "string",
      format: "cidrv6",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _base64(Class2, params) {
    return new Class2({
      type: "string",
      format: "base64",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _base64url(Class2, params) {
    return new Class2({
      type: "string",
      format: "base64url",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _e164(Class2, params) {
    return new Class2({
      type: "string",
      format: "e164",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _jwt(Class2, params) {
    return new Class2({
      type: "string",
      format: "jwt",
      check: "string_format",
      abort: false,
      ...normalizeParams(params)
    });
  }
  var TimePrecision = {
    Any: null,
    Minute: -1,
    Second: 0,
    Millisecond: 3,
    Microsecond: 6
  };
  // @__NO_SIDE_EFFECTS__
  function _isoDateTime(Class2, params) {
    return new Class2({
      type: "string",
      format: "datetime",
      check: "string_format",
      offset: false,
      local: false,
      precision: null,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _isoDate(Class2, params) {
    return new Class2({
      type: "string",
      format: "date",
      check: "string_format",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _isoTime(Class2, params) {
    return new Class2({
      type: "string",
      format: "time",
      check: "string_format",
      precision: null,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _isoDuration(Class2, params) {
    return new Class2({
      type: "string",
      format: "duration",
      check: "string_format",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _number(Class2, params) {
    return new Class2({
      type: "number",
      checks: [],
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _coercedNumber(Class2, params) {
    return new Class2({
      type: "number",
      coerce: true,
      checks: [],
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _int(Class2, params) {
    return new Class2({
      type: "number",
      check: "number_format",
      abort: false,
      format: "safeint",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _float32(Class2, params) {
    return new Class2({
      type: "number",
      check: "number_format",
      abort: false,
      format: "float32",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _float64(Class2, params) {
    return new Class2({
      type: "number",
      check: "number_format",
      abort: false,
      format: "float64",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _int32(Class2, params) {
    return new Class2({
      type: "number",
      check: "number_format",
      abort: false,
      format: "int32",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _uint32(Class2, params) {
    return new Class2({
      type: "number",
      check: "number_format",
      abort: false,
      format: "uint32",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _boolean(Class2, params) {
    return new Class2({
      type: "boolean",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _coercedBoolean(Class2, params) {
    return new Class2({
      type: "boolean",
      coerce: true,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _bigint(Class2, params) {
    return new Class2({
      type: "bigint",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _coercedBigint(Class2, params) {
    return new Class2({
      type: "bigint",
      coerce: true,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _int64(Class2, params) {
    return new Class2({
      type: "bigint",
      check: "bigint_format",
      abort: false,
      format: "int64",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _uint64(Class2, params) {
    return new Class2({
      type: "bigint",
      check: "bigint_format",
      abort: false,
      format: "uint64",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _symbol(Class2, params) {
    return new Class2({
      type: "symbol",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _undefined2(Class2, params) {
    return new Class2({
      type: "undefined",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _null2(Class2, params) {
    return new Class2({
      type: "null",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _any(Class2) {
    return new Class2({
      type: "any"
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _unknown(Class2) {
    return new Class2({
      type: "unknown"
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _never(Class2, params) {
    return new Class2({
      type: "never",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _void(Class2, params) {
    return new Class2({
      type: "void",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _date(Class2, params) {
    return new Class2({
      type: "date",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _coercedDate(Class2, params) {
    return new Class2({
      type: "date",
      coerce: true,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _nan(Class2, params) {
    return new Class2({
      type: "nan",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _lt(value, params) {
    return new $ZodCheckLessThan({
      check: "less_than",
      ...normalizeParams(params),
      value,
      inclusive: false
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _lte(value, params) {
    return new $ZodCheckLessThan({
      check: "less_than",
      ...normalizeParams(params),
      value,
      inclusive: true
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _gt(value, params) {
    return new $ZodCheckGreaterThan({
      check: "greater_than",
      ...normalizeParams(params),
      value,
      inclusive: false
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _gte(value, params) {
    return new $ZodCheckGreaterThan({
      check: "greater_than",
      ...normalizeParams(params),
      value,
      inclusive: true
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _positive(params) {
    return /* @__PURE__ */ _gt(0, params);
  }
  // @__NO_SIDE_EFFECTS__
  function _negative(params) {
    return /* @__PURE__ */ _lt(0, params);
  }
  // @__NO_SIDE_EFFECTS__
  function _nonpositive(params) {
    return /* @__PURE__ */ _lte(0, params);
  }
  // @__NO_SIDE_EFFECTS__
  function _nonnegative(params) {
    return /* @__PURE__ */ _gte(0, params);
  }
  // @__NO_SIDE_EFFECTS__
  function _multipleOf(value, params) {
    return new $ZodCheckMultipleOf({
      check: "multiple_of",
      ...normalizeParams(params),
      value
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _maxSize(maximum, params) {
    return new $ZodCheckMaxSize({
      check: "max_size",
      ...normalizeParams(params),
      maximum
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _minSize(minimum, params) {
    return new $ZodCheckMinSize({
      check: "min_size",
      ...normalizeParams(params),
      minimum
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _size(size, params) {
    return new $ZodCheckSizeEquals({
      check: "size_equals",
      ...normalizeParams(params),
      size
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _maxLength(maximum, params) {
    const ch = new $ZodCheckMaxLength({
      check: "max_length",
      ...normalizeParams(params),
      maximum
    });
    return ch;
  }
  // @__NO_SIDE_EFFECTS__
  function _minLength(minimum, params) {
    return new $ZodCheckMinLength({
      check: "min_length",
      ...normalizeParams(params),
      minimum
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _length(length, params) {
    return new $ZodCheckLengthEquals({
      check: "length_equals",
      ...normalizeParams(params),
      length
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _regex(pattern, params) {
    return new $ZodCheckRegex({
      check: "string_format",
      format: "regex",
      ...normalizeParams(params),
      pattern
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _lowercase(params) {
    return new $ZodCheckLowerCase({
      check: "string_format",
      format: "lowercase",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _uppercase(params) {
    return new $ZodCheckUpperCase({
      check: "string_format",
      format: "uppercase",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _includes(includes, params) {
    return new $ZodCheckIncludes({
      check: "string_format",
      format: "includes",
      ...normalizeParams(params),
      includes
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _startsWith(prefix, params) {
    return new $ZodCheckStartsWith({
      check: "string_format",
      format: "starts_with",
      ...normalizeParams(params),
      prefix
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _endsWith(suffix, params) {
    return new $ZodCheckEndsWith({
      check: "string_format",
      format: "ends_with",
      ...normalizeParams(params),
      suffix
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _property(property, schema, params) {
    return new $ZodCheckProperty({
      check: "property",
      property,
      schema,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _mime(types, params) {
    return new $ZodCheckMimeType({
      check: "mime_type",
      mime: types,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _overwrite(tx) {
    return new $ZodCheckOverwrite({
      check: "overwrite",
      tx
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _normalize(form) {
    return /* @__PURE__ */ _overwrite((input) => input.normalize(form));
  }
  // @__NO_SIDE_EFFECTS__
  function _trim() {
    return /* @__PURE__ */ _overwrite((input) => input.trim());
  }
  // @__NO_SIDE_EFFECTS__
  function _toLowerCase() {
    return /* @__PURE__ */ _overwrite((input) => input.toLowerCase());
  }
  // @__NO_SIDE_EFFECTS__
  function _toUpperCase() {
    return /* @__PURE__ */ _overwrite((input) => input.toUpperCase());
  }
  // @__NO_SIDE_EFFECTS__
  function _slugify() {
    return /* @__PURE__ */ _overwrite((input) => slugify(input));
  }
  // @__NO_SIDE_EFFECTS__
  function _array(Class2, element, params) {
    return new Class2({
      type: "array",
      element,
      // get element() {
      //   return element;
      // },
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _union(Class2, options, params) {
    return new Class2({
      type: "union",
      options,
      ...normalizeParams(params)
    });
  }
  function _xor(Class2, options, params) {
    return new Class2({
      type: "union",
      options,
      inclusive: false,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _discriminatedUnion(Class2, discriminator, options, params) {
    return new Class2({
      type: "union",
      options,
      discriminator,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _intersection(Class2, left, right) {
    return new Class2({
      type: "intersection",
      left,
      right
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _tuple(Class2, items, _paramsOrRest, _params) {
    const hasRest = _paramsOrRest instanceof $ZodType;
    const params = hasRest ? _params : _paramsOrRest;
    const rest = hasRest ? _paramsOrRest : null;
    return new Class2({
      type: "tuple",
      items,
      rest,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _record(Class2, keyType, valueType, params) {
    return new Class2({
      type: "record",
      keyType,
      valueType,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _map(Class2, keyType, valueType, params) {
    return new Class2({
      type: "map",
      keyType,
      valueType,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _set(Class2, valueType, params) {
    return new Class2({
      type: "set",
      valueType,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _enum(Class2, values, params) {
    const entries = Array.isArray(values) ? Object.fromEntries(values.map((v) => [v, v])) : values;
    return new Class2({
      type: "enum",
      entries,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _nativeEnum(Class2, entries, params) {
    return new Class2({
      type: "enum",
      entries,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _literal(Class2, value, params) {
    return new Class2({
      type: "literal",
      values: Array.isArray(value) ? value : [value],
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _file(Class2, params) {
    return new Class2({
      type: "file",
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _transform(Class2, fn) {
    return new Class2({
      type: "transform",
      transform: fn
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _optional(Class2, innerType) {
    return new Class2({
      type: "optional",
      innerType
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _nullable(Class2, innerType) {
    return new Class2({
      type: "nullable",
      innerType
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _default(Class2, innerType, defaultValue) {
    return new Class2({
      type: "default",
      innerType,
      get defaultValue() {
        return typeof defaultValue === "function" ? defaultValue() : shallowClone(defaultValue);
      }
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _nonoptional(Class2, innerType, params) {
    return new Class2({
      type: "nonoptional",
      innerType,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _success(Class2, innerType) {
    return new Class2({
      type: "success",
      innerType
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _catch(Class2, innerType, catchValue) {
    return new Class2({
      type: "catch",
      innerType,
      catchValue: typeof catchValue === "function" ? catchValue : () => catchValue
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _pipe(Class2, in_, out) {
    return new Class2({
      type: "pipe",
      in: in_,
      out
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _readonly(Class2, innerType) {
    return new Class2({
      type: "readonly",
      innerType
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _templateLiteral(Class2, parts, params) {
    return new Class2({
      type: "template_literal",
      parts,
      ...normalizeParams(params)
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _lazy(Class2, getter) {
    return new Class2({
      type: "lazy",
      getter
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _promise(Class2, innerType) {
    return new Class2({
      type: "promise",
      innerType
    });
  }
  // @__NO_SIDE_EFFECTS__
  function _custom(Class2, fn, _params) {
    const norm = normalizeParams(_params);
    norm.abort ?? (norm.abort = true);
    const schema = new Class2({
      type: "custom",
      check: "custom",
      fn,
      ...norm
    });
    return schema;
  }
  // @__NO_SIDE_EFFECTS__
  function _refine(Class2, fn, _params) {
    const schema = new Class2({
      type: "custom",
      check: "custom",
      fn,
      ...normalizeParams(_params)
    });
    return schema;
  }
  // @__NO_SIDE_EFFECTS__
  function _superRefine(fn, params) {
    const ch = /* @__PURE__ */ _check((payload) => {
      payload.addIssue = (issue2) => {
        if (typeof issue2 === "string") {
          payload.issues.push(issue(issue2, payload.value, ch._zod.def));
        } else {
          const _issue = issue2;
          if (_issue.fatal)
            _issue.continue = false;
          _issue.code ?? (_issue.code = "custom");
          _issue.input ?? (_issue.input = payload.value);
          _issue.inst ?? (_issue.inst = ch);
          _issue.continue ?? (_issue.continue = !ch._zod.def.abort);
          payload.issues.push(issue(_issue));
        }
      };
      return fn(payload.value, payload);
    }, params);
    return ch;
  }
  // @__NO_SIDE_EFFECTS__
  function _check(fn, params) {
    const ch = new $ZodCheck({
      check: "custom",
      ...normalizeParams(params)
    });
    ch._zod.check = fn;
    return ch;
  }
  // @__NO_SIDE_EFFECTS__
  function describe(description) {
    const ch = new $ZodCheck({ check: "describe" });
    ch._zod.onattach = [
      (inst) => {
        const existing = globalRegistry.get(inst) ?? {};
        globalRegistry.add(inst, { ...existing, description });
      }
    ];
    ch._zod.check = () => {
    };
    return ch;
  }
  // @__NO_SIDE_EFFECTS__
  function meta(metadata) {
    const ch = new $ZodCheck({ check: "meta" });
    ch._zod.onattach = [
      (inst) => {
        const existing = globalRegistry.get(inst) ?? {};
        globalRegistry.add(inst, { ...existing, ...metadata });
      }
    ];
    ch._zod.check = () => {
    };
    return ch;
  }
  // @__NO_SIDE_EFFECTS__
  function _stringbool(Classes, _params) {
    const params = normalizeParams(_params);
    let truthyArray = params.truthy ?? ["true", "1", "yes", "on", "y", "enabled"];
    let falsyArray = params.falsy ?? ["false", "0", "no", "off", "n", "disabled"];
    if (params.case !== "sensitive") {
      truthyArray = truthyArray.map((v) => typeof v === "string" ? v.toLowerCase() : v);
      falsyArray = falsyArray.map((v) => typeof v === "string" ? v.toLowerCase() : v);
    }
    const truthySet = new Set(truthyArray);
    const falsySet = new Set(falsyArray);
    const _Codec = Classes.Codec ?? $ZodCodec;
    const _Boolean = Classes.Boolean ?? $ZodBoolean;
    const _String = Classes.String ?? $ZodString;
    const stringSchema = new _String({ type: "string", error: params.error });
    const booleanSchema = new _Boolean({ type: "boolean", error: params.error });
    const codec2 = new _Codec({
      type: "pipe",
      in: stringSchema,
      out: booleanSchema,
      transform: ((input, payload) => {
        let data = input;
        if (params.case !== "sensitive")
          data = data.toLowerCase();
        if (truthySet.has(data)) {
          return true;
        } else if (falsySet.has(data)) {
          return false;
        } else {
          payload.issues.push({
            code: "invalid_value",
            expected: "stringbool",
            values: [...truthySet, ...falsySet],
            input: payload.value,
            inst: codec2,
            continue: false
          });
          return {};
        }
      }),
      reverseTransform: ((input, _payload) => {
        if (input === true) {
          return truthyArray[0] || "true";
        } else {
          return falsyArray[0] || "false";
        }
      }),
      error: params.error
    });
    return codec2;
  }
  // @__NO_SIDE_EFFECTS__
  function _stringFormat(Class2, format, fnOrRegex, _params = {}) {
    const params = normalizeParams(_params);
    const def = {
      ...normalizeParams(_params),
      check: "string_format",
      type: "string",
      format,
      fn: typeof fnOrRegex === "function" ? fnOrRegex : (val) => fnOrRegex.test(val),
      ...params
    };
    if (fnOrRegex instanceof RegExp) {
      def.pattern = fnOrRegex;
    }
    const inst = new Class2(def);
    return inst;
  }

  // ThirdParty/REA/dependencies/zod/v4/core/to-json-schema.js
  init_runtime();
  function initializeContext(params) {
    let target = params?.target ?? "draft-2020-12";
    if (target === "draft-4")
      target = "draft-04";
    if (target === "draft-7")
      target = "draft-07";
    return {
      processors: params.processors ?? {},
      metadataRegistry: params?.metadata ?? globalRegistry,
      target,
      unrepresentable: params?.unrepresentable ?? "throw",
      override: params?.override ?? (() => {
      }),
      io: params?.io ?? "output",
      counter: 0,
      seen: /* @__PURE__ */ new Map(),
      cycles: params?.cycles ?? "ref",
      reused: params?.reused ?? "inline",
      external: params?.external ?? void 0
    };
  }
  function process(schema, ctx, _params = { path: [], schemaPath: [] }) {
    var _a3;
    const def = schema._zod.def;
    const seen = ctx.seen.get(schema);
    if (seen) {
      seen.count++;
      const isCycle = _params.schemaPath.includes(schema);
      if (isCycle) {
        seen.cycle = _params.path;
      }
      return seen.schema;
    }
    const result = { schema: {}, count: 1, cycle: void 0, path: _params.path };
    ctx.seen.set(schema, result);
    const overrideSchema = schema._zod.toJSONSchema?.();
    if (overrideSchema) {
      result.schema = overrideSchema;
    } else {
      const params = {
        ..._params,
        schemaPath: [..._params.schemaPath, schema],
        path: _params.path
      };
      if (schema._zod.processJSONSchema) {
        schema._zod.processJSONSchema(ctx, result.schema, params);
      } else {
        const _json = result.schema;
        const processor = ctx.processors[def.type];
        if (!processor) {
          throw new Error(`[toJSONSchema]: Non-representable type encountered: ${def.type}`);
        }
        processor(schema, ctx, _json, params);
      }
      const parent = schema._zod.parent;
      if (parent) {
        if (!result.ref)
          result.ref = parent;
        process(parent, ctx, params);
        ctx.seen.get(parent).isParent = true;
      }
    }
    const meta3 = ctx.metadataRegistry.get(schema);
    if (meta3)
      Object.assign(result.schema, meta3);
    if (ctx.io === "input" && isTransforming(schema)) {
      delete result.schema.examples;
      delete result.schema.default;
    }
    if (ctx.io === "input" && "_prefault" in result.schema)
      (_a3 = result.schema).default ?? (_a3.default = result.schema._prefault);
    delete result.schema._prefault;
    const _result = ctx.seen.get(schema);
    return _result.schema;
  }
  function extractDefs(ctx, schema) {
    const root = ctx.seen.get(schema);
    if (!root)
      throw new Error("Unprocessed schema. This is a bug in Zod.");
    const idToSchema = /* @__PURE__ */ new Map();
    for (const entry of ctx.seen.entries()) {
      const id = ctx.metadataRegistry.get(entry[0])?.id;
      if (id) {
        const existing = idToSchema.get(id);
        if (existing && existing !== entry[0]) {
          throw new Error(`Duplicate schema id "${id}" detected during JSON Schema conversion. Two different schemas cannot share the same id when converted together.`);
        }
        idToSchema.set(id, entry[0]);
      }
    }
    const makeURI = (entry) => {
      const defsSegment = ctx.target === "draft-2020-12" ? "$defs" : "definitions";
      if (ctx.external) {
        const externalId = ctx.external.registry.get(entry[0])?.id;
        const uriGenerator = ctx.external.uri ?? ((id2) => id2);
        if (externalId) {
          return { ref: uriGenerator(externalId) };
        }
        const id = entry[1].defId ?? entry[1].schema.id ?? `schema${ctx.counter++}`;
        entry[1].defId = id;
        return { defId: id, ref: `${uriGenerator("__shared")}#/${defsSegment}/${id}` };
      }
      if (entry[1] === root) {
        return { ref: "#" };
      }
      const uriPrefix = `#`;
      const defUriPrefix = `${uriPrefix}/${defsSegment}/`;
      const defId = entry[1].schema.id ?? `__schema${ctx.counter++}`;
      return { defId, ref: defUriPrefix + defId };
    };
    const extractToDef = (entry) => {
      if (entry[1].schema.$ref) {
        return;
      }
      const seen = entry[1];
      const { ref, defId } = makeURI(entry);
      seen.def = { ...seen.schema };
      if (defId)
        seen.defId = defId;
      const schema2 = seen.schema;
      for (const key in schema2) {
        delete schema2[key];
      }
      schema2.$ref = ref;
    };
    if (ctx.cycles === "throw") {
      for (const entry of ctx.seen.entries()) {
        const seen = entry[1];
        if (seen.cycle) {
          throw new Error(`Cycle detected: #/${seen.cycle?.join("/")}/<root>

Set the \`cycles\` parameter to \`"ref"\` to resolve cyclical schemas with defs.`);
        }
      }
    }
    for (const entry of ctx.seen.entries()) {
      const seen = entry[1];
      if (schema === entry[0]) {
        extractToDef(entry);
        continue;
      }
      if (ctx.external) {
        const ext = ctx.external.registry.get(entry[0])?.id;
        if (schema !== entry[0] && ext) {
          extractToDef(entry);
          continue;
        }
      }
      const id = ctx.metadataRegistry.get(entry[0])?.id;
      if (id) {
        extractToDef(entry);
        continue;
      }
      if (seen.cycle) {
        extractToDef(entry);
        continue;
      }
      if (seen.count > 1) {
        if (ctx.reused === "ref") {
          extractToDef(entry);
          continue;
        }
      }
    }
  }
  function finalize(ctx, schema) {
    const root = ctx.seen.get(schema);
    if (!root)
      throw new Error("Unprocessed schema. This is a bug in Zod.");
    const flattenRef = (zodSchema) => {
      const seen = ctx.seen.get(zodSchema);
      if (seen.ref === null)
        return;
      const schema2 = seen.def ?? seen.schema;
      const _cached = { ...schema2 };
      const ref = seen.ref;
      seen.ref = null;
      if (ref) {
        flattenRef(ref);
        const refSeen = ctx.seen.get(ref);
        const refSchema = refSeen.schema;
        if (refSchema.$ref && (ctx.target === "draft-07" || ctx.target === "draft-04" || ctx.target === "openapi-3.0")) {
          schema2.allOf = schema2.allOf ?? [];
          schema2.allOf.push(refSchema);
        } else {
          Object.assign(schema2, refSchema);
        }
        Object.assign(schema2, _cached);
        const isParentRef = zodSchema._zod.parent === ref;
        if (isParentRef) {
          for (const key in schema2) {
            if (key === "$ref" || key === "allOf")
              continue;
            if (!(key in _cached)) {
              delete schema2[key];
            }
          }
        }
        if (refSchema.$ref && refSeen.def) {
          for (const key in schema2) {
            if (key === "$ref" || key === "allOf")
              continue;
            if (key in refSeen.def && JSON.stringify(schema2[key]) === JSON.stringify(refSeen.def[key])) {
              delete schema2[key];
            }
          }
        }
      }
      const parent = zodSchema._zod.parent;
      if (parent && parent !== ref) {
        flattenRef(parent);
        const parentSeen = ctx.seen.get(parent);
        if (parentSeen?.schema.$ref) {
          schema2.$ref = parentSeen.schema.$ref;
          if (parentSeen.def) {
            for (const key in schema2) {
              if (key === "$ref" || key === "allOf")
                continue;
              if (key in parentSeen.def && JSON.stringify(schema2[key]) === JSON.stringify(parentSeen.def[key])) {
                delete schema2[key];
              }
            }
          }
        }
      }
      ctx.override({
        zodSchema,
        jsonSchema: schema2,
        path: seen.path ?? []
      });
    };
    for (const entry of [...ctx.seen.entries()].reverse()) {
      flattenRef(entry[0]);
    }
    const result = {};
    if (ctx.target === "draft-2020-12") {
      result.$schema = "https://json-schema.org/draft/2020-12/schema";
    } else if (ctx.target === "draft-07") {
      result.$schema = "http://json-schema.org/draft-07/schema#";
    } else if (ctx.target === "draft-04") {
      result.$schema = "http://json-schema.org/draft-04/schema#";
    } else if (ctx.target === "openapi-3.0") {
    } else {
    }
    if (ctx.external?.uri) {
      const id = ctx.external.registry.get(schema)?.id;
      if (!id)
        throw new Error("Schema is missing an `id` property");
      result.$id = ctx.external.uri(id);
    }
    Object.assign(result, root.def ?? root.schema);
    const rootMetaId = ctx.metadataRegistry.get(schema)?.id;
    if (rootMetaId !== void 0 && result.id === rootMetaId)
      delete result.id;
    const defs = ctx.external?.defs ?? {};
    for (const entry of ctx.seen.entries()) {
      const seen = entry[1];
      if (seen.def && seen.defId) {
        if (seen.def.id === seen.defId)
          delete seen.def.id;
        defs[seen.defId] = seen.def;
      }
    }
    if (ctx.external) {
    } else {
      if (Object.keys(defs).length > 0) {
        if (ctx.target === "draft-2020-12") {
          result.$defs = defs;
        } else {
          result.definitions = defs;
        }
      }
    }
    try {
      const finalized = JSON.parse(JSON.stringify(result));
      Object.defineProperty(finalized, "~standard", {
        value: {
          ...schema["~standard"],
          jsonSchema: {
            input: createStandardJSONSchemaMethod(schema, "input", ctx.processors),
            output: createStandardJSONSchemaMethod(schema, "output", ctx.processors)
          }
        },
        enumerable: false,
        writable: false
      });
      return finalized;
    } catch (_err) {
      throw new Error("Error converting schema to JSON.");
    }
  }
  function isTransforming(_schema, _ctx) {
    const ctx = _ctx ?? { seen: /* @__PURE__ */ new Set() };
    if (ctx.seen.has(_schema))
      return false;
    ctx.seen.add(_schema);
    const def = _schema._zod.def;
    if (def.type === "transform")
      return true;
    if (def.type === "array")
      return isTransforming(def.element, ctx);
    if (def.type === "set")
      return isTransforming(def.valueType, ctx);
    if (def.type === "lazy")
      return isTransforming(def.getter(), ctx);
    if (def.type === "promise" || def.type === "optional" || def.type === "nonoptional" || def.type === "nullable" || def.type === "readonly" || def.type === "default" || def.type === "prefault") {
      return isTransforming(def.innerType, ctx);
    }
    if (def.type === "intersection") {
      return isTransforming(def.left, ctx) || isTransforming(def.right, ctx);
    }
    if (def.type === "record" || def.type === "map") {
      return isTransforming(def.keyType, ctx) || isTransforming(def.valueType, ctx);
    }
    if (def.type === "pipe") {
      if (_schema._zod.traits.has("$ZodCodec"))
        return true;
      return isTransforming(def.in, ctx) || isTransforming(def.out, ctx);
    }
    if (def.type === "object") {
      for (const key in def.shape) {
        if (isTransforming(def.shape[key], ctx))
          return true;
      }
      return false;
    }
    if (def.type === "union") {
      for (const option of def.options) {
        if (isTransforming(option, ctx))
          return true;
      }
      return false;
    }
    if (def.type === "tuple") {
      for (const item of def.items) {
        if (isTransforming(item, ctx))
          return true;
      }
      if (def.rest && isTransforming(def.rest, ctx))
        return true;
      return false;
    }
    return false;
  }
  var createToJSONSchemaMethod = (schema, processors = {}) => (params) => {
    const ctx = initializeContext({ ...params, processors });
    process(schema, ctx);
    extractDefs(ctx, schema);
    return finalize(ctx, schema);
  };
  var createStandardJSONSchemaMethod = (schema, io, processors = {}) => (params) => {
    const { libraryOptions, target } = params ?? {};
    const ctx = initializeContext({ ...libraryOptions ?? {}, target, io, processors });
    process(schema, ctx);
    extractDefs(ctx, schema);
    return finalize(ctx, schema);
  };

  // ThirdParty/REA/dependencies/zod/v4/core/json-schema-processors.js
  init_runtime();
  var formatMap = {
    guid: "uuid",
    url: "uri",
    datetime: "date-time",
    json_string: "json-string",
    regex: ""
    // do not set
  };
  var stringProcessor = (schema, ctx, _json, _params) => {
    const json2 = _json;
    json2.type = "string";
    const { minimum, maximum, format, patterns, contentEncoding } = schema._zod.bag;
    if (typeof minimum === "number")
      json2.minLength = minimum;
    if (typeof maximum === "number")
      json2.maxLength = maximum;
    if (format) {
      json2.format = formatMap[format] ?? format;
      if (json2.format === "")
        delete json2.format;
      if (format === "time") {
        delete json2.format;
      }
    }
    if (contentEncoding)
      json2.contentEncoding = contentEncoding;
    if (patterns && patterns.size > 0) {
      const regexes = [...patterns];
      if (regexes.length === 1)
        json2.pattern = regexes[0].source;
      else if (regexes.length > 1) {
        json2.allOf = [
          ...regexes.map((regex) => ({
            ...ctx.target === "draft-07" || ctx.target === "draft-04" || ctx.target === "openapi-3.0" ? { type: "string" } : {},
            pattern: regex.source
          }))
        ];
      }
    }
  };
  var numberProcessor = (schema, ctx, _json, _params) => {
    const json2 = _json;
    const { minimum, maximum, format, multipleOf, exclusiveMaximum, exclusiveMinimum } = schema._zod.bag;
    if (typeof format === "string" && format.includes("int"))
      json2.type = "integer";
    else
      json2.type = "number";
    const exMin = typeof exclusiveMinimum === "number" && exclusiveMinimum >= (minimum ?? Number.NEGATIVE_INFINITY);
    const exMax = typeof exclusiveMaximum === "number" && exclusiveMaximum <= (maximum ?? Number.POSITIVE_INFINITY);
    const legacy = ctx.target === "draft-04" || ctx.target === "openapi-3.0";
    if (exMin) {
      if (legacy) {
        json2.minimum = exclusiveMinimum;
        json2.exclusiveMinimum = true;
      } else {
        json2.exclusiveMinimum = exclusiveMinimum;
      }
    } else if (typeof minimum === "number") {
      json2.minimum = minimum;
    }
    if (exMax) {
      if (legacy) {
        json2.maximum = exclusiveMaximum;
        json2.exclusiveMaximum = true;
      } else {
        json2.exclusiveMaximum = exclusiveMaximum;
      }
    } else if (typeof maximum === "number") {
      json2.maximum = maximum;
    }
    if (typeof multipleOf === "number")
      json2.multipleOf = multipleOf;
  };
  var booleanProcessor = (_schema, _ctx, json2, _params) => {
    json2.type = "boolean";
  };
  var bigintProcessor = (_schema, ctx, _json, _params) => {
    if (ctx.unrepresentable === "throw") {
      throw new Error("BigInt cannot be represented in JSON Schema");
    }
  };
  var symbolProcessor = (_schema, ctx, _json, _params) => {
    if (ctx.unrepresentable === "throw") {
      throw new Error("Symbols cannot be represented in JSON Schema");
    }
  };
  var nullProcessor = (_schema, ctx, json2, _params) => {
    if (ctx.target === "openapi-3.0") {
      json2.type = "string";
      json2.nullable = true;
      json2.enum = [null];
    } else {
      json2.type = "null";
    }
  };
  var undefinedProcessor = (_schema, ctx, _json, _params) => {
    if (ctx.unrepresentable === "throw") {
      throw new Error("Undefined cannot be represented in JSON Schema");
    }
  };
  var voidProcessor = (_schema, ctx, _json, _params) => {
    if (ctx.unrepresentable === "throw") {
      throw new Error("Void cannot be represented in JSON Schema");
    }
  };
  var neverProcessor = (_schema, _ctx, json2, _params) => {
    json2.not = {};
  };
  var anyProcessor = (_schema, _ctx, _json, _params) => {
  };
  var unknownProcessor = (_schema, _ctx, _json, _params) => {
  };
  var dateProcessor = (_schema, ctx, _json, _params) => {
    if (ctx.unrepresentable === "throw") {
      throw new Error("Date cannot be represented in JSON Schema");
    }
  };
  var enumProcessor = (schema, _ctx, json2, _params) => {
    const def = schema._zod.def;
    const values = getEnumValues(def.entries);
    if (values.every((v) => typeof v === "number"))
      json2.type = "number";
    if (values.every((v) => typeof v === "string"))
      json2.type = "string";
    json2.enum = values;
  };
  var literalProcessor = (schema, ctx, json2, _params) => {
    const def = schema._zod.def;
    const vals = [];
    for (const val of def.values) {
      if (val === void 0) {
        if (ctx.unrepresentable === "throw") {
          throw new Error("Literal `undefined` cannot be represented in JSON Schema");
        } else {
        }
      } else if (typeof val === "bigint") {
        if (ctx.unrepresentable === "throw") {
          throw new Error("BigInt literals cannot be represented in JSON Schema");
        } else {
          vals.push(Number(val));
        }
      } else {
        vals.push(val);
      }
    }
    if (vals.length === 0) {
    } else if (vals.length === 1) {
      const val = vals[0];
      json2.type = val === null ? "null" : typeof val;
      if (ctx.target === "draft-04" || ctx.target === "openapi-3.0") {
        json2.enum = [val];
      } else {
        json2.const = val;
      }
    } else {
      if (vals.every((v) => typeof v === "number"))
        json2.type = "number";
      if (vals.every((v) => typeof v === "string"))
        json2.type = "string";
      if (vals.every((v) => typeof v === "boolean"))
        json2.type = "boolean";
      if (vals.every((v) => v === null))
        json2.type = "null";
      json2.enum = vals;
    }
  };
  var nanProcessor = (_schema, ctx, _json, _params) => {
    if (ctx.unrepresentable === "throw") {
      throw new Error("NaN cannot be represented in JSON Schema");
    }
  };
  var templateLiteralProcessor = (schema, _ctx, json2, _params) => {
    const _json = json2;
    const pattern = schema._zod.pattern;
    if (!pattern)
      throw new Error("Pattern not found in template literal");
    _json.type = "string";
    _json.pattern = pattern.source;
  };
  var fileProcessor = (schema, _ctx, json2, _params) => {
    const _json = json2;
    const file2 = {
      type: "string",
      format: "binary",
      contentEncoding: "binary"
    };
    const { minimum, maximum, mime } = schema._zod.bag;
    if (minimum !== void 0)
      file2.minLength = minimum;
    if (maximum !== void 0)
      file2.maxLength = maximum;
    if (mime) {
      if (mime.length === 1) {
        file2.contentMediaType = mime[0];
        Object.assign(_json, file2);
      } else {
        Object.assign(_json, file2);
        _json.anyOf = mime.map((m) => ({ contentMediaType: m }));
      }
    } else {
      Object.assign(_json, file2);
    }
  };
  var successProcessor = (_schema, _ctx, json2, _params) => {
    json2.type = "boolean";
  };
  var customProcessor = (_schema, ctx, _json, _params) => {
    if (ctx.unrepresentable === "throw") {
      throw new Error("Custom types cannot be represented in JSON Schema");
    }
  };
  var functionProcessor = (_schema, ctx, _json, _params) => {
    if (ctx.unrepresentable === "throw") {
      throw new Error("Function types cannot be represented in JSON Schema");
    }
  };
  var transformProcessor = (_schema, ctx, _json, _params) => {
    if (ctx.unrepresentable === "throw") {
      throw new Error("Transforms cannot be represented in JSON Schema");
    }
  };
  var mapProcessor = (_schema, ctx, _json, _params) => {
    if (ctx.unrepresentable === "throw") {
      throw new Error("Map cannot be represented in JSON Schema");
    }
  };
  var setProcessor = (_schema, ctx, _json, _params) => {
    if (ctx.unrepresentable === "throw") {
      throw new Error("Set cannot be represented in JSON Schema");
    }
  };
  var arrayProcessor = (schema, ctx, _json, params) => {
    const json2 = _json;
    const def = schema._zod.def;
    const { minimum, maximum } = schema._zod.bag;
    if (typeof minimum === "number")
      json2.minItems = minimum;
    if (typeof maximum === "number")
      json2.maxItems = maximum;
    json2.type = "array";
    json2.items = process(def.element, ctx, {
      ...params,
      path: [...params.path, "items"]
    });
  };
  var objectProcessor = (schema, ctx, _json, params) => {
    const json2 = _json;
    const def = schema._zod.def;
    json2.type = "object";
    json2.properties = {};
    const shape = def.shape;
    for (const key in shape) {
      json2.properties[key] = process(shape[key], ctx, {
        ...params,
        path: [...params.path, "properties", key]
      });
    }
    const allKeys = new Set(Object.keys(shape));
    const requiredKeys = new Set([...allKeys].filter((key) => {
      const v = def.shape[key]._zod;
      if (ctx.io === "input") {
        return v.optin === void 0;
      } else {
        return v.optout === void 0;
      }
    }));
    if (requiredKeys.size > 0) {
      json2.required = Array.from(requiredKeys);
    }
    if (def.catchall?._zod.def.type === "never") {
      json2.additionalProperties = false;
    } else if (!def.catchall) {
      if (ctx.io === "output")
        json2.additionalProperties = false;
    } else if (def.catchall) {
      json2.additionalProperties = process(def.catchall, ctx, {
        ...params,
        path: [...params.path, "additionalProperties"]
      });
    }
  };
  var unionProcessor = (schema, ctx, json2, params) => {
    const def = schema._zod.def;
    const isExclusive = def.inclusive === false;
    const options = def.options.map((x, i) => process(x, ctx, {
      ...params,
      path: [...params.path, isExclusive ? "oneOf" : "anyOf", i]
    }));
    if (isExclusive) {
      json2.oneOf = options;
    } else {
      json2.anyOf = options;
    }
  };
  var intersectionProcessor = (schema, ctx, json2, params) => {
    const def = schema._zod.def;
    const a = process(def.left, ctx, {
      ...params,
      path: [...params.path, "allOf", 0]
    });
    const b = process(def.right, ctx, {
      ...params,
      path: [...params.path, "allOf", 1]
    });
    const isSimpleIntersection = (val) => "allOf" in val && Object.keys(val).length === 1;
    const allOf = [
      ...isSimpleIntersection(a) ? a.allOf : [a],
      ...isSimpleIntersection(b) ? b.allOf : [b]
    ];
    json2.allOf = allOf;
  };
  var tupleProcessor = (schema, ctx, _json, params) => {
    const json2 = _json;
    const def = schema._zod.def;
    json2.type = "array";
    const prefixPath = ctx.target === "draft-2020-12" ? "prefixItems" : "items";
    const restPath = ctx.target === "draft-2020-12" ? "items" : ctx.target === "openapi-3.0" ? "items" : "additionalItems";
    const prefixItems = def.items.map((x, i) => process(x, ctx, {
      ...params,
      path: [...params.path, prefixPath, i]
    }));
    const rest = def.rest ? process(def.rest, ctx, {
      ...params,
      path: [...params.path, restPath, ...ctx.target === "openapi-3.0" ? [def.items.length] : []]
    }) : null;
    if (ctx.target === "draft-2020-12") {
      json2.prefixItems = prefixItems;
      if (rest) {
        json2.items = rest;
      }
    } else if (ctx.target === "openapi-3.0") {
      json2.items = {
        anyOf: prefixItems
      };
      if (rest) {
        json2.items.anyOf.push(rest);
      }
      json2.minItems = prefixItems.length;
      if (!rest) {
        json2.maxItems = prefixItems.length;
      }
    } else {
      json2.items = prefixItems;
      if (rest) {
        json2.additionalItems = rest;
      }
    }
    const { minimum, maximum } = schema._zod.bag;
    if (typeof minimum === "number")
      json2.minItems = minimum;
    if (typeof maximum === "number")
      json2.maxItems = maximum;
  };
  var recordProcessor = (schema, ctx, _json, params) => {
    const json2 = _json;
    const def = schema._zod.def;
    json2.type = "object";
    const keyType = def.keyType;
    const keyBag = keyType._zod.bag;
    const patterns = keyBag?.patterns;
    if (def.mode === "loose" && patterns && patterns.size > 0) {
      const valueSchema = process(def.valueType, ctx, {
        ...params,
        path: [...params.path, "patternProperties", "*"]
      });
      json2.patternProperties = {};
      for (const pattern of patterns) {
        json2.patternProperties[pattern.source] = valueSchema;
      }
    } else {
      if (ctx.target === "draft-07" || ctx.target === "draft-2020-12") {
        json2.propertyNames = process(def.keyType, ctx, {
          ...params,
          path: [...params.path, "propertyNames"]
        });
      }
      json2.additionalProperties = process(def.valueType, ctx, {
        ...params,
        path: [...params.path, "additionalProperties"]
      });
    }
    const keyValues = keyType._zod.values;
    if (keyValues) {
      const validKeyValues = [...keyValues].filter((v) => typeof v === "string" || typeof v === "number");
      if (validKeyValues.length > 0) {
        json2.required = validKeyValues;
      }
    }
  };
  var nullableProcessor = (schema, ctx, json2, params) => {
    const def = schema._zod.def;
    const inner = process(def.innerType, ctx, params);
    const seen = ctx.seen.get(schema);
    if (ctx.target === "openapi-3.0") {
      seen.ref = def.innerType;
      json2.nullable = true;
    } else {
      json2.anyOf = [inner, { type: "null" }];
    }
  };
  var nonoptionalProcessor = (schema, ctx, _json, params) => {
    const def = schema._zod.def;
    process(def.innerType, ctx, params);
    const seen = ctx.seen.get(schema);
    seen.ref = def.innerType;
  };
  var defaultProcessor = (schema, ctx, json2, params) => {
    const def = schema._zod.def;
    process(def.innerType, ctx, params);
    const seen = ctx.seen.get(schema);
    seen.ref = def.innerType;
    json2.default = JSON.parse(JSON.stringify(def.defaultValue));
  };
  var prefaultProcessor = (schema, ctx, json2, params) => {
    const def = schema._zod.def;
    process(def.innerType, ctx, params);
    const seen = ctx.seen.get(schema);
    seen.ref = def.innerType;
    if (ctx.io === "input")
      json2._prefault = JSON.parse(JSON.stringify(def.defaultValue));
  };
  var catchProcessor = (schema, ctx, json2, params) => {
    const def = schema._zod.def;
    process(def.innerType, ctx, params);
    const seen = ctx.seen.get(schema);
    seen.ref = def.innerType;
    let catchValue;
    try {
      catchValue = def.catchValue(void 0);
    } catch {
      throw new Error("Dynamic catch values are not supported in JSON Schema");
    }
    json2.default = catchValue;
  };
  var pipeProcessor = (schema, ctx, _json, params) => {
    const def = schema._zod.def;
    const inIsTransform = def.in._zod.traits.has("$ZodTransform");
    const innerType = ctx.io === "input" ? inIsTransform ? def.out : def.in : def.out;
    process(innerType, ctx, params);
    const seen = ctx.seen.get(schema);
    seen.ref = innerType;
  };
  var readonlyProcessor = (schema, ctx, json2, params) => {
    const def = schema._zod.def;
    process(def.innerType, ctx, params);
    const seen = ctx.seen.get(schema);
    seen.ref = def.innerType;
    json2.readOnly = true;
  };
  var promiseProcessor = (schema, ctx, _json, params) => {
    const def = schema._zod.def;
    process(def.innerType, ctx, params);
    const seen = ctx.seen.get(schema);
    seen.ref = def.innerType;
  };
  var optionalProcessor = (schema, ctx, _json, params) => {
    const def = schema._zod.def;
    process(def.innerType, ctx, params);
    const seen = ctx.seen.get(schema);
    seen.ref = def.innerType;
  };
  var lazyProcessor = (schema, ctx, _json, params) => {
    const innerType = schema._zod.innerType;
    process(innerType, ctx, params);
    const seen = ctx.seen.get(schema);
    seen.ref = innerType;
  };
  var allProcessors = {
    string: stringProcessor,
    number: numberProcessor,
    boolean: booleanProcessor,
    bigint: bigintProcessor,
    symbol: symbolProcessor,
    null: nullProcessor,
    undefined: undefinedProcessor,
    void: voidProcessor,
    never: neverProcessor,
    any: anyProcessor,
    unknown: unknownProcessor,
    date: dateProcessor,
    enum: enumProcessor,
    literal: literalProcessor,
    nan: nanProcessor,
    template_literal: templateLiteralProcessor,
    file: fileProcessor,
    success: successProcessor,
    custom: customProcessor,
    function: functionProcessor,
    transform: transformProcessor,
    map: mapProcessor,
    set: setProcessor,
    array: arrayProcessor,
    object: objectProcessor,
    union: unionProcessor,
    intersection: intersectionProcessor,
    tuple: tupleProcessor,
    record: recordProcessor,
    nullable: nullableProcessor,
    nonoptional: nonoptionalProcessor,
    default: defaultProcessor,
    prefault: prefaultProcessor,
    catch: catchProcessor,
    pipe: pipeProcessor,
    readonly: readonlyProcessor,
    promise: promiseProcessor,
    optional: optionalProcessor,
    lazy: lazyProcessor
  };
  function toJSONSchema(input, params) {
    if ("_idmap" in input) {
      const registry2 = input;
      const ctx2 = initializeContext({ ...params, processors: allProcessors });
      const defs = {};
      for (const entry of registry2._idmap.entries()) {
        const [_, schema] = entry;
        process(schema, ctx2);
      }
      const schemas = {};
      const external = {
        registry: registry2,
        uri: params?.uri,
        defs
      };
      ctx2.external = external;
      for (const entry of registry2._idmap.entries()) {
        const [key, schema] = entry;
        extractDefs(ctx2, schema);
        schemas[key] = finalize(ctx2, schema);
      }
      if (Object.keys(defs).length > 0) {
        const defsSegment = ctx2.target === "draft-2020-12" ? "$defs" : "definitions";
        schemas.__shared = {
          [defsSegment]: defs
        };
      }
      return { schemas };
    }
    const ctx = initializeContext({ ...params, processors: allProcessors });
    process(input, ctx);
    extractDefs(ctx, input);
    return finalize(ctx, input);
  }

  // ThirdParty/REA/dependencies/zod/v4/core/json-schema-generator.js
  init_runtime();
  var JSONSchemaGenerator = class {
    /** @deprecated Access via ctx instead */
    get metadataRegistry() {
      return this.ctx.metadataRegistry;
    }
    /** @deprecated Access via ctx instead */
    get target() {
      return this.ctx.target;
    }
    /** @deprecated Access via ctx instead */
    get unrepresentable() {
      return this.ctx.unrepresentable;
    }
    /** @deprecated Access via ctx instead */
    get override() {
      return this.ctx.override;
    }
    /** @deprecated Access via ctx instead */
    get io() {
      return this.ctx.io;
    }
    /** @deprecated Access via ctx instead */
    get counter() {
      return this.ctx.counter;
    }
    set counter(value) {
      this.ctx.counter = value;
    }
    /** @deprecated Access via ctx instead */
    get seen() {
      return this.ctx.seen;
    }
    constructor(params) {
      let normalizedTarget = params?.target ?? "draft-2020-12";
      if (normalizedTarget === "draft-4")
        normalizedTarget = "draft-04";
      if (normalizedTarget === "draft-7")
        normalizedTarget = "draft-07";
      this.ctx = initializeContext({
        processors: allProcessors,
        target: normalizedTarget,
        ...params?.metadata && { metadata: params.metadata },
        ...params?.unrepresentable && { unrepresentable: params.unrepresentable },
        ...params?.override && { override: params.override },
        ...params?.io && { io: params.io }
      });
    }
    /**
     * Process a schema to prepare it for JSON Schema generation.
     * This must be called before emit().
     */
    process(schema, _params = { path: [], schemaPath: [] }) {
      return process(schema, this.ctx, _params);
    }
    /**
     * Emit the final JSON Schema after processing.
     * Must call process() first.
     */
    emit(schema, _params) {
      if (_params) {
        if (_params.cycles)
          this.ctx.cycles = _params.cycles;
        if (_params.reused)
          this.ctx.reused = _params.reused;
        if (_params.external)
          this.ctx.external = _params.external;
      }
      extractDefs(this.ctx, schema);
      const result = finalize(this.ctx, schema);
      const { "~standard": _, ...plainResult } = result;
      return plainResult;
    }
  };

  // ThirdParty/REA/dependencies/zod/v4/core/json-schema.js
  var json_schema_exports = {};
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/classic/schemas.js
  var schemas_exports2 = {};
  __export(schemas_exports2, {
    ZodAny: () => ZodAny,
    ZodArray: () => ZodArray,
    ZodBase64: () => ZodBase64,
    ZodBase64URL: () => ZodBase64URL,
    ZodBigInt: () => ZodBigInt,
    ZodBigIntFormat: () => ZodBigIntFormat,
    ZodBoolean: () => ZodBoolean,
    ZodCIDRv4: () => ZodCIDRv4,
    ZodCIDRv6: () => ZodCIDRv6,
    ZodCUID: () => ZodCUID,
    ZodCUID2: () => ZodCUID2,
    ZodCatch: () => ZodCatch,
    ZodCodec: () => ZodCodec,
    ZodCustom: () => ZodCustom,
    ZodCustomStringFormat: () => ZodCustomStringFormat,
    ZodDate: () => ZodDate,
    ZodDefault: () => ZodDefault,
    ZodDiscriminatedUnion: () => ZodDiscriminatedUnion,
    ZodE164: () => ZodE164,
    ZodEmail: () => ZodEmail,
    ZodEmoji: () => ZodEmoji,
    ZodEnum: () => ZodEnum,
    ZodExactOptional: () => ZodExactOptional,
    ZodFile: () => ZodFile,
    ZodFunction: () => ZodFunction,
    ZodGUID: () => ZodGUID,
    ZodIPv4: () => ZodIPv4,
    ZodIPv6: () => ZodIPv6,
    ZodIntersection: () => ZodIntersection,
    ZodJWT: () => ZodJWT,
    ZodKSUID: () => ZodKSUID,
    ZodLazy: () => ZodLazy,
    ZodLiteral: () => ZodLiteral,
    ZodMAC: () => ZodMAC,
    ZodMap: () => ZodMap,
    ZodNaN: () => ZodNaN,
    ZodNanoID: () => ZodNanoID,
    ZodNever: () => ZodNever,
    ZodNonOptional: () => ZodNonOptional,
    ZodNull: () => ZodNull,
    ZodNullable: () => ZodNullable,
    ZodNumber: () => ZodNumber,
    ZodNumberFormat: () => ZodNumberFormat,
    ZodObject: () => ZodObject,
    ZodOptional: () => ZodOptional,
    ZodPipe: () => ZodPipe,
    ZodPrefault: () => ZodPrefault,
    ZodPreprocess: () => ZodPreprocess,
    ZodPromise: () => ZodPromise,
    ZodReadonly: () => ZodReadonly,
    ZodRecord: () => ZodRecord,
    ZodSet: () => ZodSet,
    ZodString: () => ZodString,
    ZodStringFormat: () => ZodStringFormat,
    ZodSuccess: () => ZodSuccess,
    ZodSymbol: () => ZodSymbol,
    ZodTemplateLiteral: () => ZodTemplateLiteral,
    ZodTransform: () => ZodTransform,
    ZodTuple: () => ZodTuple,
    ZodType: () => ZodType,
    ZodULID: () => ZodULID,
    ZodURL: () => ZodURL,
    ZodUUID: () => ZodUUID,
    ZodUndefined: () => ZodUndefined,
    ZodUnion: () => ZodUnion,
    ZodUnknown: () => ZodUnknown,
    ZodVoid: () => ZodVoid,
    ZodXID: () => ZodXID,
    ZodXor: () => ZodXor,
    _ZodString: () => _ZodString,
    _default: () => _default2,
    _function: () => _function,
    any: () => any,
    array: () => array,
    base64: () => base642,
    base64url: () => base64url2,
    bigint: () => bigint2,
    boolean: () => boolean2,
    catch: () => _catch2,
    check: () => check,
    cidrv4: () => cidrv42,
    cidrv6: () => cidrv62,
    codec: () => codec,
    cuid: () => cuid3,
    cuid2: () => cuid22,
    custom: () => custom,
    date: () => date3,
    describe: () => describe2,
    discriminatedUnion: () => discriminatedUnion,
    e164: () => e1642,
    email: () => email2,
    emoji: () => emoji2,
    enum: () => _enum2,
    exactOptional: () => exactOptional,
    file: () => file,
    float32: () => float32,
    float64: () => float64,
    function: () => _function,
    guid: () => guid2,
    hash: () => hash,
    hex: () => hex2,
    hostname: () => hostname2,
    httpUrl: () => httpUrl,
    instanceof: () => _instanceof,
    int: () => int,
    int32: () => int32,
    int64: () => int64,
    intersection: () => intersection,
    invertCodec: () => invertCodec,
    ipv4: () => ipv42,
    ipv6: () => ipv62,
    json: () => json,
    jwt: () => jwt,
    keyof: () => keyof,
    ksuid: () => ksuid2,
    lazy: () => lazy,
    literal: () => literal,
    looseObject: () => looseObject,
    looseRecord: () => looseRecord,
    mac: () => mac2,
    map: () => map,
    meta: () => meta2,
    nan: () => nan,
    nanoid: () => nanoid2,
    nativeEnum: () => nativeEnum,
    never: () => never,
    nonoptional: () => nonoptional,
    null: () => _null3,
    nullable: () => nullable,
    nullish: () => nullish2,
    number: () => number2,
    object: () => object,
    optional: () => optional,
    partialRecord: () => partialRecord,
    pipe: () => pipe,
    prefault: () => prefault,
    preprocess: () => preprocess,
    promise: () => promise,
    readonly: () => readonly,
    record: () => record,
    refine: () => refine,
    set: () => set,
    strictObject: () => strictObject,
    string: () => string2,
    stringFormat: () => stringFormat,
    stringbool: () => stringbool,
    success: () => success,
    superRefine: () => superRefine,
    symbol: () => symbol,
    templateLiteral: () => templateLiteral,
    transform: () => transform,
    tuple: () => tuple,
    uint32: () => uint32,
    uint64: () => uint64,
    ulid: () => ulid2,
    undefined: () => _undefined3,
    union: () => union,
    unknown: () => unknown,
    url: () => url,
    uuid: () => uuid2,
    uuidv4: () => uuidv4,
    uuidv6: () => uuidv6,
    uuidv7: () => uuidv7,
    void: () => _void2,
    xid: () => xid2,
    xor: () => xor
  });
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/classic/checks.js
  var checks_exports2 = {};
  __export(checks_exports2, {
    endsWith: () => _endsWith,
    gt: () => _gt,
    gte: () => _gte,
    includes: () => _includes,
    length: () => _length,
    lowercase: () => _lowercase,
    lt: () => _lt,
    lte: () => _lte,
    maxLength: () => _maxLength,
    maxSize: () => _maxSize,
    mime: () => _mime,
    minLength: () => _minLength,
    minSize: () => _minSize,
    multipleOf: () => _multipleOf,
    negative: () => _negative,
    nonnegative: () => _nonnegative,
    nonpositive: () => _nonpositive,
    normalize: () => _normalize,
    overwrite: () => _overwrite,
    positive: () => _positive,
    property: () => _property,
    regex: () => _regex,
    size: () => _size,
    slugify: () => _slugify,
    startsWith: () => _startsWith,
    toLowerCase: () => _toLowerCase,
    toUpperCase: () => _toUpperCase,
    trim: () => _trim,
    uppercase: () => _uppercase
  });
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/classic/iso.js
  var iso_exports = {};
  __export(iso_exports, {
    ZodISODate: () => ZodISODate,
    ZodISODateTime: () => ZodISODateTime,
    ZodISODuration: () => ZodISODuration,
    ZodISOTime: () => ZodISOTime,
    date: () => date2,
    datetime: () => datetime2,
    duration: () => duration2,
    time: () => time2
  });
  init_runtime();
  var ZodISODateTime = /* @__PURE__ */ $constructor("ZodISODateTime", (inst, def) => {
    $ZodISODateTime.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function datetime2(params) {
    return _isoDateTime(ZodISODateTime, params);
  }
  var ZodISODate = /* @__PURE__ */ $constructor("ZodISODate", (inst, def) => {
    $ZodISODate.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function date2(params) {
    return _isoDate(ZodISODate, params);
  }
  var ZodISOTime = /* @__PURE__ */ $constructor("ZodISOTime", (inst, def) => {
    $ZodISOTime.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function time2(params) {
    return _isoTime(ZodISOTime, params);
  }
  var ZodISODuration = /* @__PURE__ */ $constructor("ZodISODuration", (inst, def) => {
    $ZodISODuration.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function duration2(params) {
    return _isoDuration(ZodISODuration, params);
  }

  // ThirdParty/REA/dependencies/zod/v4/classic/parse.js
  init_runtime();

  // ThirdParty/REA/dependencies/zod/v4/classic/errors.js
  init_runtime();
  var initializer2 = (inst, issues) => {
    $ZodError.init(inst, issues);
    inst.name = "ZodError";
    Object.defineProperties(inst, {
      format: {
        value: (mapper) => formatError(inst, mapper)
        // enumerable: false,
      },
      flatten: {
        value: (mapper) => flattenError(inst, mapper)
        // enumerable: false,
      },
      addIssue: {
        value: (issue2) => {
          inst.issues.push(issue2);
          inst.message = JSON.stringify(inst.issues, jsonStringifyReplacer, 2);
        }
        // enumerable: false,
      },
      addIssues: {
        value: (issues2) => {
          inst.issues.push(...issues2);
          inst.message = JSON.stringify(inst.issues, jsonStringifyReplacer, 2);
        }
        // enumerable: false,
      },
      isEmpty: {
        get() {
          return inst.issues.length === 0;
        }
        // enumerable: false,
      }
    });
  };
  var ZodError = /* @__PURE__ */ $constructor("ZodError", initializer2);
  var ZodRealError = /* @__PURE__ */ $constructor("ZodError", initializer2, {
    Parent: Error
  });

  // ThirdParty/REA/dependencies/zod/v4/classic/parse.js
  var parse2 = /* @__PURE__ */ _parse(ZodRealError);
  var parseAsync2 = /* @__PURE__ */ _parseAsync(ZodRealError);
  var safeParse2 = /* @__PURE__ */ _safeParse(ZodRealError);
  var safeParseAsync2 = /* @__PURE__ */ _safeParseAsync(ZodRealError);
  var encode2 = /* @__PURE__ */ _encode(ZodRealError);
  var decode2 = /* @__PURE__ */ _decode(ZodRealError);
  var encodeAsync2 = /* @__PURE__ */ _encodeAsync(ZodRealError);
  var decodeAsync2 = /* @__PURE__ */ _decodeAsync(ZodRealError);
  var safeEncode2 = /* @__PURE__ */ _safeEncode(ZodRealError);
  var safeDecode2 = /* @__PURE__ */ _safeDecode(ZodRealError);
  var safeEncodeAsync2 = /* @__PURE__ */ _safeEncodeAsync(ZodRealError);
  var safeDecodeAsync2 = /* @__PURE__ */ _safeDecodeAsync(ZodRealError);

  // ThirdParty/REA/dependencies/zod/v4/classic/schemas.js
  var _installedGroups = /* @__PURE__ */ new WeakMap();
  function _installLazyMethods(inst, group, methods) {
    const proto = Object.getPrototypeOf(inst);
    let installed = _installedGroups.get(proto);
    if (!installed) {
      installed = /* @__PURE__ */ new Set();
      _installedGroups.set(proto, installed);
    }
    if (installed.has(group))
      return;
    installed.add(group);
    for (const key in methods) {
      const fn = methods[key];
      Object.defineProperty(proto, key, {
        configurable: true,
        enumerable: false,
        get() {
          const bound = fn.bind(this);
          Object.defineProperty(this, key, {
            configurable: true,
            writable: true,
            enumerable: true,
            value: bound
          });
          return bound;
        },
        set(v) {
          Object.defineProperty(this, key, {
            configurable: true,
            writable: true,
            enumerable: true,
            value: v
          });
        }
      });
    }
  }
  var ZodType = /* @__PURE__ */ $constructor("ZodType", (inst, def) => {
    $ZodType.init(inst, def);
    Object.assign(inst["~standard"], {
      jsonSchema: {
        input: createStandardJSONSchemaMethod(inst, "input"),
        output: createStandardJSONSchemaMethod(inst, "output")
      }
    });
    inst.toJSONSchema = createToJSONSchemaMethod(inst, {});
    inst.def = def;
    inst.type = def.type;
    Object.defineProperty(inst, "_def", { value: def });
    inst.parse = (data, params) => parse2(inst, data, params, { callee: inst.parse });
    inst.safeParse = (data, params) => safeParse2(inst, data, params);
    inst.parseAsync = async (data, params) => parseAsync2(inst, data, params, { callee: inst.parseAsync });
    inst.safeParseAsync = async (data, params) => safeParseAsync2(inst, data, params);
    inst.spa = inst.safeParseAsync;
    inst.encode = (data, params) => encode2(inst, data, params);
    inst.decode = (data, params) => decode2(inst, data, params);
    inst.encodeAsync = async (data, params) => encodeAsync2(inst, data, params);
    inst.decodeAsync = async (data, params) => decodeAsync2(inst, data, params);
    inst.safeEncode = (data, params) => safeEncode2(inst, data, params);
    inst.safeDecode = (data, params) => safeDecode2(inst, data, params);
    inst.safeEncodeAsync = async (data, params) => safeEncodeAsync2(inst, data, params);
    inst.safeDecodeAsync = async (data, params) => safeDecodeAsync2(inst, data, params);
    _installLazyMethods(inst, "ZodType", {
      check(...chks) {
        const def2 = this.def;
        return this.clone(util_exports.mergeDefs(def2, {
          checks: [
            ...def2.checks ?? [],
            ...chks.map((ch) => typeof ch === "function" ? { _zod: { check: ch, def: { check: "custom" }, onattach: [] } } : ch)
          ]
        }), { parent: true });
      },
      with(...chks) {
        return this.check(...chks);
      },
      clone(def2, params) {
        return clone(this, def2, params);
      },
      brand() {
        return this;
      },
      register(reg, meta3) {
        reg.add(this, meta3);
        return this;
      },
      refine(check2, params) {
        return this.check(refine(check2, params));
      },
      superRefine(refinement, params) {
        return this.check(superRefine(refinement, params));
      },
      overwrite(fn) {
        return this.check(_overwrite(fn));
      },
      optional() {
        return optional(this);
      },
      exactOptional() {
        return exactOptional(this);
      },
      nullable() {
        return nullable(this);
      },
      nullish() {
        return optional(nullable(this));
      },
      nonoptional(params) {
        return nonoptional(this, params);
      },
      array() {
        return array(this);
      },
      or(arg) {
        return union([this, arg]);
      },
      and(arg) {
        return intersection(this, arg);
      },
      transform(tx) {
        return pipe(this, transform(tx));
      },
      default(d) {
        return _default2(this, d);
      },
      prefault(d) {
        return prefault(this, d);
      },
      catch(params) {
        return _catch2(this, params);
      },
      pipe(target) {
        return pipe(this, target);
      },
      readonly() {
        return readonly(this);
      },
      describe(description) {
        const cl = this.clone();
        globalRegistry.add(cl, { description });
        return cl;
      },
      meta(...args) {
        if (args.length === 0)
          return globalRegistry.get(this);
        const cl = this.clone();
        globalRegistry.add(cl, args[0]);
        return cl;
      },
      isOptional() {
        return this.safeParse(void 0).success;
      },
      isNullable() {
        return this.safeParse(null).success;
      },
      apply(fn) {
        return fn(this);
      }
    });
    Object.defineProperty(inst, "description", {
      get() {
        return globalRegistry.get(inst)?.description;
      },
      configurable: true
    });
    return inst;
  });
  var _ZodString = /* @__PURE__ */ $constructor("_ZodString", (inst, def) => {
    $ZodString.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => stringProcessor(inst, ctx, json2, params);
    const bag = inst._zod.bag;
    inst.format = bag.format ?? null;
    inst.minLength = bag.minimum ?? null;
    inst.maxLength = bag.maximum ?? null;
    _installLazyMethods(inst, "_ZodString", {
      regex(...args) {
        return this.check(_regex(...args));
      },
      includes(...args) {
        return this.check(_includes(...args));
      },
      startsWith(...args) {
        return this.check(_startsWith(...args));
      },
      endsWith(...args) {
        return this.check(_endsWith(...args));
      },
      min(...args) {
        return this.check(_minLength(...args));
      },
      max(...args) {
        return this.check(_maxLength(...args));
      },
      length(...args) {
        return this.check(_length(...args));
      },
      nonempty(...args) {
        return this.check(_minLength(1, ...args));
      },
      lowercase(params) {
        return this.check(_lowercase(params));
      },
      uppercase(params) {
        return this.check(_uppercase(params));
      },
      trim() {
        return this.check(_trim());
      },
      normalize(...args) {
        return this.check(_normalize(...args));
      },
      toLowerCase() {
        return this.check(_toLowerCase());
      },
      toUpperCase() {
        return this.check(_toUpperCase());
      },
      slugify() {
        return this.check(_slugify());
      }
    });
  });
  var ZodString = /* @__PURE__ */ $constructor("ZodString", (inst, def) => {
    $ZodString.init(inst, def);
    _ZodString.init(inst, def);
    inst.email = (params) => inst.check(_email(ZodEmail, params));
    inst.url = (params) => inst.check(_url(ZodURL, params));
    inst.jwt = (params) => inst.check(_jwt(ZodJWT, params));
    inst.emoji = (params) => inst.check(_emoji2(ZodEmoji, params));
    inst.guid = (params) => inst.check(_guid(ZodGUID, params));
    inst.uuid = (params) => inst.check(_uuid(ZodUUID, params));
    inst.uuidv4 = (params) => inst.check(_uuidv4(ZodUUID, params));
    inst.uuidv6 = (params) => inst.check(_uuidv6(ZodUUID, params));
    inst.uuidv7 = (params) => inst.check(_uuidv7(ZodUUID, params));
    inst.nanoid = (params) => inst.check(_nanoid(ZodNanoID, params));
    inst.guid = (params) => inst.check(_guid(ZodGUID, params));
    inst.cuid = (params) => inst.check(_cuid(ZodCUID, params));
    inst.cuid2 = (params) => inst.check(_cuid2(ZodCUID2, params));
    inst.ulid = (params) => inst.check(_ulid(ZodULID, params));
    inst.base64 = (params) => inst.check(_base64(ZodBase64, params));
    inst.base64url = (params) => inst.check(_base64url(ZodBase64URL, params));
    inst.xid = (params) => inst.check(_xid(ZodXID, params));
    inst.ksuid = (params) => inst.check(_ksuid(ZodKSUID, params));
    inst.ipv4 = (params) => inst.check(_ipv4(ZodIPv4, params));
    inst.ipv6 = (params) => inst.check(_ipv6(ZodIPv6, params));
    inst.cidrv4 = (params) => inst.check(_cidrv4(ZodCIDRv4, params));
    inst.cidrv6 = (params) => inst.check(_cidrv6(ZodCIDRv6, params));
    inst.e164 = (params) => inst.check(_e164(ZodE164, params));
    inst.datetime = (params) => inst.check(datetime2(params));
    inst.date = (params) => inst.check(date2(params));
    inst.time = (params) => inst.check(time2(params));
    inst.duration = (params) => inst.check(duration2(params));
  });
  function string2(params) {
    return _string(ZodString, params);
  }
  var ZodStringFormat = /* @__PURE__ */ $constructor("ZodStringFormat", (inst, def) => {
    $ZodStringFormat.init(inst, def);
    _ZodString.init(inst, def);
  });
  var ZodEmail = /* @__PURE__ */ $constructor("ZodEmail", (inst, def) => {
    $ZodEmail.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function email2(params) {
    return _email(ZodEmail, params);
  }
  var ZodGUID = /* @__PURE__ */ $constructor("ZodGUID", (inst, def) => {
    $ZodGUID.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function guid2(params) {
    return _guid(ZodGUID, params);
  }
  var ZodUUID = /* @__PURE__ */ $constructor("ZodUUID", (inst, def) => {
    $ZodUUID.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function uuid2(params) {
    return _uuid(ZodUUID, params);
  }
  function uuidv4(params) {
    return _uuidv4(ZodUUID, params);
  }
  function uuidv6(params) {
    return _uuidv6(ZodUUID, params);
  }
  function uuidv7(params) {
    return _uuidv7(ZodUUID, params);
  }
  var ZodURL = /* @__PURE__ */ $constructor("ZodURL", (inst, def) => {
    $ZodURL.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function url(params) {
    return _url(ZodURL, params);
  }
  function httpUrl(params) {
    return _url(ZodURL, {
      protocol: regexes_exports.httpProtocol,
      hostname: regexes_exports.domain,
      ...util_exports.normalizeParams(params)
    });
  }
  var ZodEmoji = /* @__PURE__ */ $constructor("ZodEmoji", (inst, def) => {
    $ZodEmoji.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function emoji2(params) {
    return _emoji2(ZodEmoji, params);
  }
  var ZodNanoID = /* @__PURE__ */ $constructor("ZodNanoID", (inst, def) => {
    $ZodNanoID.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function nanoid2(params) {
    return _nanoid(ZodNanoID, params);
  }
  var ZodCUID = /* @__PURE__ */ $constructor("ZodCUID", (inst, def) => {
    $ZodCUID.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function cuid3(params) {
    return _cuid(ZodCUID, params);
  }
  var ZodCUID2 = /* @__PURE__ */ $constructor("ZodCUID2", (inst, def) => {
    $ZodCUID2.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function cuid22(params) {
    return _cuid2(ZodCUID2, params);
  }
  var ZodULID = /* @__PURE__ */ $constructor("ZodULID", (inst, def) => {
    $ZodULID.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function ulid2(params) {
    return _ulid(ZodULID, params);
  }
  var ZodXID = /* @__PURE__ */ $constructor("ZodXID", (inst, def) => {
    $ZodXID.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function xid2(params) {
    return _xid(ZodXID, params);
  }
  var ZodKSUID = /* @__PURE__ */ $constructor("ZodKSUID", (inst, def) => {
    $ZodKSUID.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function ksuid2(params) {
    return _ksuid(ZodKSUID, params);
  }
  var ZodIPv4 = /* @__PURE__ */ $constructor("ZodIPv4", (inst, def) => {
    $ZodIPv4.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function ipv42(params) {
    return _ipv4(ZodIPv4, params);
  }
  var ZodMAC = /* @__PURE__ */ $constructor("ZodMAC", (inst, def) => {
    $ZodMAC.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function mac2(params) {
    return _mac(ZodMAC, params);
  }
  var ZodIPv6 = /* @__PURE__ */ $constructor("ZodIPv6", (inst, def) => {
    $ZodIPv6.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function ipv62(params) {
    return _ipv6(ZodIPv6, params);
  }
  var ZodCIDRv4 = /* @__PURE__ */ $constructor("ZodCIDRv4", (inst, def) => {
    $ZodCIDRv4.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function cidrv42(params) {
    return _cidrv4(ZodCIDRv4, params);
  }
  var ZodCIDRv6 = /* @__PURE__ */ $constructor("ZodCIDRv6", (inst, def) => {
    $ZodCIDRv6.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function cidrv62(params) {
    return _cidrv6(ZodCIDRv6, params);
  }
  var ZodBase64 = /* @__PURE__ */ $constructor("ZodBase64", (inst, def) => {
    $ZodBase64.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function base642(params) {
    return _base64(ZodBase64, params);
  }
  var ZodBase64URL = /* @__PURE__ */ $constructor("ZodBase64URL", (inst, def) => {
    $ZodBase64URL.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function base64url2(params) {
    return _base64url(ZodBase64URL, params);
  }
  var ZodE164 = /* @__PURE__ */ $constructor("ZodE164", (inst, def) => {
    $ZodE164.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function e1642(params) {
    return _e164(ZodE164, params);
  }
  var ZodJWT = /* @__PURE__ */ $constructor("ZodJWT", (inst, def) => {
    $ZodJWT.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function jwt(params) {
    return _jwt(ZodJWT, params);
  }
  var ZodCustomStringFormat = /* @__PURE__ */ $constructor("ZodCustomStringFormat", (inst, def) => {
    $ZodCustomStringFormat.init(inst, def);
    ZodStringFormat.init(inst, def);
  });
  function stringFormat(format, fnOrRegex, _params = {}) {
    return _stringFormat(ZodCustomStringFormat, format, fnOrRegex, _params);
  }
  function hostname2(_params) {
    return _stringFormat(ZodCustomStringFormat, "hostname", regexes_exports.hostname, _params);
  }
  function hex2(_params) {
    return _stringFormat(ZodCustomStringFormat, "hex", regexes_exports.hex, _params);
  }
  function hash(alg, params) {
    const enc = params?.enc ?? "hex";
    const format = `${alg}_${enc}`;
    const regex = regexes_exports[format];
    if (!regex)
      throw new Error(`Unrecognized hash format: ${format}`);
    return _stringFormat(ZodCustomStringFormat, format, regex, params);
  }
  var ZodNumber = /* @__PURE__ */ $constructor("ZodNumber", (inst, def) => {
    $ZodNumber.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => numberProcessor(inst, ctx, json2, params);
    _installLazyMethods(inst, "ZodNumber", {
      gt(value, params) {
        return this.check(_gt(value, params));
      },
      gte(value, params) {
        return this.check(_gte(value, params));
      },
      min(value, params) {
        return this.check(_gte(value, params));
      },
      lt(value, params) {
        return this.check(_lt(value, params));
      },
      lte(value, params) {
        return this.check(_lte(value, params));
      },
      max(value, params) {
        return this.check(_lte(value, params));
      },
      int(params) {
        return this.check(int(params));
      },
      safe(params) {
        return this.check(int(params));
      },
      positive(params) {
        return this.check(_gt(0, params));
      },
      nonnegative(params) {
        return this.check(_gte(0, params));
      },
      negative(params) {
        return this.check(_lt(0, params));
      },
      nonpositive(params) {
        return this.check(_lte(0, params));
      },
      multipleOf(value, params) {
        return this.check(_multipleOf(value, params));
      },
      step(value, params) {
        return this.check(_multipleOf(value, params));
      },
      finite() {
        return this;
      }
    });
    const bag = inst._zod.bag;
    inst.minValue = Math.max(bag.minimum ?? Number.NEGATIVE_INFINITY, bag.exclusiveMinimum ?? Number.NEGATIVE_INFINITY) ?? null;
    inst.maxValue = Math.min(bag.maximum ?? Number.POSITIVE_INFINITY, bag.exclusiveMaximum ?? Number.POSITIVE_INFINITY) ?? null;
    inst.isInt = (bag.format ?? "").includes("int") || Number.isSafeInteger(bag.multipleOf ?? 0.5);
    inst.isFinite = true;
    inst.format = bag.format ?? null;
  });
  function number2(params) {
    return _number(ZodNumber, params);
  }
  var ZodNumberFormat = /* @__PURE__ */ $constructor("ZodNumberFormat", (inst, def) => {
    $ZodNumberFormat.init(inst, def);
    ZodNumber.init(inst, def);
  });
  function int(params) {
    return _int(ZodNumberFormat, params);
  }
  function float32(params) {
    return _float32(ZodNumberFormat, params);
  }
  function float64(params) {
    return _float64(ZodNumberFormat, params);
  }
  function int32(params) {
    return _int32(ZodNumberFormat, params);
  }
  function uint32(params) {
    return _uint32(ZodNumberFormat, params);
  }
  var ZodBoolean = /* @__PURE__ */ $constructor("ZodBoolean", (inst, def) => {
    $ZodBoolean.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => booleanProcessor(inst, ctx, json2, params);
  });
  function boolean2(params) {
    return _boolean(ZodBoolean, params);
  }
  var ZodBigInt = /* @__PURE__ */ $constructor("ZodBigInt", (inst, def) => {
    $ZodBigInt.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => bigintProcessor(inst, ctx, json2, params);
    inst.gte = (value, params) => inst.check(_gte(value, params));
    inst.min = (value, params) => inst.check(_gte(value, params));
    inst.gt = (value, params) => inst.check(_gt(value, params));
    inst.gte = (value, params) => inst.check(_gte(value, params));
    inst.min = (value, params) => inst.check(_gte(value, params));
    inst.lt = (value, params) => inst.check(_lt(value, params));
    inst.lte = (value, params) => inst.check(_lte(value, params));
    inst.max = (value, params) => inst.check(_lte(value, params));
    inst.positive = (params) => inst.check(_gt(BigInt(0), params));
    inst.negative = (params) => inst.check(_lt(BigInt(0), params));
    inst.nonpositive = (params) => inst.check(_lte(BigInt(0), params));
    inst.nonnegative = (params) => inst.check(_gte(BigInt(0), params));
    inst.multipleOf = (value, params) => inst.check(_multipleOf(value, params));
    const bag = inst._zod.bag;
    inst.minValue = bag.minimum ?? null;
    inst.maxValue = bag.maximum ?? null;
    inst.format = bag.format ?? null;
  });
  function bigint2(params) {
    return _bigint(ZodBigInt, params);
  }
  var ZodBigIntFormat = /* @__PURE__ */ $constructor("ZodBigIntFormat", (inst, def) => {
    $ZodBigIntFormat.init(inst, def);
    ZodBigInt.init(inst, def);
  });
  function int64(params) {
    return _int64(ZodBigIntFormat, params);
  }
  function uint64(params) {
    return _uint64(ZodBigIntFormat, params);
  }
  var ZodSymbol = /* @__PURE__ */ $constructor("ZodSymbol", (inst, def) => {
    $ZodSymbol.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => symbolProcessor(inst, ctx, json2, params);
  });
  function symbol(params) {
    return _symbol(ZodSymbol, params);
  }
  var ZodUndefined = /* @__PURE__ */ $constructor("ZodUndefined", (inst, def) => {
    $ZodUndefined.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => undefinedProcessor(inst, ctx, json2, params);
  });
  function _undefined3(params) {
    return _undefined2(ZodUndefined, params);
  }
  var ZodNull = /* @__PURE__ */ $constructor("ZodNull", (inst, def) => {
    $ZodNull.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => nullProcessor(inst, ctx, json2, params);
  });
  function _null3(params) {
    return _null2(ZodNull, params);
  }
  var ZodAny = /* @__PURE__ */ $constructor("ZodAny", (inst, def) => {
    $ZodAny.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => anyProcessor(inst, ctx, json2, params);
  });
  function any() {
    return _any(ZodAny);
  }
  var ZodUnknown = /* @__PURE__ */ $constructor("ZodUnknown", (inst, def) => {
    $ZodUnknown.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => unknownProcessor(inst, ctx, json2, params);
  });
  function unknown() {
    return _unknown(ZodUnknown);
  }
  var ZodNever = /* @__PURE__ */ $constructor("ZodNever", (inst, def) => {
    $ZodNever.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => neverProcessor(inst, ctx, json2, params);
  });
  function never(params) {
    return _never(ZodNever, params);
  }
  var ZodVoid = /* @__PURE__ */ $constructor("ZodVoid", (inst, def) => {
    $ZodVoid.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => voidProcessor(inst, ctx, json2, params);
  });
  function _void2(params) {
    return _void(ZodVoid, params);
  }
  var ZodDate = /* @__PURE__ */ $constructor("ZodDate", (inst, def) => {
    $ZodDate.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => dateProcessor(inst, ctx, json2, params);
    inst.min = (value, params) => inst.check(_gte(value, params));
    inst.max = (value, params) => inst.check(_lte(value, params));
    const c = inst._zod.bag;
    inst.minDate = c.minimum ? new Date(c.minimum) : null;
    inst.maxDate = c.maximum ? new Date(c.maximum) : null;
  });
  function date3(params) {
    return _date(ZodDate, params);
  }
  var ZodArray = /* @__PURE__ */ $constructor("ZodArray", (inst, def) => {
    $ZodArray.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => arrayProcessor(inst, ctx, json2, params);
    inst.element = def.element;
    _installLazyMethods(inst, "ZodArray", {
      min(n, params) {
        return this.check(_minLength(n, params));
      },
      nonempty(params) {
        return this.check(_minLength(1, params));
      },
      max(n, params) {
        return this.check(_maxLength(n, params));
      },
      length(n, params) {
        return this.check(_length(n, params));
      },
      unwrap() {
        return this.element;
      }
    });
  });
  function array(element, params) {
    return _array(ZodArray, element, params);
  }
  function keyof(schema) {
    const shape = schema._zod.def.shape;
    return _enum2(Object.keys(shape));
  }
  var ZodObject = /* @__PURE__ */ $constructor("ZodObject", (inst, def) => {
    $ZodObjectJIT.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => objectProcessor(inst, ctx, json2, params);
    util_exports.defineLazy(inst, "shape", () => {
      return def.shape;
    });
    _installLazyMethods(inst, "ZodObject", {
      keyof() {
        return _enum2(Object.keys(this._zod.def.shape));
      },
      catchall(catchall) {
        return this.clone({ ...this._zod.def, catchall });
      },
      passthrough() {
        return this.clone({ ...this._zod.def, catchall: unknown() });
      },
      loose() {
        return this.clone({ ...this._zod.def, catchall: unknown() });
      },
      strict() {
        return this.clone({ ...this._zod.def, catchall: never() });
      },
      strip() {
        return this.clone({ ...this._zod.def, catchall: void 0 });
      },
      extend(incoming) {
        return util_exports.extend(this, incoming);
      },
      safeExtend(incoming) {
        return util_exports.safeExtend(this, incoming);
      },
      merge(other) {
        return util_exports.merge(this, other);
      },
      pick(mask) {
        return util_exports.pick(this, mask);
      },
      omit(mask) {
        return util_exports.omit(this, mask);
      },
      partial(...args) {
        return util_exports.partial(ZodOptional, this, args[0]);
      },
      required(...args) {
        return util_exports.required(ZodNonOptional, this, args[0]);
      }
    });
  });
  function object(shape, params) {
    const def = {
      type: "object",
      shape: shape ?? {},
      ...util_exports.normalizeParams(params)
    };
    return new ZodObject(def);
  }
  function strictObject(shape, params) {
    return new ZodObject({
      type: "object",
      shape,
      catchall: never(),
      ...util_exports.normalizeParams(params)
    });
  }
  function looseObject(shape, params) {
    return new ZodObject({
      type: "object",
      shape,
      catchall: unknown(),
      ...util_exports.normalizeParams(params)
    });
  }
  var ZodUnion = /* @__PURE__ */ $constructor("ZodUnion", (inst, def) => {
    $ZodUnion.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => unionProcessor(inst, ctx, json2, params);
    inst.options = def.options;
  });
  function union(options, params) {
    return new ZodUnion({
      type: "union",
      options,
      ...util_exports.normalizeParams(params)
    });
  }
  var ZodXor = /* @__PURE__ */ $constructor("ZodXor", (inst, def) => {
    ZodUnion.init(inst, def);
    $ZodXor.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => unionProcessor(inst, ctx, json2, params);
    inst.options = def.options;
  });
  function xor(options, params) {
    return new ZodXor({
      type: "union",
      options,
      inclusive: false,
      ...util_exports.normalizeParams(params)
    });
  }
  var ZodDiscriminatedUnion = /* @__PURE__ */ $constructor("ZodDiscriminatedUnion", (inst, def) => {
    ZodUnion.init(inst, def);
    $ZodDiscriminatedUnion.init(inst, def);
  });
  function discriminatedUnion(discriminator, options, params) {
    return new ZodDiscriminatedUnion({
      type: "union",
      options,
      discriminator,
      ...util_exports.normalizeParams(params)
    });
  }
  var ZodIntersection = /* @__PURE__ */ $constructor("ZodIntersection", (inst, def) => {
    $ZodIntersection.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => intersectionProcessor(inst, ctx, json2, params);
  });
  function intersection(left, right) {
    return new ZodIntersection({
      type: "intersection",
      left,
      right
    });
  }
  var ZodTuple = /* @__PURE__ */ $constructor("ZodTuple", (inst, def) => {
    $ZodTuple.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => tupleProcessor(inst, ctx, json2, params);
    inst.rest = (rest) => inst.clone({
      ...inst._zod.def,
      rest
    });
  });
  function tuple(items, _paramsOrRest, _params) {
    const hasRest = _paramsOrRest instanceof $ZodType;
    const params = hasRest ? _params : _paramsOrRest;
    const rest = hasRest ? _paramsOrRest : null;
    return new ZodTuple({
      type: "tuple",
      items,
      rest,
      ...util_exports.normalizeParams(params)
    });
  }
  var ZodRecord = /* @__PURE__ */ $constructor("ZodRecord", (inst, def) => {
    $ZodRecord.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => recordProcessor(inst, ctx, json2, params);
    inst.keyType = def.keyType;
    inst.valueType = def.valueType;
  });
  function record(keyType, valueType, params) {
    if (!valueType || !valueType._zod) {
      return new ZodRecord({
        type: "record",
        keyType: string2(),
        valueType: keyType,
        ...util_exports.normalizeParams(valueType)
      });
    }
    return new ZodRecord({
      type: "record",
      keyType,
      valueType,
      ...util_exports.normalizeParams(params)
    });
  }
  function partialRecord(keyType, valueType, params) {
    const k = clone(keyType);
    k._zod.values = void 0;
    return new ZodRecord({
      type: "record",
      keyType: k,
      valueType,
      ...util_exports.normalizeParams(params)
    });
  }
  function looseRecord(keyType, valueType, params) {
    return new ZodRecord({
      type: "record",
      keyType,
      valueType,
      mode: "loose",
      ...util_exports.normalizeParams(params)
    });
  }
  var ZodMap = /* @__PURE__ */ $constructor("ZodMap", (inst, def) => {
    $ZodMap.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => mapProcessor(inst, ctx, json2, params);
    inst.keyType = def.keyType;
    inst.valueType = def.valueType;
    inst.min = (...args) => inst.check(_minSize(...args));
    inst.nonempty = (params) => inst.check(_minSize(1, params));
    inst.max = (...args) => inst.check(_maxSize(...args));
    inst.size = (...args) => inst.check(_size(...args));
  });
  function map(keyType, valueType, params) {
    return new ZodMap({
      type: "map",
      keyType,
      valueType,
      ...util_exports.normalizeParams(params)
    });
  }
  var ZodSet = /* @__PURE__ */ $constructor("ZodSet", (inst, def) => {
    $ZodSet.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => setProcessor(inst, ctx, json2, params);
    inst.min = (...args) => inst.check(_minSize(...args));
    inst.nonempty = (params) => inst.check(_minSize(1, params));
    inst.max = (...args) => inst.check(_maxSize(...args));
    inst.size = (...args) => inst.check(_size(...args));
  });
  function set(valueType, params) {
    return new ZodSet({
      type: "set",
      valueType,
      ...util_exports.normalizeParams(params)
    });
  }
  var ZodEnum = /* @__PURE__ */ $constructor("ZodEnum", (inst, def) => {
    $ZodEnum.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => enumProcessor(inst, ctx, json2, params);
    inst.enum = def.entries;
    inst.options = Object.values(def.entries);
    const keys = new Set(Object.keys(def.entries));
    inst.extract = (values, params) => {
      const newEntries = {};
      for (const value of values) {
        if (keys.has(value)) {
          newEntries[value] = def.entries[value];
        } else
          throw new Error(`Key ${value} not found in enum`);
      }
      return new ZodEnum({
        ...def,
        checks: [],
        ...util_exports.normalizeParams(params),
        entries: newEntries
      });
    };
    inst.exclude = (values, params) => {
      const newEntries = { ...def.entries };
      for (const value of values) {
        if (keys.has(value)) {
          delete newEntries[value];
        } else
          throw new Error(`Key ${value} not found in enum`);
      }
      return new ZodEnum({
        ...def,
        checks: [],
        ...util_exports.normalizeParams(params),
        entries: newEntries
      });
    };
  });
  function _enum2(values, params) {
    const entries = Array.isArray(values) ? Object.fromEntries(values.map((v) => [v, v])) : values;
    return new ZodEnum({
      type: "enum",
      entries,
      ...util_exports.normalizeParams(params)
    });
  }
  function nativeEnum(entries, params) {
    return new ZodEnum({
      type: "enum",
      entries,
      ...util_exports.normalizeParams(params)
    });
  }
  var ZodLiteral = /* @__PURE__ */ $constructor("ZodLiteral", (inst, def) => {
    $ZodLiteral.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => literalProcessor(inst, ctx, json2, params);
    inst.values = new Set(def.values);
    Object.defineProperty(inst, "value", {
      get() {
        if (def.values.length > 1) {
          throw new Error("This schema contains multiple valid literal values. Use `.values` instead.");
        }
        return def.values[0];
      }
    });
  });
  function literal(value, params) {
    return new ZodLiteral({
      type: "literal",
      values: Array.isArray(value) ? value : [value],
      ...util_exports.normalizeParams(params)
    });
  }
  var ZodFile = /* @__PURE__ */ $constructor("ZodFile", (inst, def) => {
    $ZodFile.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => fileProcessor(inst, ctx, json2, params);
    inst.min = (size, params) => inst.check(_minSize(size, params));
    inst.max = (size, params) => inst.check(_maxSize(size, params));
    inst.mime = (types, params) => inst.check(_mime(Array.isArray(types) ? types : [types], params));
  });
  function file(params) {
    return _file(ZodFile, params);
  }
  var ZodTransform = /* @__PURE__ */ $constructor("ZodTransform", (inst, def) => {
    $ZodTransform.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => transformProcessor(inst, ctx, json2, params);
    inst._zod.parse = (payload, _ctx) => {
      if (_ctx.direction === "backward") {
        throw new $ZodEncodeError(inst.constructor.name);
      }
      payload.addIssue = (issue2) => {
        if (typeof issue2 === "string") {
          payload.issues.push(util_exports.issue(issue2, payload.value, def));
        } else {
          const _issue = issue2;
          if (_issue.fatal)
            _issue.continue = false;
          _issue.code ?? (_issue.code = "custom");
          _issue.input ?? (_issue.input = payload.value);
          _issue.inst ?? (_issue.inst = inst);
          payload.issues.push(util_exports.issue(_issue));
        }
      };
      const output = def.transform(payload.value, payload);
      if (output instanceof Promise) {
        return output.then((output2) => {
          payload.value = output2;
          payload.fallback = true;
          return payload;
        });
      }
      payload.value = output;
      payload.fallback = true;
      return payload;
    };
  });
  function transform(fn) {
    return new ZodTransform({
      type: "transform",
      transform: fn
    });
  }
  var ZodOptional = /* @__PURE__ */ $constructor("ZodOptional", (inst, def) => {
    $ZodOptional.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => optionalProcessor(inst, ctx, json2, params);
    inst.unwrap = () => inst._zod.def.innerType;
  });
  function optional(innerType) {
    return new ZodOptional({
      type: "optional",
      innerType
    });
  }
  var ZodExactOptional = /* @__PURE__ */ $constructor("ZodExactOptional", (inst, def) => {
    $ZodExactOptional.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => optionalProcessor(inst, ctx, json2, params);
    inst.unwrap = () => inst._zod.def.innerType;
  });
  function exactOptional(innerType) {
    return new ZodExactOptional({
      type: "optional",
      innerType
    });
  }
  var ZodNullable = /* @__PURE__ */ $constructor("ZodNullable", (inst, def) => {
    $ZodNullable.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => nullableProcessor(inst, ctx, json2, params);
    inst.unwrap = () => inst._zod.def.innerType;
  });
  function nullable(innerType) {
    return new ZodNullable({
      type: "nullable",
      innerType
    });
  }
  function nullish2(innerType) {
    return optional(nullable(innerType));
  }
  var ZodDefault = /* @__PURE__ */ $constructor("ZodDefault", (inst, def) => {
    $ZodDefault.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => defaultProcessor(inst, ctx, json2, params);
    inst.unwrap = () => inst._zod.def.innerType;
    inst.removeDefault = inst.unwrap;
  });
  function _default2(innerType, defaultValue) {
    return new ZodDefault({
      type: "default",
      innerType,
      get defaultValue() {
        return typeof defaultValue === "function" ? defaultValue() : util_exports.shallowClone(defaultValue);
      }
    });
  }
  var ZodPrefault = /* @__PURE__ */ $constructor("ZodPrefault", (inst, def) => {
    $ZodPrefault.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => prefaultProcessor(inst, ctx, json2, params);
    inst.unwrap = () => inst._zod.def.innerType;
  });
  function prefault(innerType, defaultValue) {
    return new ZodPrefault({
      type: "prefault",
      innerType,
      get defaultValue() {
        return typeof defaultValue === "function" ? defaultValue() : util_exports.shallowClone(defaultValue);
      }
    });
  }
  var ZodNonOptional = /* @__PURE__ */ $constructor("ZodNonOptional", (inst, def) => {
    $ZodNonOptional.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => nonoptionalProcessor(inst, ctx, json2, params);
    inst.unwrap = () => inst._zod.def.innerType;
  });
  function nonoptional(innerType, params) {
    return new ZodNonOptional({
      type: "nonoptional",
      innerType,
      ...util_exports.normalizeParams(params)
    });
  }
  var ZodSuccess = /* @__PURE__ */ $constructor("ZodSuccess", (inst, def) => {
    $ZodSuccess.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => successProcessor(inst, ctx, json2, params);
    inst.unwrap = () => inst._zod.def.innerType;
  });
  function success(innerType) {
    return new ZodSuccess({
      type: "success",
      innerType
    });
  }
  var ZodCatch = /* @__PURE__ */ $constructor("ZodCatch", (inst, def) => {
    $ZodCatch.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => catchProcessor(inst, ctx, json2, params);
    inst.unwrap = () => inst._zod.def.innerType;
    inst.removeCatch = inst.unwrap;
  });
  function _catch2(innerType, catchValue) {
    return new ZodCatch({
      type: "catch",
      innerType,
      catchValue: typeof catchValue === "function" ? catchValue : () => catchValue
    });
  }
  var ZodNaN = /* @__PURE__ */ $constructor("ZodNaN", (inst, def) => {
    $ZodNaN.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => nanProcessor(inst, ctx, json2, params);
  });
  function nan(params) {
    return _nan(ZodNaN, params);
  }
  var ZodPipe = /* @__PURE__ */ $constructor("ZodPipe", (inst, def) => {
    $ZodPipe.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => pipeProcessor(inst, ctx, json2, params);
    inst.in = def.in;
    inst.out = def.out;
  });
  function pipe(in_, out) {
    return new ZodPipe({
      type: "pipe",
      in: in_,
      out
      // ...util.normalizeParams(params),
    });
  }
  var ZodCodec = /* @__PURE__ */ $constructor("ZodCodec", (inst, def) => {
    ZodPipe.init(inst, def);
    $ZodCodec.init(inst, def);
  });
  function codec(in_, out, params) {
    return new ZodCodec({
      type: "pipe",
      in: in_,
      out,
      transform: params.decode,
      reverseTransform: params.encode
    });
  }
  function invertCodec(codec2) {
    const def = codec2._zod.def;
    return new ZodCodec({
      type: "pipe",
      in: def.out,
      out: def.in,
      transform: def.reverseTransform,
      reverseTransform: def.transform
    });
  }
  var ZodPreprocess = /* @__PURE__ */ $constructor("ZodPreprocess", (inst, def) => {
    ZodPipe.init(inst, def);
    $ZodPreprocess.init(inst, def);
  });
  var ZodReadonly = /* @__PURE__ */ $constructor("ZodReadonly", (inst, def) => {
    $ZodReadonly.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => readonlyProcessor(inst, ctx, json2, params);
    inst.unwrap = () => inst._zod.def.innerType;
  });
  function readonly(innerType) {
    return new ZodReadonly({
      type: "readonly",
      innerType
    });
  }
  var ZodTemplateLiteral = /* @__PURE__ */ $constructor("ZodTemplateLiteral", (inst, def) => {
    $ZodTemplateLiteral.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => templateLiteralProcessor(inst, ctx, json2, params);
  });
  function templateLiteral(parts, params) {
    return new ZodTemplateLiteral({
      type: "template_literal",
      parts,
      ...util_exports.normalizeParams(params)
    });
  }
  var ZodLazy = /* @__PURE__ */ $constructor("ZodLazy", (inst, def) => {
    $ZodLazy.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => lazyProcessor(inst, ctx, json2, params);
    inst.unwrap = () => inst._zod.def.getter();
  });
  function lazy(getter) {
    return new ZodLazy({
      type: "lazy",
      getter
    });
  }
  var ZodPromise = /* @__PURE__ */ $constructor("ZodPromise", (inst, def) => {
    $ZodPromise.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => promiseProcessor(inst, ctx, json2, params);
    inst.unwrap = () => inst._zod.def.innerType;
  });
  function promise(innerType) {
    return new ZodPromise({
      type: "promise",
      innerType
    });
  }
  var ZodFunction = /* @__PURE__ */ $constructor("ZodFunction", (inst, def) => {
    $ZodFunction.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => functionProcessor(inst, ctx, json2, params);
  });
  function _function(params) {
    return new ZodFunction({
      type: "function",
      input: Array.isArray(params?.input) ? tuple(params?.input) : params?.input ?? array(unknown()),
      output: params?.output ?? unknown()
    });
  }
  var ZodCustom = /* @__PURE__ */ $constructor("ZodCustom", (inst, def) => {
    $ZodCustom.init(inst, def);
    ZodType.init(inst, def);
    inst._zod.processJSONSchema = (ctx, json2, params) => customProcessor(inst, ctx, json2, params);
  });
  function check(fn) {
    const ch = new $ZodCheck({
      check: "custom"
      // ...util.normalizeParams(params),
    });
    ch._zod.check = fn;
    return ch;
  }
  function custom(fn, _params) {
    return _custom(ZodCustom, fn ?? (() => true), _params);
  }
  function refine(fn, _params = {}) {
    return _refine(ZodCustom, fn, _params);
  }
  function superRefine(fn, params) {
    return _superRefine(fn, params);
  }
  var describe2 = describe;
  var meta2 = meta;
  function _instanceof(cls, params = {}) {
    const inst = new ZodCustom({
      type: "custom",
      check: "custom",
      fn: (data) => data instanceof cls,
      abort: true,
      ...util_exports.normalizeParams(params)
    });
    inst._zod.bag.Class = cls;
    inst._zod.check = (payload) => {
      if (!(payload.value instanceof cls)) {
        payload.issues.push({
          code: "invalid_type",
          expected: cls.name,
          input: payload.value,
          inst,
          path: [...inst._zod.def.path ?? []]
        });
      }
    };
    return inst;
  }
  var stringbool = (...args) => _stringbool({
    Codec: ZodCodec,
    Boolean: ZodBoolean,
    String: ZodString
  }, ...args);
  function json(params) {
    const jsonSchema = lazy(() => {
      return union([string2(params), number2(), boolean2(), _null3(), array(jsonSchema), record(string2(), jsonSchema)]);
    });
    return jsonSchema;
  }
  function preprocess(fn, schema) {
    return new ZodPreprocess({
      type: "pipe",
      in: transform(fn),
      out: schema
    });
  }

  // ThirdParty/REA/dependencies/zod/v4/classic/compat.js
  init_runtime();
  var ZodIssueCode = {
    invalid_type: "invalid_type",
    too_big: "too_big",
    too_small: "too_small",
    invalid_format: "invalid_format",
    not_multiple_of: "not_multiple_of",
    unrecognized_keys: "unrecognized_keys",
    invalid_union: "invalid_union",
    invalid_key: "invalid_key",
    invalid_element: "invalid_element",
    invalid_value: "invalid_value",
    custom: "custom"
  };
  function setErrorMap(map2) {
    config({
      customError: map2
    });
  }
  function getErrorMap() {
    return config().customError;
  }
  var ZodFirstPartyTypeKind;
  /* @__PURE__ */ (function(ZodFirstPartyTypeKind2) {
  })(ZodFirstPartyTypeKind || (ZodFirstPartyTypeKind = {}));

  // ThirdParty/REA/dependencies/zod/v4/classic/from-json-schema.js
  init_runtime();
  var z = {
    ...schemas_exports2,
    ...checks_exports2,
    iso: iso_exports
  };
  var RECOGNIZED_KEYS = /* @__PURE__ */ new Set([
    // Schema identification
    "$schema",
    "$ref",
    "$defs",
    "definitions",
    // Core schema keywords
    "$id",
    "id",
    "$comment",
    "$anchor",
    "$vocabulary",
    "$dynamicRef",
    "$dynamicAnchor",
    // Type
    "type",
    "enum",
    "const",
    // Composition
    "anyOf",
    "oneOf",
    "allOf",
    "not",
    // Object
    "properties",
    "required",
    "additionalProperties",
    "patternProperties",
    "propertyNames",
    "minProperties",
    "maxProperties",
    // Array
    "items",
    "prefixItems",
    "additionalItems",
    "minItems",
    "maxItems",
    "uniqueItems",
    "contains",
    "minContains",
    "maxContains",
    // String
    "minLength",
    "maxLength",
    "pattern",
    "format",
    // Number
    "minimum",
    "maximum",
    "exclusiveMinimum",
    "exclusiveMaximum",
    "multipleOf",
    // Already handled metadata
    "description",
    "default",
    // Content
    "contentEncoding",
    "contentMediaType",
    "contentSchema",
    // Unsupported (error-throwing)
    "unevaluatedItems",
    "unevaluatedProperties",
    "if",
    "then",
    "else",
    "dependentSchemas",
    "dependentRequired",
    // OpenAPI
    "nullable",
    "readOnly"
  ]);
  function detectVersion(schema, defaultTarget) {
    const $schema = schema.$schema;
    if ($schema === "https://json-schema.org/draft/2020-12/schema") {
      return "draft-2020-12";
    }
    if ($schema === "http://json-schema.org/draft-07/schema#") {
      return "draft-7";
    }
    if ($schema === "http://json-schema.org/draft-04/schema#") {
      return "draft-4";
    }
    return defaultTarget ?? "draft-2020-12";
  }
  function resolveRef(ref, ctx) {
    if (!ref.startsWith("#")) {
      throw new Error("External $ref is not supported, only local refs (#/...) are allowed");
    }
    const path3 = ref.slice(1).split("/").filter(Boolean);
    if (path3.length === 0) {
      return ctx.rootSchema;
    }
    const defsKey = ctx.version === "draft-2020-12" ? "$defs" : "definitions";
    if (path3[0] === defsKey) {
      const key = path3[1];
      if (!key || !ctx.defs[key]) {
        throw new Error(`Reference not found: ${ref}`);
      }
      return ctx.defs[key];
    }
    throw new Error(`Reference not found: ${ref}`);
  }
  function convertBaseSchema(schema, ctx) {
    if (schema.not !== void 0) {
      if (typeof schema.not === "object" && Object.keys(schema.not).length === 0) {
        return z.never();
      }
      throw new Error("not is not supported in Zod (except { not: {} } for never)");
    }
    if (schema.unevaluatedItems !== void 0) {
      throw new Error("unevaluatedItems is not supported");
    }
    if (schema.unevaluatedProperties !== void 0) {
      throw new Error("unevaluatedProperties is not supported");
    }
    if (schema.if !== void 0 || schema.then !== void 0 || schema.else !== void 0) {
      throw new Error("Conditional schemas (if/then/else) are not supported");
    }
    if (schema.dependentSchemas !== void 0 || schema.dependentRequired !== void 0) {
      throw new Error("dependentSchemas and dependentRequired are not supported");
    }
    if (schema.$ref) {
      const refPath = schema.$ref;
      if (ctx.refs.has(refPath)) {
        return ctx.refs.get(refPath);
      }
      if (ctx.processing.has(refPath)) {
        return z.lazy(() => {
          if (!ctx.refs.has(refPath)) {
            throw new Error(`Circular reference not resolved: ${refPath}`);
          }
          return ctx.refs.get(refPath);
        });
      }
      ctx.processing.add(refPath);
      const resolved = resolveRef(refPath, ctx);
      const zodSchema2 = convertSchema(resolved, ctx);
      ctx.refs.set(refPath, zodSchema2);
      ctx.processing.delete(refPath);
      return zodSchema2;
    }
    if (schema.enum !== void 0) {
      const enumValues = schema.enum;
      if (ctx.version === "openapi-3.0" && schema.nullable === true && enumValues.length === 1 && enumValues[0] === null) {
        return z.null();
      }
      if (enumValues.length === 0) {
        return z.never();
      }
      if (enumValues.length === 1) {
        return z.literal(enumValues[0]);
      }
      if (enumValues.every((v) => typeof v === "string")) {
        return z.enum(enumValues);
      }
      const literalSchemas = enumValues.map((v) => z.literal(v));
      if (literalSchemas.length < 2) {
        return literalSchemas[0];
      }
      return z.union([literalSchemas[0], literalSchemas[1], ...literalSchemas.slice(2)]);
    }
    if (schema.const !== void 0) {
      return z.literal(schema.const);
    }
    const type = schema.type;
    if (Array.isArray(type)) {
      const typeSchemas = type.map((t) => {
        const typeSchema = { ...schema, type: t };
        return convertBaseSchema(typeSchema, ctx);
      });
      if (typeSchemas.length === 0) {
        return z.never();
      }
      if (typeSchemas.length === 1) {
        return typeSchemas[0];
      }
      return z.union(typeSchemas);
    }
    if (!type) {
      return z.any();
    }
    let zodSchema;
    switch (type) {
      case "string": {
        let stringSchema = z.string();
        if (schema.format) {
          const format = schema.format;
          if (format === "email") {
            stringSchema = stringSchema.check(z.email());
          } else if (format === "uri" || format === "uri-reference") {
            stringSchema = stringSchema.check(z.url());
          } else if (format === "uuid" || format === "guid") {
            stringSchema = stringSchema.check(z.uuid());
          } else if (format === "date-time") {
            stringSchema = stringSchema.check(z.iso.datetime());
          } else if (format === "date") {
            stringSchema = stringSchema.check(z.iso.date());
          } else if (format === "time") {
            stringSchema = stringSchema.check(z.iso.time());
          } else if (format === "duration") {
            stringSchema = stringSchema.check(z.iso.duration());
          } else if (format === "ipv4") {
            stringSchema = stringSchema.check(z.ipv4());
          } else if (format === "ipv6") {
            stringSchema = stringSchema.check(z.ipv6());
          } else if (format === "mac") {
            stringSchema = stringSchema.check(z.mac());
          } else if (format === "cidr") {
            stringSchema = stringSchema.check(z.cidrv4());
          } else if (format === "cidr-v6") {
            stringSchema = stringSchema.check(z.cidrv6());
          } else if (format === "base64") {
            stringSchema = stringSchema.check(z.base64());
          } else if (format === "base64url") {
            stringSchema = stringSchema.check(z.base64url());
          } else if (format === "e164") {
            stringSchema = stringSchema.check(z.e164());
          } else if (format === "jwt") {
            stringSchema = stringSchema.check(z.jwt());
          } else if (format === "emoji") {
            stringSchema = stringSchema.check(z.emoji());
          } else if (format === "nanoid") {
            stringSchema = stringSchema.check(z.nanoid());
          } else if (format === "cuid") {
            stringSchema = stringSchema.check(z.cuid());
          } else if (format === "cuid2") {
            stringSchema = stringSchema.check(z.cuid2());
          } else if (format === "ulid") {
            stringSchema = stringSchema.check(z.ulid());
          } else if (format === "xid") {
            stringSchema = stringSchema.check(z.xid());
          } else if (format === "ksuid") {
            stringSchema = stringSchema.check(z.ksuid());
          }
        }
        if (typeof schema.minLength === "number") {
          stringSchema = stringSchema.min(schema.minLength);
        }
        if (typeof schema.maxLength === "number") {
          stringSchema = stringSchema.max(schema.maxLength);
        }
        if (schema.pattern) {
          stringSchema = stringSchema.regex(new RegExp(schema.pattern));
        }
        zodSchema = stringSchema;
        break;
      }
      case "number":
      case "integer": {
        let numberSchema = type === "integer" ? z.number().int() : z.number();
        if (typeof schema.minimum === "number") {
          numberSchema = numberSchema.min(schema.minimum);
        }
        if (typeof schema.maximum === "number") {
          numberSchema = numberSchema.max(schema.maximum);
        }
        if (typeof schema.exclusiveMinimum === "number") {
          numberSchema = numberSchema.gt(schema.exclusiveMinimum);
        } else if (schema.exclusiveMinimum === true && typeof schema.minimum === "number") {
          numberSchema = numberSchema.gt(schema.minimum);
        }
        if (typeof schema.exclusiveMaximum === "number") {
          numberSchema = numberSchema.lt(schema.exclusiveMaximum);
        } else if (schema.exclusiveMaximum === true && typeof schema.maximum === "number") {
          numberSchema = numberSchema.lt(schema.maximum);
        }
        if (typeof schema.multipleOf === "number") {
          numberSchema = numberSchema.multipleOf(schema.multipleOf);
        }
        zodSchema = numberSchema;
        break;
      }
      case "boolean": {
        zodSchema = z.boolean();
        break;
      }
      case "null": {
        zodSchema = z.null();
        break;
      }
      case "object": {
        const shape = {};
        const properties = schema.properties || {};
        const requiredSet = new Set(schema.required || []);
        for (const [key, propSchema] of Object.entries(properties)) {
          const propZodSchema = convertSchema(propSchema, ctx);
          shape[key] = requiredSet.has(key) ? propZodSchema : propZodSchema.optional();
        }
        if (schema.propertyNames) {
          const keySchema = convertSchema(schema.propertyNames, ctx);
          const valueSchema = schema.additionalProperties && typeof schema.additionalProperties === "object" ? convertSchema(schema.additionalProperties, ctx) : z.any();
          if (Object.keys(shape).length === 0) {
            zodSchema = z.record(keySchema, valueSchema);
            break;
          }
          const objectSchema2 = z.object(shape).passthrough();
          const recordSchema3 = z.looseRecord(keySchema, valueSchema);
          zodSchema = z.intersection(objectSchema2, recordSchema3);
          break;
        }
        if (schema.patternProperties) {
          const patternProps = schema.patternProperties;
          const patternKeys = Object.keys(patternProps);
          const looseRecords = [];
          for (const pattern of patternKeys) {
            const patternValue = convertSchema(patternProps[pattern], ctx);
            const keySchema = z.string().regex(new RegExp(pattern));
            looseRecords.push(z.looseRecord(keySchema, patternValue));
          }
          const schemasToIntersect = [];
          if (Object.keys(shape).length > 0) {
            schemasToIntersect.push(z.object(shape).passthrough());
          }
          schemasToIntersect.push(...looseRecords);
          if (schemasToIntersect.length === 0) {
            zodSchema = z.object({}).passthrough();
          } else if (schemasToIntersect.length === 1) {
            zodSchema = schemasToIntersect[0];
          } else {
            let result = z.intersection(schemasToIntersect[0], schemasToIntersect[1]);
            for (let i = 2; i < schemasToIntersect.length; i++) {
              result = z.intersection(result, schemasToIntersect[i]);
            }
            zodSchema = result;
          }
          break;
        }
        const objectSchema = z.object(shape);
        if (schema.additionalProperties === false) {
          zodSchema = objectSchema.strict();
        } else if (typeof schema.additionalProperties === "object") {
          zodSchema = objectSchema.catchall(convertSchema(schema.additionalProperties, ctx));
        } else {
          zodSchema = objectSchema.passthrough();
        }
        break;
      }
      case "array": {
        const prefixItems = schema.prefixItems;
        const items = schema.items;
        if (prefixItems && Array.isArray(prefixItems)) {
          const tupleItems = prefixItems.map((item) => convertSchema(item, ctx));
          const rest = items && typeof items === "object" && !Array.isArray(items) ? convertSchema(items, ctx) : void 0;
          if (rest) {
            zodSchema = z.tuple(tupleItems).rest(rest);
          } else {
            zodSchema = z.tuple(tupleItems);
          }
          if (typeof schema.minItems === "number") {
            zodSchema = zodSchema.check(z.minLength(schema.minItems));
          }
          if (typeof schema.maxItems === "number") {
            zodSchema = zodSchema.check(z.maxLength(schema.maxItems));
          }
        } else if (Array.isArray(items)) {
          const tupleItems = items.map((item) => convertSchema(item, ctx));
          const rest = schema.additionalItems && typeof schema.additionalItems === "object" ? convertSchema(schema.additionalItems, ctx) : void 0;
          if (rest) {
            zodSchema = z.tuple(tupleItems).rest(rest);
          } else {
            zodSchema = z.tuple(tupleItems);
          }
          if (typeof schema.minItems === "number") {
            zodSchema = zodSchema.check(z.minLength(schema.minItems));
          }
          if (typeof schema.maxItems === "number") {
            zodSchema = zodSchema.check(z.maxLength(schema.maxItems));
          }
        } else if (items !== void 0) {
          const element = convertSchema(items, ctx);
          let arraySchema = z.array(element);
          if (typeof schema.minItems === "number") {
            arraySchema = arraySchema.min(schema.minItems);
          }
          if (typeof schema.maxItems === "number") {
            arraySchema = arraySchema.max(schema.maxItems);
          }
          zodSchema = arraySchema;
        } else {
          zodSchema = z.array(z.any());
        }
        break;
      }
      default:
        throw new Error(`Unsupported type: ${type}`);
    }
    return zodSchema;
  }
  function convertSchema(schema, ctx) {
    if (typeof schema === "boolean") {
      return schema ? z.any() : z.never();
    }
    let baseSchema = convertBaseSchema(schema, ctx);
    const hasExplicitType = schema.type || schema.enum !== void 0 || schema.const !== void 0;
    if (schema.anyOf && Array.isArray(schema.anyOf)) {
      const options = schema.anyOf.map((s) => convertSchema(s, ctx));
      const anyOfUnion = z.union(options);
      baseSchema = hasExplicitType ? z.intersection(baseSchema, anyOfUnion) : anyOfUnion;
    }
    if (schema.oneOf && Array.isArray(schema.oneOf)) {
      const options = schema.oneOf.map((s) => convertSchema(s, ctx));
      const oneOfUnion = z.xor(options);
      baseSchema = hasExplicitType ? z.intersection(baseSchema, oneOfUnion) : oneOfUnion;
    }
    if (schema.allOf && Array.isArray(schema.allOf)) {
      if (schema.allOf.length === 0) {
        baseSchema = hasExplicitType ? baseSchema : z.any();
      } else {
        let result = hasExplicitType ? baseSchema : convertSchema(schema.allOf[0], ctx);
        const startIdx = hasExplicitType ? 0 : 1;
        for (let i = startIdx; i < schema.allOf.length; i++) {
          result = z.intersection(result, convertSchema(schema.allOf[i], ctx));
        }
        baseSchema = result;
      }
    }
    if (schema.nullable === true && ctx.version === "openapi-3.0") {
      baseSchema = z.nullable(baseSchema);
    }
    if (schema.readOnly === true) {
      baseSchema = z.readonly(baseSchema);
    }
    if (schema.default !== void 0) {
      baseSchema = baseSchema.default(schema.default);
    }
    const extraMeta = {};
    const coreMetadataKeys = ["$id", "id", "$comment", "$anchor", "$vocabulary", "$dynamicRef", "$dynamicAnchor"];
    for (const key of coreMetadataKeys) {
      if (key in schema) {
        extraMeta[key] = schema[key];
      }
    }
    const contentMetadataKeys = ["contentEncoding", "contentMediaType", "contentSchema"];
    for (const key of contentMetadataKeys) {
      if (key in schema) {
        extraMeta[key] = schema[key];
      }
    }
    for (const key of Object.keys(schema)) {
      if (!RECOGNIZED_KEYS.has(key)) {
        extraMeta[key] = schema[key];
      }
    }
    if (Object.keys(extraMeta).length > 0) {
      ctx.registry.add(baseSchema, extraMeta);
    }
    if (schema.description) {
      baseSchema = baseSchema.describe(schema.description);
    }
    return baseSchema;
  }
  function fromJSONSchema(schema, params) {
    if (typeof schema === "boolean") {
      return schema ? z.any() : z.never();
    }
    let normalized;
    try {
      normalized = JSON.parse(JSON.stringify(schema));
    } catch {
      throw new Error("fromJSONSchema input is not valid JSON (possibly cyclic); use $defs/$ref for recursive schemas");
    }
    const version2 = detectVersion(normalized, params?.defaultTarget);
    const defs = normalized.$defs || normalized.definitions || {};
    const ctx = {
      version: version2,
      defs,
      refs: /* @__PURE__ */ new Map(),
      processing: /* @__PURE__ */ new Set(),
      rootSchema: normalized,
      registry: params?.registry ?? globalRegistry
    };
    return convertSchema(normalized, ctx);
  }

  // ThirdParty/REA/dependencies/zod/v4/classic/coerce.js
  var coerce_exports = {};
  __export(coerce_exports, {
    bigint: () => bigint3,
    boolean: () => boolean3,
    date: () => date4,
    number: () => number3,
    string: () => string3
  });
  init_runtime();
  function string3(params) {
    return _coercedString(ZodString, params);
  }
  function number3(params) {
    return _coercedNumber(ZodNumber, params);
  }
  function boolean3(params) {
    return _coercedBoolean(ZodBoolean, params);
  }
  function bigint3(params) {
    return _coercedBigint(ZodBigInt, params);
  }
  function date4(params) {
    return _coercedDate(ZodDate, params);
  }

  // ThirdParty/REA/dependencies/zod/v4/classic/external.js
  config(en_default());

  // ThirdParty/REA/upstream/src/domain/apple/appleBundleAnatomy.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/digests.ts
  init_runtime();
  var SHA256_PATTERN = /^[a-f0-9]{64}$/u;
  var digestSchema = external_exports.string().regex(SHA256_PATTERN);
  var prefixedDigestSchema = (prefix) => external_exports.string().regex(
    new RegExp(`^${prefix}_[a-f0-9]{64}$`, "u"),
    `Expected a ${prefix}_ prefixed lowercase sha256 digest`
  );

  // ThirdParty/REA/upstream/src/domain/apple/appleBundleAnatomy.ts
  var pathSchema = external_exports.string().min(1);
  var BUNDLE_EXTENSION = /\.(?:app|appex|xpc|framework|systemextension|dext|bundle|plugin|qlgenerator|mdimporter)$/iu;
  var MACH_O_FORMATS = ["mach-o", "mach-o-universal"];
  var appleComponentSchema = external_exports.strictObject({
    path: pathSchema,
    artifact_id: prefixedDigestSchema("art"),
    sha256: digestSchema,
    format: external_exports.string().min(1)
  });
  var appleBundleSchema = external_exports.strictObject({
    path: pathSchema,
    parent_path: pathSchema.nullable(),
    layout: external_exports.enum(["shallow", "macos-deep", "versioned-framework"]),
    role: external_exports.enum([
      "application",
      "app-extension",
      "xpc-service",
      "framework",
      "login-item",
      "system-extension",
      "driver-extension",
      "plug-in",
      "resource-bundle",
      "bundle",
      "helper-application",
      "nested-application"
    ]),
    role_basis: external_exports.literal("path-convention"),
    info_plist_path: pathSchema.nullable(),
    executable_candidates: external_exports.array(pathSchema),
    signing_paths: external_exports.array(pathSchema)
  });
  var isSidecar = (path3) => {
    const segments = path3.split("/");
    return segments.includes("__MACOSX") || (segments.at(-1) ?? "").startsWith("._");
  };
  var isWithin = (path3, root) => root === "." || path3 === root || path3.startsWith(`${root}/`);
  var applicationRoots = (entries, subject) => {
    if (subject.format === "directory" && /\.app$/iu.test(subject.name))
      return ["."];
    const found = /* @__PURE__ */ new Set();
    for (const { path: path3 } of entries) {
      if (isSidecar(path3)) continue;
      const ios = /^(Payload\/[^/]+\.app)(?:\/|$)/u.exec(path3);
      if (ios?.[1] !== void 0) {
        found.add(ios[1]);
        continue;
      }
      const segments = path3.split("/");
      const index = segments.findIndex(
        (segment, position) => /\.app$/iu.test(segment) && segments[position + 1] === "Contents"
      );
      if (index >= 0) found.add(segments.slice(0, index + 1).join("/"));
    }
    const roots = [...found];
    return roots.filter(
      (root) => !roots.some((other) => other !== root && isWithin(root, other))
    ).sort(compare);
  };
  var detectBundles = (entries, roots) => {
    const paths = new Set(roots);
    for (const { path: path3, kind } of entries) {
      if (isSidecar(path3)) continue;
      const root = roots.find((candidate) => isWithin(path3, candidate));
      if (root === void 0) continue;
      const segments = path3.split("/");
      const start = root === "." ? 0 : root.split("/").length;
      for (let index = start; index < segments.length; index++) {
        const segment = segments[index] ?? "";
        const leaf = index === segments.length - 1;
        if (BUNDLE_EXTENSION.test(segment) && (!leaf || kind === "directory"))
          paths.add(segments.slice(0, index + 1).join("/"));
      }
    }
    const tree = indexTree(entries);
    return [...paths].sort(compare).map((path3) => {
      const layout = bundleLayout(path3, tree);
      return {
        path: path3,
        parent_path: enclosingBundle(path3, paths),
        layout,
        role: roots.includes(path3) ? "application" : bundleRole(path3),
        role_basis: "path-convention",
        info_plist_path: infoPlistPath(path3, layout, tree),
        executable_candidates: executableCandidates(path3, layout, tree),
        signing_paths: signingPaths(path3, layout, tree)
      };
    });
  };
  var indexTree = (entries) => {
    const children = /* @__PURE__ */ new Map();
    const files = /* @__PURE__ */ new Map();
    const directories = /* @__PURE__ */ new Set();
    for (const { path: path3, kind, component } of entries) {
      if (isSidecar(path3)) continue;
      if (kind === "file" && component !== void 0) files.set(path3, component);
      if (kind === "directory") directories.add(path3);
      const segments = path3.split("/");
      let parent = "";
      for (const segment of segments) {
        const names = children.get(parent) ?? /* @__PURE__ */ new Set();
        names.add(segment);
        children.set(parent, names);
        parent = joinPath(parent, segment);
        if (parent !== path3) directories.add(parent);
      }
    }
    return { children, files, directories };
  };
  var joinPath = (directory, name) => directory === "" ? name : `${directory}/${name}`;
  var directoryOf = (bundle) => bundle === "." ? "" : bundle;
  var enclosingBundle = (path3, bundles) => {
    if (path3 === ".") return null;
    const segments = path3.split("/");
    for (let length = segments.length - 1; length > 0; length--) {
      const candidate = segments.slice(0, length).join("/");
      if (bundles.has(candidate)) return candidate;
    }
    return bundles.has(".") ? "." : null;
  };
  var bundleLayout = (bundle, tree) => {
    const names = tree.children.get(directoryOf(bundle));
    if (names?.has("Contents") === true) return "macos-deep";
    if (names?.has("Versions") === true) return "versioned-framework";
    return "shallow";
  };
  var bundleRole = (bundle) => {
    const segments = bundle.split("/");
    const name = (segments.at(-1) ?? "").toLowerCase();
    const container = segments.at(-2);
    if (name.endsWith(".appex")) return "app-extension";
    if (name.endsWith(".xpc")) return "xpc-service";
    if (name.endsWith(".framework")) return "framework";
    if (name.endsWith(".systemextension")) return "system-extension";
    if (name.endsWith(".dext")) return "driver-extension";
    if (name.endsWith(".bundle")) {
      if (container === "PlugIns") return "plug-in";
      return container === "Resources" ? "resource-bundle" : "bundle";
    }
    if (!name.endsWith(".app")) return "plug-in";
    if (container === "LoginItems" && segments.at(-3) === "Library")
      return "login-item";
    if (container === "Helpers") return "helper-application";
    return "nested-application";
  };
  var directFiles = (directory, tree) => [...tree.children.get(directory) ?? []].map((name) => joinPath(directory, name)).filter((path3) => tree.files.has(path3)).sort(compare);
  var contentDirectories = (bundle, layout, tree) => {
    const directory = directoryOf(bundle);
    if (layout === "macos-deep") return [joinPath(directory, "Contents")];
    if (layout === "shallow") return [directory];
    const versions = joinPath(directory, "Versions");
    return [...tree.children.get(versions) ?? []].filter((version2) => version2 !== "Current").map((version2) => joinPath(versions, version2)).filter((version2) => tree.directories.has(version2)).sort(compare);
  };
  var infoPlistPath = (bundle, layout, tree) => {
    const directories = contentDirectories(bundle, layout, tree);
    if (directories.length !== 1) return null;
    const candidates = directories.map(
      (directory) => joinPath(
        directory,
        layout === "versioned-framework" ? "Resources/Info.plist" : "Info.plist"
      )
    ).filter((path3) => tree.files.has(path3));
    return candidates.length === 1 ? candidates[0] ?? null : null;
  };
  var executableCandidates = (bundle, layout, tree) => contentDirectories(bundle, layout, tree).flatMap(
    (directory) => directFiles(
      layout === "macos-deep" ? joinPath(directory, "MacOS") : directory,
      tree
    )
  ).filter(
    (path3) => MACH_O_FORMATS.includes(tree.files.get(path3)?.format ?? "")
  );
  var signingPaths = (bundle, layout, tree) => contentDirectories(bundle, layout, tree).flatMap((directory) => [
    joinPath(directory, "_CodeSignature/CodeResources"),
    joinPath(directory, "embedded.provisionprofile"),
    joinPath(directory, "embedded.mobileprovision")
  ]).filter((path3) => tree.files.has(path3)).sort(compare);
  var compare = (left, right) => left < right ? -1 : left > right ? 1 : 0;

  // ThirdParty/REA/upstream/src/domain/apple/dylibResolution.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/apple/dyldPaths.ts
  init_runtime();
  var MAX_SYMLINK_HOPS = 32;
  var resolveTreePath = async (view, input) => {
    const pending = segmentsOf(input);
    const resolved = [];
    let last;
    let hops = 0;
    while (pending.length > 0) {
      const segment = pending.shift() ?? "";
      if (segment === "..") {
        if (resolved.length === 0) return { kind: "escapes" };
        resolved.pop();
        last = { kind: "directory" };
        continue;
      }
      const path3 = [...resolved, segment].join("/");
      const entry = await view.entry(path3);
      if (entry === void 0) return { kind: "absent" };
      if (entry.kind === "symlink") {
        hops += 1;
        if (hops > MAX_SYMLINK_HOPS) return { kind: "absent" };
        if (entry.target.startsWith("/")) return { kind: "escapes" };
        pending.unshift(...segmentsOf(entry.target));
        continue;
      }
      if (entry.kind === "file" && pending.length > 0) return { kind: "absent" };
      resolved.push(segment);
      last = entry;
    }
    return last?.kind === "file" ? { kind: "file", path: resolved.join("/") } : { kind: "not-file" };
  };
  var segmentsOf = (path3) => path3.split("/").filter((segment) => segment !== "" && segment !== ".");
  var directoryOf2 = (path3) => {
    const index = path3.lastIndexOf("/");
    return index < 0 ? "" : path3.slice(0, index);
  };
  var joinPath2 = (directory, rest) => directory === "" ? rest : rest === "" ? directory : `${directory}/${rest}`;
  var expandPrefix = (raw, context) => {
    const variable = /^@(executable_path|loader_path)(?:\/(.*))?$/u.exec(raw);
    if (variable !== null) {
      const rest = variable[2] ?? "";
      if (variable[1] === "loader_path")
        return { scope: "target", path: joinPath2(context.ownerDirectory, rest) };
      return context.executable === null ? { scope: "undetermined", path: raw } : {
        scope: "target",
        path: joinPath2(directoryOf2(context.executable), rest)
      };
    }
    if (raw.startsWith("/")) return { scope: "outside", path: raw };
    return { scope: "undetermined", path: raw };
  };
  var COMPATIBLE_ARCHITECTURES = {
    x86_64h: ["x86_64h", "x86_64"]
  };
  var compatibleSlice = (slices, process2) => {
    for (const architecture of COMPATIBLE_ARCHITECTURES[process2] ?? [process2]) {
      const slice = slices.find((item) => item.architecture === architecture);
      if (slice !== void 0) return slice;
    }
    return void 0;
  };

  // ThirdParty/REA/upstream/src/domain/apple/dyldEnvironment.ts
  init_runtime();
  var embeddedDyldOverrides = (environment, platforms) => {
    const overrides = [];
    for (const setting of environment) {
      const delimiter = setting.indexOf("=");
      if (delimiter <= 0) continue;
      const variable = setting.slice(0, delimiter);
      const value = setting.slice(delimiter + 1);
      const effect = overrideEffect(variable, value);
      if (effect === void 0) continue;
      if (variable === "DYLD_ROOT_PATH" && platforms.length > 0 && platforms.every((platform) => platform >= 1 && platform <= 12) && !platforms.some((platform) => [7, 8, 9, 12].includes(platform)))
        continue;
      overrides.push({ variable, value, ...effect });
    }
    return overrides;
  };
  var overrideEffect = (variable, value) => {
    switch (variable) {
      // Empty directory components still produce /leaf candidates in dyld.
      // In particular, an empty fallback value is not a no-op.
      case "DYLD_LIBRARY_PATH":
        return { phase: "override", scope: "library" };
      case "DYLD_FRAMEWORK_PATH":
        return { phase: "override", scope: "framework" };
      case "DYLD_FALLBACK_LIBRARY_PATH":
        return { phase: "fallback", scope: "library" };
      case "DYLD_FALLBACK_FRAMEWORK_PATH":
        return { phase: "fallback", scope: "framework" };
      // Versioned paths map discovered images to their reported install names,
      // so the directory's kind does not establish the replaced image's kind.
      case "DYLD_VERSIONED_LIBRARY_PATH":
      case "DYLD_VERSIONED_FRAMEWORK_PATH":
      case "DYLD_IMAGE_SUFFIX":
        return /[^:]/u.test(value) ? { phase: "override", scope: "all" } : void 0;
      case "DYLD_INSERT_LIBRARIES":
        return value === "" ? void 0 : { phase: "override", scope: "all" };
      case "DYLD_ROOT_PATH":
      case "DYLD_OVERLAY_PATH":
        return value === "" ? void 0 : { phase: "override", scope: "prefix" };
      default:
        return void 0;
    }
  };
  var isFrameworkInstallName = (name, overrides) => {
    const separator = name.lastIndexOf(".framework/");
    if (separator < 0) return false;
    const framework = name.slice(0, separator).split("/").at(-1);
    const leaf = name.slice(name.lastIndexOf("/") + 1);
    return leaf === framework || overrides.some(
      ({ variable, value }) => variable === "DYLD_IMAGE_SUFFIX" && leaf === `${framework}${value}`
    );
  };
  var hasApplicableDyldOverrides = (overrides, installName, ordinarySearchFoundImage) => {
    const kind = isFrameworkInstallName(installName, overrides) ? "framework" : "library";
    return overrides.some(
      ({ phase, scope }) => (phase === "override" || !ordinarySearchFoundImage) && (scope === "all" || scope === kind || scope === "prefix" && !installName.startsWith("@"))
    );
  };

  // ThirdParty/REA/upstream/src/domain/apple/dylibResolutionFindings.ts
  init_runtime();
  var deriveFindings = (edges, roots, images) => {
    const findings = [];
    edges.forEach((edge, index) => {
      if (edge.resolution.status === "unresolved")
        findings.push(unresolvedFinding(edge, index));
      const resolvedAt = edge.candidates.findIndex(
        ({ outcome }) => outcome === "resolved"
      );
      const earlier = edge.candidates.slice(0, Math.max(resolvedAt, 0)).filter(
        ({ source: source2, outcome }) => source2 === "rpath" && outcome === "absent"
      ).map(({ path: path3 }) => path3);
      if (resolvedAt > 0 && earlier.length > 0)
        findings.push({
          kind: "earlier-rpath-candidate-absent",
          edge_index: index,
          image: edge.loader,
          basis: "derived",
          explanation: `The modeled dyld search checks ${earlier.join(", ")} before ${edge.resolution.image ?? edge.install_name}. A compatible Mach-O placed at an earlier modeled path could take precedence over that fallback, subject to unmodeled search inputs and code-signing library validation; library validation is not evaluated here (see inspect_signature).${edge.loader_conditional ? " This loader loads only conditionally; if it never loads, this search never occurs." : ""}${edge.resolution.status === "conditional" ? " Unmodeled environment overrides or earlier unknown candidates may take precedence; placing an image at this rpath does not establish which image dyld will load." : ""}`
        });
    });
    for (const { image, architecture } of roots) {
      const facts2 = images.get(image);
      const slice = facts2?.status === "parsed" ? facts2.slices.find(
        (candidate) => candidate.architecture === architecture
      ) : void 0;
      const environment = slice?.dyld_environment ?? [];
      if (environment.length > 0)
        findings.push({
          kind: "dyld-environment-present",
          edge_index: null,
          image,
          basis: "derived",
          explanation: slice?.file_type === "execute" ? `${image} (${architecture}) sets dyld environment variables through LC_DYLD_ENVIRONMENT (${environment.join(", ")}); any image-selection overrides they request are not modeled. Diagnostic settings alone do not alter resolution.` : `${image} (${architecture}) contains LC_DYLD_ENVIRONMENT (${environment.join(", ")}). Dyld reads these commands only from the main executable; entries in this non-executable root are observations and do not alter resolution.`
        });
    }
    return findings;
  };
  var unresolvedFinding = (edge, index) => {
    const base = {
      edge_index: index,
      image: edge.loader,
      basis: "derived"
    };
    const missing = `No candidate for ${edge.command === "LC_LAZY_LOAD_DYLIB" ? "lazily loaded " : edge.weak ? "weak dependency " : ""}${edge.install_name} exists in the analyzed root`;
    const when = edge.loader_conditional ? `. ${edge.loader} loads only conditionally; if it loads, ` : "; ";
    if (edge.command === "LC_LAZY_LOAD_DYLIB")
      return {
        ...base,
        kind: "lazy-load-unresolved",
        explanation: `${missing}${when}dyld loads it on first use, which would fail unless the image is supplied elsewhere.`
      };
    return edge.weak ? {
      ...base,
      kind: "weak-load-unresolved",
      explanation: `${missing}${when}dyld continues without it.`
    } : {
      ...base,
      kind: "required-load-unresolved",
      explanation: `${missing}${when}dyld would fail to load this required dependency for ${edge.root} (${edge.architecture}) unless the image is supplied elsewhere.`
    };
  };
  var DYLIB_RESOLUTION_LIMITATIONS = [
    "LC_LAZY_LOAD_DYLIB dependencies are resolved but not traversed, because dyld loads them only on first use.",
    "Slices are matched by dyld's graded architectures (an x86_64h process also loads x86_64). arm64e processes that disable pointer authentication can also load arm64 slices; that fallback is not modeled.",
    "Absolute install names and rpaths are outside the analyzed root and are not evaluated, including /System and /usr/lib libraries that the dyld shared cache usually provides.",
    "Leaf and relative install names depend on dyld fallback paths, DYLD_* variables, and the working directory; they are undetermined.",
    "Load order follows dyld's dependents-first traversal in load-command order. An image reached through several chains is resolved once per process, with the rpath stack and conditionality of the first chain; a later request whose install name matches an already loaded image reuses it.",
    "@loader_path uses each image's symlink-resolved path within the analyzed root.",
    "Code-signing checks that can reject a found image, such as library validation and the hardened runtime, are not evaluated.",
    "Dylib compatibility versions are not compared. Apple's linker documentation describes a load-time rejection when an image's compatibility version is older than the loader requires, but dyld on macOS 26 was observed to load such an image."
  ];

  // ThirdParty/REA/upstream/src/domain/apple/dylibResolution.ts
  var ROOT_RELATIVE_PATH = /^(?:[^\x2f\\\x00.][^\x2f\\\x00]*|\.[^\x2f\\\x00.][^\x2f\\\x00]*|\.\.[^\x2f\\\x00]+)(?:\x2f(?:[^\x2f\\\x00.][^\x2f\\\x00]*|\.[^\x2f\\\x00.][^\x2f\\\x00]*|\.\.[^\x2f\\\x00]+))*$/u;
  var rootRelativePathSchema = external_exports.string().min(1).regex(
    ROOT_RELATIVE_PATH,
    "Use a normalized path relative to the analyzed root, without a leading or trailing '/', '//', or '.' and '..' segments"
  );
  var dylibResolutionInputSchema = external_exports.strictObject({
    roots: external_exports.array(rootRelativePathSchema).min(1).optional(),
    architecture: external_exports.enum(["arm64", "arm64e", "x86_64"]).optional()
  });
  var dependencyCommandSchema = external_exports.enum([
    "LC_LOAD_DYLIB",
    "LC_LOAD_WEAK_DYLIB",
    "LC_REEXPORT_DYLIB",
    "LC_LAZY_LOAD_DYLIB",
    "LC_LOAD_UPWARD_DYLIB"
  ]);
  var dependencySchema = external_exports.strictObject({
    command: dependencyCommandSchema,
    encoding: external_exports.enum(["dylib_command", "dylib_use_command"]),
    install_name: external_exports.string(),
    weak: external_exports.boolean(),
    upward: external_exports.boolean(),
    reexport: external_exports.boolean(),
    delayed_init: external_exports.boolean(),
    current_version: external_exports.string(),
    compatibility_version: external_exports.string()
  });
  var machoSliceSchema = external_exports.strictObject({
    architecture: external_exports.string().min(1),
    /** Physical identity observed in the thin header and, for FAT, its table. */
    slice_offset: external_exports.number().int().nonnegative(),
    slice_size: external_exports.number().int().positive(),
    cpu_type: external_exports.number().int().nonnegative(),
    cpu_subtype: external_exports.number().int().nonnegative(),
    fat_cpu_type: external_exports.number().int().nonnegative().nullable(),
    fat_cpu_subtype: external_exports.number().int().nonnegative().nullable(),
    fat_alignment_exponent: external_exports.number().int().nonnegative().nullable(),
    file_type: external_exports.enum(["execute", "dylib", "bundle", "other"]),
    file_type_code: external_exports.number().int().nonnegative(),
    /** Raw LC_BUILD_VERSION platform number; null means no such command was observed. */
    platform: external_exports.number().int().nonnegative().nullable(),
    /** Every distinct build platform declared by LC_BUILD_VERSION/version-min commands. */
    platforms: external_exports.array(external_exports.number().int().nonnegative()),
    install_name: external_exports.string().nullable(),
    dependencies: external_exports.array(dependencySchema),
    rpaths: external_exports.array(external_exports.string()),
    dyld_environment: external_exports.array(external_exports.string()),
    code_signature_present: external_exports.boolean()
  });
  var candidateSchema = external_exports.strictObject({
    path: external_exports.string(),
    source: external_exports.enum([
      "literal",
      "executable_path",
      "loader_path",
      "rpath",
      "already-loaded"
    ]),
    rpath: external_exports.string().nullable(),
    rpath_owner: external_exports.string().nullable(),
    outcome: external_exports.enum([
      "resolved",
      "absent",
      "not-mach-o",
      "malformed",
      "unsupported",
      "architecture-missing",
      "not-loadable",
      "platform-mismatch",
      "outside-target",
      "escapes-target",
      "undetermined"
    ]),
    resolved_path: external_exports.string().nullable()
  });
  var edgeSchema = external_exports.strictObject({
    root: external_exports.string(),
    architecture: external_exports.string(),
    loader: external_exports.string(),
    via: external_exports.array(external_exports.string()),
    ...dependencySchema.shape,
    candidates: external_exports.array(candidateSchema),
    resolution: external_exports.strictObject({
      status: external_exports.enum(["resolved", "conditional", "unresolved", "undetermined"]),
      image: external_exports.string().nullable()
    }),
    install_name_matches: external_exports.boolean().nullable(),
    /**
     * The loader was reached through a conditional edge, so it might not load;
     * this edge describes what happens only if it does.
     */
    loader_conditional: external_exports.boolean()
  });
  var findingSchema = external_exports.strictObject({
    kind: external_exports.enum([
      "required-load-unresolved",
      "weak-load-unresolved",
      "lazy-load-unresolved",
      "earlier-rpath-candidate-absent",
      "dyld-environment-present"
    ]),
    edge_index: external_exports.number().int().nonnegative().nullable(),
    image: external_exports.string().nullable(),
    basis: external_exports.literal("derived"),
    explanation: external_exports.string().min(1)
  });
  var imageSchema = external_exports.strictObject({
    path: external_exports.string(),
    sha256: digestSchema,
    parse_status: external_exports.enum(["parsed", "malformed", "unsupported"]),
    reason: external_exports.string().nullable(),
    slices: external_exports.array(machoSliceSchema.omit({ dependencies: true }))
  });
  var dylibResolutionResultSchema = external_exports.strictObject({
    root_path: external_exports.string(),
    target_sha256: digestSchema,
    roots: external_exports.array(
      external_exports.strictObject({ image: external_exports.string(), architecture: external_exports.string() })
    ),
    images: external_exports.array(imageSchema),
    edges: external_exports.array(edgeSchema),
    findings: external_exports.array(findingSchema),
    coverage: external_exports.strictObject({
      status: external_exports.enum(["complete", "partial"]),
      unparsed_images: external_exports.array(external_exports.string()),
      roots_without_architecture: external_exports.array(external_exports.string())
    }),
    limitations: external_exports.array(external_exports.string().min(1))
  });
  var candidateTemplates = (dependency, loader, context) => {
    const name = dependency.install_name;
    if (!name.startsWith("@rpath/")) {
      const source2 = name.startsWith("@executable_path") ? "executable_path" : name.startsWith("@loader_path") ? "loader_path" : "literal";
      return [
        {
          expansion: expandPrefix(name, {
            ownerDirectory: directoryOf2(loader),
            executable: context.executable
          }),
          source: source2,
          rpath: null,
          rpathOwner: null
        }
      ];
    }
    const rest = name.slice("@rpath/".length);
    const owners = [...context.loaded.get(loader)?.chain ?? [loader]].reverse();
    return owners.flatMap(
      (owner) => (context.loaded.get(owner)?.slice.rpaths ?? []).map((rpath) => {
        const base = expandPrefix(rpath, {
          ownerDirectory: directoryOf2(owner),
          executable: context.executable
        });
        const expansion = {
          scope: base.scope,
          path: base.scope === "outside" ? `${base.path.replace(/\/+$/u, "")}/${rest}` : joinPath2(base.path, rest)
        };
        return { expansion, source: "rpath", rpath, rpathOwner: owner };
      })
    );
  };
  var evaluateCandidate = async (template, context) => {
    const base = {
      path: template.expansion.path,
      source: template.source,
      rpath: template.rpath,
      rpath_owner: template.rpathOwner
    };
    if (template.expansion.scope === "outside")
      return { ...base, outcome: "outside-target", resolved_path: null };
    if (template.expansion.scope === "undetermined")
      return { ...base, outcome: "undetermined", resolved_path: null };
    const lookup = await resolveTreePath(context.view, template.expansion.path);
    if (lookup.kind === "escapes")
      return { ...base, outcome: "escapes-target", resolved_path: null };
    if (lookup.kind !== "file")
      return { ...base, outcome: "absent", resolved_path: null };
    const facts2 = await imageFacts(context, lookup.path);
    let outcome;
    if (facts2.status !== "parsed") outcome = facts2.status;
    else {
      const slice = compatibleSlice(facts2.slices, context.architecture);
      if (slice === void 0) outcome = "architecture-missing";
      else if (slice.file_type_code !== 6) outcome = "not-loadable";
      else {
        const platformResult = platformLoadability(
          context.platforms,
          slice.platforms,
          slice.file_type_code,
          context.architecture
        );
        outcome = platformResult === "compatible" ? "resolved" : platformResult === "incompatible" ? "platform-mismatch" : "undetermined";
      }
    }
    return { ...base, outcome, resolved_path: lookup.path };
  };
  var platformLoadability = (processPlatforms, imagePlatforms, fileType, architecture) => {
    if (processPlatforms.length === 0 || imagePlatforms.length === 0)
      return "unknown";
    const outcomes = processPlatforms.map(
      (processPlatform) => imageLoadabilityForPlatform(
        processPlatform,
        imagePlatforms,
        fileType,
        architecture
      )
    );
    if (outcomes.every((outcome) => outcome === "compatible"))
      return "compatible";
    if (outcomes.every((outcome) => outcome === "incompatible"))
      return "incompatible";
    return "unknown";
  };
  var imageLoadabilityForPlatform = (processPlatform, imagePlatforms, fileType, architecture) => {
    if (imagePlatforms.includes(processPlatform)) return "compatible";
    if (processPlatform === 6 && imagePlatforms.includes(1)) return "compatible";
    if (processPlatform === 2 && imagePlatforms.includes(6)) return "compatible";
    if (processPlatform === 2 && imagePlatforms.includes(11)) return "compatible";
    if (processPlatform === 7 && imagePlatforms.includes(12)) return "compatible";
    if (processPlatform === 1 && fileType === 2 && imagePlatforms.includes(6))
      return "compatible";
    if (processPlatform === 2 && imagePlatforms.includes(1) && architecture.startsWith("arm64") || [7, 8, 9].includes(processPlatform) && imagePlatforms.includes(1))
      return "unknown";
    if (isKnownPlatform(processPlatform) && imagePlatforms.every(isKnownPlatform))
      return "incompatible";
    return "unknown";
  };
  var isKnownPlatform = (platform) => platform >= 1 && platform <= 12;
  var imageFacts = async (context, path3) => {
    const known = context.images.get(path3);
    if (known !== void 0) return known;
    const facts2 = await context.view.image(path3);
    context.images.set(path3, facts2);
    return facts2;
  };
  var resolution = (candidates) => {
    let external = false;
    for (const candidate of candidates) {
      if (candidate.outcome === "resolved")
        return {
          status: external ? "conditional" : "resolved",
          image: candidate.resolved_path
        };
      if (candidate.outcome === "outside-target" || candidate.outcome === "escapes-target" || candidate.outcome === "unsupported" || candidate.outcome === "undetermined")
        external = true;
    }
    return { status: external ? "undetermined" : "unresolved", image: null };
  };
  var resolveDependency = async (dependency, loader, context) => {
    const current = context.loaded.get(loader);
    const chain = current?.chain ?? [loader];
    const loaded = context.byInstallName.get(dependency.install_name);
    const candidates = [];
    if (loaded !== void 0)
      candidates.push({
        path: dependency.install_name,
        source: "already-loaded",
        rpath: null,
        rpath_owner: null,
        outcome: "resolved",
        resolved_path: loaded
      });
    else
      for (const template of candidateTemplates(dependency, loader, context)) {
        const candidate = await evaluateCandidate(template, context);
        candidates.push(candidate);
        if (candidate.outcome === "resolved") break;
      }
    const modeled = resolution(candidates);
    const searchUnknown = loaded === void 0 && hasApplicableDyldOverrides(
      context.searchOverrides,
      dependency.install_name,
      modeled.image !== null
    );
    if (searchUnknown) context.environmentRoots.add(context.root);
    const searched = searchUnknown ? {
      ...modeled,
      status: modeled.image === null ? "undetermined" : "conditional"
    } : modeled;
    const resolved = loaded !== void 0 && context.loaded.get(loaded)?.conditional === true && searched.status === "resolved" ? { ...searched, status: "conditional" } : searched;
    const image = resolved.image === null ? void 0 : context.images.get(resolved.image);
    const slice = image?.status === "parsed" ? compatibleSlice(image.slices, context.architecture) : void 0;
    return {
      root: context.root,
      architecture: context.architecture,
      loader,
      via: [...chain],
      ...dependency,
      candidates,
      resolution: resolved,
      install_name_matches: slice === void 0 || slice.install_name === null ? null : slice.install_name === dependency.install_name,
      loader_conditional: current?.conditional ?? false
    };
  };
  var traceProcess = async (context, rootSlice, signal) => {
    const edges = [];
    context.loaded.set(context.root, {
      slice: rootSlice,
      chain: [context.root],
      conditional: false
    });
    if (rootSlice.install_name !== null)
      context.byInstallName.set(rootSlice.install_name, context.root);
    const pending = [context.root];
    while (pending.length > 0) {
      signal?.throwIfAborted();
      const loader = pending.pop() ?? "";
      const current = context.loaded.get(loader);
      if (current === void 0) continue;
      const created = [];
      for (const dependency of current.slice.dependencies) {
        const edge = await resolveDependency(dependency, loader, context);
        edges.push(edge);
        if (dependency.command === "LC_LAZY_LOAD_DYLIB") continue;
        const image = edge.resolution.image;
        if (image === null || context.loaded.has(image)) continue;
        const facts2 = context.images.get(image);
        const slice = facts2?.status === "parsed" ? compatibleSlice(facts2.slices, context.architecture) : void 0;
        if (slice === void 0) continue;
        context.loaded.set(image, {
          slice,
          chain: [...current.chain, image],
          // dyld may load an unknown earlier candidate instead of this fallback.
          conditional: current.conditional || edge.resolution.status === "conditional"
        });
        if (slice.install_name !== null && !context.byInstallName.has(slice.install_name))
          context.byInstallName.set(slice.install_name, image);
        created.push(image);
      }
      pending.push(...created.reverse());
    }
    return edges;
  };
  var traceDylibLoading = async (view, request) => {
    const images = /* @__PURE__ */ new Map();
    for (const path3 of request.unclassified ?? [])
      images.set(path3, await view.image(path3));
    const roots = [];
    const edges = [];
    const withoutArchitecture = [];
    const environmentRoots = /* @__PURE__ */ new Set();
    for (const root of request.roots) {
      const facts2 = await view.image(root);
      images.set(root, facts2);
      if (facts2.status !== "parsed") continue;
      const slices = facts2.slices.filter(
        ({ architecture }) => request.architecture === void 0 || architecture === request.architecture
      );
      if (slices.length === 0) withoutArchitecture.push(root);
      for (const slice of slices) {
        const executable = slice.file_type === "execute" ? root : null;
        const searchOverrides = executable === null ? [] : embeddedDyldOverrides(slice.dyld_environment, slice.platforms);
        if (searchOverrides.some(
          ({ variable, value }) => variable === "DYLD_INSERT_LIBRARIES" && value !== ""
        ))
          environmentRoots.add(root);
        roots.push({ image: root, architecture: slice.architecture });
        edges.push(
          ...await traceProcess(
            {
              view,
              root,
              architecture: slice.architecture,
              searchOverrides,
              environmentRoots,
              platforms: slice.platforms,
              executable,
              loaded: /* @__PURE__ */ new Map(),
              byInstallName: /* @__PURE__ */ new Map(),
              images
            },
            slice,
            request.signal
          )
        );
      }
    }
    const reported = [...images.entries()].filter(([, facts2]) => facts2.status !== "not-mach-o").sort(([left], [right]) => compare2(left, right));
    const unparsed = reported.filter(([, facts2]) => facts2.status !== "parsed").map(([path3]) => path3);
    return {
      roots,
      images: reported.map(([path3, facts2]) => ({
        path: path3,
        parse_status: facts2.status === "not-mach-o" ? "unsupported" : facts2.status,
        reason: facts2.status === "parsed" || facts2.status === "not-mach-o" ? null : facts2.reason,
        slices: facts2.status === "parsed" ? facts2.slices.map(withoutDependencies) : []
      })),
      edges,
      findings: deriveFindings(edges, roots, images),
      coverage: {
        status: unparsed.length === 0 && withoutArchitecture.length === 0 && environmentRoots.size === 0 ? "complete" : "partial",
        unparsed_images: unparsed,
        roots_without_architecture: withoutArchitecture
      },
      limitations: [
        ...DYLIB_RESOLUTION_LIMITATIONS,
        ...environmentRoots.size === 0 ? [] : [
          `Roots ${[...environmentRoots].join(", ")} request applicable image-selection inputs through LC_DYLD_ENVIRONMENT that are not modeled; affected dependencies or inserted images remain uncertain.`
        ]
      ]
    };
  };
  var withoutDependencies = (slice) => ({
    architecture: slice.architecture,
    slice_offset: slice.slice_offset,
    slice_size: slice.slice_size,
    cpu_type: slice.cpu_type,
    cpu_subtype: slice.cpu_subtype,
    fat_cpu_type: slice.fat_cpu_type,
    fat_cpu_subtype: slice.fat_cpu_subtype,
    fat_alignment_exponent: slice.fat_alignment_exponent,
    file_type: slice.file_type,
    file_type_code: slice.file_type_code,
    platform: slice.platform,
    platforms: slice.platforms,
    install_name: slice.install_name,
    rpaths: slice.rpaths,
    dyld_environment: slice.dyld_environment,
    code_signature_present: slice.code_signature_present
  });
  var compare2 = (left, right) => left < right ? -1 : left > right ? 1 : 0;

  // ThirdParty/REA/adapters/native.ts
  init_runtime();
  var path = external_exports.string().min(1).max(4096).refine((p) => !p.startsWith("/") && !p.split("/").includes(".."), "root-relative path");
  var facts = external_exports.discriminatedUnion("status", [
    external_exports.strictObject({ status: external_exports.literal("parsed"), slices: external_exports.array(machoSliceSchema).max(32) }),
    external_exports.strictObject({ status: external_exports.enum(["malformed", "unsupported"]), reason: external_exports.string().max(2048) }),
    external_exports.strictObject({ status: external_exports.literal("not-mach-o") })
  ]);
  var nativeInputSchema = external_exports.strictObject({
    inventoryComplete: external_exports.literal(true),
    subject: external_exports.strictObject({ name: external_exports.string().max(4096), format: external_exports.string().max(128) }),
    entries: external_exports.array(external_exports.strictObject({ path, kind: external_exports.enum(["file", "directory", "symlink", "slice"]), component: appleComponentSchema.optional(), target: external_exports.string().max(4096).optional() })).max(2e4),
    images: external_exports.array(external_exports.strictObject({ path, facts })).max(2048),
    roots: external_exports.array(path).min(1).max(128),
    architecture: external_exports.string().max(64).optional()
  });
  async function nativeApplication(raw) {
    const input = nativeInputSchema.parse(raw);
    checkpoint();
    const entries = new Map(input.entries.map((e) => [e.path, e]));
    const images = new Map(input.images.map((e) => [e.path, e.facts]));
    if (entries.size !== input.entries.length || images.size !== input.images.length) throw new Error("duplicate path");
    let probes = 0;
    const view = {
      entry: async (p) => {
        checkpoint();
        if (++probes > 1e5) throw new Error("expansion budget");
        const e = entries.get(p);
        if (!e) return void 0;
        if (e.kind === "symlink") {
          if (e.target === void 0) throw new Error("missing symlink target");
          return { kind: "symlink", target: e.target };
        }
        return { kind: e.kind === "directory" ? "directory" : "file" };
      },
      image: async (p) => {
        checkpoint();
        if (++probes > 1e5) throw new Error("expansion budget");
        return images.get(p) ?? { status: "unsupported", reason: "Mach-O facts not captured" };
      }
    };
    const roots = applicationRoots(input.entries, input.subject);
    const trace = await traceDylibLoading(view, { roots: input.roots, architecture: input.architecture, signal: { throwIfAborted: checkpoint } });
    return { applicationRoots: roots, bundles: detectBundles(input.entries, roots), trace };
  }

  // ThirdParty/REA/adapters/ui.ts
  init_runtime();
  init_runtime();

  // ThirdParty/REA/upstream/src/artifacts/apple/NibArchive.ts
  init_runtime();
  init_runtime();

  // ThirdParty/REA/upstream/src/artifacts/apple/InterfaceBuilderDecodeBudget.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/propertyListXmlText.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/artifacts/apple/InterfaceBuilderDecodeBudget.ts
  var InterfaceBuilderDecodeBudgetExceeded = class extends Error {
    constructor(reason, message) {
      super(message);
      this.reason = reason;
      this.name = "InterfaceBuilderDecodeBudgetExceeded";
    }
    reason;
  };
  var InterfaceBuilderDecodeBudget = class {
    #initialBytes;
    #remainingBytes;
    constructor(maxBytes) {
      this.#initialBytes = maxBytes;
      this.#remainingBytes = maxBytes;
    }
    /** Representation bytes still available for the current inspection. */
    get remainingBytes() {
      return this.#remainingBytes;
    }
    /** Representation bytes reserved so far. */
    get usedBytes() {
      return this.#initialBytes - this.#remainingBytes;
    }
    /** Reserve representation bytes before allocation, or report exhaustion. */
    reserve(bytes, message) {
      if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > this.#remainingBytes)
        throw new InterfaceBuilderDecodeBudgetExceeded(
          "aggregate_decode_budget_exhausted",
          message
        );
      this.#remainingBytes -= bytes;
    }
    /** Reserve an upper bound for one JSON-serialized string occurrence. */
    reserveJsonStringOccurrence(value) {
      this.reserve(
        value.length * 6 + 2,
        "projected JSON strings exceed the aggregate Interface Builder decode budget"
      );
    }
    /** Reserve the exact JSON string length for a base64 value from Buffer. */
    reserveBase64JsonStringOccurrence(value) {
      this.reserve(
        value.length + 2,
        "projected NIB base64 values exceed the aggregate Interface Builder decode budget"
      );
    }
    /** Reserve an upper bound for one JSON object property name occurrence. */
    reserveJsonPropertyNameOccurrence(value) {
      this.reserve(
        value.length * 6 + 3,
        "projected JSON property names exceed the aggregate Interface Builder decode budget"
      );
    }
    /** Reserve bytes for an optional projection without throwing on exhaustion. */
    tryReserve(bytes) {
      if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > this.#remainingBytes)
        return false;
      this.#remainingBytes -= bytes;
      return true;
    }
  };

  // ThirdParty/REA/upstream/src/artifacts/apple/NibArchive.ts
  var MAGIC = import_buffer.Buffer.from("NIBArchive", "ascii");
  var DEFAULT_DECODE_BUDGET_BYTES = 128 * 1024 * 1024;
  var decodeNibArchive = (bytes, budget = new InterfaceBuilderDecodeBudget(DEFAULT_DECODE_BUDGET_BYTES)) => {
    if (bytes.length < 50 || !bytes.subarray(0, MAGIC.length).equals(MAGIC))
      throw new TypeError("NIBArchive magic or header is invalid");
    const formatVersion = readU32(bytes, 10);
    const coderVersion = readU32(bytes, 14);
    if (formatVersion !== 1)
      throw new TypeError(
        `Unsupported NIBArchive format version ${formatVersion}`
      );
    const objectCount = readCount(bytes, 18, "object");
    const objectsOffset = readOffset(bytes, 22, bytes.length, "object");
    const keyCount = readCount(bytes, 26, "key");
    const keysOffset = readOffset(bytes, 30, bytes.length, "key");
    const valueCount = readCount(bytes, 34, "value");
    const valuesOffset = readOffset(bytes, 38, bytes.length, "value");
    const classCount = readCount(bytes, 42, "class");
    const classesOffset = readOffset(bytes, 46, bytes.length, "class");
    assertOrderedOffsets(bytes.length, [
      objectsOffset,
      keysOffset,
      valuesOffset,
      classesOffset
    ]);
    const projectedFieldCount = preflightProjectedFieldCount(
      bytes,
      objectsOffset,
      keysOffset,
      objectCount,
      valueCount,
      classCount,
      budget.remainingBytes
    );
    budget.reserve(
      objectCount * 96 + projectedFieldCount * 96,
      "NIBArchive object and projected field counts exceed the aggregate Interface Builder decode budget"
    );
    const objectRecords = parseObjects(
      bytes,
      objectsOffset,
      keysOffset,
      objectCount,
      valueCount,
      classCount
    );
    const keys = parseStrings(
      bytes,
      keysOffset,
      valuesOffset,
      keyCount,
      "key",
      budget
    );
    const classes = parseClasses(
      bytes,
      classesOffset,
      bytes.length,
      classCount,
      budget
    );
    const neededValues = valueIndexes(objectRecords, valueCount);
    const values = parseValues(
      bytes,
      valuesOffset,
      classesOffset,
      valueCount,
      keyCount,
      neededValues,
      budget
    );
    for (const { value } of values.values()) {
      if (typeof value === "object" && value !== null && !Array.isArray(value) && typeof value.$nib_object_ref === "number" && value.$nib_object_ref >= objectCount)
        throw new TypeError(
          "NIBArchive object reference is outside the object table"
        );
    }
    const objects = objectRecords.flatMap((object2, id) => {
      const className = classes[object2.class_index];
      if (className === void 0) return [];
      const fields = {};
      for (let index = object2.value_start; index < object2.value_start + object2.value_count; index += 1) {
        const value = values.get(index);
        if (value === void 0) continue;
        const key = keys[value.key_index];
        if (key !== void 0) fields[key] = value.value;
      }
      return [{ id, class_name: className, values: fields }];
    });
    let connectionObjectCount = 0;
    for (const object2 of objects)
      if (/(?:Outlet|Connection|Segue|ActionConnection)/iu.test(object2.class_name))
        connectionObjectCount += 1;
    return {
      format_version: formatVersion,
      coder_version: coderVersion,
      object_count: objectCount,
      connection_object_count: connectionObjectCount,
      objects,
      classes,
      limitations: [
        "NIBArchive class extensions and unsupported value encodings are retained as unavailable fields.",
        "NIBArchive object relationships are decoded from serialized references; runtime object creation and execution are not performed."
      ]
    };
  };
  var parseObjects = (bytes, start, end, count, valueCount, classCount) => {
    const cursor = { offset: start };
    const output = [];
    for (let index = 0; index < count; index += 1) {
      const classIndex = readVarint(bytes, cursor, end);
      const valueStart = readVarint(bytes, cursor, end);
      const countForObject = readVarint(bytes, cursor, end);
      if (classIndex >= classCount || valueStart > valueCount || countForObject > valueCount - valueStart)
        throw new TypeError(
          `NIBArchive object ${index} references an invalid table range`
        );
      output.push({
        class_index: classIndex,
        value_start: valueStart,
        value_count: countForObject
      });
    }
    if (cursor.offset > end)
      throw new TypeError("NIBArchive object table overlaps the next table");
    return output;
  };
  var preflightProjectedFieldCount = (bytes, start, end, objectCount, valueCount, classCount, maxBytes) => {
    if (objectCount * 96 > maxBytes)
      throw new InterfaceBuilderDecodeBudgetExceeded(
        "aggregate_decode_budget_exhausted",
        "NIBArchive object count exceeds the aggregate Interface Builder decode budget"
      );
    const cursor = { offset: start };
    let projectedFields = 0;
    for (let index = 0; index < objectCount; index += 1) {
      const classIndex = readVarint(bytes, cursor, end);
      const valueStart = readVarint(bytes, cursor, end);
      const fieldCount = readVarint(bytes, cursor, end);
      if (classIndex >= classCount || valueStart > valueCount || fieldCount > valueCount - valueStart)
        throw new TypeError(
          `NIBArchive object ${index} references an invalid table range`
        );
      projectedFields += fieldCount;
      if (!Number.isSafeInteger(projectedFields) || projectedFields * 96 > maxBytes - objectCount * 96)
        throw new InterfaceBuilderDecodeBudgetExceeded(
          "aggregate_decode_budget_exhausted",
          "NIBArchive projected field ranges exceed the aggregate Interface Builder decode budget"
        );
    }
    return projectedFields;
  };
  var parseStrings = (bytes, start, end, count, label, budget) => {
    const cursor = { offset: start };
    const output = [];
    for (let index = 0; index < count; index += 1) {
      const length = readVarint(bytes, cursor, end);
      const next = checkedEnd(cursor.offset, length, end, `${label} ${index}`);
      budget.reserve(
        32 + length * 2,
        `NIBArchive ${label} strings exceed the aggregate Interface Builder decode budget`
      );
      const value = decodeUtf8(bytes, cursor.offset, next, `${label} ${index}`);
      cursor.offset = next;
      output.push(value);
    }
    return output;
  };
  var parseClasses = (bytes, start, end, count, budget) => {
    const cursor = { offset: start };
    const output = [];
    for (let index = 0; index < count; index += 1) {
      const length = readVarint(bytes, cursor, end);
      const extraCount = readVarint(bytes, cursor, end);
      if (extraCount > 16)
        throw new TypeError(
          `NIBArchive class ${index} has too many extension values`
        );
      ensureRange(
        cursor.offset,
        extraCount * 4,
        end,
        `class ${index} extensions`
      );
      cursor.offset += extraCount * 4;
      const next = checkedEnd(cursor.offset, length, end, `class ${index}`);
      budget.reserve(
        32 + length * 2,
        "NIBArchive class names exceed the aggregate Interface Builder decode budget"
      );
      const name = decodeUtf8(
        bytes,
        cursor.offset,
        next,
        `class ${index}`
      ).replace(/\0+$/u, "");
      cursor.offset = next;
      output.push(name);
    }
    return output;
  };
  var parseValues = (bytes, start, end, count, keyCount, needed, budget) => {
    const cursor = { offset: start };
    const output = /* @__PURE__ */ new Map();
    for (let index = 0; index < count; index += 1) {
      const keyIndex = readVarint(bytes, cursor, end);
      if (keyIndex >= keyCount)
        throw new TypeError(
          `NIBArchive value ${index} references an invalid key`
        );
      ensureRange(cursor.offset, 1, end, `value ${index} type`);
      const type = bytes[cursor.offset++] ?? -1;
      if (!needed.has(index)) {
        skipValue(bytes, cursor, end, type, index);
        continue;
      }
      budget.reserve(
        64,
        "NIBArchive decoded values exceed the aggregate Interface Builder decode budget"
      );
      const value = readValue(bytes, cursor, end, type, index, budget);
      output.set(index, { key_index: keyIndex, value });
    }
    if (cursor.offset > end)
      throw new TypeError("NIBArchive value table overlaps the next table");
    return output;
  };
  var readValue = (bytes, cursor, end, type, index, budget) => {
    switch (type) {
      case 0:
        ensureRange(cursor.offset, 1, end, `value ${index}`);
        return bytes.readInt8(cursor.offset++);
      case 1:
        ensureRange(cursor.offset, 2, end, `value ${index}`);
        {
          const value = bytes.readInt16LE(cursor.offset);
          cursor.offset += 2;
          return value;
        }
      case 2:
        ensureRange(cursor.offset, 4, end, `value ${index}`);
        {
          const value = bytes.readInt32LE(cursor.offset);
          cursor.offset += 4;
          return value;
        }
      case 3:
        ensureRange(cursor.offset, 8, end, `value ${index}`);
        {
          const value = bytes.readBigInt64LE(cursor.offset);
          cursor.offset += 8;
          return value <= BigInt(Number.MAX_SAFE_INTEGER) && value >= BigInt(Number.MIN_SAFE_INTEGER) ? Number(value) : value.toString();
        }
      case 4:
        return true;
      case 5:
        return false;
      case 6:
        ensureRange(cursor.offset, 4, end, `value ${index}`);
        {
          const value = bytes.readFloatLE(cursor.offset);
          cursor.offset += 4;
          return Number.isFinite(value) ? value : null;
        }
      case 7:
        ensureRange(cursor.offset, 8, end, `value ${index}`);
        {
          const value = bytes.readDoubleLE(cursor.offset);
          cursor.offset += 8;
          return Number.isFinite(value) ? value : null;
        }
      case 8: {
        const length = readVarint(bytes, cursor, end);
        const next = checkedEnd(
          cursor.offset,
          length,
          end,
          `value ${index} data`
        );
        budget.reserve(
          32 + 4 * Math.ceil(length / 3),
          `NIBArchive data value ${index} exceeds the aggregate Interface Builder decode budget`
        );
        const encoded2 = bytes.subarray(cursor.offset, next).toString("base64");
        cursor.offset = next;
        return { $nib_data_base64: encoded2 };
      }
      case 9:
        return null;
      case 10:
        ensureRange(cursor.offset, 4, end, `value ${index} reference`);
        {
          const objectIndex = bytes.readUInt32LE(cursor.offset);
          cursor.offset += 4;
          return { $nib_object_ref: objectIndex };
        }
      default:
        throw new TypeError(
          `NIBArchive value ${index} has unsupported type ${type}`
        );
    }
  };
  var skipValue = (bytes, cursor, end, type, index) => {
    switch (type) {
      case 0:
        ensureRange(cursor.offset, 1, end, `value ${index}`);
        cursor.offset += 1;
        return;
      case 1:
        ensureRange(cursor.offset, 2, end, `value ${index}`);
        cursor.offset += 2;
        return;
      case 2:
      case 10:
        ensureRange(cursor.offset, 4, end, `value ${index}`);
        cursor.offset += 4;
        return;
      case 3:
      case 7:
        ensureRange(cursor.offset, 8, end, `value ${index}`);
        cursor.offset += 8;
        return;
      case 6:
        ensureRange(cursor.offset, 4, end, `value ${index}`);
        cursor.offset += 4;
        return;
      case 4:
      case 5:
      case 9:
        return;
      case 8: {
        const length = readVarint(bytes, cursor, end);
        cursor.offset = checkedEnd(
          cursor.offset,
          length,
          end,
          `value ${index} data`
        );
        return;
      }
      default:
        throw new TypeError(
          `NIBArchive value ${index} has unsupported type ${type}`
        );
    }
  };
  var valueIndexes = (objects, total) => {
    const indexes = /* @__PURE__ */ new Set();
    for (const object2 of objects)
      for (let index = object2.value_start; index < object2.value_start + object2.value_count; index += 1)
        indexes.add(index);
    if (indexes.size > total)
      throw new TypeError(
        "NIBArchive object value ranges exceed the value table"
      );
    return indexes;
  };
  var readCount = (bytes, offset, label) => {
    const count = readU32(bytes, offset);
    if (count > bytes.length)
      throw new TypeError(`NIBArchive ${label} count exceeds the archive length`);
    return count;
  };
  var readOffset = (bytes, offset, fileLength, label) => {
    const value = readU32(bytes, offset);
    if (value < 50 || value > fileLength)
      throw new TypeError(`NIBArchive ${label} table offset is invalid`);
    return value;
  };
  var readU32 = (bytes, offset) => {
    ensureRange(offset, 4, bytes.length, "header");
    return bytes.readUInt32LE(offset);
  };
  var decodeUtf8 = (bytes, start, end, label) => {
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(
        bytes.subarray(start, end)
      );
    } catch (cause) {
      throw new TypeError(`NIBArchive ${label} is not valid UTF-8`, {
        cause
      });
    }
  };
  var readVarint = (bytes, cursor, end) => {
    let value = 0;
    let shift = 0;
    for (let index = 0; index < 5; index += 1) {
      ensureRange(cursor.offset, 1, end, "variable integer");
      const byte = bytes[cursor.offset++] ?? 0;
      value += (byte & 127) * 2 ** shift;
      if ((byte & 128) !== 0) {
        if (value > 2147483647)
          throw new TypeError("NIBArchive variable integer is out of range");
        return value;
      }
      shift += 7;
    }
    throw new TypeError("NIBArchive variable integer is too long");
  };
  var checkedEnd = (start, length, limit, label) => {
    if (!Number.isSafeInteger(length) || length < 0 || start + length > limit)
      throw new TypeError(`NIBArchive ${label} exceeds its table`);
    return start + length;
  };
  var ensureRange = (start, length, limit, label) => {
    checkedEnd(start, length, limit, label);
  };
  var assertOrderedOffsets = (length, offsets) => {
    let previous = 50;
    for (const offset of offsets) {
      if (offset < previous || offset > length)
        throw new TypeError("NIBArchive table offsets are out of order");
      previous = offset;
    }
  };

  // ThirdParty/REA/upstream/src/artifacts/apple/NibViewHierarchy.ts
  init_runtime();
  var projectNibViewHierarchy = (objects, retainedIds, reserveNode = () => true, maxNodes = 2e4) => {
    const { parents, involved, invalid } = collectNibParents(
      objects,
      retainedIds
    );
    if (parents.size === 0) return { hierarchy: null, omitted: invalid };
    const children = /* @__PURE__ */ new Map();
    for (const [child, parent] of parents) {
      if (!retainedIds.has(parent) || !retainedIds.has(child)) continue;
      const siblings = children.get(parent) ?? [];
      siblings.push(child);
      children.set(parent, siblings);
    }
    const roots = [];
    const pending = [];
    for (const id of involved)
      if (!parents.has(id)) pending.push({ id, depth: 0, output: roots });
    const visited = /* @__PURE__ */ new Set();
    while (pending.length > 0) {
      const item = pending.pop();
      if (item === void 0) break;
      if (visited.has(item.id) || item.depth > 128 || visited.size >= maxNodes || !reserveNode())
        continue;
      visited.add(item.id);
      const node = { objectID: String(item.id), children: [] };
      item.output.push(node);
      for (const child of [...children.get(item.id) ?? []].reverse())
        pending.push({ id: child, depth: item.depth + 1, output: node.children });
    }
    return {
      hierarchy: roots,
      omitted: involved.size - visited.size + invalid
    };
  };
  var mergeNibHierarchies = (legacy, recovered, reserveNode = () => true, maxNodes = 2e4) => {
    const existing = /* @__PURE__ */ new Map();
    const owners = /* @__PURE__ */ new Map();
    const parents = /* @__PURE__ */ new Map();
    const pending = legacy.map((node) => ({
      node,
      output: legacy,
      parent: null
    }));
    while (pending.length > 0) {
      const entry = pending.pop();
      if (entry === void 0 || existing.has(entry.node.objectID)) continue;
      existing.set(entry.node.objectID, entry.node);
      owners.set(entry.node.objectID, entry.output);
      if (entry.parent !== null) parents.set(entry.node.objectID, entry.parent);
      pending.push(
        ...entry.node.children.map((node) => ({
          node,
          output: entry.node.children,
          parent: entry.node.objectID
        }))
      );
    }
    let omitted2 = 0;
    const additions = recovered.map((node) => ({
      node,
      output: legacy,
      parent: null
    }));
    while (additions.length > 0) {
      const entry = additions.pop();
      if (entry === void 0) break;
      let target = existing.get(entry.node.objectID);
      if (target === void 0) {
        if (existing.size >= maxNodes || !reserveNode()) {
          omitted2 += 1;
          continue;
        }
        target = { objectID: entry.node.objectID, children: [] };
        existing.set(target.objectID, target);
        entry.output.push(target);
        owners.set(target.objectID, entry.output);
        if (entry.parent !== null) parents.set(target.objectID, entry.parent);
      } else if (entry.parent !== null && owners.get(target.objectID) !== entry.output) {
        const owner = owners.get(target.objectID);
        if (owner !== legacy || wouldCycle(target.objectID, entry.parent, parents)) {
          omitted2 += 1;
        } else {
          owner.splice(owner.indexOf(target), 1);
          entry.output.push(target);
          owners.set(target.objectID, entry.output);
          parents.set(target.objectID, entry.parent);
        }
      }
      for (const node of [...entry.node.children].reverse())
        additions.push({
          node,
          output: target.children,
          parent: target.objectID
        });
    }
    return { hierarchy: legacy, omitted: omitted2 };
  };
  var wouldCycle = (child, parent, parents) => {
    const seen = /* @__PURE__ */ new Set();
    let current = parent;
    while (current !== void 0 && !seen.has(current)) {
      if (current === child) return true;
      seen.add(current);
      current = parents.get(current);
    }
    return false;
  };
  var reference = (value) => {
    if (typeof value !== "object" || value === null || Array.isArray(value))
      return null;
    return typeof value.$nib_object_ref === "number" ? value.$nib_object_ref : null;
  };
  var collectNibParents = (objects, retainedIds) => {
    const parents = /* @__PURE__ */ new Map();
    const involved = /* @__PURE__ */ new Set();
    let invalid = 0;
    for (const object2 of objects) {
      if (!retainedIds.has(object2.id)) continue;
      const child = reference(object2.values.NSWindowView);
      if (object2.class_name.replace(/\0+$/u, "") === "NSWindowTemplate" && invalidReference(object2.values.NSWindowView))
        invalid += 1;
      if (object2.class_name.replace(/\0+$/u, "") === "NSWindowTemplate" && child !== null) {
        parents.set(child, object2.id);
        involved.add(object2.id);
        involved.add(child);
      }
      const parent = reference(object2.values.NSSuperview);
      if (invalidReference(object2.values.NSSuperview)) invalid += 1;
      if (parent === null) continue;
      parents.set(object2.id, parent);
      involved.add(object2.id);
      if (retainedIds.has(parent)) involved.add(parent);
    }
    return { parents, involved, invalid };
  };
  var invalidReference = (value) => value !== void 0 && value !== null && reference(value) === null;

  // ThirdParty/REA/upstream/src/domain/apple/interfaceBuilderGraph.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/apple/interfaceBuilderKeyedArchive.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/jsonValue.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/immutableJson.ts
  init_runtime();
  var immutableSnapshots = /* @__PURE__ */ new WeakSet();
  var isImmutableJsonSnapshot = (value) => value === null || typeof value === "string" || typeof value === "boolean" || typeof value === "number" && Number.isFinite(value) || typeof value === "object" && immutableSnapshots.has(value);

  // ThirdParty/REA/upstream/src/domain/jsonValue.ts
  var MAX_JSON_DEPTH = 1e3;
  var isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value);
  var recordShape = external_exports.record(external_exports.string(), external_exports.unknown());
  var immutableValidation = /* @__PURE__ */ new WeakMap();
  var jsonValueValidationIssue = (root) => {
    const steps = jsonValueValidationSteps(root);
    for (; ; ) {
      const step = steps.next();
      if (step.done) return step.value;
    }
  };
  function* jsonValueValidationSteps(root) {
    const immutable = typeof root === "object" && root !== null && isImmutableJsonSnapshot(root) ? root : void 0;
    if (immutable !== void 0 && immutableValidation.has(immutable))
      return immutableValidation.get(immutable);
    const finish = (issue2) => {
      if (immutable !== void 0) immutableValidation.set(immutable, issue2);
      return issue2;
    };
    const pending = [
      { value: root, depth: 0 }
    ];
    let examined = 0;
    while (pending.length > 0) {
      if (examined++ === 4096) {
        examined = 0;
        yield;
      }
      const item = pending.pop();
      if (item === void 0) break;
      if (item.depth > MAX_JSON_DEPTH)
        return finish(
          `JSON value exceeds maximum nesting depth of ${MAX_JSON_DEPTH}`
        );
      const value = item.value;
      if (value === null || typeof value === "string" || typeof value === "boolean")
        continue;
      if (typeof value === "number") {
        if (!Number.isFinite(value)) return finish("JSON numbers must be finite");
      } else if (Array.isArray(value)) {
        for (const child of value)
          pending.push({ value: child, depth: item.depth + 1 });
      } else if (isRecord(value) && recordShape.safeParse(value).success) {
        for (const child of Object.values(value))
          pending.push({ value: child, depth: item.depth + 1 });
      } else return finish("Invalid JSON value");
    }
    return finish(void 0);
  }
  var preserveJsonValue = (value) => {
    if (Array.isArray(value)) return value.map(preserveJsonValue);
    if (value !== null && typeof value === "object")
      return Object.fromEntries(
        Object.entries(value).map(([key, child]) => [
          key,
          preserveJsonValue(child)
        ])
      );
    return value;
  };
  var validatedJsonValue = external_exports.custom(
    (value) => jsonValueValidationIssue(value) === void 0,
    {
      error: (issue2) => jsonValueValidationIssue(issue2.input) ?? "Invalid JSON value"
    }
  );
  validatedJsonValue._zod.toJSONSchema = () => ({});
  var jsonValueSchema = external_exports.unknown().nonoptional().pipe(validatedJsonValue).transform(preserveJsonValue);
  jsonValueSchema._zod.toJSONSchema = () => ({});
  var objectValidation = external_exports.custom(
    isRecord,
    "Expected JSON object"
  );
  var objectProjection = () => ({ type: "object", additionalProperties: {} });
  objectValidation._zod.toJSONSchema = objectProjection;
  var jsonObjectSchema = jsonValueSchema.pipe(objectValidation);
  jsonObjectSchema._zod.toJSONSchema = objectProjection;

  // ThirdParty/REA/upstream/src/domain/apple/interfaceBuilderKeyedArchive.ts
  var recordSchema = external_exports.record(external_exports.string(), external_exports.unknown());
  var objectNode = external_exports.strictObject({
    id: external_exports.string().min(1),
    kind: external_exports.enum([
      "view_controller",
      "view",
      "control",
      "constraint",
      "layout_guide",
      "resource",
      "placeholder",
      "external_object",
      "other"
    ]),
    class_name: external_exports.string().nullable(),
    name: external_exports.string().min(1),
    attributes: external_exports.record(external_exports.string(), jsonValueSchema)
  });
  var connection = external_exports.strictObject({
    id: external_exports.string().min(1),
    kind: external_exports.enum(["outlet", "action", "segue", "other"]),
    source_id: external_exports.string().min(1),
    destination_id: external_exports.string().nullable(),
    label: external_exports.string().nullable(),
    attributes: external_exports.record(external_exports.string(), jsonValueSchema)
  });
  var parseInterfaceBuilderRecords = (value) => {
    const root = record2(value);
    const keyed = parseKeyedArchive(root);
    if (keyed !== null) return keyed;
    const objectsRaw = record2(root["com.apple.ibtool.document.objects"]);
    const connectionsRaw = record2(root["com.apple.ibtool.document.connections"]);
    const hierarchyRaw = root["com.apple.ibtool.document.hierarchy"];
    const classesRaw = record2(root["com.apple.ibtool.document.classes"]);
    const objects = [];
    const connections = [];
    let omittedConnections = 0;
    const objectEntries = Object.entries(objectsRaw);
    for (const [id, raw] of objectEntries.slice(0, 2e4)) {
      const attributes = record2(raw);
      const className = firstString(
        attributes["customClass"],
        attributes["class"],
        attributes["isa"]
      );
      const label = firstString(
        attributes["label"],
        attributes["title"],
        attributes["name"],
        className
      );
      objects.push(
        objectNode.parse({
          id,
          kind: classifyObject(className),
          class_name: className,
          name: label ?? id,
          attributes: jsonSafeRecord(attributes)
        })
      );
    }
    for (const [sourceId, rawConnections] of Object.entries(connectionsRaw)) {
      if (!Array.isArray(rawConnections)) continue;
      for (const [index, raw] of rawConnections.entries()) {
        if (connections.length >= 4e4) {
          omittedConnections += rawConnections.length - index;
          break;
        }
        const item = record2(raw);
        const type = firstString(item.type, item.connectionType) ?? "unknown";
        const destination = firstString(
          item["destination-id"],
          item.destinationId
        );
        const label = firstString(item.label, item.selector, item.identifier);
        connections.push(
          connection.parse({
            id: `${sourceId}:connection:${index}`,
            kind: classifyConnection(type),
            source_id: sourceId,
            destination_id: destination,
            label,
            attributes: jsonSafeRecord(item)
          })
        );
      }
    }
    return {
      objects,
      connections,
      hierarchy: Array.isArray(hierarchyRaw) ? hierarchyRaw.slice(0, 2e4) : [],
      classes: classesRaw,
      objectCount: objectEntries.length,
      omittedObjects: Math.max(0, objectEntries.length - 2e4),
      omittedConnections,
      omittedHierarchyReferences: 0
    };
  };
  var archiveUid = (value) => {
    if (typeof value !== "object" || value === null || Array.isArray(value))
      return void 0;
    if (Object.keys(value).length !== 1) return void 0;
    const item = record2(value);
    const marker = Object.hasOwn(item, "UID") ? item.UID : item["CF$UID"];
    return typeof marker === "number" && Number.isInteger(marker) ? marker : void 0;
  };
  var HIERARCHY_KEY = /(?:subviews|contentview|childviewcontrollers|children|views)$/iu;
  var keyedArchiveTable = (objectTable) => {
    const classNameOf = (value) => {
      const classReference = record2(value).$class;
      const uid2 = archiveUid(classReference);
      return firstString(
        record2(uid2 === void 0 ? classReference : objectTable[uid2]).$classname
      );
    };
    const archivedString = (target) => {
      if (typeof target === "string") return target;
      const text2 = record2(target)["NS.string"];
      return typeof text2 === "string" && /^NS(?:Mutable)?String$/u.test(classNameOf(target) ?? "") ? text2 : void 0;
    };
    const text = (value) => {
      const uid2 = archiveUid(value);
      return firstString(
        uid2 === void 0 ? value : archivedString(objectTable[uid2])
      );
    };
    const authoredId = (item) => firstString(text(item.objectID), text(item["object-id"]));
    const reference2 = (uid2) => {
      const target = uid2 === 0 ? null : objectTable[uid2];
      if (target === void 0 || target === null) return null;
      if (typeof target !== "object") return target;
      const string4 = archivedString(target);
      if (string4 !== void 0) return string4;
      const objectId = authoredId(record2(target));
      return {
        archiveUID: uid2,
        ...objectId === null ? {} : { objectID: objectId },
        className: classNameOf(target)
      };
    };
    const resolve = (value) => {
      const uid2 = archiveUid(value);
      if (uid2 !== void 0) return reference2(uid2);
      if (Array.isArray(value)) return value.map(resolve);
      if (typeof value !== "object" || value === null) return value;
      const output = {};
      for (const [key, child] of Object.entries(value)) {
        if (key === "$class") output.className = classNameOf(value);
        else output[key] = resolve(child);
      }
      return output;
    };
    const hierarchy = (start) => {
      let omittedReferences = 0;
      const visited = /* @__PURE__ */ new Set();
      const root = [];
      const pending = [
        { value: start, output: root }
      ];
      const appendNode = (item, uid2, output) => {
        const objectId = firstString(
          authoredId(item),
          text(item.id),
          uid2 === void 0 ? null : String(uid2)
        );
        if (objectId === null) {
          for (const [key, child] of Object.entries(item).reverse())
            if (HIERARCHY_KEY.test(key)) pending.push({ value: child, output });
          return;
        }
        const children = [];
        output.push({ objectID: objectId, children });
        for (const [key, child] of Object.entries(item).reverse())
          if (HIERARCHY_KEY.test(key))
            pending.push({ value: child, output: children });
      };
      while (pending.length > 0) {
        const entry = pending.pop();
        if (entry === void 0) break;
        const { value, output } = entry;
        const uid2 = archiveUid(value);
        if (uid2 !== void 0) {
          if (uid2 === 0) continue;
          const target = objectTable[uid2];
          if (target === void 0) {
            omittedReferences += 1;
            continue;
          }
          if (visited.has(uid2)) continue;
          visited.add(uid2);
          if (Array.isArray(target)) {
            for (let index = target.length - 1; index >= 0; index -= 1) {
              const child = target[index];
              if (child !== void 0) pending.push({ value: child, output });
            }
            continue;
          }
          if (typeof target !== "object" || target === null) continue;
          const item = record2(target);
          if (archivedArrayClass(item.$class)) {
            const members = item["NS.objects"];
            if (Array.isArray(members))
              for (let index = members.length - 1; index >= 0; index -= 1) {
                const child = members[index];
                if (child !== void 0) pending.push({ value: child, output });
              }
            continue;
          }
          appendNode(item, uid2, output);
          continue;
        }
        if (Array.isArray(value)) {
          for (let index = value.length - 1; index >= 0; index -= 1) {
            const child = value[index];
            if (child !== void 0) pending.push({ value: child, output });
          }
        } else if (typeof value === "object" && value !== null) {
          appendNode(record2(value), void 0, output);
        }
      }
      return { items: root, omittedReferences };
    };
    const archivedArrayClass = (classReference) => {
      const uid2 = archiveUid(classReference);
      const descriptor = record2(
        uid2 === void 0 ? classReference : objectTable[uid2]
      );
      const classNames = Array.isArray(descriptor.$classes) ? descriptor.$classes.filter(
        (name) => typeof name === "string"
      ) : [];
      return classNames.includes("NSArray") || classNames.includes("NSMutableArray");
    };
    return { resolve, hierarchy };
  };
  var parseKeyedArchive = (root) => {
    if (root.$archiver !== "NSKeyedArchiver" || !Array.isArray(root.$objects))
      return null;
    const objectTable = root.$objects;
    const { resolve, hierarchy: toHierarchy } = keyedArchiveTable(objectTable);
    const objects = [];
    const connections = [];
    let objectCount = 0;
    let omittedConnections = 0;
    for (const [index, raw] of objectTable.entries()) {
      if (index === 0) continue;
      const resolved = record2(resolve(raw));
      const className = firstString(resolved.className);
      if (className === null) continue;
      objectCount += 1;
      const fields = Object.fromEntries(
        Object.entries(resolved).filter(([key]) => key !== "className")
      );
      const authoredId = firstString(fields.objectID, fields["object-id"]);
      const objectId = authoredId ?? (typeof fields.archiveUID === "number" ? String(fields.archiveUID) : String(index));
      const kind = classifyObject(className);
      if (objects.length < 2e4)
        objects.push(
          objectNode.parse({
            id: objectId,
            kind,
            class_name: className,
            name: firstString(
              fields.label,
              fields.title,
              fields.identifier,
              fields.accessibilityLabel,
              className
            ) ?? `object ${String(index)}`,
            attributes: jsonSafeRecord(fields)
          })
        );
      if (/(?:Outlet|Connection|Segue|ActionConnection|ControlConnector)/iu.test(
        className
      )) {
        const controlAction = /ControlConnector/iu.test(className);
        const source2 = firstObjectReference(
          controlAction ? fields.destination : fields.source,
          archivedObjectReference(fields.NSSource),
          controlAction ? fields.to : fields.from,
          controlAction ? fields.target : fields.owner
        );
        if (source2 === null) continue;
        const kind2 = controlAction ? "action" : classifyConnection(className);
        const parsedConnection = connection.parse({
          id: `archive:${objectId}`,
          kind: kind2,
          source_id: source2,
          destination_id: firstObjectReference(
            controlAction ? fields.source : fields.destination,
            archivedObjectReference(fields.NSDestination),
            controlAction ? fields.from : fields.to,
            controlAction ? fields.owner : fields.target
          ),
          label: firstString(
            fields.label,
            fields.NSLabel,
            fields.selector,
            fields.identifier,
            fields.action
          ),
          attributes: jsonSafeRecord(fields)
        });
        if (connections.length < 4e4) connections.push(parsedConnection);
        else omittedConnections += 1;
      }
    }
    const top = record2(root.$top);
    const hierarchy = toHierarchy(top.root ?? top.UITopLevelObjectsKey);
    const classes = Object.fromEntries(
      objectTable.flatMap((raw) => {
        const item = record2(raw);
        const name = firstString(item.$classname);
        return name === null ? [] : [
          [
            name,
            {
              superclasses: Array.isArray(item.$classes) ? item.$classes : []
            }
          ]
        ];
      })
    );
    return {
      objects,
      connections,
      hierarchy: hierarchy.items,
      classes,
      objectCount,
      omittedObjects: Math.max(0, objectCount - 2e4),
      omittedConnections,
      omittedHierarchyReferences: hierarchy.omittedReferences
    };
  };
  var record2 = (value) => recordSchema.safeParse(value).data ?? {};
  var firstString = (...values) => {
    for (const value of values)
      if (typeof value === "string" && value.length > 0) return value;
    return null;
  };
  var archivedObjectReference = (value) => {
    const item = record2(value);
    if (typeof item.archiveUID !== "number") return null;
    return firstString(item.objectID, item["object-id"]) ?? String(item.archiveUID);
  };
  var firstObjectReference = (...values) => {
    for (const value of values) {
      const direct = firstString(value);
      if (direct !== null) return direct;
      const item = record2(value);
      const objectId = firstString(
        item.objectID,
        item["object-id"],
        item.id,
        item.identifier,
        typeof item.archiveUID === "number" ? String(item.archiveUID) : null
      );
      if (objectId !== null) return objectId;
    }
    return null;
  };
  var classifyObject = (className) => {
    const value = className?.toLowerCase() ?? "";
    if (value.includes("constraint")) return "constraint";
    if (value.includes("layoutguide")) return "layout_guide";
    if (value.includes("placeholder") || value.includes("firstresponder") || value === "uiproxyobject")
      return "placeholder";
    if (value.includes("image") || value.includes("color") || value.includes("font"))
      return "resource";
    if (value.includes("external")) return "external_object";
    if (value.includes("viewcontroller") || value.includes("windowcontroller"))
      return "view_controller";
    if (value.includes("button") || value.includes("control") || value.includes("textfield") || value.includes("slider") || value.includes("menuitem"))
      return "control";
    if (value.includes("view") || value.includes("window") || value.includes("cell"))
      return "view";
    return "other";
  };
  var classifyConnection = (type) => {
    const value = type.toLowerCase();
    if (value.includes("outlet")) return "outlet";
    if (value.includes("action")) return "action";
    if (value.includes("segue")) return "segue";
    return "other";
  };
  var jsonSafeRecord = (value) => Object.fromEntries(
    Object.entries(value).flatMap(([key, item]) => {
      try {
        const serialized = JSON.stringify(item);
        if (serialized === void 0) return [];
        const parsed = jsonValueSchema.safeParse(JSON.parse(serialized));
        return parsed.success ? [[key, parsed.data]] : [];
      } catch (cause) {
        void cause;
        return [];
      }
    })
  );

  // ThirdParty/REA/upstream/src/domain/native/nativeInvestigationGraph.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/native/objcSwiftMetadata.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/unicodeCodePointOrder.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/native/objcSwiftMetadata.ts
  var objcMethodTypeSchema = external_exports.enum([
    "instance",
    "class",
    "ivar_getter",
    "ivar_setter"
  ]);
  var objcPropertyAttributeSchema = external_exports.strictObject({
    name: external_exports.string().min(1),
    value: external_exports.string()
  });
  var objcMethodSchema = external_exports.strictObject({
    selector: external_exports.string().min(1),
    method_type: objcMethodTypeSchema,
    address: external_exports.number().int().nullable(),
    is_required: external_exports.boolean().nullable(),
    is_optional: external_exports.boolean().nullable()
  });
  var objcPropertySchema = external_exports.strictObject({
    name: external_exports.string().min(1),
    type_encoding: external_exports.string().nullable(),
    attributes: external_exports.array(objcPropertyAttributeSchema),
    atomicity: external_exports.enum(["atomic", "nonatomic"]).nullable(),
    is_readonly: external_exports.boolean().nullable(),
    getter: external_exports.string().nullable(),
    setter: external_exports.string().nullable()
  });
  var objcProtocolSchema = external_exports.strictObject({
    name: external_exports.string().min(1),
    methods: external_exports.array(objcMethodSchema).default([]),
    optional_methods: external_exports.array(objcMethodSchema).default([]),
    properties: external_exports.array(objcPropertySchema).default([])
  });
  var objcClassSchema = external_exports.strictObject({
    name: external_exports.string().min(1),
    super_class: external_exports.string().nullable(),
    is_meta_class: external_exports.boolean().nullable(),
    is_root_class: external_exports.boolean().nullable(),
    methods: external_exports.array(objcMethodSchema).default([]),
    properties: external_exports.array(objcPropertySchema).default([]),
    protocols: external_exports.array(external_exports.string()).default([]),
    ivar_count: external_exports.number().int().nonnegative().nullable(),
    instance_size: external_exports.number().int().nonnegative().nullable(),
    location: external_exports.object({
      address: external_exports.string().nullable(),
      file_offset: external_exports.number().int().nonnegative().nullable()
    }).optional(),
    superclass_address: external_exports.string().nullable().optional(),
    metaclass_address: external_exports.string().nullable().optional(),
    decode: external_exports.object({
      status: external_exports.enum(["decoded", "partial", "unsupported", "invalid"]),
      reason: external_exports.string().nullable()
    }).optional(),
    evidence: external_exports.array(
      external_exports.object({
        kind: external_exports.literal("binary_metadata"),
        description: external_exports.string(),
        location: external_exports.object({
          address: external_exports.string().nullable(),
          file_offset: external_exports.number().int().nonnegative().nullable()
        }),
        artifact_path: external_exports.string(),
        artifact_sha256: external_exports.string()
      })
    ).optional()
  });
  var nativeMetadataLocationSchema = external_exports.strictObject({
    address: external_exports.string().nullable(),
    file_offset: external_exports.number().int().nonnegative().nullable()
  });
  var nativeMetadataDecodeSchema = external_exports.strictObject({
    status: external_exports.enum(["decoded", "partial", "unsupported", "invalid"]),
    reason: external_exports.string().nullable()
  });
  var nativeMetadataEvidenceSchema = external_exports.strictObject({
    kind: external_exports.enum([
      "binary_metadata",
      "interface_builder_resource",
      "symbol",
      "reference",
      "decompiler"
    ]),
    description: external_exports.string().min(1),
    location: nativeMetadataLocationSchema,
    artifact_path: external_exports.string().min(1).nullable().default(null),
    artifact_sha256: external_exports.string().regex(/^[a-f0-9]{64}$/u).nullable().default(null)
  });
  var objcIvarSchema = external_exports.strictObject({
    class_name: external_exports.string().min(1),
    name: external_exports.string().min(1),
    type_encoding: external_exports.string().nullable(),
    offset: external_exports.number().int().nonnegative().nullable(),
    size: external_exports.number().int().nonnegative().nullable().default(null),
    alignment: external_exports.number().int().positive().nullable().default(null),
    location: nativeMetadataLocationSchema,
    decode: nativeMetadataDecodeSchema,
    evidence: external_exports.array(nativeMetadataEvidenceSchema).min(1)
  });
  var objcProtocolRecordSchema = external_exports.strictObject({
    name: external_exports.string(),
    adopted_protocols: external_exports.array(external_exports.string()),
    methods: external_exports.array(objcMethodSchema),
    optional_methods: external_exports.array(objcMethodSchema),
    location: nativeMetadataLocationSchema,
    decode: nativeMetadataDecodeSchema,
    evidence: external_exports.array(nativeMetadataEvidenceSchema).min(1)
  });
  var objcDispatchImplementationSchema = external_exports.strictObject({
    class_name: external_exports.string().min(1),
    selector: external_exports.string().min(1),
    method_type: external_exports.enum(["instance", "class"]),
    implementation_address: external_exports.string().nullable(),
    /** Category that adds this method, when it is not defined by the class itself. */
    category: external_exports.string().nullable().optional(),
    location: nativeMetadataLocationSchema,
    decode: nativeMetadataDecodeSchema,
    evidence: external_exports.array(nativeMetadataEvidenceSchema).min(1)
  });
  var objcCategorySchema = external_exports.strictObject({
    name: external_exports.string().min(1),
    /** Extended class; external classes come from the category's bind symbol. */
    class_name: external_exports.string().min(1).nullable(),
    class_source: external_exports.enum(["local", "external", "unresolved"]),
    instance_methods: external_exports.array(external_exports.string()),
    class_methods: external_exports.array(external_exports.string()),
    protocols: external_exports.array(external_exports.string()),
    properties: external_exports.array(objcPropertySchema),
    location: nativeMetadataLocationSchema,
    decode: nativeMetadataDecodeSchema,
    evidence: external_exports.array(nativeMetadataEvidenceSchema).min(1)
  });
  var swiftConformanceSchema = external_exports.strictObject({
    type_name: external_exports.string().min(1),
    protocol_name: external_exports.string().min(1),
    module: external_exports.string().nullable(),
    witness_table: nativeMetadataLocationSchema,
    location: nativeMetadataLocationSchema,
    decode: nativeMetadataDecodeSchema,
    evidence: external_exports.array(nativeMetadataEvidenceSchema).min(1)
  });
  var swiftDispatchSlotSchema = external_exports.strictObject({
    owner: external_exports.string().min(1),
    table_kind: external_exports.enum(["witness_table", "class_vtable"]),
    slot_index: external_exports.number().int().nonnegative(),
    requirement: external_exports.string().nullable(),
    implementation: external_exports.string().nullable(),
    implementation_address: external_exports.string().nullable(),
    thunk_address: external_exports.string().nullable(),
    location: nativeMetadataLocationSchema,
    decode: nativeMetadataDecodeSchema,
    evidence: external_exports.array(nativeMetadataEvidenceSchema).min(1)
  });
  var relativePointerSchema = external_exports.strictObject({
    field: nativeMetadataLocationSchema,
    target: nativeMetadataLocationSchema,
    displacement: external_exports.number().int(),
    indirectable: external_exports.boolean(),
    indirect: external_exports.boolean().nullable(),
    decode: nativeMetadataDecodeSchema,
    evidence: external_exports.array(nativeMetadataEvidenceSchema).min(1)
  });
  var swiftSymbolSchema = external_exports.strictObject({
    mangled_name: external_exports.string().min(1),
    address: external_exports.string().min(1),
    decode: nativeMetadataDecodeSchema,
    evidence: external_exports.array(nativeMetadataEvidenceSchema).min(1)
  });
  var nativeMetadataCoverageSchema = external_exports.strictObject({
    facet: external_exports.string().min(1),
    status: external_exports.enum(["complete", "partial", "unsupported", "not_requested"]),
    reason: external_exports.string().nullable(),
    examined: external_exports.number().int().nonnegative(),
    decoded: external_exports.number().int().nonnegative()
  });
  var swiftDeclKindSchema = external_exports.enum([
    "class",
    "struct",
    "enum",
    "protocol",
    "extension",
    "actor",
    "global_var",
    "global_func"
  ]);
  var swiftAccessLevelSchema = external_exports.enum([
    "private",
    "fileprivate",
    "internal",
    "public",
    "open"
  ]);
  var swiftDeclSchema = external_exports.strictObject({
    kind: swiftDeclKindSchema,
    name: external_exports.string().min(1),
    module: external_exports.string().nullable(),
    access_level: swiftAccessLevelSchema.default("internal"),
    super_class: external_exports.string().nullable(),
    protocols: external_exports.array(external_exports.string()).default([]),
    is_final: external_exports.boolean().default(false),
    is_required: external_exports.boolean().default(false),
    is_convenience_init: external_exports.boolean().default(false),
    is_override: external_exports.boolean().default(false)
  });
  var dbOperationSchema = external_exports.enum([
    "save",
    "readback",
    "open_database",
    "close_database",
    "export",
    "import"
  ]);
  var dbSaveResultSchema = external_exports.strictObject({
    operation: dbOperationSchema,
    succeeded: external_exports.boolean(),
    preserved_names: external_exports.number().int().nonnegative().default(0),
    preserved_comments: external_exports.number().int().nonnegative().default(0),
    preserved_bookmarks: external_exports.number().int().nonnegative().default(0),
    database_path: external_exports.string().nullable(),
    error: external_exports.string().nullable()
  });
  var objcSwiftMetadataSchema = external_exports.strictObject({
    objc_classes: external_exports.array(objcClassSchema).default([]),
    objc_protocols: external_exports.array(objcProtocolSchema).default([]),
    objc_categories: external_exports.array(objcCategorySchema).default([]),
    swift_decls: external_exports.array(swiftDeclSchema).default([]),
    objc_ivars: external_exports.array(objcIvarSchema).default([]),
    objc_protocol_records: external_exports.array(objcProtocolRecordSchema).default([]),
    objc_dispatch_implementations: external_exports.array(objcDispatchImplementationSchema).default([]),
    swift_conformances: external_exports.array(swiftConformanceSchema).default([]),
    swift_dispatch_slots: external_exports.array(swiftDispatchSlotSchema).default([]),
    swift_symbols: external_exports.array(swiftSymbolSchema).default([]),
    relative_pointers: external_exports.array(relativePointerSchema).default([]),
    coverage: external_exports.array(nativeMetadataCoverageSchema).default([]),
    db_save_result: dbSaveResultSchema.nullable()
  });
  var nativeDispatchMetadataResultSchema = external_exports.strictObject({
    target_sha256: external_exports.string().regex(/^[a-f0-9]{64}$/u).nullable(),
    provider: external_exports.strictObject({
      id: external_exports.string().min(1),
      name: external_exports.string().min(1),
      version: external_exports.string().nullable()
    }),
    analysis_profile_digest: external_exports.string().min(1).nullable(),
    result: objcSwiftMetadataSchema
  });

  // ThirdParty/REA/upstream/src/domain/native/nativeInvestigationGraph.ts
  var nativeInvestigationNodeKindSchema = external_exports.enum([
    "storyboard",
    "scene",
    "view_controller",
    "view",
    "control",
    "constraint",
    "layout_guide",
    "resource",
    "placeholder",
    "external_object",
    "outlet",
    "action",
    "segue",
    "objc_class",
    "objc_selector",
    "swift_declaration",
    "swift_requirement",
    "dispatch_table",
    "dispatch_slot",
    "thunk",
    "function",
    "state_value",
    "global_value",
    "field",
    "branch_condition",
    "sink",
    "unknown"
  ]);
  var nativeInvestigationNodeSchema = external_exports.strictObject({
    id: external_exports.string().min(1),
    kind: nativeInvestigationNodeKindSchema,
    name: external_exports.string().min(1),
    location: nativeMetadataLocationSchema.nullable(),
    attributes: external_exports.record(external_exports.string(), jsonValueSchema),
    evidence: external_exports.array(nativeMetadataEvidenceSchema)
  });
  var nativeInvestigationRelationSchema = external_exports.enum([
    "contains",
    "outlet_to",
    "target_action",
    "segue_to",
    "objc_dispatch",
    "swift_witness_dispatch",
    "swift_vtable_dispatch",
    "thunk_to",
    "direct_call",
    "indirect_call",
    "provider_call",
    "reads",
    "writes",
    "flows_to",
    "controls"
  ]);
  var nativeInvestigationEdgeSchema = external_exports.discriminatedUnion(
    "resolution",
    [
      external_exports.strictObject({
        id: external_exports.string().min(1),
        from: external_exports.string().min(1),
        to: external_exports.string().min(1),
        relation: nativeInvestigationRelationSchema,
        resolution: external_exports.enum(["observed", "inferred", "resolved", "ambiguous"]),
        evidence: external_exports.array(nativeMetadataEvidenceSchema).min(1),
        limitations: external_exports.array(external_exports.string())
      }),
      external_exports.strictObject({
        id: external_exports.string().min(1),
        from: external_exports.string().min(1),
        to: external_exports.null(),
        relation: nativeInvestigationRelationSchema,
        resolution: external_exports.literal("unresolved"),
        reason: external_exports.string().min(1),
        evidence: external_exports.array(nativeMetadataEvidenceSchema),
        limitations: external_exports.array(external_exports.string())
      })
    ]
  );
  var nativeInvestigationCoverageSchema = external_exports.strictObject({
    facet: external_exports.string().min(1),
    status: external_exports.enum(["complete", "partial", "unsupported", "not_requested"]),
    reason: external_exports.string().nullable(),
    examined: external_exports.number().int().nonnegative(),
    omitted: external_exports.number().int().nonnegative()
  });
  var nativeInvestigationGraphSchema = external_exports.strictObject({
    target_sha256: external_exports.string().regex(/^[a-f0-9]{64}$/u),
    provider: external_exports.strictObject({
      id: external_exports.string().min(1),
      version: external_exports.string().nullable(),
      tool_version: external_exports.string().min(1)
    }),
    nodes: external_exports.array(nativeInvestigationNodeSchema),
    edges: external_exports.array(nativeInvestigationEdgeSchema),
    coverage: external_exports.array(nativeInvestigationCoverageSchema),
    truncated: external_exports.boolean()
  });
  var nativeInvestigationTraceLimitsSchema = external_exports.strictObject({
    max_depth: external_exports.number().int().min(0).max(32).default(8),
    max_nodes: external_exports.number().int().min(1).max(2e3).default(250),
    max_edges: external_exports.number().int().min(1).max(5e3).default(500)
  });
  var nativeInvestigationTraceSchema = external_exports.strictObject({
    target_sha256: external_exports.string().regex(/^[a-f0-9]{64}$/u),
    provider: nativeInvestigationGraphSchema.shape.provider,
    start: external_exports.string().min(1),
    direction: external_exports.enum(["forward", "backward"]),
    nodes: external_exports.array(nativeInvestigationNodeSchema),
    edges: external_exports.array(nativeInvestigationEdgeSchema),
    unresolved: external_exports.array(nativeInvestigationEdgeSchema),
    reached_depth: external_exports.number().int().nonnegative(),
    truncated: external_exports.boolean(),
    reason: external_exports.string().nullable(),
    coverage: external_exports.array(nativeInvestigationCoverageSchema),
    limitations: external_exports.array(external_exports.string().min(1))
  });
  var joinInterfaceBuilderDispatch = (graph, metadata) => {
    const nodes = new Map(graph.nodes.map((node) => [node.id, node]));
    const edges = [...graph.edges];
    const existingEdgeIds = new Set(edges.map(({ id }) => id));
    const selectorNodesByAction = /* @__PURE__ */ new Map();
    for (const edge of edges) {
      if (edge.resolution === "observed" && edge.relation === "target_action" && nodes.get(edge.to)?.kind === "objc_selector")
        selectorNodesByAction.set(edge.from, edge.to);
    }
    let examined = 0;
    let resolved = 0;
    let inferredWithoutOwnerClass = 0;
    for (const action of nodes.values()) {
      if (action.kind !== "action") continue;
      const selector = action.attributes.selector;
      if (typeof selector !== "string" || selector.length === 0) continue;
      const selectorNodeId = selectorNodesByAction.get(action.id);
      if (selectorNodeId === void 0) continue;
      const destinationEdge = edges.find(
        (edge) => edge.resolution === "observed" && edge.relation === "target_action" && edge.from === action.id && ["view_controller", "placeholder", "external_object"].includes(
          nodes.get(edge.to)?.kind ?? ""
        )
      );
      if (destinationEdge === void 0 || destinationEdge.resolution !== "observed")
        continue;
      const owner = nodes.get(destinationEdge.to);
      examined += 1;
      const declaredClass = owner?.attributes.class_name;
      const className = typeof declaredClass === "string" && declaredClass.length > 0 && owner?.kind === "view_controller" ? declaredClass : null;
      const candidates = metadata.objc_dispatch_implementations.filter(
        (candidate) => candidate.method_type === "instance" && candidate.selector === selector && (className === null || candidate.class_name.replace(/\([^)]*\)$/u, "") === className)
      );
      const implementation = candidates.length === 1 ? candidates[0] : void 0;
      const edgeId = `dispatch:${selectorNodeId}:${className ?? owner?.id ?? "unknown"}:${selector}`;
      if (existingEdgeIds.has(edgeId)) continue;
      existingEdgeIds.add(edgeId);
      if (implementation === void 0 || implementation.implementation_address === null) {
        edges.push({
          id: edgeId,
          from: selectorNodeId,
          to: null,
          relation: "objc_dispatch",
          resolution: "unresolved",
          reason: candidates.length > 1 ? "selector_has_multiple_candidate_implementations" : "implementation_not_resolved_from_binary_metadata_or_provider_symbols",
          evidence: [
            ...action.evidence,
            ...candidates.flatMap(({ evidence }) => evidence)
          ],
          limitations: [
            "A missing or ambiguous symbol match does not prove that the runtime implementation is absent."
          ]
        });
        continue;
      }
      const functionId = `native:function:${implementation.implementation_address}`;
      if (!nodes.has(functionId))
        nodes.set(functionId, {
          id: functionId,
          kind: "function",
          name: `${implementation.class_name} ${selector}`,
          location: {
            address: implementation.implementation_address,
            file_offset: implementation.location.file_offset
          },
          attributes: {
            class_name: implementation.class_name,
            selector,
            method_type: implementation.method_type
          },
          evidence: implementation.evidence
        });
      edges.push({
        id: edgeId,
        from: selectorNodeId,
        to: functionId,
        relation: "objc_dispatch",
        resolution: className !== null && implementation.decode.status === "decoded" ? "resolved" : "inferred",
        evidence: [...action.evidence, ...implementation.evidence],
        limitations: className === null ? [
          "The selector uniquely matches a encoded or symbolized method, but the Interface Builder receiver is an unresolved placeholder; runtime dispatch was not observed."
        ] : [
          "The Interface Builder target and encoded or symbolized method agree on class and selector; runtime dispatch and dynamically supplied targets were not observed."
        ]
      });
      resolved += 1;
      if (className === null) inferredWithoutOwnerClass += 1;
    }
    return nativeInvestigationGraphSchema.parse({
      ...graph,
      provider: {
        id: "rea-native-investigation",
        version: null,
        tool_version: "rea-native-investigation/1"
      },
      nodes: [...nodes.values()],
      edges,
      coverage: [
        ...graph.coverage,
        {
          facet: "ui_to_objc_dispatch",
          status: examined === resolved && inferredWithoutOwnerClass === 0 ? "complete" : "partial",
          reason: examined === resolved && inferredWithoutOwnerClass === 0 ? null : inferredWithoutOwnerClass > 0 ? "some_action_receivers_remain_placeholders" : "some_action_implementations_not_resolved",
          examined,
          omitted: examined - resolved + inferredWithoutOwnerClass
        }
      ]
    });
  };

  // ThirdParty/REA/upstream/src/domain/apple/interfaceBuilderGraph.ts
  var interfaceBuilderDocumentSchema = external_exports.strictObject({
    relative_path: external_exports.string().min(1),
    archive_sha256: external_exports.string().regex(/^[a-f0-9]{64}$/u),
    document_kind: external_exports.enum(["nib", "storyboard_scene"]),
    object_count: external_exports.number().int().nonnegative(),
    connection_count: external_exports.number().int().nonnegative(),
    hierarchy_complete: external_exports.boolean()
  });
  var interfaceBuilderAnalysisSchema = external_exports.strictObject({
    target_sha256: external_exports.string().regex(/^[a-f0-9]{64}$/u),
    documents: external_exports.array(interfaceBuilderDocumentSchema).max(64),
    graph: nativeInvestigationGraphSchema,
    limitations: external_exports.array(external_exports.string())
  });
  var buildInterfaceBuilderAnalysis = (input) => {
    const nodes = /* @__PURE__ */ new Map();
    const edges = [];
    const coverage = [];
    const summaries = [];
    let truncated = false;
    let omittedObjects = 0;
    let omittedConnections = 0;
    let omittedGraphNodes = 0;
    let omittedHierarchyReferences = 0;
    for (const document of input.documents.slice(0, input.limits.max_documents)) {
      const parsed = parseInterfaceBuilderRecords(document.raw);
      const prefix = `ib:${document.relativePath}:`;
      const rootId = `${prefix}root`;
      const objectIds = new Set(parsed.objects.map(({ id }) => id));
      const evidenceFor = (description) => [
        {
          kind: "interface_builder_resource",
          description: `${document.relativePath}: ${description}`,
          location: { address: null, file_offset: null },
          artifact_path: document.relativePath,
          artifact_sha256: document.archiveSha256
        }
      ];
      const addNode = (node) => {
        if (nodes.has(node.id)) return true;
        if (nodes.size >= input.limits.max_objects) {
          truncated = true;
          omittedGraphNodes += 1;
          return false;
        }
        nodes.set(node.id, node);
        return true;
      };
      const rootNode = {
        id: rootId,
        kind: document.documentKind === "nib" ? "scene" : "storyboard",
        name: document.relativePath,
        location: null,
        attributes: { document_kind: document.documentKind },
        evidence: evidenceFor("compiled document")
      };
      addNode(rootNode);
      let documentObjectCount = 0;
      for (const object2 of parsed.objects.slice(0, input.limits.max_objects)) {
        const id = `${prefix}object:${object2.id}`;
        const kind = object2.kind === "other" ? "unknown" : object2.kind;
        if (!addNode({
          id,
          kind,
          name: object2.name,
          location: null,
          attributes: {
            ...object2.attributes,
            interface_builder_object_id: object2.id,
            class_name: object2.class_name
          },
          evidence: evidenceFor(`object ${object2.id}`)
        })) {
          break;
        }
        documentObjectCount += 1;
      }
      let connectionEdgeCount = 0;
      let hierarchyEdgeCount = 0;
      let documentOmittedConnections = 0;
      let documentOmittedHierarchyEdges = 0;
      const objectNodeId = (objectId) => `${prefix}object:${objectId}`;
      const addEdge = (edge, isHierarchy) => {
        if (isHierarchy ? hierarchyEdgeCount >= input.limits.max_objects : connectionEdgeCount >= input.limits.max_connections * 3) {
          truncated = true;
          if (isHierarchy) {
            documentOmittedHierarchyEdges += 1;
          } else {
            omittedConnections += 1;
            documentOmittedConnections += 1;
          }
          return;
        }
        edges.push(edge);
        if (isHierarchy) hierarchyEdgeCount += 1;
        else connectionEdgeCount += 1;
      };
      const connect = (id, from, to, relation, description, reason) => {
        if (!nodes.has(from)) {
          truncated = true;
          if (relation === "contains" && id.includes(":hierarchy:")) {
            documentOmittedHierarchyEdges += 1;
          } else {
            omittedConnections += 1;
            documentOmittedConnections += 1;
          }
          return;
        }
        const evidence = evidenceFor(description);
        const unresolvedEndpoint = to !== null && !nodes.has(to);
        if (unresolvedEndpoint) truncated = true;
        const edgeTo = unresolvedEndpoint ? null : to;
        const edgeReason = unresolvedEndpoint ? "endpoint_omitted_by_object_limit" : reason ?? "destination_unresolved";
        addEdge(
          edgeTo === null ? {
            id,
            from,
            to: null,
            relation,
            resolution: "unresolved",
            reason: edgeReason,
            evidence,
            limitations: []
          } : {
            id,
            from,
            to: edgeTo,
            relation,
            resolution: "observed",
            evidence,
            limitations: []
          },
          relation === "contains" && id.includes(":hierarchy:")
        );
      };
      let hierarchyCount = 0;
      let hierarchyTruncated = false;
      const visitHierarchy = (initial, initialParentId) => {
        const pending = [{ value: initial, parentId: initialParentId }];
        while (pending.length > 0) {
          if (hierarchyCount >= input.limits.max_objects) {
            truncated = true;
            hierarchyTruncated = true;
            return;
          }
          const entry = pending.pop();
          if (entry === void 0) break;
          const { value, parentId } = entry;
          if (Array.isArray(value)) {
            for (let index = value.length - 1; index >= 0; index -= 1) {
              const child = value[index];
              if (child !== void 0) pending.push({ value: child, parentId });
            }
            continue;
          }
          if (typeof value !== "object" || value === null) continue;
          const item = record2(value);
          const objectId = firstString(
            item.objectID,
            item["object-id"],
            item.id,
            typeof item.archiveUID === "number" ? String(item.archiveUID) : null
          );
          let nextParent = parentId;
          if (objectId !== null) {
            const known = objectIds.has(objectId);
            const childId = known ? objectNodeId(objectId) : `${prefix}unknown:${objectId}`;
            if (!known && !addNode({
              id: childId,
              kind: "unknown",
              name: firstString(item.label, item.name) ?? objectId,
              location: null,
              attributes: { interface_builder_object_id: objectId },
              evidence: evidenceFor(`hierarchy item ${objectId}`)
            }))
              hierarchyTruncated = true;
            connect(
              `${prefix}hierarchy:${parentId}:${childId}`,
              parentId,
              childId,
              "contains",
              `hierarchy ${objectId}`
            );
            nextParent = childId;
            hierarchyCount += 1;
          }
          pending.push({ value: item.children, parentId: nextParent });
        }
      };
      for (const hierarchy of parsed.hierarchy) visitHierarchy(hierarchy, rootId);
      for (const [index, item] of parsed.connections.slice(0, input.limits.max_connections).entries()) {
        const sourceId = objectNodeId(item.source_id);
        if (!nodes.has(sourceId))
          addNode({
            id: sourceId,
            kind: "unknown",
            name: item.source_id,
            location: null,
            attributes: { interface_builder_object_id: item.source_id },
            evidence: evidenceFor(`connection source ${item.source_id}`)
          });
        const destinationId = item.destination_id === null ? null : objectNodeId(item.destination_id);
        if (item.kind === "action") {
          const actionId = `${prefix}action:${item.id}`;
          const selectorId = item.label === null ? null : `${prefix}selector:${item.destination_id ?? "unknown"}:${item.label}`;
          addNode({
            id: actionId,
            kind: "action",
            name: item.label ?? "unlabeled action",
            location: null,
            attributes: {
              selector: item.label,
              destination_id: item.destination_id,
              ...item.attributes
            },
            evidence: evidenceFor(`action ${item.id}`)
          });
          connect(
            `${actionId}:source`,
            sourceId,
            actionId,
            "target_action",
            `action source ${item.source_id}`
          );
          if (selectorId !== null) {
            addNode({
              id: selectorId,
              kind: "objc_selector",
              name: item.label ?? "unknown selector",
              location: null,
              attributes: { destination_id: item.destination_id },
              evidence: evidenceFor(`selector ${item.label}`)
            });
            connect(
              `${actionId}:selector`,
              actionId,
              selectorId,
              "target_action",
              `selector ${item.label}`
            );
          }
          if (destinationId === null || !nodes.has(destinationId))
            connect(
              `${actionId}:destination`,
              actionId,
              null,
              "target_action",
              `action destination ${item.destination_id ?? "missing"}`,
              "destination_object_missing_or_external"
            );
          else
            connect(
              `${actionId}:destination`,
              actionId,
              destinationId,
              "target_action",
              `action destination ${item.destination_id}`
            );
        } else if (item.kind === "outlet") {
          const outletId = `${prefix}outlet:${item.id}`;
          addNode({
            id: outletId,
            kind: "outlet",
            name: item.label ?? item.id,
            location: null,
            attributes: item.attributes,
            evidence: evidenceFor(`outlet ${item.id}`)
          });
          connect(
            `${outletId}:source`,
            sourceId,
            outletId,
            "contains",
            `outlet source ${item.source_id}`
          );
          if (destinationId === null || !nodes.has(destinationId))
            connect(
              `${outletId}:destination`,
              outletId,
              null,
              "outlet_to",
              `outlet ${item.label ?? item.id}`,
              "destination_object_missing_or_external"
            );
          else
            connect(
              `${outletId}:destination`,
              outletId,
              destinationId,
              "outlet_to",
              `outlet ${item.label ?? item.id}`
            );
        } else if (item.kind === "segue") {
          if (destinationId === null || !nodes.has(destinationId))
            connect(
              `${prefix}segue:${index}`,
              sourceId,
              null,
              "segue_to",
              `segue ${item.label ?? item.id}`,
              "destination_scene_missing"
            );
          else
            connect(
              `${prefix}segue:${index}`,
              sourceId,
              destinationId,
              "segue_to",
              `segue ${item.label ?? item.id}`
            );
        } else {
          connect(
            `${prefix}unknown-connection:${index}`,
            sourceId,
            null,
            "contains",
            `connection type ${item.kind}`,
            "unsupported_connection_type"
          );
        }
      }
      const objectsTruncated = parsed.omittedObjects > 0 || parsed.objects.length > documentObjectCount;
      const parserOmittedHierarchyReferences = parsed.omittedHierarchyReferences;
      omittedHierarchyReferences += parserOmittedHierarchyReferences;
      const parserOmittedConnections = parsed.omittedConnections;
      const connectionsTruncated = parserOmittedConnections > 0 || parsed.connections.length > input.limits.max_connections;
      omittedObjects += parsed.omittedObjects + Math.max(0, parsed.objects.length - documentObjectCount);
      omittedConnections += Math.max(0, parsed.connections.length - input.limits.max_connections) + parserOmittedConnections;
      summaries.push({
        relative_path: document.relativePath,
        archive_sha256: document.archiveSha256,
        document_kind: document.documentKind,
        object_count: parsed.objectCount,
        connection_count: parsed.connections.length + parserOmittedConnections,
        hierarchy_complete: parsed.hierarchy.length > 0 && !truncated && parserOmittedHierarchyReferences === 0
      });
      coverage.push(
        {
          facet: `objects:${document.relativePath}`,
          status: objectsTruncated ? "partial" : "complete",
          reason: objectsTruncated ? "object_limit_reached" : null,
          examined: documentObjectCount,
          omitted: parsed.omittedObjects + Math.max(0, parsed.objects.length - documentObjectCount)
        },
        {
          facet: `connections:${document.relativePath}`,
          status: connectionsTruncated || documentOmittedConnections > 0 ? "partial" : "complete",
          reason: connectionsTruncated || documentOmittedConnections > 0 ? "connection_limit_reached" : null,
          examined: Math.min(
            parsed.connections.length,
            input.limits.max_connections
          ),
          omitted: Math.max(
            0,
            parsed.connections.length - input.limits.max_connections
          ) + documentOmittedConnections + parserOmittedConnections
        },
        {
          facet: `hierarchy:${document.relativePath}`,
          status: parserOmittedHierarchyReferences > 0 ? "partial" : parsed.hierarchy.length === 0 ? "unsupported" : hierarchyTruncated || documentOmittedHierarchyEdges > 0 ? "partial" : "complete",
          reason: parserOmittedHierarchyReferences > 0 ? "archive_hierarchy_references_missing" : parsed.hierarchy.length === 0 ? "archive_hierarchy_not_decoded" : hierarchyTruncated || documentOmittedHierarchyEdges > 0 ? "graph_limit_reached" : null,
          examined: hierarchyCount,
          omitted: documentOmittedHierarchyEdges + parserOmittedHierarchyReferences
        },
        {
          facet: `classes:${document.relativePath}`,
          status: Object.keys(parsed.classes).length > 0 ? "complete" : "unsupported",
          reason: Object.keys(parsed.classes).length > 0 ? null : "archive_class_table_not_decoded",
          examined: Object.keys(parsed.classes).length,
          omitted: 0
        }
      );
    }
    if (input.documents.length > input.limits.max_documents) {
      truncated = true;
      coverage.push({
        facet: "documents",
        status: "partial",
        reason: "document_limit_reached",
        examined: input.limits.max_documents,
        omitted: input.documents.length - input.limits.max_documents
      });
    }
    if (omittedGraphNodes > 0)
      coverage.push({
        facet: "graph_nodes",
        status: "partial",
        reason: "max_objects_reached",
        examined: nodes.size,
        omitted: omittedGraphNodes
      });
    return interfaceBuilderAnalysisSchema.parse({
      target_sha256: input.targetSha256,
      documents: summaries,
      graph: {
        target_sha256: input.targetSha256,
        provider: {
          id: "rea-artifact-graph",
          version: "1",
          tool_version: input.toolVersion
        },
        nodes: [...nodes.values()],
        edges,
        coverage,
        truncated: truncated || omittedObjects > 0 || omittedConnections > 0 || omittedHierarchyReferences > 0
      },
      limitations: [
        "The graph reflects recognized Interface Builder archive fields and connections; omitted private or unrecognized archive fields remain unknown.",
        "A target-action selector is an Interface Builder observation and does not prove that the binary contains a matching implementation.",
        "Decoded constraints, runtime visibility, dynamic UI creation, and pixel geometry are not inferred from these archives."
      ]
    });
  };
  var interfaceBuilderLimitsSchema = external_exports.strictObject({
    max_documents: external_exports.number().int().min(1).max(64).default(64),
    max_objects: external_exports.number().int().min(1).max(2e4).default(2e4),
    max_connections: external_exports.number().int().min(1).max(4e4).default(4e4),
    trace: nativeInvestigationTraceLimitsSchema.default({
      max_depth: 8,
      max_nodes: 250,
      max_edges: 500
    })
  });

  // ThirdParty/REA/upstream/src/domain/apple/keyedArchive.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/analysisErrorCore.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/analysisErrorBase.ts
  init_runtime();
  var AnalysisError = class extends Error {
    capturedOutput;
    cleanup;
    cleanupIncomplete;
    cleanupResources;
    constructor(message, options) {
      super(message, options);
      this.capturedOutput = options?.capturedOutput === void 0 ? void 0 : { ...options.capturedOutput };
      this.cleanup = options?.cleanup;
      this.cleanupIncomplete = options?.cleanup !== void 0;
      this.cleanupResources = options?.cleanup?.resources ?? [];
      this.partialObservation = options?.partialObservation;
    }
    userMessage = void 0;
    userCategory = void 0;
    executionFailure = void 0;
    partialObservation;
    cleanupReport = void 0;
    /** Retain a completed observation when a later step fails. */
    retainPartialObservation(observation) {
      this.partialObservation ??= observation;
      return this;
    }
  };

  // ThirdParty/REA/upstream/src/domain/analysisErrorCore.ts
  var AnalysisInputError = class extends AnalysisError {
    constructor(operation, options, issues = []) {
      super(`Invalid analysis input for ${operation}`, options);
      this.operation = operation;
      this.issues = issues;
    }
    operation;
    issues;
    _tag = "AnalysisInputError";
  };
  var AnalysisOutputError = class extends AnalysisError {
    constructor(operation, reason, options) {
      super(`Invalid analysis output for ${operation}: ${reason}`, options);
      this.operation = operation;
      this.reason = reason;
    }
    operation;
    reason;
    _tag = "AnalysisOutputError";
  };

  // ThirdParty/REA/upstream/src/domain/apple/keyedArchive.ts
  var KeyedArchiveKindError = class extends TypeError {
    constructor(message, kind) {
      super(message);
      this.kind = kind;
    }
    kind;
    name = "KeyedArchiveKindError";
  };
  var keyedArchiveInputSchema = external_exports.strictObject({
    path: external_exports.string().min(1).default("."),
    root: external_exports.string().optional(),
    offset: external_exports.number().int().min(0).default(0),
    limit: external_exports.number().int().min(1).max(2e4).default(2e4)
  });
  var linkSchema = external_exports.strictObject({
    source: external_exports.number().int().nonnegative().nullable(),
    path: external_exports.array(external_exports.union([external_exports.string(), external_exports.number().int().nonnegative()])),
    target: external_exports.number().int().nonnegative().nullable(),
    status: external_exports.enum(["resolved", "nil", "unresolved", "malformed"]),
    raw: jsonValueSchema
  });
  var keyedArchiveResultSchema = external_exports.strictObject({
    target_sha256: external_exports.string(),
    archive_path: external_exports.string(),
    archive_sha256: external_exports.string(),
    archive_format: external_exports.enum(["binary-plist", "xml-plist"]),
    roots: external_exports.record(external_exports.string(), jsonValueSchema),
    objects: external_exports.array(
      external_exports.strictObject({
        id: external_exports.number().int().nonnegative(),
        kind: external_exports.enum([
          "nil",
          "scalar",
          "array",
          "dictionary",
          "class-descriptor",
          "archived-object"
        ]),
        class_id: external_exports.number().int().nonnegative().nullable(),
        class_name: external_exports.string().nullable(),
        status: external_exports.enum(["observed", "unknown-class", "unresolved-class", "nil"]),
        value: jsonValueSchema
      })
    ),
    references: external_exports.array(linkSchema),
    total_objects: external_exports.number().int().nonnegative(),
    total_references: external_exports.number().int().nonnegative(),
    offset: external_exports.number().int().nonnegative(),
    next_offset: external_exports.number().int().nonnegative().nullable(),
    truncated: external_exports.boolean(),
    limitations: external_exports.array(external_exports.string())
  });
  var record3 = (value) => value !== null && typeof value === "object" && !Array.isArray(value) ? value : void 0;
  var uid = (value) => {
    const object2 = record3(value);
    if (object2 === void 0 || Object.keys(object2).length !== 1)
      return void 0;
    const marker = Object.hasOwn(object2, "UID") ? object2.UID : object2["CF$UID"];
    return typeof marker === "number" ? marker : void 0;
  };
  var archiverMismatch = (archive) => {
    if (archive === void 0) return "its root is not a dictionary";
    if (!Object.hasOwn(archive, "$archiver")) return "it has no $archiver key";
    return typeof archive.$archiver === "string" ? `its $archiver is ${JSON.stringify(archive.$archiver)}` : "its $archiver is not a string";
  };
  var projectKeyedArchive = (value, selection) => {
    const archive = record3(jsonValueSchema.parse(value));
    if (archive?.$archiver !== "NSKeyedArchiver")
      throw new KeyedArchiveKindError(
        `Selected property list is not an NSKeyedArchiver archive: ${archiverMismatch(archive)}`,
        "property-list"
      );
    if (!Array.isArray(archive.$objects))
      throw new TypeError("Expected NSKeyedArchiver with an $objects array");
    const table = archive.$objects;
    if (table.length > 2e5)
      throw new RangeError("Archive exceeds 200000 object-table entries");
    const top = record3(archive.$top);
    if (top === void 0 || Object.keys(top).length === 0)
      throw new TypeError("Keyed archive has no $top roots");
    if (selection.root !== void 0 && !Object.hasOwn(top, selection.root))
      throw new AnalysisInputError("inspect_keyed_archive", void 0, [
        {
          path: ["root"],
          reason: "invalid_value",
          message: `Archive root does not exist: ${selection.root}. Select one of the archive's $top roots or omit root.`,
          expected: Object.keys(top)
        }
      ]);
    const roots = selection.root === void 0 ? top : { [selection.root]: top[selection.root] ?? null };
    const references = [];
    const scan = (source2, initial) => {
      const pending = [
        { value: initial, path: [] }
      ];
      let visited = 0;
      while (pending.length > 0) {
        const item = pending.pop();
        if (item === void 0) break;
        if (++visited > 2e5 || item.path.length > 128)
          throw new RangeError(
            "Archive exceeds 200000 values per object or 128 nesting levels"
          );
        const target = uid(item.value);
        if (target !== void 0) {
          const index = Number.isSafeInteger(target) && target >= 0 ? target : null;
          references.push({
            source: source2,
            path: item.path,
            target: index,
            raw: item.value,
            status: index === null ? "malformed" : index >= table.length ? "unresolved" : index === 0 && table[0] === "$null" ? "nil" : "resolved"
          });
        } else if (Array.isArray(item.value)) {
          for (let index = item.value.length - 1; index >= 0; index--) {
            const child = item.value[index];
            if (child !== void 0)
              pending.push({ value: child, path: [...item.path, index] });
          }
        } else {
          const fields = record3(item.value);
          if (fields !== void 0)
            for (const key of Object.keys(fields).sort().reverse()) {
              const child = fields[key];
              if (child !== void 0)
                pending.push({ value: child, path: [...item.path, key] });
            }
        }
        if (references.length > 2e5)
          throw new RangeError("Archive exceeds 200000 reference edges");
      }
    };
    scan(null, roots);
    const objects = table.map((value2, id) => {
      scan(id, value2);
      const fields = record3(value2);
      const classUid = uid(fields?.$class);
      const classId = classUid !== void 0 && Number.isSafeInteger(classUid) && classUid >= 0 ? classUid : null;
      const descriptor = classId === null ? void 0 : record3(table[classId]);
      const className = typeof descriptor?.$classname === "string" ? descriptor.$classname : null;
      const isNil = id === 0 && value2 === "$null";
      return {
        id,
        kind: isNil ? "nil" : Array.isArray(value2) ? "array" : fields === void 0 ? "scalar" : typeof fields.$classname === "string" ? "class-descriptor" : Object.hasOwn(fields, "$class") ? "archived-object" : "dictionary",
        class_id: classId,
        class_name: className,
        status: isNil ? "nil" : fields !== void 0 && Object.hasOwn(fields, "$class") ? className === null ? "unresolved-class" : "unknown-class" : "observed",
        value: value2
      };
    });
    const end = Math.min(objects.length, selection.offset + selection.limit);
    const page = objects.slice(selection.offset, end);
    const ids = new Set(page.map(({ id }) => id));
    return {
      roots,
      objects: page,
      references: references.filter(
        ({ source: source2 }) => source2 === null || ids.has(source2)
      ),
      total_objects: objects.length,
      total_references: references.length,
      offset: selection.offset,
      next_offset: end < objects.length ? end : null,
      truncated: page.length !== objects.length,
      limitations: [
        "Archive classes are never instantiated. Class names and serialized fields are observed; class-specific semantics are unknown.",
        "Conditional references serialized as UID 0 cannot be distinguished from ordinary nil references. Missing fields remain absent in the raw serialized value.",
        "Root selection selects the named $top entry; object pagination retains original indices and does not recursively expand references."
      ]
    };
  };

  // ThirdParty/REA/upstream/src/domain/apple/appleAssetCatalog.ts
  init_runtime();
  var appleAssetCatalogInputSchema = external_exports.strictObject({
    offset: external_exports.number().int().min(0).default(0),
    limit: external_exports.number().int().min(1).max(1e4).default(1e3)
  });
  var catalogSchema = external_exports.strictObject({
    path: external_exports.string().min(1),
    sha256: external_exports.string().regex(/^[a-f0-9]{64}$/u),
    record_count: external_exports.number().int().nonnegative()
  });
  var recordSchema2 = external_exports.strictObject({
    catalog_path: external_exports.string().min(1),
    catalog_sha256: external_exports.string().regex(/^[a-f0-9]{64}$/u),
    index: external_exports.number().int().nonnegative(),
    kind: external_exports.enum(["catalog", "rendition"]),
    asset_name: external_exports.string().nullable(),
    rendition_name: external_exports.string().nullable(),
    metadata: external_exports.record(external_exports.string(), jsonValueSchema)
  });
  var resourceKeyMatchSchema = external_exports.strictObject({
    source_node_id: external_exports.string().min(1),
    source_path: external_exports.string().min(1),
    source_archive_sha256: external_exports.string().regex(/^[a-f0-9]{64}$/u),
    field: external_exports.string().min(1),
    key: external_exports.string().min(1),
    status: external_exports.enum(["matched", "ambiguous", "unmatched"]),
    renditions: external_exports.array(
      external_exports.strictObject({
        catalog_path: external_exports.string().min(1),
        catalog_sha256: external_exports.string().regex(/^[a-f0-9]{64}$/u),
        record_index: external_exports.number().int().nonnegative(),
        rendition_name: external_exports.string().nullable()
      })
    )
  });
  var appleAssetCatalogResultSchema = external_exports.strictObject({
    target_sha256: external_exports.string().regex(/^[a-f0-9]{64}$/u),
    catalogs: external_exports.array(catalogSchema),
    total_records: external_exports.number().int().nonnegative(),
    offset: external_exports.number().int().nonnegative(),
    limit: external_exports.number().int().positive(),
    records: external_exports.array(recordSchema2),
    resource_key_matches: external_exports.array(resourceKeyMatchSchema),
    next_offset: external_exports.number().int().nonnegative().nullable(),
    truncated: external_exports.boolean(),
    limitations: external_exports.array(external_exports.string())
  });
  var parseAppleAssetCatalogRecords = (value) => {
    if (!Array.isArray(value))
      throw new AnalysisOutputError(
        "inspect_asset_catalog",
        "assetutil output must be a JSON array"
      );
    return value.map((record4, index) => {
      const parsed = external_exports.record(external_exports.string(), jsonValueSchema).safeParse(record4);
      if (!parsed.success)
        throw new AnalysisOutputError(
          "inspect_asset_catalog",
          `assetutil record ${index} is not a JSON object`,
          { cause: parsed.error }
        );
      return parsed.data;
    });
  };
  var projectAppleAssetCatalogPage = (input) => {
    const all = input.catalogs.flatMap(
      (catalog) => catalog.records.map((metadata, index) => ({
        catalog_path: catalog.path,
        catalog_sha256: catalog.sha256,
        index,
        kind: typeof metadata.RenditionName === "string" || typeof metadata.Name === "string" ? "rendition" : "catalog",
        asset_name: typeof metadata.Name === "string" ? metadata.Name : null,
        rendition_name: typeof metadata.RenditionName === "string" ? metadata.RenditionName : null,
        metadata
      }))
    );
    const records = all.slice(input.offset, input.offset + input.limit);
    const next = input.offset + records.length;
    const recordsByAssetName = /* @__PURE__ */ new Map();
    for (const record4 of all) {
      if (record4.kind !== "rendition" || record4.asset_name === null) continue;
      const matches = recordsByAssetName.get(record4.asset_name) ?? [];
      matches.push(record4);
      recordsByAssetName.set(record4.asset_name, matches);
    }
    const resourceKeyMatches = (input.resourceReferences ?? []).map((source2) => {
      const matches = recordsByAssetName.get(source2.key) ?? [];
      return {
        source_node_id: source2.sourceNodeId,
        source_path: source2.sourcePath,
        source_archive_sha256: source2.sourceArchiveSha256,
        field: source2.field,
        key: source2.key,
        status: matches.length === 0 ? "unmatched" : matches.length === 1 ? "matched" : "ambiguous",
        renditions: matches.map((record4) => ({
          catalog_path: record4.catalog_path,
          catalog_sha256: record4.catalog_sha256,
          record_index: record4.index,
          rendition_name: record4.rendition_name
        }))
      };
    });
    return appleAssetCatalogResultSchema.parse({
      target_sha256: input.targetSha256,
      catalogs: input.catalogs.map(
        ({ path: path3, sha256, records: catalogRecords }) => ({
          path: path3,
          sha256,
          record_count: catalogRecords.length
        })
      ),
      total_records: all.length,
      offset: input.offset,
      limit: input.limit,
      records,
      resource_key_matches: resourceKeyMatches,
      next_offset: next < all.length ? next : null,
      truncated: input.offset > 0 || next < all.length,
      limitations: [
        "Rendition metadata is reported as emitted by the installed assetutil version; private fields and platform-specific interpretations are not normalized.",
        "Asset catalog inspection does not decode or extract rendition image bytes."
      ]
    });
  };

  // ThirdParty/REA/adapters/ui.ts
  var hash2 = external_exports.string().regex(/^[a-f0-9]{64}$/u);
  var path2 = external_exports.string().min(1).max(4096).refine((p) => !p.startsWith("/") && !p.split("/").some((c) => c === ".." || c === "." || c === "") && !p.includes("\\"), "root-relative path");
  var encoded = external_exports.string().max(12 * 1024 * 1024);
  var uiInputSchema = external_exports.strictObject({
    targetSHA256: hash2,
    snapshotID: external_exports.string().min(1).max(256),
    documents: external_exports.array(external_exports.strictObject({ relativePath: path2, archiveSHA256: hash2, kind: external_exports.enum(["nib", "storyboard_scene"]), format: external_exports.enum(["nibArchive", "keyedArchiveJSON"]), bytesBase64: encoded })).max(64),
    omittedDocuments: external_exports.number().int().min(0).max(1e6).default(0),
    omittedCatalogs: external_exports.number().int().min(0).max(1e6).default(0),
    metadata: external_exports.strictObject({ targetSHA256: hash2, snapshotID: external_exports.string().min(1).max(256), value: objcSwiftMetadataSchema }).optional(),
    assetCatalogs: external_exports.array(external_exports.strictObject({ path: path2, sha256: hash2, captureID: external_exports.string().min(1).max(256), toolSHA256: hash2, metadataJSONBase64: encoded, metadataSHA256: hash2 })).max(64).optional()
  });
  var DECODE_BUDGET = 32 * 1024 * 1024;
  var CheckedBudget = class extends InterfaceBuilderDecodeBudget {
    reserve(bytes, message) {
      checkpoint();
      super.reserve(bytes, message);
    }
    tryReserve(bytes) {
      checkpoint();
      return super.tryReserve(bytes);
    }
  };
  function capturedBytes(base643, expected, budget) {
    const estimated = base643.length / 4 * 3;
    budget.reserve(estimated, "captured byte budget exhausted");
    const bytes = import_buffer.Buffer.from(base643, "base64");
    if (bytes.toString("base64") !== base643) throw new Error("noncanonical base64");
    if (sha256Base64(base643) !== expected) throw new Error("captured bytes hash mismatch");
    return bytes;
  }
  function capturedJSON(bytes, budget) {
    budget.reserve(bytes.length * 6, "decoded JSON expansion budget exhausted");
    const value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    guardJSON(value);
    return value;
  }
  function uiResources(raw) {
    guardJSON(raw);
    const input = uiInputSchema.parse(raw);
    checkpoint();
    if (input.metadata && (input.metadata.targetSHA256 !== input.targetSHA256 || input.metadata.snapshotID !== input.snapshotID)) throw new Error("wrong image or snapshot metadata");
    const budget = new CheckedBudget(DECODE_BUDGET);
    const documents = [];
    const coverage = [];
    const seen = /* @__PURE__ */ new Set();
    for (const document of input.documents) {
      checkpoint();
      if (seen.has(document.relativePath)) throw new Error("duplicate archive path");
      seen.add(document.relativePath);
      const bytes = capturedBytes(document.bytesBase64, document.archiveSHA256, budget);
      try {
        let decoded;
        let omitted2 = 0;
        if (document.format === "nibArchive") {
          const archive = decodeNibArchive(bytes, budget);
          const projection = projectNibArchive(archive, budget, 1e4);
          decoded = projection.raw;
          omitted2 = projection.omitted;
        } else {
          decoded = capturedJSON(bytes, budget);
          projectKeyedArchive(decoded, { offset: 0, limit: 1 });
        }
        documents.push({ relativePath: document.relativePath, archiveSha256: document.archiveSHA256, documentKind: document.kind, raw: decoded });
        coverage.push({ facet: document.relativePath, status: omitted2 ? "partial" : "complete", reason: omitted2 ? "hierarchy_references_omitted" : null, examined: 1, omitted: omitted2 });
      } catch (error51) {
        if (!(error51 instanceof TypeError || error51 instanceof SyntaxError || error51 instanceof external_exports.ZodError || error51 instanceof AnalysisOutputError || error51 instanceof AnalysisInputError)) throw error51;
        checkpoint();
        coverage.push({ facet: document.relativePath, status: "unsupported", reason: "malformed_or_unsupported_archive", examined: 1, omitted: 1 });
      }
    }
    const limits = interfaceBuilderLimitsSchema.parse({ max_documents: 64, max_objects: 1e4, max_connections: 2e4 });
    let analysis = buildInterfaceBuilderAnalysis({ targetSha256: input.targetSHA256, toolVersion: "macscope-rea-ui/1", documents, limits });
    analysis = { ...analysis, graph: { ...analysis.graph, nodes: analysis.graph.nodes.map((node) => {
      const values = node.attributes.nibValues;
      if (values && typeof values === "object" && !Array.isArray(values)) {
        const original = values.NSOriginalClassName;
        if (original === "NSViewController" || original === "NSWindowController" || original === "UIViewController") return { ...node, kind: "view_controller" };
      }
      return node;
    }) } };
    checkpoint();
    const dispatchCandidates = input.metadata?.value.objc_dispatch_implementations ?? [];
    for (const candidate of dispatchCandidates) {
      for (const address of [candidate.implementation_address, candidate.location.address]) {
        if (address !== null && !/^(?:0x[0-9a-fA-F]+|[0-9]+)$/u.test(address)) throw new Error("invalid exact address");
      }
    }
    if (input.metadata) {
      analysis = { ...analysis, graph: joinInterfaceBuilderDispatch(analysis.graph, input.metadata.value) };
      const metadataCoverage = input.metadata.value.coverage;
      if (metadataCoverage.length === 0) coverage.push({ facet: "objc_metadata", status: "partial", reason: "metadata_completeness_unspecified", examined: dispatchCandidates.length, omitted: 0 });
      for (const item of metadataCoverage) coverage.push({ facet: "metadata:" + item.facet, status: item.status, reason: item.reason, examined: item.examined, omitted: Math.max(0, item.examined - item.decoded) });
    } else coverage.push({ facet: "objc_metadata", status: "not_requested", reason: "metadata_unavailable", examined: 0, omitted: 0 });
    coverage.push({ facet: "archive_inventory", status: input.omittedDocuments ? "partial" : "complete", reason: input.omittedDocuments ? "archives_omitted" : null, examined: input.documents.length, omitted: input.omittedDocuments });
    if (input.omittedCatalogs > 0) coverage.push({ facet: "asset_catalog_inventory", status: "partial", reason: "catalogs_omitted", examined: input.assetCatalogs?.length ?? 0, omitted: input.omittedCatalogs });
    let assetCatalogs = null;
    const catalogProvenance = [];
    if (input.assetCatalogs === void 0) coverage.push({ facet: "asset_catalogs", status: "not_requested", reason: "catalog_metadata_unavailable", examined: 0, omitted: 0 });
    else {
      const catalogs = [];
      const paths = /* @__PURE__ */ new Set();
      for (const catalog of input.assetCatalogs) {
        checkpoint();
        if (paths.has(catalog.path)) throw new Error("duplicate catalog path");
        paths.add(catalog.path);
        const bytes = capturedBytes(catalog.metadataJSONBase64, catalog.metadataSHA256, budget);
        try {
          const records = parseAppleAssetCatalogRecords(capturedJSON(bytes, budget));
          if (records.length > 1e4) throw new InterfaceBuilderDecodeBudgetExceeded("aggregate_decode_budget_exhausted", "catalog record budget exhausted");
          catalogs.push({ path: catalog.path, sha256: catalog.sha256, records });
          const { metadataJSONBase64, ...provenance } = catalog;
          catalogProvenance.push(provenance);
          coverage.push({ facet: catalog.path, status: "complete", reason: null, examined: records.length, omitted: 0 });
        } catch (error51) {
          if (!(error51 instanceof TypeError || error51 instanceof SyntaxError || error51 instanceof external_exports.ZodError || error51 instanceof AnalysisOutputError || error51 instanceof AnalysisInputError)) throw error51;
          checkpoint();
          coverage.push({ facet: catalog.path, status: "unsupported", reason: "malformed_catalog_metadata", examined: 1, omitted: 1 });
        }
      }
      assetCatalogs = projectAppleAssetCatalogPage({ targetSha256: input.targetSHA256, catalogs, offset: 0, limit: 1e4 });
      if (input.assetCatalogs.length === 0) coverage.push({ facet: "asset_catalogs", status: "not_requested", reason: "no_captured_catalog_metadata", examined: 0, omitted: 0 });
    }
    checkpoint();
    const result = { snapshotID: input.snapshotID, analysis, dispatchCandidates, assetCatalogs, catalogProvenance, coverage, decodedBytes: budget.usedBytes };
    guardJSON(result);
    return result;
  }
  var projectNibArchive = (archive, budget, maxHierarchyNodes) => {
    const byId = new Map(archive.objects.map((object2) => [object2.id, object2]));
    const normalizedClassNames = /* @__PURE__ */ new Map();
    const normalizeClassName = (value) => {
      const known = normalizedClassNames.get(value);
      if (known !== void 0) return known;
      const normalized = value.replace(/\0+$/u, "");
      normalizedClassNames.set(value, normalized);
      return normalized;
    };
    const decodedStrings = /* @__PURE__ */ new Map();
    const decodedString = (objectId, object2) => {
      if (decodedStrings.has(objectId))
        return decodedStrings.get(objectId) ?? null;
      const data = object2.values["NS.bytes"];
      if (typeof data !== "object" || data === null || Array.isArray(data)) {
        decodedStrings.set(objectId, null);
        return null;
      }
      const encoded2 = data.$nib_data_base64;
      if (typeof encoded2 !== "string") {
        decodedStrings.set(objectId, null);
        return null;
      }
      budget.reserve(
        64 + encoded2.length * 2,
        "NIBArchive string projection exceeds the aggregate Interface Builder decode budget"
      );
      const value = import_buffer.Buffer.from(encoded2, "base64").toString("utf8");
      decodedStrings.set(objectId, value);
      return value;
    };
    let projectedFields = 0;
    for (const object2 of archive.objects)
      projectedFields += Object.keys(object2.values).length;
    budget.reserve(
      archive.objects.length * 128 + projectedFields * 128,
      "NIBArchive graph projection exceeds the aggregate Interface Builder decode budget"
    );
    budget.reserve(
      archive.classes.length * 96,
      "NIBArchive class projection exceeds the aggregate Interface Builder decode budget"
    );
    const dereference = (value) => {
      if (typeof value !== "object" || value === null || Array.isArray(value))
        return value;
      const encodedData = value.$nib_data_base64;
      if (typeof encodedData === "string") {
        budget.reserveBase64JsonStringOccurrence(encodedData);
        return value;
      }
      const ref = value.$nib_object_ref;
      if (typeof ref !== "number") return value;
      const target = byId.get(ref);
      if (target === void 0) return void 0;
      if (normalizeClassName(target.class_name) === "NSString") {
        const string4 = decodedString(ref, target);
        if (string4 !== null) {
          budget.reserveJsonStringOccurrence(string4);
          return string4;
        }
      }
      return { objectID: String(ref) };
    };
    const referencedString = (value) => {
      if (typeof value !== "object" || value === null || Array.isArray(value))
        return null;
      const ref = value.$nib_object_ref;
      if (typeof ref !== "number") return null;
      const target = byId.get(ref);
      if (target === void 0 || normalizeClassName(target.class_name) !== "NSString")
        return null;
      const string4 = decodedString(ref, target);
      if (string4 === null) return null;
      budget.reserveJsonStringOccurrence(string4);
      return string4;
    };
    const runtimeClasses = /* @__PURE__ */ new Map();
    const runtimeClass = (objectId) => {
      if (runtimeClasses.has(objectId))
        return runtimeClasses.get(objectId) ?? null;
      const object2 = byId.get(objectId);
      if (object2 === void 0) return null;
      const storedClass = normalizeClassName(object2.class_name);
      const resolvedClass = storedClass === "NSClassSwapper" ? referencedString(object2.values.NSClassName) ?? storedClass : storedClass === "UIClassSwapper" ? referencedString(object2.values.UIClassName) ?? storedClass : storedClass;
      runtimeClasses.set(objectId, resolvedClass);
      return resolvedClass;
    };
    const objects = Object.fromEntries(
      archive.objects.filter((object2) => {
        const name = runtimeClass(object2.id) ?? "";
        return !/^(?:NSObject|NSIBObjectData|NSString|NSMutableString|NSNumber|NSArray|NSMutableArray|NSSet|NSMutableSet|NSDictionary|NSMutableDictionary|NSApplication|NSNib.*Connector|UIRuntime\w*Connection)$/u.test(
          name
        );
      }).map((object2) => {
        const className = runtimeClass(object2.id) ?? normalizeClassName(object2.class_name);
        budget.reserveJsonStringOccurrence(className);
        let name = className;
        for (const [key, value] of Object.entries(object2.values)) {
          if (!/(?:title|label|identifier|accessibility|name|contents)/iu.test(
            key
          ))
            continue;
          const resolved = dereference(value);
          if (typeof resolved !== "string") continue;
          name = resolved;
          break;
        }
        budget.reserveJsonStringOccurrence(name);
        return [
          String(object2.id),
          {
            customClass: className,
            label: name,
            objectID: String(object2.id),
            nibValues: Object.fromEntries(
              Object.entries(object2.values).map(([key, value]) => {
                budget.reserveJsonPropertyNameOccurrence(key);
                return [key, dereference(value) ?? null];
              })
            )
          }
        ];
      })
    );
    const connections = {};
    const hierarchy = [];
    const reference2 = (value) => {
      if (typeof value !== "object" || value === null || Array.isArray(value))
        return null;
      return typeof value.$nib_object_ref === "number" ? value.$nib_object_ref : null;
    };
    for (const object2 of archive.objects) {
      const className = normalizeClassName(object2.class_name);
      const uiKit = /^UIRuntime\w*Connection$/u.test(className);
      if (!uiKit && !className.includes("Connector")) continue;
      const values = object2.values;
      const source2 = reference2(uiKit ? values.UISource : values.NSSource);
      if (source2 === null) continue;
      const destination = reference2(
        uiKit ? values.UIDestination : values.NSDestination
      );
      const label = referencedString(uiKit ? values.UILabel : values.NSLabel);
      const type = className.includes("Outlet") ? "outlet" : className.includes("Control") || className.includes("Event") ? "action" : className;
      budget.reserveJsonStringOccurrence(type);
      const eventMask = values.UIEventMask;
      (connections[String(source2)] ??= []).push({
        type,
        "destination-id": destination === null ? null : String(destination),
        label,
        source_id: String(source2),
        archive_object_id: String(object2.id),
        ...typeof eventMask === "number" ? { ui_event_mask: eventMask } : {}
      });
    }
    let hierarchyOmitted = 0;
    let hierarchyNodeCount = 0;
    const hierarchyFor = (objectId, seen, depth) => {
      if (depth > 32 || seen.has(objectId)) {
        hierarchyOmitted += 1;
        return null;
      }
      if (hierarchyNodeCount >= maxHierarchyNodes) {
        hierarchyOmitted += 1;
        return null;
      }
      if (!budget.tryReserve(128)) {
        hierarchyOmitted += 1;
        return null;
      }
      const object2 = byId.get(objectId);
      if (object2 === void 0) {
        hierarchyOmitted += 1;
        return null;
      }
      hierarchyNodeCount += 1;
      const nextSeen = new Set(seen).add(objectId);
      const children = [];
      for (const [key, value] of Object.entries(object2.values)) {
        if (!/(?:subviews|contentview|childviewcontrollers|view)$/iu.test(key))
          continue;
        const direct = reference2(value);
        if (direct === null) continue;
        const target = byId.get(direct);
        if (target === void 0) {
          hierarchyOmitted += 1;
          continue;
        }
        if (/array|set/iu.test(target.class_name)) {
          for (const candidate of Object.values(target.values)) {
            const child = reference2(candidate);
            const nested = child === null ? null : hierarchyFor(child, nextSeen, depth + 1);
            if (nested !== null) children.push(nested);
          }
        } else {
          const nested = hierarchyFor(direct, nextSeen, depth + 1);
          if (nested !== null) children.push(nested);
        }
      }
      return { objectID: String(objectId), children };
    };
    const ibData = archive.objects.find(
      ({ class_name }) => normalizeClassName(class_name) === "NSIBObjectData"
    );
    const rootId = reference2(ibData?.values.NSRoot);
    const hierarchyRoots = rootId === null ? [] : [rootId];
    for (const hierarchyRoot of hierarchyRoots) {
      const root = hierarchyFor(hierarchyRoot, /* @__PURE__ */ new Set(), 0);
      if (root !== null) hierarchy.push(root);
    }
    const viewHierarchy = projectNibViewHierarchy(
      archive.objects,
      new Set(Object.keys(objects).map(Number)),
      () => budget.tryReserve(128),
      maxHierarchyNodes
    );
    const merged = mergeNibHierarchies(
      hierarchy,
      viewHierarchy.hierarchy ?? [],
      () => budget.tryReserve(96),
      maxHierarchyNodes
    );
    return {
      omitted: viewHierarchy.omitted + hierarchyOmitted + merged.omitted,
      raw: jsonValueSchema.parse({
        "com.apple.ibtool.document.objects": objects,
        "com.apple.ibtool.document.connections": connections,
        "com.apple.ibtool.document.hierarchy": merged.hierarchy,
        "com.apple.ibtool.document.classes": Object.fromEntries(
          archive.classes.map((name) => {
            const className = normalizeClassName(name);
            budget.reserveJsonPropertyNameOccurrence(className);
            return [className, {}];
          })
        )
      })
    };
  };

  // ThirdParty/REA/adapters/comparison.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/process/processComparison.ts
  init_runtime();

  // ThirdParty/REA/dependencies/canonicalize/lib/canonicalize.js
  init_runtime();
  function canonicalize(object2, seen = /* @__PURE__ */ new Set()) {
    if (typeof object2 === "number" && isNaN(object2)) {
      throw new Error("NaN is not allowed");
    }
    if (typeof object2 === "number" && !isFinite(object2)) {
      throw new Error("Infinity is not allowed");
    }
    if (object2 === null || typeof object2 !== "object") {
      return JSON.stringify(object2);
    }
    if (typeof object2.toJSON === "function") {
      if (seen.has(object2)) {
        throw new Error("Circular reference detected");
      }
      seen.add(object2);
      const result2 = canonicalize(object2.toJSON(), seen);
      seen.delete(object2);
      return result2;
    }
    if (seen.has(object2)) {
      throw new Error("Circular reference detected");
    }
    seen.add(object2);
    let result;
    if (Array.isArray(object2)) {
      const values = object2.map((cv) => {
        const value = cv === void 0 || typeof cv === "symbol" ? null : cv;
        return canonicalize(value, seen);
      });
      result = `[${values.join(",")}]`;
    } else {
      const parts = [];
      for (const key of Object.keys(object2).sort()) {
        if (object2[key] === void 0 || typeof object2[key] === "symbol") {
          continue;
        }
        parts.push(`${canonicalize(key)}:${canonicalize(object2[key], seen)}`);
      }
      result = `{${parts.join(",")}}`;
    }
    seen.delete(object2);
    return result;
  }

  // ThirdParty/REA/upstream/src/domain/process/processCaptureCoverage.ts
  init_runtime();
  var byteRetentionSchema = external_exports.strictObject({
    budget_bytes: external_exports.number().int().nonnegative(),
    observed_bytes: external_exports.number().int().nonnegative(),
    retained_bytes: external_exports.number().int().nonnegative(),
    observed_frames: external_exports.number().int().nonnegative(),
    retained_frames: external_exports.number().int().nonnegative()
  });
  var filesystemCoverageSchema = external_exports.strictObject({
    files_limit: external_exports.number().int().nonnegative(),
    depth_limit: external_exports.number().int().nonnegative(),
    enumeration_truncated: external_exports.boolean(),
    enumeration_reasons: external_exports.array(
      external_exports.enum(["files_limit", "depth_limit", "identity_changed"])
    ),
    hash_budget_bytes: external_exports.number().int().nonnegative(),
    hashed_bytes: external_exports.number().int().nonnegative(),
    hash_omissions: external_exports.array(
      external_exports.strictObject({
        path: external_exports.string(),
        size_bytes: external_exports.number().int().nonnegative(),
        remaining_budget_bytes: external_exports.number().int().nonnegative(),
        reason: external_exports.enum([
          "file_bytes_budget",
          "file_changed_or_short_read",
          "file_unavailable"
        ]),
        system_code: external_exports.string().nullable()
      })
    )
  });
  var processCaptureTruncationDetailsSchema = external_exports.strictObject({
    raw_terminal: byteRetentionSchema.describe(
      "UTF-8 bytes of original PTY chunks; whole chunks are retained or omitted."
    ),
    rendered_terminal: byteRetentionSchema.describe(
      "Cumulative UTF-8 bytes of serialized state plus visible lines, evaluated from retained PTY input; whole frames are retained or omitted."
    ),
    filesystem_before: filesystemCoverageSchema,
    filesystem_after: filesystemCoverageSchema,
    process: external_exports.strictObject({
      sample_limit: external_exports.number().int().nonnegative(),
      sampling_partial: external_exports.boolean(),
      retained_samples: external_exports.number().int().nonnegative(),
      sample_limit_reached: external_exports.boolean(),
      sampling_failures: external_exports.number().int().nonnegative(),
      first_sampling_failure: external_exports.string().nullable(),
      coverage: external_exports.literal("sampled")
    })
  });
  var omitted = (retention) => retention.observed_frames > retention.retained_frames;
  var filesystemTruncated = (coverage) => coverage.enumeration_truncated || coverage.hash_omissions.length > 0;
  var processSourceTruncated = (capture, source2) => {
    const details = capture.truncation_details;
    switch (source2) {
      case "terminal_raw":
        return omitted(details.raw_terminal);
      case "terminal_rendered":
        return omitted(details.raw_terminal) || omitted(details.rendered_terminal);
      case "filesystem":
        return filesystemTruncated(details.filesystem_before) || filesystemTruncated(details.filesystem_after);
      case "process":
        return details.process.sampling_partial;
      case "interaction":
      case "lifecycle":
        return false;
    }
  };

  // ThirdParty/REA/upstream/src/domain/process/processObservation.ts
  init_runtime();
  var comparableTerminalFrame = (frame) => ({
    sequence: frame.sequence,
    at_ms: frame.at_ms,
    data: frame.data
  });
  var processObservationSourceSchema = external_exports.enum([
    "terminal_raw",
    "terminal_rendered",
    "interaction",
    "lifecycle",
    "process",
    "filesystem"
  ]);
  var processObservationLocationSchema = external_exports.strictObject({
    collection: external_exports.enum([
      "frames",
      "rendered_frames",
      "interaction_events",
      "lifecycle",
      "process_samples",
      "filesystem_checkpoints"
    ]),
    index: external_exports.number().int().nonnegative(),
    capture_order: external_exports.number().int().nonnegative()
  });
  var comparableProcessObservationPayload = (value, ignoredFields = []) => {
    if (ignoredFields.length === 0 || typeof value !== "object" || value === null || Array.isArray(value))
      return value;
    return Object.fromEntries(
      Object.entries(value).filter(([name]) => !ignoredFields.includes(name))
    );
  };
  var createProcessObservation = (input) => ({
    event_id: `obs.${input.location.collection}.${String(input.location.index)}`,
    source: input.source,
    source_sequence: input.source_sequence,
    capture_order: input.location.capture_order,
    captured_at_ms: input.captured_at_ms,
    subject_id: input.subject_id,
    location: input.location,
    payload: jsonValueSchema.parse(input.payload)
  });
  var atMilliseconds = (value) => {
    if (typeof value !== "object" || value === null) return null;
    if ("at_ms" in value && isSafeMillisecond(value.at_ms)) return value.at_ms;
    if ("dispatched_at_ms" in value && isSafeMillisecond(value.dispatched_at_ms))
      return value.dispatched_at_ms;
    return null;
  };
  var isSafeMillisecond = (value) => typeof value === "number" && Number.isSafeInteger(value);
  var processObservationSubject = (source2, value) => {
    if (typeof value !== "object" || value === null || Array.isArray(value))
      return null;
    if (source2 === "process" && "pid" in value && typeof value.pid === "number")
      return `process:${String(value.pid)}`;
    if (source2 === "filesystem" && "name" in value && typeof value.name === "string")
      return `checkpoint:${value.name}`;
    return null;
  };
  var projectedRecord = (capture, location) => {
    const projected = (() => {
      switch (location.collection) {
        case "frames": {
          const frame = capture.frames[location.index];
          return {
            source: "terminal_raw",
            value: frame === void 0 ? void 0 : comparableTerminalFrame(frame)
          };
        }
        case "rendered_frames":
          return {
            source: "terminal_rendered",
            value: capture.rendered_frames[location.index]
          };
        case "interaction_events":
          return {
            source: "interaction",
            value: capture.interaction_events[location.index]
          };
        case "lifecycle":
          return location.index === 0 ? {
            source: "lifecycle",
            value: { event: "exit", ...capture.exit }
          } : location.index === 1 ? {
            source: "lifecycle",
            value: { event: "settlement", ...capture.settlement }
          } : null;
        case "process_samples":
          return {
            source: "process",
            value: capture.process_samples[location.index]
          };
        case "filesystem_checkpoints":
          return {
            source: "filesystem",
            value: capture.filesystem_checkpoints[location.index]
          };
      }
    })();
    if (projected === null || projected.value === void 0) return null;
    const payload = jsonValueSchema.parse(projected.value);
    return {
      source: projected.source,
      captured_at_ms: atMilliseconds(payload),
      subject_id: processObservationSubject(projected.source, payload),
      payload
    };
  };
  var projectProcessObservation = (capture, location) => {
    const projected = projectedRecord(capture, location);
    if (projected === null) return null;
    return createProcessObservation({
      source: projected.source,
      source_sequence: location.index,
      captured_at_ms: projected.captured_at_ms,
      subject_id: projected.subject_id,
      location,
      payload: projected.payload
    });
  };

  // ThirdParty/REA/upstream/src/domain/process/processTraceEvaluation.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/process/processTraceSpecification.ts
  init_runtime();

  // ThirdParty/REA/upstream/src/domain/stringPatterns.ts
  init_runtime();
  var IDENTIFIER_PATTERN = /^[A-Za-z][A-Za-z0-9._\x2d]*$/u;

  // ThirdParty/REA/upstream/src/domain/process/processTraceSpecification.ts
  var identifierSchema = external_exports.string().regex(IDENTIFIER_PATTERN);
  var cardinalitySchema = external_exports.discriminatedUnion("kind", [
    external_exports.strictObject({ kind: external_exports.literal("required") }),
    external_exports.strictObject({ kind: external_exports.literal("optional") }),
    external_exports.strictObject({
      kind: external_exports.literal("exact"),
      count: external_exports.number().int().min(0)
    }),
    external_exports.strictObject({
      kind: external_exports.literal("range"),
      min: external_exports.number().int().min(0),
      max: external_exports.number().int().min(0)
    }).refine(({ min, max }) => min <= max, {
      message: "cardinality min must not exceed max",
      path: ["min"]
    })
  ]);
  var eventDeclarationSchema = external_exports.strictObject({
    id: identifierSchema,
    source: processObservationSourceSchema,
    exact: jsonValueSchema,
    ignore_fields: external_exports.array(
      external_exports.enum([
        "sequence",
        "at_ms",
        "scheduled_at_ms",
        "dispatched_at_ms",
        "elapsed_ms"
      ])
    ).refine((values) => new Set(values).size === values.length, {
      message: "ignored event fields must be unique"
    }).optional(),
    cardinality: cardinalitySchema.default({ kind: "required" })
  });
  var partialOrderLanguageSchema = external_exports.strictObject({
    kind: external_exports.literal("partial_order"),
    happens_before: external_exports.array(
      external_exports.strictObject({
        before: identifierSchema,
        after: identifierSchema
      })
    ).default([]),
    not_before: external_exports.array(
      external_exports.strictObject({
        event: identifierSchema,
        anchor: identifierSchema
      })
    ).default([]),
    unordered_groups: external_exports.array(external_exports.strictObject({ events: external_exports.array(identifierSchema).min(2) })).default([]),
    prefix: external_exports.array(identifierSchema).default([]),
    suffix: external_exports.array(identifierSchema).default([])
  });
  var finiteTraceTokenSchema = external_exports.union([
    identifierSchema,
    external_exports.strictObject({ unordered: external_exports.array(identifierSchema).min(2) })
  ]);
  var finiteTraceLanguageSchema = external_exports.strictObject({
    kind: external_exports.literal("finite_traces"),
    variants: external_exports.array(
      external_exports.strictObject({
        id: identifierSchema,
        trace: external_exports.array(finiteTraceTokenSchema)
      })
    ).min(1)
  });
  var specificationShapeSchema = external_exports.strictObject({
    events: external_exports.array(eventDeclarationSchema).min(1),
    language: external_exports.discriminatedUnion("kind", [
      partialOrderLanguageSchema,
      finiteTraceLanguageSchema
    ])
  });
  var canonicalTraceJson = (value) => {
    const serialized = canonicalize(value);
    if (serialized === void 0)
      throw new TypeError("Trace specification contains a non-JSON value");
    return serialized;
  };
  var processTraceCardinalityBounds = (cardinality) => {
    switch (cardinality.kind) {
      case "required":
        return [1, 1];
      case "optional":
        return [0, 1];
      case "exact":
        return [cardinality.count, cardinality.count];
      case "range":
        return [cardinality.min, cardinality.max];
    }
  };
  var addReferenceIssue = (context, known, id, path3) => {
    if (!known.has(id))
      context.addIssue({
        code: "custom",
        message: `unknown event id: ${id}`,
        path: path3
      });
  };
  var pairKey = (left, right) => [left, right].sort().join("\0");
  var buildAdjacency = (language, context, known) => {
    const adjacency = new Map([...known].map((id) => [id, /* @__PURE__ */ new Set()]));
    for (const [index, edge] of language.happens_before.entries()) {
      const path3 = ["language", "happens_before", index];
      addReferenceIssue(context, known, edge.before, [...path3, "before"]);
      addReferenceIssue(context, known, edge.after, [...path3, "after"]);
      if (edge.before === edge.after)
        context.addIssue({
          code: "custom",
          message: "happens-before edges must reference distinct events",
          path: path3
        });
      adjacency.get(edge.before)?.add(edge.after);
    }
    return adjacency;
  };
  var validateNotBefore = (language, context, known, reachable) => {
    const pairs = /* @__PURE__ */ new Set();
    for (const [index, constraint] of language.not_before.entries()) {
      const path3 = ["language", "not_before", index];
      addReferenceIssue(context, known, constraint.event, [...path3, "event"]);
      addReferenceIssue(context, known, constraint.anchor, [...path3, "anchor"]);
      if (constraint.event === constraint.anchor)
        context.addIssue({
          code: "custom",
          message: "not-before constraints must reference distinct events",
          path: path3
        });
      const key = pairKey(constraint.event, constraint.anchor);
      if (pairs.has(key))
        context.addIssue({
          code: "custom",
          message: "not-before event pairs must be declared once",
          path: path3
        });
      pairs.add(key);
      if (reachable.get(constraint.event)?.has(constraint.anchor) === true)
        context.addIssue({
          code: "custom",
          message: "not-before constraint conflicts with happens-before order",
          path: path3
        });
    }
    return pairs;
  };
  var graphHasCycle = (ids, adjacency) => {
    const active = /* @__PURE__ */ new Set();
    const complete = /* @__PURE__ */ new Set();
    const visit = (current) => {
      if (active.has(current)) return true;
      if (complete.has(current)) return false;
      active.add(current);
      const cyclic = [...adjacency.get(current) ?? []].some(visit);
      active.delete(current);
      complete.add(current);
      return cyclic;
    };
    return ids.some(visit);
  };
  var computeReachability = (ids, adjacency) => {
    const reachable = /* @__PURE__ */ new Map();
    for (const origin of ids) {
      const seen = /* @__PURE__ */ new Set();
      const pending = [...adjacency.get(origin) ?? []];
      while (pending.length > 0) {
        const current = pending.pop();
        if (current === void 0 || seen.has(current)) continue;
        seen.add(current);
        pending.push(...adjacency.get(current) ?? []);
      }
      reachable.set(origin, seen);
    }
    return reachable;
  };
  var isOrdered = (reachable, left, right) => reachable.get(left)?.has(right) === true || reachable.get(right)?.has(left) === true;
  var validateUnorderedGroups = (language, context, known, relations) => {
    const pairs = /* @__PURE__ */ new Set();
    for (const [groupIndex, group] of language.unordered_groups.entries()) {
      const path3 = ["language", "unordered_groups", groupIndex];
      if (new Set(group.events).size !== group.events.length)
        context.addIssue({
          code: "custom",
          message: "unordered groups must not repeat event ids",
          path: [...path3, "events"]
        });
      for (const [eventIndex, id] of group.events.entries())
        addReferenceIssue(context, known, id, [...path3, "events", eventIndex]);
      for (const [leftIndex, leftId] of group.events.entries()) {
        for (const rightId of group.events.slice(leftIndex + 1)) {
          const key = pairKey(leftId, rightId);
          if (pairs.has(key))
            context.addIssue({
              code: "custom",
              message: "unordered event pairs must be declared once",
              path: path3
            });
          pairs.add(key);
          if (isOrdered(relations.reachable, leftId, rightId) || relations.notBeforePairs.has(key))
            context.addIssue({
              code: "custom",
              message: "ordered events cannot also be declared unordered",
              path: path3
            });
        }
      }
    }
    return pairs;
  };
  var validateCompletePairDeclarations = (ids, relations, unorderedPairs, context) => {
    for (const [leftIndex, leftId] of ids.entries())
      for (const rightId of ids.slice(leftIndex + 1))
        if (!isOrdered(relations.reachable, leftId, rightId) && !relations.notBeforePairs.has(pairKey(leftId, rightId)) && !unorderedPairs.has(pairKey(leftId, rightId)))
          context.addIssue({
            code: "custom",
            message: `event pair ${leftId}/${rightId} must be explicitly ordered or unordered`,
            path: ["language"]
          });
  };
  var validatePartialOrder = (specification, context) => {
    if (specification.language.kind !== "partial_order") return;
    const ids = specification.events.map(({ id }) => id);
    const known = new Set(ids);
    const adjacency = buildAdjacency(specification.language, context, known);
    if (graphHasCycle(ids, adjacency))
      context.addIssue({
        code: "custom",
        message: "happens-before graph must be acyclic",
        path: ["language"]
      });
    const reachable = computeReachability(ids, adjacency);
    const notBeforePairs = validateNotBefore(
      specification.language,
      context,
      known,
      reachable
    );
    const relations = { reachable, notBeforePairs };
    const unorderedPairs = validateUnorderedGroups(
      specification.language,
      context,
      known,
      relations
    );
    validateCompletePairDeclarations(ids, relations, unorderedPairs, context);
    for (const [kind, values] of [
      ["prefix", specification.language.prefix],
      ["suffix", specification.language.suffix]
    ])
      for (const [index, id] of values.entries())
        addReferenceIssue(context, known, id, ["language", kind, index]);
  };
  var countVariantEvents = (trace) => {
    const counts = /* @__PURE__ */ new Map();
    for (const token of trace)
      for (const id of typeof token === "string" ? [token] : token.unordered)
        counts.set(id, (counts.get(id) ?? 0) + 1);
    return counts;
  };
  var validateFiniteTraces = (specification, context) => {
    if (specification.language.kind !== "finite_traces") return;
    const known = new Set(specification.events.map(({ id }) => id));
    const variantIds = /* @__PURE__ */ new Set();
    const variantTraces = /* @__PURE__ */ new Set();
    for (const [
      variantIndex,
      variant
    ] of specification.language.variants.entries()) {
      const variantPath = ["language", "variants", variantIndex];
      if (variantIds.has(variant.id))
        context.addIssue({
          code: "custom",
          message: "finite trace variant ids must be unique",
          path: [...variantPath, "id"]
        });
      variantIds.add(variant.id);
      const canonicalTrace = canonicalTraceJson(variant.trace);
      if (variantTraces.has(canonicalTrace))
        context.addIssue({
          code: "custom",
          message: "finite trace variants must not duplicate a trace",
          path: [...variantPath, "trace"]
        });
      variantTraces.add(canonicalTrace);
      for (const [tokenIndex, token] of variant.trace.entries()) {
        const values = typeof token === "string" ? [token] : token.unordered;
        for (const [eventIndex, id] of values.entries())
          addReferenceIssue(context, known, id, [
            ...variantPath,
            "trace",
            tokenIndex,
            ...typeof token === "string" ? [] : ["unordered", eventIndex]
          ]);
      }
      const counts = countVariantEvents(variant.trace);
      for (const event of specification.events) {
        const [minimum, maximum] = processTraceCardinalityBounds(
          event.cardinality
        );
        const count = counts.get(event.id) ?? 0;
        if (count < minimum || count > maximum)
          context.addIssue({
            code: "custom",
            message: `variant ${variant.id} violates ${event.id} cardinality`,
            path: [...variantPath, "trace"]
          });
      }
    }
  };
  var processTraceSpecificationSchema = specificationShapeSchema.superRefine((specification, context) => {
    const ids = /* @__PURE__ */ new Set();
    const predicates = /* @__PURE__ */ new Set();
    const ignoredFieldsBySource = /* @__PURE__ */ new Map();
    for (const [index, event] of specification.events.entries()) {
      if (ids.has(event.id))
        context.addIssue({
          code: "custom",
          message: "event ids must be unique",
          path: ["events", index, "id"]
        });
      ids.add(event.id);
      const ignoredFields = [...event.ignore_fields ?? []].sort();
      if (ignoredFields.length > 0 && (typeof event.exact !== "object" || event.exact === null || Array.isArray(event.exact)))
        context.addIssue({
          code: "custom",
          message: "ignored schedule fields require an exact object payload",
          path: ["events", index, "ignore_fields"]
        });
      const ignoredKey = canonicalTraceJson(ignoredFields);
      const priorIgnoredKey = ignoredFieldsBySource.get(event.source);
      if (priorIgnoredKey !== void 0 && priorIgnoredKey !== ignoredKey)
        context.addIssue({
          code: "custom",
          message: "events from one source must use the same ignored schedule fields",
          path: ["events", index, "ignore_fields"]
        });
      ignoredFieldsBySource.set(event.source, ignoredKey);
      if (ignoredFields.some(
        (field) => typeof event.exact === "object" && event.exact !== null && !Array.isArray(event.exact) && field in event.exact
      ))
        context.addIssue({
          code: "custom",
          message: "exact payload must omit every ignored schedule field",
          path: ["events", index, "exact"]
        });
      const predicate = `${event.source}\0${canonicalTraceJson(
        comparableProcessObservationPayload(event.exact, ignoredFields)
      )}`;
      if (predicates.has(predicate))
        context.addIssue({
          code: "custom",
          message: "exact event predicates must not overlap",
          path: ["events", index]
        });
      predicates.add(predicate);
    }
    validatePartialOrder(specification, context);
    validateFiniteTraces(specification, context);
  });

  // ThirdParty/REA/upstream/src/domain/process/processTraceEvaluation.ts
  var identifierSchema2 = external_exports.string().regex(/^[A-Za-z][A-Za-z0-9._\x2d]{0,63}$/u);
  var matchedEventSchema = external_exports.strictObject({
    event_id: identifierSchema2,
    location: processObservationLocationSchema
  });
  var sideResultShape = {
    satisfied_constraints: external_exports.array(external_exports.string()),
    raw_trace: external_exports.array(matchedEventSchema)
  };
  var sideResultSchema = external_exports.union([
    external_exports.strictObject({
      ...sideResultShape,
      status: external_exports.literal("pass"),
      matched_variant: identifierSchema2.nullable()
    }),
    external_exports.strictObject({
      ...sideResultShape,
      status: external_exports.enum(["fail", "unknown"]),
      matched_variant: external_exports.null()
    })
  ]);
  var diagnosticSchema = external_exports.strictObject({
    kind: external_exports.enum([
      "journal",
      "predicate",
      "cardinality",
      "edge",
      "prefix",
      "suffix",
      "trace"
    ]),
    side: external_exports.enum(["left", "right"]),
    message: external_exports.string(),
    event_ids: external_exports.array(identifierSchema2),
    locations: external_exports.array(processObservationLocationSchema)
  });
  var processTraceComparisonResultSchema = external_exports.strictObject({
    verdict: external_exports.enum(["equivalent", "different", "nonconforming", "unknown"]),
    left: sideResultSchema,
    right: sideResultSchema,
    diagnostic: diagnosticSchema.nullable()
  });
  var scopesFor = (sources) => new Set(
    [...sources].map((source2) => {
      if (source2.startsWith("terminal_")) return "terminal";
      if (source2 === "lifecycle") return "exit";
      if (source2 === "filesystem") return "filesystem";
      if (source2 === "process") return "process";
      return "interaction";
    })
  );
  var unknownSide = (rawTrace = []) => ({
    status: "unknown",
    matched_variant: null,
    satisfied_constraints: [],
    raw_trace: rawTrace
  });
  var failure = (input) => ({
    result: {
      status: "fail",
      matched_variant: null,
      satisfied_constraints: [],
      raw_trace: input.rawTrace
    },
    diagnostic: {
      kind: input.kind,
      message: input.message,
      event_ids: [...input.eventIds],
      locations: [...input.locations]
    }
  });
  var evaluateFiniteTrace = (ids, specification) => {
    if (specification.language.kind !== "finite_traces") return null;
    for (const variant of specification.language.variants) {
      let offset = 0;
      let accepted = true;
      for (const token of variant.trace) {
        if (typeof token === "string") {
          if (ids[offset] !== token) accepted = false;
          offset += 1;
          continue;
        }
        const actual = ids.slice(offset, offset + token.unordered.length).sort();
        const expected = [...token.unordered].sort();
        if (canonicalTraceJson(actual) !== canonicalTraceJson(expected))
          accepted = false;
        offset += token.unordered.length;
      }
      if (accepted && offset === ids.length) return variant.id;
    }
    return null;
  };
  var collectRecords = (capture, sources) => {
    const records = [];
    for (const location of capture.event_journal) {
      const record4 = projectProcessObservation(capture, location);
      if (record4 !== null && sources.has(record4.source))
        records.push({
          source: record4.source,
          payload: record4.payload,
          location
        });
    }
    return records;
  };
  var matchRecords = (records, specification) => {
    const rawTrace = [];
    const locationsById = /* @__PURE__ */ new Map();
    const ignoredFieldsBySource = /* @__PURE__ */ new Map();
    const eventsByKey = /* @__PURE__ */ new Map();
    for (const event of specification.events) {
      const ignoredFields = event.ignore_fields ?? [];
      ignoredFieldsBySource.set(event.source, ignoredFields);
      eventsByKey.set(
        `${event.source}\0${canonicalTraceJson(
          comparableProcessObservationPayload(event.exact, ignoredFields)
        )}`,
        event
      );
    }
    for (const record4 of records) {
      const match = eventsByKey.get(
        `${record4.source}\0${canonicalTraceJson(
          comparableProcessObservationPayload(
            record4.payload,
            ignoredFieldsBySource.get(record4.source)
          )
        )}`
      );
      if (match === void 0)
        return failure({
          kind: "predicate",
          message: "Observed event does not match any declared exact predicate.",
          eventIds: [],
          locations: [record4.location],
          rawTrace
        });
      rawTrace.push({ event_id: match.id, location: record4.location });
      const locations = locationsById.get(match.id) ?? [];
      locations.push(record4.location);
      locationsById.set(match.id, locations);
    }
    return { rawTrace, locationsById };
  };
  var cardinalityFailure = (trace, specification) => {
    for (const event of specification.events) {
      const [minimum, maximum] = processTraceCardinalityBounds(event.cardinality);
      const locations = trace.locationsById.get(event.id) ?? [];
      if (locations.length < minimum || locations.length > maximum)
        return failure({
          kind: "cardinality",
          message: `${event.id} observed ${String(locations.length)} times; expected ${String(minimum)}..${String(maximum)}.`,
          eventIds: [event.id],
          locations,
          rawTrace: trace.rawTrace
        });
    }
    return null;
  };
  var evaluateOrderingConstraints = (trace, language) => {
    const satisfied = [];
    for (const edge of language.happens_before) {
      const before = trace.locationsById.get(edge.before) ?? [];
      const after = trace.locationsById.get(edge.after) ?? [];
      const lastBefore = before.at(-1);
      const firstAfter = after[0];
      if (lastBefore === void 0 && firstAfter !== void 0)
        return {
          failure: failure({
            kind: "edge",
            message: `${edge.before} is required when ${edge.after} occurs.`,
            eventIds: [edge.before, edge.after],
            locations: [firstAfter],
            rawTrace: trace.rawTrace
          }),
          satisfied
        };
      if (lastBefore !== void 0 && firstAfter !== void 0 && lastBefore.capture_order >= firstAfter.capture_order)
        return {
          failure: failure({
            kind: "edge",
            message: `${edge.before} must happen before ${edge.after}.`,
            eventIds: [edge.before, edge.after],
            locations: [lastBefore, firstAfter],
            rawTrace: trace.rawTrace
          }),
          satisfied
        };
      satisfied.push(`happens_before:${edge.before}:${edge.after}`);
    }
    for (const constraint of language.not_before) {
      const events = trace.locationsById.get(constraint.event) ?? [];
      const anchors = trace.locationsById.get(constraint.anchor) ?? [];
      const firstEvent = events[0];
      const firstAnchor = anchors[0];
      if (firstEvent !== void 0 && firstAnchor === void 0)
        return {
          failure: failure({
            kind: "edge",
            message: `${constraint.anchor} is required when ${constraint.event} occurs.`,
            eventIds: [constraint.event, constraint.anchor],
            locations: [firstEvent],
            rawTrace: trace.rawTrace
          }),
          satisfied
        };
      if (firstEvent !== void 0 && firstAnchor !== void 0 && firstEvent.capture_order < firstAnchor.capture_order)
        return {
          failure: failure({
            kind: "edge",
            message: `${constraint.event} must not occur before ${constraint.anchor}.`,
            eventIds: [constraint.event, constraint.anchor],
            locations: [firstEvent, firstAnchor],
            rawTrace: trace.rawTrace
          }),
          satisfied
        };
      satisfied.push(`not_before:${constraint.event}:${constraint.anchor}`);
    }
    return { failure: null, satisfied };
  };
  var boundaryFailure = (trace, kind, expected) => {
    const ids = trace.rawTrace.map(({ event_id }) => event_id);
    const actual = kind === "prefix" ? ids.slice(0, expected.length) : expected.length === 0 ? [] : ids.slice(-expected.length);
    if (canonicalTraceJson(actual) === canonicalTraceJson(expected)) return null;
    const locations = kind === "prefix" ? trace.rawTrace.slice(0, expected.length) : trace.rawTrace.slice(-expected.length);
    return failure({
      kind,
      message: `Observed trace does not satisfy the declared ${kind}.`,
      eventIds: expected,
      locations: locations.map(({ location }) => location),
      rawTrace: trace.rawTrace
    });
  };
  var evaluatePartialOrder = (trace, language) => {
    const ordering = evaluateOrderingConstraints(trace, language);
    if (ordering.failure !== null) return ordering.failure;
    const prefixFailure = boundaryFailure(trace, "prefix", language.prefix);
    if (prefixFailure !== null) return prefixFailure;
    const suffixFailure = boundaryFailure(trace, "suffix", language.suffix);
    if (suffixFailure !== null) return suffixFailure;
    const satisfied = ordering.satisfied;
    satisfied.push(
      ...language.unordered_groups.map(
        ({ events }) => `unordered:${events.join(":")}`
      )
    );
    if (language.prefix.length > 0)
      satisfied.push(`prefix:${language.prefix.join(":")}`);
    if (language.suffix.length > 0)
      satisfied.push(`suffix:${language.suffix.join(":")}`);
    return {
      result: {
        status: "pass",
        matched_variant: null,
        satisfied_constraints: satisfied,
        raw_trace: trace.rawTrace
      },
      diagnostic: null
    };
  };
  var evaluateMatchedTrace = (trace, specification) => {
    const invalidCardinality = cardinalityFailure(trace, specification);
    if (invalidCardinality !== null) return invalidCardinality;
    if (specification.language.kind === "partial_order")
      return evaluatePartialOrder(trace, specification.language);
    const ids = trace.rawTrace.map(({ event_id }) => event_id);
    const variant = evaluateFiniteTrace(ids, specification);
    return variant === null ? failure({
      kind: "trace",
      message: "Observed events do not match any finite trace variant.",
      eventIds: ids,
      locations: trace.rawTrace.map(({ location }) => location),
      rawTrace: trace.rawTrace
    }) : {
      result: {
        status: "pass",
        matched_variant: variant,
        satisfied_constraints: [`variant:${variant}`],
        raw_trace: trace.rawTrace
      },
      diagnostic: null
    };
  };
  var evaluateProcessTraceSide = (capture, specification) => {
    const sources = new Set(specification.events.map(({ source: source2 }) => source2));
    const relevantScopes = scopesFor(sources);
    const incomplete = [...sources].some((source2) => processSourceTruncated(capture, source2)) || capture.residual_unknowns.some(({ scope }) => relevantScopes.has(scope));
    if (capture.event_journal.length === 0)
      return {
        result: unknownSide(),
        diagnostic: {
          kind: "journal",
          message: "Capture has no cross-source event journal.",
          event_ids: [],
          locations: []
        }
      };
    const matched = matchRecords(collectRecords(capture, sources), specification);
    if (incomplete)
      return {
        result: unknownSide(
          "rawTrace" in matched ? matched.rawTrace : matched.result.raw_trace
        ),
        diagnostic: null
      };
    return "rawTrace" in matched ? evaluateMatchedTrace(matched, specification) : matched;
  };

  // ThirdParty/REA/upstream/src/domain/process/processTraceDimensionProjection.ts
  init_runtime();
  var dimensionsForTraceSources = (sources) => {
    const dimensions = /* @__PURE__ */ new Set();
    for (const source2 of sources) {
      if (source2.startsWith("terminal_")) dimensions.add("terminal");
      else if (source2 === "interaction") dimensions.add("interaction");
      else if (source2 === "lifecycle") dimensions.add("exit");
      else if (source2 === "filesystem") dimensions.add("filesystem");
      else if (source2 === "process") dimensions.add("process");
    }
    return dimensions;
  };
  var traceCoversObservedDimension = (dimension, sources, left, right) => {
    const any2 = (leftValues, rightValues) => leftValues.length > 0 || rightValues.length > 0;
    switch (dimension) {
      case "terminal":
        return (!any2(left.frames, right.frames) || sources.has("terminal_raw")) && (!any2(left.rendered_frames, right.rendered_frames) || sources.has("terminal_rendered"));
      case "interaction":
        return sources.has("interaction");
      case "exit":
        return sources.has("lifecycle");
      case "filesystem":
        return false;
      case "process":
        return sources.has("process");
    }
  };

  // ThirdParty/REA/upstream/src/domain/process/processTraceComparison.ts
  init_runtime();
  var compareProcessTraces = (left, right, specificationInput) => {
    const specification = processTraceSpecificationSchema.parse(specificationInput);
    const leftEvaluation = evaluateProcessTraceSide(left, specification);
    const rightEvaluation = evaluateProcessTraceSide(right, specification);
    const diagnostic = leftEvaluation.diagnostic === null ? rightEvaluation.diagnostic === null ? null : { side: "right", ...rightEvaluation.diagnostic } : { side: "left", ...leftEvaluation.diagnostic };
    const outcomesDiffer = leftEvaluation.result.status !== rightEvaluation.result.status || JSON.stringify(
      leftEvaluation.result.raw_trace.map(({ event_id }) => event_id)
    ) !== JSON.stringify(
      rightEvaluation.result.raw_trace.map(({ event_id }) => event_id)
    );
    return processTraceComparisonResultSchema.parse({
      verdict: leftEvaluation.result.status === "unknown" || rightEvaluation.result.status === "unknown" ? "unknown" : leftEvaluation.result.status === "pass" && rightEvaluation.result.status === "pass" ? "equivalent" : outcomesDiffer ? "different" : "nonconforming",
      left: leftEvaluation.result,
      right: rightEvaluation.result,
      diagnostic
    });
  };
  var processTraceOutcomesDiffer = (comparison) => comparison.left.status !== comparison.right.status || JSON.stringify(comparison.left.raw_trace.map(({ event_id }) => event_id)) !== JSON.stringify(comparison.right.raw_trace.map(({ event_id }) => event_id));

  // ThirdParty/REA/upstream/src/domain/process/processComparison.ts
  var OPERATION = "compare_process_captures";
  var comparisonStatusSchema = external_exports.enum([
    "unchanged",
    "added",
    "removed",
    "changed",
    "truncated",
    "unknown",
    "contradiction"
  ]);
  var PROCESS_COMPARISON_DIMENSIONS = [
    "terminal",
    "interaction",
    "exit",
    "filesystem",
    "process"
  ];
  var deriveProcessComparisonStatus = (dimensions) => {
    if (dimensions.includes("truncated")) return "truncated";
    if (dimensions.some(
      (status) => ["changed", "added", "removed"].includes(status)
    ))
      return "changed";
    return dimensions.includes("unknown") ? "unknown" : "unchanged";
  };
  var processCaptureComparisonSchema = external_exports.object({
    status: comparisonStatusSchema,
    terminal: comparisonStatusSchema,
    interaction: comparisonStatusSchema,
    exit: comparisonStatusSchema,
    filesystem: comparisonStatusSchema,
    process: comparisonStatusSchema,
    first_divergence: external_exports.discriminatedUnion("status", [
      external_exports.object({ status: external_exports.literal("none") }),
      external_exports.object({ status: external_exports.literal("unknown"), reason: external_exports.string() }),
      external_exports.object({
        status: external_exports.literal("found"),
        dimension: external_exports.enum([
          "terminal",
          "interaction",
          "exit",
          "filesystem",
          "process"
        ]),
        index: external_exports.number().int().nonnegative(),
        left_at_ms: external_exports.number().int().nonnegative().nullable(),
        right_at_ms: external_exports.number().int().nonnegative().nullable(),
        left: jsonValueSchema.nullable(),
        right: jsonValueSchema.nullable()
      })
    ]),
    trace: processTraceComparisonResultSchema.optional(),
    limitations: external_exports.array(external_exports.string())
  }).superRefine((comparison, context) => {
    const expected = deriveProcessComparisonStatus(
      PROCESS_COMPARISON_DIMENSIONS.map((dimension) => comparison[dimension])
    );
    if (comparison.status !== expected)
      context.addIssue({
        code: "custom",
        message: "Process comparison status contradicts its dimensions",
        path: ["status"]
      });
  });
  var terminalObservations = (capture) => [
    ...capture.frames.map((frame) => ({
      kind: "raw",
      ...comparableTerminalFrame(frame)
    })),
    ...capture.rendered_frames.map((frame) => ({
      kind: "rendered",
      ...frame
    }))
  ].sort((left, right) => {
    const time3 = left.at_ms - right.at_ms;
    if (time3 !== 0) return time3;
    if (left.kind !== right.kind) return left.kind === "raw" ? -1 : 1;
    return left.sequence - right.sequence;
  });
  var filesystemObservations = (capture) => capture.filesystem_checkpoints;
  var sameJsonValue = (left, right) => {
    const encodedLeft = canonicalize(left);
    return encodedLeft !== void 0 && encodedLeft === canonicalize(right);
  };
  var processDimensionObservations = (capture, dimension) => {
    switch (dimension) {
      case "terminal":
        return terminalObservations(capture);
      case "interaction":
        return capture.interaction_events;
      case "exit":
        return [{ ...capture.exit, settlement: capture.settlement }];
      case "filesystem":
        return filesystemObservations(capture);
      case "process":
        return capture.process_samples;
    }
  };
  var classifyCollection = (left, right) => {
    if (sameJsonValue(left, right)) return "unchanged";
    if (left.length === 0) return "added";
    if (right.length === 0) return "removed";
    return "changed";
  };
  var hasUnknown = (capture, scope) => capture.residual_unknowns.some((item) => item.scope === scope);
  var eventTime = (value) => {
    if (typeof value === "object" && value !== null && "at_ms" in value && typeof value.at_ms === "number" && Number.isSafeInteger(value.at_ms) && value.at_ms >= 0)
      return value.at_ms;
    return null;
  };
  var firstCollectionDivergence = (dimension, left, right) => {
    const length = Math.max(left.length, right.length);
    for (let index = 0; index < length; index += 1) {
      const leftValue = left[index] ?? null;
      const rightValue = right[index] ?? null;
      if (sameJsonValue(leftValue, rightValue)) continue;
      return {
        status: "found",
        dimension,
        index,
        left_at_ms: eventTime(leftValue),
        right_at_ms: eventTime(rightValue),
        left: jsonValueSchema.parse(leftValue),
        right: jsonValueSchema.parse(rightValue)
      };
    }
    return null;
  };
  var chooseFirstDivergence = (candidates) => {
    const found = candidates.filter(
      (candidate) => candidate !== null
    );
    return found.sort((left, right) => {
      const leftTime = Math.min(
        left.left_at_ms ?? Number.MAX_SAFE_INTEGER,
        left.right_at_ms ?? Number.MAX_SAFE_INTEGER
      );
      const rightTime = Math.min(
        right.left_at_ms ?? Number.MAX_SAFE_INTEGER,
        right.right_at_ms ?? Number.MAX_SAFE_INTEGER
      );
      return leftTime - rightTime;
    })[0] ?? { status: "none" };
  };
  var assertComparable = (left, right, options) => {
    if (left.manifest.comparison_contract_sha256 !== right.manifest.comparison_contract_sha256) {
      const fields = differingContractFields(
        left.manifest.comparison_contract,
        right.manifest.comparison_contract
      );
      throw new AnalysisInputError(OPERATION, void 0, [
        {
          path: ["right"],
          reason: "invalid_value",
          message: `Process captures have incompatible comparison contracts${fields.length === 0 ? "" : `; these scenario fields differ: ${fields.join(", ")}`}. Capture both scenarios with the same values for these fields, then compare them.`,
          expected: fields
        }
      ]);
    }
    if (options.maxCaptureAgeMs === void 0) return;
    const maxCaptureAgeMs = options.maxCaptureAgeMs;
    const now = (options.now ?? Date.now)();
    const stale = [
      ["left", left],
      ["right", right]
    ].flatMap(([side, { manifest }]) => {
      const age = now - Date.parse(manifest.completed_at);
      return age > maxCaptureAgeMs ? [
        `${side} completed at ${manifest.completed_at} (${String(age)} ms ago)`
      ] : [];
    });
    if (stale.length > 0)
      throw new AnalysisInputError(OPERATION, void 0, [
        {
          path: ["max_capture_age_ms"],
          reason: "out_of_range",
          message: `Process capture exceeds max_capture_age_ms ${String(maxCaptureAgeMs)}: ${stale.join("; ")}. Recapture the stale scenario or raise max_capture_age_ms.`
        }
      ]);
  };
  var differingContractFields = (left, right) => [.../* @__PURE__ */ new Set([...Object.keys(left), ...Object.keys(right)])].filter(
    (field) => !Object.hasOwn(left, field) || !Object.hasOwn(right, field) || canonicalize(left[field]) !== canonicalize(right[field])
  ).sort();
  var applyTraceVerdict = (dimensions, specification, trace, captures) => {
    const traceShowsDifference = processTraceOutcomesDiffer(trace);
    const traceStatus = trace.verdict === "unknown" ? "unknown" : trace.verdict === "equivalent" || !traceShowsDifference ? "unchanged" : "changed";
    const sources = new Set(specification.events.map(({ source: source2 }) => source2));
    const covered = dimensionsForTraceSources(sources);
    const statusFor = (dimension) => {
      const exact = dimensions[dimension];
      if (!covered.has(dimension)) return exact;
      if (trace.verdict === "nonconforming") return exact;
      if (trace.verdict === "different")
        return traceShowsDifference ? "changed" : exact;
      if (trace.verdict === "unknown" && ["changed", "added", "removed"].includes(exact))
        return exact;
      return traceCoversObservedDimension(
        dimension,
        sources,
        captures[0],
        captures[1]
      ) ? traceStatus : exact;
    };
    return {
      terminal: statusFor("terminal"),
      interaction: statusFor("interaction"),
      exit: statusFor("exit"),
      filesystem: statusFor("filesystem"),
      process: statusFor("process")
    };
  };
  var compareDimensions = (left, right, sameNormalization) => {
    const classify = (scope, leftValues, rightValues, source2) => !sameNormalization || hasUnknown(left, scope) || hasUnknown(right, scope) || processSourceTruncated(left, source2) || processSourceTruncated(right, source2) ? "unknown" : classifyCollection(leftValues, rightValues);
    return {
      terminal: classify(
        "terminal",
        terminalObservations(left),
        terminalObservations(right),
        "terminal_rendered"
      ),
      interaction: classify(
        "interaction",
        left.interaction_events,
        right.interaction_events,
        "interaction"
      ),
      exit: hasUnknown(left, "exit") || hasUnknown(right, "exit") ? "unknown" : sameJsonValue(
        { exit: left.exit, settlement: left.settlement },
        { exit: right.exit, settlement: right.settlement }
      ) ? "unchanged" : "changed",
      filesystem: classify(
        "filesystem",
        filesystemObservations(left),
        filesystemObservations(right),
        "filesystem"
      ),
      process: classify(
        "process",
        left.process_samples,
        right.process_samples,
        "process"
      )
    };
  };
  var compareProcessCaptures = (left, right, options = {}) => {
    assertComparable(left, right, options);
    const sameNormalization = sameJsonValue(
      left.normalization,
      right.normalization
    );
    const exactDimensions = compareDimensions(left, right, sameNormalization);
    const trace = options.traceSpecification === void 0 ? void 0 : compareProcessTraces(left, right, options.traceSpecification);
    const dimensions = trace === void 0 || options.traceSpecification === void 0 ? exactDimensions : applyTraceVerdict(exactDimensions, options.traceSpecification, trace, [
      left,
      right
    ]);
    const divergenceCandidates = PROCESS_COMPARISON_DIMENSIONS.map(
      (dimension) => dimensions[dimension] === "unknown" ? null : firstCollectionDivergence(
        dimension,
        processDimensionObservations(left, dimension),
        processDimensionObservations(right, dimension)
      )
    );
    const observedFirstDivergence = chooseFirstDivergence(
      divergenceCandidates.map(
        (candidate) => candidate !== null && trace?.verdict === "equivalent" && dimensions[candidate.dimension] === "unchanged" ? null : candidate
      )
    );
    const firstDivergence = left.truncated || right.truncated ? {
      status: "unknown",
      reason: "Incomplete observations prevent locating the first divergence; unaffected dimensions retain their comparisons."
    } : trace?.verdict === "equivalent" && deriveProcessComparisonStatus(
      PROCESS_COMPARISON_DIMENSIONS.map(
        (dimension) => dimensions[dimension]
      )
    ) === "unchanged" ? { status: "none" } : observedFirstDivergence.status === "found" ? observedFirstDivergence : !sameNormalization || left.residual_unknowns.length > 0 || right.residual_unknowns.length > 0 ? {
      status: "unknown",
      reason: "Residual unknowns prevent proving that no divergence occurred."
    } : observedFirstDivergence;
    const observedStatus = deriveProcessComparisonStatus(
      PROCESS_COMPARISON_DIMENSIONS.map((dimension) => dimensions[dimension])
    );
    return {
      status: observedStatus,
      ...dimensions,
      first_divergence: firstDivergence,
      ...trace === void 0 ? {} : { trace },
      limitations: [
        ...left.limitations,
        ...right.limitations,
        ...left.residual_unknowns.map(({ reason }) => reason),
        ...right.residual_unknowns.map(({ reason }) => reason),
        ...sameNormalization ? [] : ["Capture normalization rules differ."]
      ]
    };
  };

  // ThirdParty/REA/adapters/comparison.ts
  init_runtime();
  var digest = external_exports.string().regex(/^[0-9a-f]{64}$/);
  var uint = external_exports.number().int().nonnegative().safe();
  var source = external_exports.enum(["stdout", "stderr", "exit", "filesystem", "interaction", "process"]);
  var relative = external_exports.string().max(4096).refine((p) => p === "." || !p.startsWith("/") && !p.split("/").some((c) => c === ".." || c === "" || c === ".") && !p.includes("\0"), "unsafe relative path");
  var scenarioSchema = external_exports.strictObject({
    arguments: external_exports.array(external_exports.string()).max(4096),
    environment: external_exports.record(external_exports.string(), external_exports.string()),
    inputTreeSHA256: digest,
    workingDirectory: relative,
    interactions: external_exports.array(external_exports.strictObject({ atMS: uint, kind: external_exports.enum(["stdin", "signal", "resize"]), value: external_exports.string() })).max(1e4),
    dimensions: external_exports.array(source).min(1).max(6).refine((v) => new Set(v).size === v.length),
    normalization: external_exports.strictObject({ kind: external_exports.literal("exact-values-v1") })
  });
  var observationSchema = external_exports.strictObject({ order: uint, source, atMS: uint, value: external_exports.unknown() });
  var captureSchema = external_exports.strictObject({
    captureID: external_exports.string().min(1).max(128),
    scenario: scenarioSchema,
    scenarioSHA256: digest,
    executable: external_exports.strictObject({ sha256: digest, byteCount: uint }),
    producerReceipt: external_exports.strictObject({ receiptID: external_exports.string().min(1), captureID: external_exports.string(), scenarioSHA256: digest, executableSHA256: digest, inputTreeSHA256: digest, materializedInputTreeSHA256: digest }),
    observations: external_exports.array(observationSchema).max(1e5),
    completeSources: external_exports.array(source).max(6),
    truncatedSources: external_exports.array(source).max(6),
    cleanup: external_exports.enum(["verifiedAbsent", "failed", "unknown"]),
    execution: external_exports.enum(["accepted", "rejected"])
  });
  var comparisonInputSchema = external_exports.strictObject({
    left: captureSchema,
    right: captureSchema,
    admittedCaptureSHA256: external_exports.tuple([digest, digest])
  });
  var fail = (reason) => {
    throw new Error("Invalid committed process capture: " + reason);
  };
  function verify(c, admitted) {
    checkpoint();
    if (sha256UTF8(canonical(c)) !== admitted) fail("capture hash is not admitted");
    if (sha256UTF8(canonical(c.scenario)) !== c.scenarioSHA256) fail("scenario commitment mismatch");
    const r = c.producerReceipt;
    if (r.captureID !== c.captureID || r.scenarioSHA256 !== c.scenarioSHA256 || r.executableSHA256 !== c.executable.sha256 || r.inputTreeSHA256 !== c.scenario.inputTreeSHA256 || r.materializedInputTreeSHA256 !== r.inputTreeSHA256) fail("producer receipt binding mismatch");
    if (new Set(c.completeSources).size !== c.completeSources.length || new Set(c.truncatedSources).size !== c.truncatedSources.length) fail("duplicate coverage declaration");
    const exits = c.observations.filter((o) => o.source === "exit");
    if (exits.length > 1) fail("contradictory termination journal");
    let last = -1;
    for (let i = 0; i < c.observations.length; i++) {
      if ((i & 255) === 0) checkpoint();
      const o = c.observations[i];
      if (o.order !== i || o.atMS < last) fail("journal order contradiction");
      last = o.atMS;
      if (o.source === "stdout" || o.source === "stderr") external_exports.string().parse(o.value);
      if (o.source === "exit") {
        const termination = external_exports.strictObject({ code: external_exports.number().int().safe().nullable(), signal: external_exports.string().nullable(), reason: external_exports.enum(["exited", "signaled", "timeout", "cancelled"]) }).parse(o.value);
        if (termination.reason === "exited" && (termination.code === null || termination.signal !== null)) fail("contradictory exited termination");
        if (termination.reason === "signaled" && (termination.signal === null || termination.code !== null)) fail("contradictory signaled termination");
      }
      if (o.source === "filesystem") external_exports.array(external_exports.strictObject({ path: relative, sha256: digest, byteCount: uint })).max(1e4).parse(o.value);
      if (o.source === "interaction") external_exports.strictObject({ scheduledIndex: uint, kind: external_exports.enum(["stdin", "signal", "resize"]), value: external_exports.string() }).parse(o.value);
      if (o.source === "process") external_exports.strictObject({ pid: uint, parent_pid: uint, command: external_exports.string(), process_group_id: uint, session_id: uint }).parse(o.value);
    }
    if (c.completeSources.includes("exit") && exits.length !== 1) fail("complete exit lacks termination");
    const interactions = c.observations.filter((o) => o.source === "interaction");
    interactions.forEach((o, index) => {
      const v = o.value, planned = c.scenario.interactions[v.scheduledIndex];
      if (v.scheduledIndex !== index || !planned || planned.kind !== v.kind || planned.value !== v.value || planned.atMS !== o.atMS) fail("interaction contradicts committed schedule");
    });
    if (c.completeSources.includes("interaction") && interactions.length !== c.scenario.interactions.length) fail("complete interaction journal omits schedule");
    for (const o of c.observations.filter((o2) => o2.source === "filesystem")) {
      const paths = o.value.map((v) => v.path);
      if (new Set(paths).size !== paths.length) fail("duplicate filesystem identity");
    }
  }
  function project(c, s) {
    const events = c.observations.filter((o) => o.source === s);
    const complete = c.execution === "accepted" && c.cleanup === "verifiedAbsent" && c.completeSources.includes(s) && !c.truncatedSources.includes(s);
    const frames = s === "stdout" || s === "stderr" ? events.map((o, i) => ({ sequence: i, at_ms: 0, data: o.value })) : [];
    const byteCount = frames.reduce((n, o) => n + new TextEncoderFallback().length(o.data), 0);
    const retention = { budget_bytes: byteCount, observed_bytes: byteCount, retained_bytes: byteCount, observed_frames: frames.length, retained_frames: frames.length };
    const scope = s === "stdout" || s === "stderr" ? "terminal" : s;
    return {
      manifest: { comparison_contract: c.scenario, comparison_contract_sha256: c.scenarioSHA256 },
      normalization: c.scenario.normalization,
      frames,
      rendered_frames: [],
      interaction_events: s === "interaction" ? events.map((o) => ({ at_ms: o.atMS, ...o.value })) : [],
      exit: s === "exit" ? events[0]?.value ?? { code: null, signal: null, reason: "unknown" } : { code: 0, signal: null, reason: "exited" },
      settlement: { state: "quiesced", elapsed_ms: 0, cleanup_outcome: "verified" },
      filesystem_checkpoints: s === "filesystem" ? events.map((o) => ({ at_ms: 0, files: o.value })) : [],
      process_samples: s === "process" ? events.map((o) => ({ at_ms: o.atMS, ...o.value })) : [],
      truncated: !complete,
      truncation_details: { raw_terminal: retention, rendered_terminal: retention, filesystem_before: { enumeration_truncated: false, hash_omissions: [] }, filesystem_after: { enumeration_truncated: false, hash_omissions: [] }, process: { sampling_partial: false } },
      residual_unknowns: complete ? [] : [{ scope, reason: "Producer coverage, accepted execution, or cleanup is incomplete." }],
      limitations: []
    };
  }
  var TextEncoderFallback = class {
    length(value) {
      let n = 0;
      for (const c of value) {
        const p = c.codePointAt(0);
        n += p < 128 ? 1 : p < 2048 ? 2 : p < 65536 ? 3 : 4;
      }
      return n;
    }
  };
  function processComparison(raw) {
    guardJSON(raw);
    const input = comparisonInputSchema.parse(raw);
    verify(input.left, input.admittedCaptureSHA256[0]);
    verify(input.right, input.admittedCaptureSHA256[1]);
    if (input.left.scenarioSHA256 !== input.right.scenarioSHA256) return { status: "nonComparable", reason: "Scenario commitments differ.", dimensions: [] };
    const dimensions = input.left.scenario.dimensions.map((s) => {
      checkpoint();
      const a = project(input.left, s), b = project(input.right, s);
      const comparison = compareProcessCaptures(a, b);
      const dimension = s === "stdout" || s === "stderr" ? "terminal" : s;
      const status = comparison[dimension];
      return { source: s, status: status === "unchanged" ? "equal" : status === "unknown" ? "unknown" : "different", comparison };
    });
    return {
      status: dimensions.some((d) => d.status === "different") ? "different" : dimensions.some((d) => d.status === "unknown") ? "unknown" : "equal",
      dimensions,
      leftCaptureID: input.left.captureID,
      rightCaptureID: input.right.captureID,
      scenarioSHA256: input.left.scenarioSHA256,
      executableSHA256: [input.left.executable.sha256, input.right.executable.sha256]
    };
  }

  // ThirdParty/REA/adapters/kernel.ts
  var implementationIdentity = "33748ca432095d686f62a6a485a77432a059f26de1971754defcecd10918b6d2";
  function boundedDiagnostic(text) {
    let result = "", bytes = 0;
    for (const point of text) {
      const scalar = point.codePointAt(0);
      const safe = scalar >= 55296 && scalar <= 57343 ? "\uFFFD" : point;
      const size = import_buffer.Buffer.byteLength(safe, "utf8");
      if (bytes + size > 1024) break;
      result += safe;
      bytes += size;
    }
    return result;
  }
  async function analyze(text) {
    let request;
    try {
      checkpoint();
      if (typeof text !== "string" || import_buffer.Buffer.byteLength(text, "utf8") > 16 * 1024 * 1024) throw new Error("request budget");
      request = JSON.parse(text);
      guardJSON(request);
      if (canonical(request) !== text) throw new Error("noncanonical request");
      if (Object.keys(request).sort().join(",") !== "input,operation,requestID,schemaVersion" || request.schemaVersion !== 1 || typeof request.requestID !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(request.requestID)) throw new Error("invalid request envelope");
      let result;
      checkpoint();
      switch (request.operation) {
        case "nativeApplication":
          result = await nativeApplication(request.input);
          break;
        case "uiResources":
          result = await uiResources(request.input);
          break;
        case "processComparison":
          result = await processComparison(request.input);
          break;
        default:
          throw new Error("unsupported operation");
      }
      checkpoint();
      guardJSON(result);
      const response = canonical({ schemaVersion: 1, requestID: request.requestID, operation: request.operation, implementationIdentity, ok: true, result });
      if (import_buffer.Buffer.byteLength(response, "utf8") > 8 * 1024 * 1024) throw new Error("response budget");
      checkpoint();
      return response;
    } catch (error51) {
      const detail = String(error51 instanceof Error ? error51.message : error51);
      const message = boundedDiagnostic(detail);
      return canonical({ schemaVersion: 1, requestID: typeof request?.requestID === "string" ? request.requestID.slice(0, 128) : "", operation: typeof request?.operation === "string" ? request.operation.slice(0, 128) : "", implementationIdentity, ok: false, error: { code: /cancel|deadline/i.test(detail) ? "cancelled" : /budget|limit/i.test(detail) ? "budget" : "invalidInput", message } });
    }
  }
  return __toCommonJS(kernel_exports);
})();
