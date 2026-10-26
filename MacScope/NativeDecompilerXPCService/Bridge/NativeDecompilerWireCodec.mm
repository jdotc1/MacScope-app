#import "NativeDecompilerWireBridge.hpp"

#include "../../../Tools/NativeDecompilerBridge/src/CanonicalRequest.hpp"

#import <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstring>
#include <limits>
#include <optional>
#include <set>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

@interface MSOrderedPropertyListDictionary : NSDictionary {
@private
    NSDictionary *_values;
    NSArray<NSString *> *_orderedKeys;
}
- (instancetype)initWithValues:(NSDictionary *)values
                    orderedKeys:(NSArray<NSString *> *)orderedKeys;
@end

@implementation MSOrderedPropertyListDictionary

- (instancetype)initWithValues:(NSDictionary *)values
                    orderedKeys:(NSArray<NSString *> *)orderedKeys {
    self = [super init];
    if (self != nil) {
        _values = [values copy];
        _orderedKeys = [orderedKeys copy];
    }
    return self;
}

- (NSUInteger)count { return _orderedKeys.count; }
- (id)objectForKey:(id)key { return [_values objectForKey:key]; }
- (NSEnumerator *)keyEnumerator { return [_orderedKeys objectEnumerator]; }
- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

@end

namespace macscope::native_decompiler::xpc_bridge {
namespace {

constexpr NSUInteger kMaximumRequestBytes = 32U * 1024U * 1024U;
constexpr NSUInteger kMaximumResponseBytes = 64U * 1024U * 1024U;
// The transport contract advertises wider outer ceilings, but the frozen C++
// input model is the accepted publication boundary and is intentionally
// stricter. Reject before allocating records that it cannot construct.
constexpr NSUInteger kMaximumRegions = 256U;
constexpr NSUInteger kMaximumSymbols = 100'000U;
constexpr NSUInteger kMaximumTotalRegionBytes = 64U * 1024U * 1024U;
constexpr NSUInteger kMaximumAppliedPatchIDs = 100'000U;
constexpr std::size_t kMaximumPlistObjects = 1'000'000U;
constexpr std::size_t kMaximumPlistDictionaries = 250'000U;
constexpr std::size_t kMaximumPlistKeyReferences = 1'000'000U;
constexpr std::size_t kMaximumPlistTraversedReferences = 2'000'000U;
constexpr std::size_t kMaximumPlistUniqueKeyBytes = 4U * 1024U * 1024U;

[[noreturn]] void fail(WireFailureCode code, std::string_view message) {
    throw WireError(code, std::string(message));
}

std::string nativeString(NSString *value);

class BinaryPlistKeyScanner final {
public:
    explicit BinaryPlistKeyScanner(NSData *payload)
        : bytes_(static_cast<const std::uint8_t *>(payload.bytes)), size_(payload.length) {}

    void validate() {
        if (size_ < 40U || std::memcmp(bytes_, "bplist00", 8U) != 0) malformed();
        trailer_ = size_ - 32U;
        offsetSize_ = bytes_[trailer_ + 6U];
        referenceSize_ = bytes_[trailer_ + 7U];
        const auto objectCount = readInteger(trailer_ + 8U, 8U);
        const auto topObject = readInteger(trailer_ + 16U, 8U);
        const auto offsetTable = readInteger(trailer_ + 24U, 8U);
        if (offsetSize_ == 0U || offsetSize_ > 8U || referenceSize_ == 0U || referenceSize_ > 8U ||
            objectCount == 0U || objectCount > kMaximumPlistObjects || topObject >= objectCount ||
            objectCount > std::numeric_limits<std::size_t>::max() ||
            offsetTable > std::numeric_limits<std::size_t>::max()) {
            malformed();
        }
        const auto count = static_cast<std::size_t>(objectCount);
        objectTableEnd_ = static_cast<std::size_t>(offsetTable);
        if (objectTableEnd_ > trailer_ ||
            count > (trailer_ - objectTableEnd_) / offsetSize_) {
            malformed();
        }
        offsets_.reserve(count);
        for (std::size_t index = 0; index < count; ++index) {
            const auto offset = readInteger(objectTableEnd_ + index * offsetSize_, offsetSize_);
            if (offset >= objectTableEnd_) malformed();
            offsets_.push_back(static_cast<std::size_t>(offset));
        }

        std::vector<bool> visited(count, false);
        std::vector<std::size_t> pending{static_cast<std::size_t>(topObject)};
        while (!pending.empty()) {
            const auto object = pending.back();
            pending.pop_back();
            if (object >= count || visited[object]) continue;
            visited[object] = true;
            const auto offset = offsets_[object];
            const auto kind = bytes_[offset] >> 4U;
            if (kind == 0xDU) {
                visitDictionary(offset, pending);
            } else if (kind == 0xAU || kind == 0xCU) {
                visitCollection(offset, pending);
            }
        }
    }

private:
    [[noreturn]] static void malformed() {
        fail(WireFailureCode::malformedRequest, "malformed binary property-list object table");
    }

    [[nodiscard]] std::uint64_t readInteger(std::size_t offset, std::size_t count) const {
        if (count == 0U || count > 8U || offset > size_ || count > size_ - offset) malformed();
        std::uint64_t value = 0;
        for (std::size_t index = 0; index < count; ++index) {
            value = (value << 8U) | bytes_[offset + index];
        }
        return value;
    }

    [[nodiscard]] std::pair<std::size_t, std::size_t> collectionInfo(std::size_t offset) const {
        if (offset >= objectTableEnd_) malformed();
        const auto inlineCount = static_cast<std::size_t>(bytes_[offset] & 0x0fU);
        if (inlineCount < 0x0fU) return {inlineCount, offset + 1U};
        const auto integerOffset = offset + 1U;
        if (integerOffset >= objectTableEnd_ || bytes_[integerOffset] >> 4U != 0x1U) malformed();
        const auto exponent = bytes_[integerOffset] & 0x0fU;
        if (exponent > 3U) malformed();
        const auto byteCount = static_cast<std::size_t>(1U << exponent);
        const auto count = readInteger(integerOffset + 1U, byteCount);
        if (count > std::numeric_limits<std::size_t>::max()) malformed();
        const auto start = integerOffset + 1U + byteCount;
        if (start > objectTableEnd_) malformed();
        return {static_cast<std::size_t>(count), start};
    }

    [[nodiscard]] std::size_t referenceAt(std::size_t offset) const {
        const auto reference = readInteger(offset, referenceSize_);
        if (reference >= offsets_.size()) malformed();
        return static_cast<std::size_t>(reference);
    }

    void accountReferences(std::size_t count) {
        if (count > kMaximumPlistTraversedReferences - traversedReferences_) malformed();
        traversedReferences_ += count;
    }

    void visitCollection(std::size_t offset, std::vector<std::size_t>& pending) {
        const auto [count, references] = collectionInfo(offset);
        if (count > (objectTableEnd_ - references) / referenceSize_) malformed();
        accountReferences(count);
        for (std::size_t index = 0; index < count; ++index) {
            pending.push_back(referenceAt(references + index * referenceSize_));
        }
    }

    void visitDictionary(std::size_t offset, std::vector<std::size_t>& pending) {
        if (++dictionaryCount_ > kMaximumPlistDictionaries) malformed();
        const auto [count, references] = collectionInfo(offset);
        if (count > kMaximumPlistKeyReferences - keyReferences_) malformed();
        keyReferences_ += count;
        if (count > std::numeric_limits<std::size_t>::max() / 2U) malformed();
        const auto totalReferences = count * 2U;
        if (totalReferences > (objectTableEnd_ - references) / referenceSize_) malformed();
        accountReferences(totalReferences);

        std::set<std::string> keys;
        for (std::size_t index = 0; index < count; ++index) {
            const auto keyReference = referenceAt(references + index * referenceSize_);
            const auto& key = keyString(keyReference);
            if (!keys.insert(key).second) {
                fail(WireFailureCode::malformedRequest, "binary property list has duplicate dictionary keys");
            }
            const auto valueOffset = references + (count + index) * referenceSize_;
            pending.push_back(referenceAt(valueOffset));
        }
    }

    const std::string& keyString(std::size_t object) {
        if (const auto found = keyCache_.find(object); found != keyCache_.end()) return found->second;
        const auto offset = offsets_.at(object);
        const auto kind = bytes_[offset] >> 4U;
        if (kind != 0x5U && kind != 0x6U && kind != 0x7U) malformed();
        const auto [count, payload] = collectionInfo(offset);
        const auto width = kind == 0x6U ? 2U : 1U;
        if (count > (objectTableEnd_ - payload) / width) malformed();
        NSStringEncoding encoding = kind == 0x5U ? NSASCIIStringEncoding
            : (kind == 0x6U ? NSUTF16BigEndianStringEncoding : NSUTF8StringEncoding);
        NSString *decoded = [[NSString alloc] initWithBytes:bytes_ + payload
                                                     length:count * width
                                                   encoding:encoding];
        if (decoded == nil) malformed();
        std::string key = nativeString(decoded);
        if (key.size() > kMaximumPlistUniqueKeyBytes - uniqueKeyBytes_) malformed();
        uniqueKeyBytes_ += key.size();
        return keyCache_.emplace(object, std::move(key)).first->second;
    }

    const std::uint8_t *bytes_;
    std::size_t size_;
    std::size_t trailer_ = 0;
    std::size_t objectTableEnd_ = 0;
    std::size_t offsetSize_ = 0;
    std::size_t referenceSize_ = 0;
    std::size_t dictionaryCount_ = 0;
    std::size_t keyReferences_ = 0;
    std::size_t traversedReferences_ = 0;
    std::size_t uniqueKeyBytes_ = 0;
    std::vector<std::size_t> offsets_;
    std::unordered_map<std::size_t, std::string> keyCache_;
};

NSString *wireString(const std::string& value) {
    NSString *string = [[NSString alloc] initWithBytes:value.data()
                                                length:value.size()
                                              encoding:NSUTF8StringEncoding];
    if (string == nil) fail(WireFailureCode::nativeFailure, "native text is not UTF-8");
    return string;
}

std::string nativeString(NSString *value) {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (data == nil) fail(WireFailureCode::invalidRequest, "wire text is not UTF-8");
    return {static_cast<const char *>(data.bytes), data.length};
}

bool isBoundedText(NSString *value, NSUInteger maximum, bool allowEmpty = false) {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (data == nil || data.length > maximum || (!allowEmpty && data.length == 0)) return false;
    const auto *bytes = static_cast<const std::uint8_t *>(data.bytes);
    for (NSUInteger index = 0; index < data.length; ++index) {
        if (bytes[index] < 0x20U || bytes[index] == 0x7fU) return false;
    }
    return true;
}

bool isLowerHex(NSString *value, NSUInteger count) {
    NSData *data = [value dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:NO];
    if (data == nil || data.length != count) return false;
    const auto *bytes = static_cast<const std::uint8_t *>(data.bytes);
    for (NSUInteger index = 0; index < data.length; ++index) {
        const auto byte = bytes[index];
        if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f'))) return false;
    }
    return true;
}

NSString *requireString(id value, NSUInteger maximum, bool allowEmpty = false) {
    if (![value isKindOfClass:NSString.class] || !isBoundedText(value, maximum, allowEmpty)) {
        fail(WireFailureCode::invalidRequest, "expected bounded text");
    }
    return value;
}

NSDictionary *requireDictionary(id value) {
    if (![value isKindOfClass:NSDictionary.class]) {
        fail(WireFailureCode::invalidRequest, "expected dictionary");
    }
    return value;
}

NSArray *requireArray(id value, NSUInteger maximum) {
    if (![value isKindOfClass:NSArray.class] || [value count] > maximum) {
        fail(WireFailureCode::invalidRequest, "expected bounded array");
    }
    return value;
}

NSData *requireData(id value, NSUInteger maximum, bool allowEmpty = false) {
    if (![value isKindOfClass:NSData.class] || [value length] > maximum ||
        (!allowEmpty && [value length] == 0)) {
        fail(WireFailureCode::invalidRequest, "expected bounded data");
    }
    return value;
}

void requireExactKeys(
    NSDictionary *dictionary,
    NSArray<NSString *> *required,
    NSArray<NSString *> *optional = @[]
) {
    NSSet<NSString *> *requiredSet = [NSSet setWithArray:required];
    NSMutableSet<NSString *> *allowed = [requiredSet mutableCopy];
    [allowed addObjectsFromArray:optional];
    for (id key in dictionary) {
        if (![key isKindOfClass:NSString.class] || ![allowed containsObject:key]) {
            fail(WireFailureCode::invalidRequest, "wire object has an unknown key");
        }
    }
    for (NSString *key in required) {
        if (dictionary[key] == nil) fail(WireFailureCode::invalidRequest, "wire object is missing a key");
    }
}

std::uint32_t requireUInt32(id value) {
    if (![value isKindOfClass:NSNumber.class]) {
        fail(WireFailureCode::invalidRequest, "expected unsigned integer");
    }
    CFTypeRef reference = (__bridge CFTypeRef)value;
    if (CFGetTypeID(reference) == CFBooleanGetTypeID() ||
        CFGetTypeID(reference) != CFNumberGetTypeID() ||
        CFNumberIsFloatType((CFNumberRef)reference) || [value longLongValue] < 0 ||
        [value unsignedLongLongValue] > std::numeric_limits<std::uint32_t>::max()) {
        fail(WireFailureCode::invalidRequest, "expected UInt32");
    }
    return static_cast<std::uint32_t>([value unsignedLongLongValue]);
}

bool requireBool(id value) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
        fail(WireFailureCode::invalidRequest, "expected Boolean");
    }
    return [value boolValue];
}

std::int32_t requireInt32(id value) {
    if (![value isKindOfClass:NSNumber.class]) {
        fail(WireFailureCode::invalidRequest, "expected signed integer");
    }
    CFTypeRef reference = (__bridge CFTypeRef)value;
    const auto signedValue = [value longLongValue];
    if (CFGetTypeID(reference) == CFBooleanGetTypeID() ||
        CFGetTypeID(reference) != CFNumberGetTypeID() ||
        CFNumberIsFloatType((CFNumberRef)reference) ||
        signedValue < std::numeric_limits<std::int32_t>::min() ||
        signedValue > std::numeric_limits<std::int32_t>::max()) {
        fail(WireFailureCode::invalidRequest, "expected Int32");
    }
    return static_cast<std::int32_t>(signedValue);
}

std::uint64_t requireHexUInt64(id value) {
    if (![value isKindOfClass:NSString.class] || !isLowerHex(value, 16)) {
        fail(WireFailureCode::invalidRequest, "expected canonical UInt64");
    }
    std::uint64_t result = 0;
    NSData *data = [value dataUsingEncoding:NSASCIIStringEncoding];
    const auto *bytes = static_cast<const std::uint8_t *>(data.bytes);
    for (NSUInteger index = 0; index < data.length; ++index) {
        const auto byte = bytes[index];
        const std::uint64_t digit = byte <= '9' ? byte - '0' : byte - 'a' + 10U;
        result = (result << 4U) | digit;
    }
    return result;
}

std::uint32_t requireHexUInt32(id value) {
    if (![value isKindOfClass:NSString.class] || !isLowerHex(value, 8)) {
        fail(WireFailureCode::invalidRequest, "expected canonical UInt32 hexadecimal text");
    }
    return static_cast<std::uint32_t>(strtoul([static_cast<NSString *>(value) UTF8String], nullptr, 16));
}

NSString *hexUInt64(std::uint64_t value) {
    return [NSString stringWithFormat:@"%016llx", static_cast<unsigned long long>(value)];
}

NSUUID *requireCanonicalUUID(id value) {
    NSString *string = requireString(value, 36);
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:string];
    if (uuid == nil || ![uuid.UUIDString isEqualToString:string]) {
        fail(WireFailureCode::invalidRequest, "expected canonical UUID");
    }
    return uuid;
}

void requireTag(NSString *value, std::initializer_list<NSString *> allowed) {
    for (NSString *candidate : allowed) {
        if ([value isEqualToString:candidate]) return;
    }
    fail(WireFailureCode::invalidRequest, "unsupported wire enum");
}

std::vector<std::uint8_t> bytesFromData(NSData *data) {
    const auto *begin = static_cast<const std::uint8_t *>(data.bytes);
    return {begin, begin + data.length};
}

NSArray<NSString *> *stringArray(id value, NSUInteger maximum, NSUInteger stringMaximum) {
    NSArray *array = requireArray(value, maximum);
    NSMutableArray<NSString *> *output = [NSMutableArray arrayWithCapacity:array.count];
    for (id item in array) [output addObject:requireString(item, stringMaximum)];
    return output;
}

std::vector<std::string> nativeStrings(NSArray<NSString *> *values) {
    std::vector<std::string> output;
    output.reserve(values.count);
    for (NSString *value in values) output.push_back(nativeString(value));
    return output;
}

ImageIdentity decodeImage(NSDictionary *dictionary) {
    requireExactKeys(dictionary, @[@"imageID", @"uuid", @"preferredLoadAddress"]);
    NSString *uuid = requireCanonicalUUID(dictionary[@"uuid"]).UUIDString;
    return {
        nativeString(requireString(dictionary[@"imageID"], 256)),
        nativeString(uuid),
        requireHexUInt64(dictionary[@"preferredLoadAddress"]),
    };
}

FunctionIdentity decodeFunction(NSDictionary *dictionary, std::uint32_t schemaVersion) {
    if (schemaVersion == 4U) {
        requireExactKeys(dictionary, @[@"functionID", @"name", @"entryAddress", @"endAddressExclusive", @"codeRanges"]);
    } else {
        requireExactKeys(dictionary, @[@"functionID", @"name", @"entryAddress", @"endAddressExclusive"]);
    }
    FunctionIdentity function{
        nativeString(requireString(dictionary[@"functionID"], 1'024)),
        nativeString(requireString(dictionary[@"name"], 4'096)),
        requireHexUInt64(dictionary[@"entryAddress"]),
        requireHexUInt64(dictionary[@"endAddressExclusive"]),
        {},
    };
    if (schemaVersion == 4U) {
        NSArray *ranges = requireArray(dictionary[@"codeRanges"], 64U);
        if (ranges.count == 0U) fail(WireFailureCode::invalidRequest, "function code ranges are empty");
        for (id item in ranges) {
            NSDictionary *range = requireDictionary(item);
            requireExactKeys(range, @[@"startAddress", @"endAddressExclusive"]);
            function.codeRanges.push_back({
                requireHexUInt64(range[@"startAddress"]),
                requireHexUInt64(range[@"endAddressExclusive"]),
            });
        }
    }
    return function;
}

template <typename Enum>
Enum decodeAuthoredEnum(id value, std::uint32_t maximum) {
    const auto raw = requireUInt32(value);
    if (raw > maximum) fail(WireFailureCode::invalidRequest, "unsupported authored enum");
    return static_cast<Enum>(raw);
}

std::optional<std::uint64_t> optionalHexUInt64(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];
    if (value == nil) return std::nullopt;
    return requireHexUInt64(value);
}

AuthoredLayoutRules decodeAuthoredLayoutRules(NSDictionary *dictionary) {
    requireExactKeys(dictionary, @[@"isPacked"], @[@"packAlignment", @"minimumAlignment"]);
    return {
        requireBool(dictionary[@"isPacked"]),
        optionalHexUInt64(dictionary, @"packAlignment"),
        optionalHexUInt64(dictionary, @"minimumAlignment"),
    };
}

AuthoredType decodeAuthoredType(NSDictionary *dictionary, std::size_t depth);
AuthoredFieldStorage decodeAuthoredFieldStorage(NSDictionary *dictionary, std::size_t depth);

AuthoredAtom decodeAuthoredAtom(NSDictionary *dictionary) {
    const auto tag = decodeAuthoredEnum<AuthoredAtomTag>(dictionary[@"tag"], 3U);
    switch (tag) {
    case AuthoredAtomTag::void_:
        requireExactKeys(dictionary, @[@"tag"]);
        return {.tag = tag, .payload = std::monostate{}};
    case AuthoredAtomTag::scalar:
        requireExactKeys(dictionary, @[@"tag", @"scalarKind"]);
        return {
            .tag = tag,
            .payload = decodeAuthoredEnum<AuthoredScalarKind>(dictionary[@"scalarKind"], 11U),
        };
    case AuthoredAtomTag::darwinAlias:
        requireExactKeys(dictionary, @[@"tag", @"darwinAliasKind"]);
        return {
            .tag = tag,
            .payload = decodeAuthoredEnum<AuthoredDarwinAliasKind>(
                dictionary[@"darwinAliasKind"], 5U
            ),
        };
    case AuthoredAtomTag::named:
        requireExactKeys(dictionary, @[@"tag", @"namedKind", @"name"]);
        return {
            .tag = tag,
            .payload = AuthoredNamedAtom{
                decodeAuthoredEnum<AuthoredNamedKind>(dictionary[@"namedKind"], 3U),
                nativeString(requireString(dictionary[@"name"], 4'096)),
            },
        };
    }
    fail(WireFailureCode::invalidRequest, "unsupported authored atom");
}

AuthoredType decodeAuthoredType(NSDictionary *dictionary, std::size_t depth) {
    if (depth > 64U) fail(WireFailureCode::invalidRequest, "authored type depth exceeded");
    const auto tag = decodeAuthoredEnum<AuthoredTypeTag>(dictionary[@"tag"], 1U);
    switch (tag) {
    case AuthoredTypeTag::qualifiedValue: {
        requireExactKeys(dictionary, @[@"tag", @"atom", @"qualifiers"]);
        const auto qualifiers = requireUInt32(dictionary[@"qualifiers"]);
        if (qualifiers > 7U) fail(WireFailureCode::invalidRequest, "unknown authored qualifiers");
        return {
            .tag = tag,
            .payload = AuthoredQualifiedValue{
                decodeAuthoredAtom(requireDictionary(dictionary[@"atom"])),
                static_cast<std::uint8_t>(qualifiers),
            },
        };
    }
    case AuthoredTypeTag::dataPointer: {
        requireExactKeys(dictionary, @[
            @"tag", @"pointee", @"indirectionLevel", @"pointerQualifiersByLevel",
        ]);
        NSArray *qualifierObjects = requireArray(dictionary[@"pointerQualifiersByLevel"], 8U);
        std::vector<std::uint8_t> qualifiers;
        qualifiers.reserve(qualifierObjects.count);
        for (id value in qualifierObjects) {
            const auto qualifier = requireUInt32(value);
            if (qualifier > 7U) fail(WireFailureCode::invalidRequest, "unknown pointer qualifiers");
            qualifiers.push_back(static_cast<std::uint8_t>(qualifier));
        }
        return {
            .tag = tag,
            .payload = AuthoredDataPointer{
                std::make_shared<AuthoredType>(decodeAuthoredType(
                    requireDictionary(dictionary[@"pointee"]), depth + 1U
                )),
                requireHexUInt64(dictionary[@"indirectionLevel"]),
                std::move(qualifiers),
            },
        };
    }
    }
    fail(WireFailureCode::invalidRequest, "unsupported authored type");
}

AuthoredRecordField decodeAuthoredRecordField(NSDictionary *dictionary, std::size_t depth) {
    if (depth > 64U) fail(WireFailureCode::invalidRequest, "authored field depth exceeded");
    requireExactKeys(
        dictionary,
        @[@"name", @"storage", @"promotesInlineFields"],
        @[@"bitWidth", @"minimumAlignment", @"minimumAlignmentType"]
    );
    std::shared_ptr<AuthoredType> alignmentType;
    if (dictionary[@"minimumAlignmentType"] != nil) {
        alignmentType = std::make_shared<AuthoredType>(decodeAuthoredType(
            requireDictionary(dictionary[@"minimumAlignmentType"]), depth + 1U
        ));
    }
    return {
        nativeString(requireString(dictionary[@"name"], 4'096, true)),
        std::make_shared<AuthoredFieldStorage>(decodeAuthoredFieldStorage(
            requireDictionary(dictionary[@"storage"]), depth + 1U
        )),
        optionalHexUInt64(dictionary, @"bitWidth"),
        optionalHexUInt64(dictionary, @"minimumAlignment"),
        std::move(alignmentType),
        requireBool(dictionary[@"promotesInlineFields"]),
    };
}

std::vector<AuthoredRecordField> decodeAuthoredFields(id value, std::size_t depth) {
    NSArray *objects = requireArray(value, 4'096U);
    std::vector<AuthoredRecordField> fields;
    fields.reserve(objects.count);
    for (id object in objects) {
        fields.push_back(decodeAuthoredRecordField(requireDictionary(object), depth + 1U));
    }
    return fields;
}

AuthoredFieldStorage decodeAuthoredFieldStorage(NSDictionary *dictionary, std::size_t depth) {
    if (depth > 64U) fail(WireFailureCode::invalidRequest, "authored storage depth exceeded");
    const auto tag = decodeAuthoredEnum<AuthoredFieldStorageTag>(dictionary[@"tag"], 4U);
    switch (tag) {
    case AuthoredFieldStorageTag::value:
        requireExactKeys(dictionary, @[@"tag", @"type"]);
        return {
            .tag = tag,
            .payload = AuthoredValueStorage{decodeAuthoredType(
                requireDictionary(dictionary[@"type"]), depth + 1U
            )},
        };
    case AuthoredFieldStorageTag::fixedArray:
        requireExactKeys(dictionary, @[@"tag", @"element", @"count"]);
        return {
            .tag = tag,
            .payload = AuthoredFixedArrayStorage{
                std::make_shared<AuthoredFieldStorage>(decodeAuthoredFieldStorage(
                    requireDictionary(dictionary[@"element"]), depth + 1U
                )),
                requireHexUInt64(dictionary[@"count"]),
            },
        };
    case AuthoredFieldStorageTag::flexibleArray:
        requireExactKeys(dictionary, @[@"tag", @"element"]);
        return {
            .tag = tag,
            .payload = AuthoredFlexibleArrayStorage{
                std::make_shared<AuthoredFieldStorage>(decodeAuthoredFieldStorage(
                    requireDictionary(dictionary[@"element"]), depth + 1U
                )),
            },
        };
    case AuthoredFieldStorageTag::opaquePointerCarrier:
        requireExactKeys(dictionary, @[@"tag", @"kind"]);
        return {
            .tag = tag,
            .payload = AuthoredOpaquePointerCarrierStorage{
                decodeAuthoredEnum<AuthoredOpaquePointerCarrierKind>(dictionary[@"kind"], 1U),
            },
        };
    case AuthoredFieldStorageTag::inlineAggregate:
        requireExactKeys(dictionary, @[@"tag", @"kind", @"layoutRules", @"fields"]);
        return {
            .tag = tag,
            .payload = AuthoredInlineAggregateStorage{
                decodeAuthoredEnum<AuthoredNamedKind>(dictionary[@"kind"], 3U),
                decodeAuthoredLayoutRules(requireDictionary(dictionary[@"layoutRules"])),
                decodeAuthoredFields(dictionary[@"fields"], depth + 1U),
            },
        };
    }
    fail(WireFailureCode::invalidRequest, "unsupported authored field storage");
}

AuthoredTypeDefinition decodeAuthoredTypeDefinition(NSDictionary *dictionary) {
    const auto kind = decodeAuthoredEnum<AuthoredTypeDefinitionKind>(dictionary[@"kind"], 3U);
    const auto name = nativeString(requireString(dictionary[@"name"], 4'096));
    switch (kind) {
    case AuthoredTypeDefinitionKind::recordStruct:
    case AuthoredTypeDefinitionKind::recordUnion:
        requireExactKeys(dictionary, @[@"kind", @"name", @"layoutRules", @"fields"]);
        return {
            .kind = kind,
            .name = name,
            .payload = AuthoredRecordDefinition{
                kind == AuthoredTypeDefinitionKind::recordStruct
                    ? AuthoredNamedKind::struct_ : AuthoredNamedKind::union_,
                decodeAuthoredLayoutRules(requireDictionary(dictionary[@"layoutRules"])),
                decodeAuthoredFields(dictionary[@"fields"], 0U),
            },
        };
    case AuthoredTypeDefinitionKind::enumeration: {
        requireExactKeys(dictionary, @[@"kind", @"name", @"representation", @"cases"]);
        NSArray *objects = requireArray(dictionary[@"cases"], 4'096U);
        std::vector<AuthoredEnumCase> cases;
        cases.reserve(objects.count);
        for (id object in objects) {
            NSDictionary *enumCase = requireDictionary(object);
            requireExactKeys(enumCase, @[@"name", @"value"]);
            cases.push_back({
                nativeString(requireString(enumCase[@"name"], 4'096)),
                requireInt32(enumCase[@"value"]),
            });
        }
        return {
            .kind = kind,
            .name = name,
            .payload = AuthoredEnumerationDefinition{
                decodeAuthoredEnum<AuthoredEnumRepresentation>(dictionary[@"representation"], 0U),
                std::move(cases),
            },
        };
    }
    case AuthoredTypeDefinitionKind::typedef_:
        requireExactKeys(dictionary, @[@"kind", @"name", @"target"]);
        return {
            .kind = kind,
            .name = name,
            .payload = AuthoredTypedefDefinition{
                std::make_shared<AuthoredFieldStorage>(decodeAuthoredFieldStorage(
                    requireDictionary(dictionary[@"target"]), 0U
                )),
            },
        };
    }
    fail(WireFailureCode::invalidRequest, "unsupported authored definition");
}

AuthoredSignature decodeAuthoredSignature(id object) {
    NSDictionary *signature = requireDictionary(object);
    requireExactKeys(
        signature,
        @[@"functionAddress", @"parameterListState", @"parameters", @"variadicState", @"noReturnState"],
        @[@"returnType"]
    );
    std::shared_ptr<AuthoredType> returnType;
    if (signature[@"returnType"] != nil) {
        returnType = std::make_shared<AuthoredType>(decodeAuthoredType(
            requireDictionary(signature[@"returnType"]), 0U
        ));
    }
    NSArray *parameters = requireArray(signature[@"parameters"], 4'096U);
    std::vector<AuthoredParameter> nativeParameters;
    nativeParameters.reserve(parameters.count);
    for (id parameterObject in parameters) {
        NSDictionary *parameter = requireDictionary(parameterObject);
        requireExactKeys(parameter, @[@"name", @"type"], @[@"storageRegister"]);
        std::optional<std::string> storageRegister;
        if (parameter[@"storageRegister"] != nil) {
            storageRegister = nativeString(requireString(parameter[@"storageRegister"], 1'024, true));
        }
        nativeParameters.push_back({
            nativeString(requireString(parameter[@"name"], 4'096, true)),
            decodeAuthoredType(requireDictionary(parameter[@"type"]), 0U),
            std::move(storageRegister),
        });
    }
    return {
        requireHexUInt64(signature[@"functionAddress"]),
        std::move(returnType),
        decodeAuthoredEnum<AuthoredParameterListState>(signature[@"parameterListState"], 1U),
        std::move(nativeParameters),
        decodeAuthoredEnum<AuthoredVariadicState>(signature[@"variadicState"], 2U),
        decodeAuthoredEnum<AuthoredNoReturnState>(signature[@"noReturnState"], 2U),
    };
}

AuthoredInputs decodeAuthoredInputs(NSDictionary *dictionary) {
    AuthoredInputs inputs;
    inputs.schemaVersion = requireUInt32(dictionary[@"schemaVersion"]);
    // Schema v2 adds callee signature hints and v3 local names; v1 keeps its exact
    // closed key set.
    if (inputs.schemaVersion >= 3U) {
        requireExactKeys(dictionary, @[
            @"schemaVersion", @"names", @"signatures", @"appliedTypes", @"typeDefinitions",
            @"calleeSignatureHints", @"localNames",
        ]);
    } else if (inputs.schemaVersion >= 2U) {
        requireExactKeys(dictionary, @[
            @"schemaVersion", @"names", @"signatures", @"appliedTypes", @"typeDefinitions",
            @"calleeSignatureHints",
        ]);
    } else {
        requireExactKeys(dictionary, @[
            @"schemaVersion", @"names", @"signatures", @"appliedTypes", @"typeDefinitions",
        ]);
    }

    NSArray *names = requireArray(dictionary[@"names"], 4'096U);
    inputs.names.reserve(names.count);
    for (id object in names) {
        NSDictionary *name = requireDictionary(object);
        requireExactKeys(name, @[@"address", @"subjectKind", @"name"]);
        inputs.names.push_back({
            requireHexUInt64(name[@"address"]),
            decodeAuthoredEnum<AuthoredNameSubjectKind>(name[@"subjectKind"], 2U),
            nativeString(requireString(name[@"name"], 4'096)),
        });
    }

    NSArray *signatures = requireArray(dictionary[@"signatures"], 4'096U);
    inputs.signatures.reserve(signatures.count);
    for (id object in signatures) {
        inputs.signatures.push_back(decodeAuthoredSignature(object));
    }

    NSArray *appliedTypes = requireArray(dictionary[@"appliedTypes"], 4'096U);
    inputs.appliedTypes.reserve(appliedTypes.count);
    for (id object in appliedTypes) {
        NSDictionary *applied = requireDictionary(object);
        requireExactKeys(applied, @[@"address", @"subjectKind", @"typeDefinitionName", @"byteCount"]);
        inputs.appliedTypes.push_back({
            requireHexUInt64(applied[@"address"]),
            decodeAuthoredEnum<AuthoredAppliedTypeSubjectKind>(applied[@"subjectKind"], 0U),
            nativeString(requireString(applied[@"typeDefinitionName"], 4'096)),
            requireHexUInt64(applied[@"byteCount"]),
        });
    }

    NSArray *definitions = requireArray(dictionary[@"typeDefinitions"], 1'024U);
    inputs.typeDefinitions.reserve(definitions.count);
    for (id object in definitions) {
        inputs.typeDefinitions.push_back(decodeAuthoredTypeDefinition(requireDictionary(object)));
    }
    if (inputs.schemaVersion >= 2U) {
        NSArray *hints = requireArray(dictionary[@"calleeSignatureHints"], 4'096U);
        inputs.calleeSignatureHints.reserve(hints.count);
        for (id object in hints) {
            NSDictionary *hint = requireDictionary(object);
            requireExactKeys(hint, @[@"name", @"source", @"signature"]);
            inputs.calleeSignatureHints.push_back({
                nativeString(requireString(hint[@"name"], 4'096)),
                decodeAuthoredEnum<CalleeSignatureHintSource>(hint[@"source"], 4U),
                decodeAuthoredSignature(hint[@"signature"]),
            });
        }
    }
    if (inputs.schemaVersion >= 3U) {
        NSArray *locals = requireArray(dictionary[@"localNames"], 4'096U);
        inputs.localNames.reserve(locals.count);
        for (id object in locals) {
            NSDictionary *local = requireDictionary(object);
            requireExactKeys(local, @[@"storageKind", @"stackOffset", @"byteSize", @"register", @"name"],
                             @[@"type"]);
            std::shared_ptr<AuthoredType> type;
            if (local[@"type"] != nil) {
                type = std::make_shared<AuthoredType>(decodeAuthoredType(requireDictionary(local[@"type"]), 0U));
            }
            inputs.localNames.push_back({
                decodeAuthoredEnum<AuthoredLocalStorageKind>(local[@"storageKind"], 1U),
                requireInt32(local[@"stackOffset"]),
                requireUInt32(local[@"byteSize"]),
                nativeString(requireString(local[@"register"], 16, true)),
                nativeString(requireString(local[@"name"], 4'096)),
                std::move(type),
            });
        }
    }
    try {
        return canonicalizedAuthoredInputs(std::move(inputs));
    } catch (const ContractError&) {
        fail(WireFailureCode::invalidRequest, "authored inputs violate native contract");
    }
}

NSArray *arrayOfStrings(const std::vector<std::string>& values) {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto& value : values) [array addObject:wireString(value)];
    return array;
}

template <typename Value, typename Transform>
NSArray *mappedArray(const std::vector<Value>& values, Transform transform) {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto& value : values) [array addObject:transform(value)];
    return array;
}

NSDictionary *encodeImage(const ImageIdentity& image) {
    return @{
        @"imageID": wireString(image.imageId),
        @"uuid": wireString(image.uuid),
        @"preferredLoadAddress": hexUInt64(image.preferredLoadAddress),
    };
}

NSDictionary *encodeFunction(const FunctionIdentity& function) {
    NSMutableDictionary *encoded = [@{
        @"functionID": wireString(function.functionId),
        @"name": wireString(function.name),
        @"entryAddress": hexUInt64(function.entryAddress),
        @"endAddressExclusive": hexUInt64(function.endAddressExclusive),
    } mutableCopy];
    if (!function.codeRanges.empty()) {
        encoded[@"codeRanges"] = mappedArray(function.codeRanges, [](const FunctionIdentity::CodeRange& range) {
            return @{
                @"startAddress": hexUInt64(range.startAddress),
                @"endAddressExclusive": hexUInt64(range.endAddressExclusive),
            };
        });
    }
    return encoded;
}

NSDictionary *encodeRange(const SourceRange& range) {
    return @{
        @"imageID": wireString(range.imageId),
        @"startAddress": hexUInt64(range.startAddress),
        @"endAddressExclusive": hexUInt64(range.endAddressExclusive),
    };
}

NSArray *encodeRanges(const std::vector<SourceRange>& ranges) {
    return mappedArray(ranges, [](const SourceRange& range) { return encodeRange(range); });
}

NSString *mappedWireTag(
    const std::string& value,
    std::initializer_list<std::pair<std::string_view, NSString *>> mappings
) {
    for (const auto& [native, wire] : mappings) {
        if (value == native) return wire;
    }
    fail(WireFailureCode::nativeFailure, "native enum is not representable in the current wire schema");
}

NSString *opcodeWireTag(const std::string& opcode) {
    std::string result = opcode;
    std::transform(result.begin(), result.end(), result.begin(), [](unsigned char value) {
        return static_cast<char>(std::tolower(value));
    });
    // Wire vocabulary is generated from the shared manifest so the native provider,
    // this codec and the Swift decoder cannot drift apart. Adding an opcode in one
    // place and not the others previously produced a whole-result rejection rather
    // than a compile error. See MacScopeNativeDecompiler/PcodeOpcodeVocabulary.def.
    static const std::set<std::string> allowed{
#define MACSCOPE_PCODE_OPCODE(enumerator, canonical, wire) wire,
#include "MacScopeNativeDecompiler/PcodeOpcodeVocabulary.def"
#undef MACSCOPE_PCODE_OPCODE
    };
    if (!allowed.contains(result)) {
        fail(WireFailureCode::nativeFailure, "native opcode is not representable in the current wire schema");
    }
    return wireString(result);
}

template <typename Value>
void addOptional(NSMutableDictionary *dictionary, NSString *key, const std::optional<Value>& value) {
    if (value) dictionary[key] = wireString(*value);
}

void addOptionalHex(
    NSMutableDictionary *dictionary,
    NSString *key,
    const std::optional<std::uint64_t>& value
) {
    if (value) dictionary[key] = hexUInt64(*value);
}

NSString *failureTag(WireFailureCode code) {
    switch (code) {
    case WireFailureCode::malformedRequest: return @"malformed-request";
    case WireFailureCode::invalidRequest: return @"invalid-request";
    case WireFailureCode::nativeFailure: return @"native-failure";
    case WireFailureCode::packageVerificationFailed: return @"package-verification-failed";
    case WireFailureCode::busy: return @"busy";
    case WireFailureCode::cancelled: return @"cancelled";
    case WireFailureCode::timedOut: return @"timed-out";
    case WireFailureCode::unavailable: return @"unavailable";
    case WireFailureCode::unsupportedSchemaVersion: return @"unsupported-schema-version";
    case WireFailureCode::requestIDMismatch: return @"request-id-mismatch";
    case WireFailureCode::unsupportedCompiler: return @"unsupported-compiler";
    case WireFailureCode::requestTooLarge: return @"request-too-large";
    case WireFailureCode::responseTooLarge: return @"response-too-large";
    }
}

NSString *sanitizeDetail(const std::string& detail) {
    NSString *source = wireString(detail);
    NSMutableString *output = [NSMutableString stringWithCapacity:std::min<NSUInteger>(source.length, 1'024U)];
    for (NSUInteger index = 0; index < source.length && output.length < 1'024U; ++index) {
        unichar character = [source characterAtIndex:index];
        if (character < 0x20U || character == 0x7fU || character == '/' || character == '\\') {
            [output appendString:@" "];
        } else {
            [output appendFormat:@"%C", character];
        }
    }
    while ([output rangeOfString:@"0x" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [output replaceOccurrencesOfString:@"0x"
                               withString:@"hex"
                                  options:NSCaseInsensitiveSearch
                                    range:NSMakeRange(0, output.length)];
    }
    return [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

NSArray<NSString *> *orderedKeysForReplyDictionary(NSDictionary *dictionary) {
    static NSArray<NSArray<NSString *> *> *orders = @[
        @[@"schemaVersion", @"requestID", @"outcome", @"success", @"failure"],
        @[@"availability", @"result"],
        @[@"available", @"reasonCode", @"runtimeIdentity", @"capabilities"],
        @[@"backendID", @"engineVersion", @"engineRevision", @"wrapperVersion",
          @"wrapperRevision", @"packageManifestSHA256", @"packageTreeSHA256",
          @"languageID", @"compilerSpecID", @"targetProfileID", @"contextProfileSHA256"],
        @[@"nativeDecompilerHeritage", @"completeRegisterSSA", @"memorySSA",
          @"recoveredVariables", @"recoveredTypes", @"structuredControlFlow",
          @"tokenizedPseudocode", @"imageQualifiedSourceRanges"],
        @[@"requestID", @"requestSHA256", @"image", @"function", @"addressSpaces",
          @"types", @"instructions", @"varnodes", @"operations", @"blocks", @"edges",
          @"ssaValues", @"ssaBindings", @"phis", @"memoryVersions", @"memoryPhis",
          @"memoryEffects", @"variables", @"calls", @"regions", @"tokens",
          @"pseudocodeDocument", @"warnings", @"blockPartition"],
        @[@"version", @"entryBlockID", @"blocks", @"instructions", @"edges"],
        @[@"blockID", @"ordinal", @"entryAddress", @"sourceRanges"],
        @[@"instructionID", @"disposition", @"spans"],
        @[@"blockID", @"firstOperationIndex", @"operationCount"],
        @[@"edgeID", @"sourceSlot", @"targetSlot", @"transferKind"],
        @[@"imageID", @"uuid", @"preferredLoadAddress"],
        @[@"functionID", @"name", @"entryAddress", @"endAddressExclusive"],
        @[@"imageID", @"startAddress", @"endAddressExclusive"],
        @[@"id", @"name", @"kind", @"addressSizeBytes", @"isProcessorSpace"],
        @[@"name", @"typeID", @"bitOffset", @"bitSize"],
        @[@"id", @"kind", @"name", @"byteSize", @"isSigned", @"pointeeTypeID",
          @"fields", @"confidence", @"provenance", @"returnTypeID", @"parameterTypeIDs"],
        @[@"id", @"address", @"bytes", @"mnemonic", @"body", @"operationIDs", @"sourceRanges"],
        @[@"id", @"addressSpaceID", @"offset", @"sizeBytes", @"role", @"typeID", @"registerName"],
        @[@"id", @"blockID", @"sequence", @"opcode", @"outputVarnodeID",
          @"inputVarnodeIDs", @"directTargetAddress", @"sourceRanges",
          @"userOperationName", @"authenticationEffect"],
        @[@"kind", @"outputSSAValueID"],
        @[@"id", @"startAddress", @"endAddressExclusive", @"operationIDs",
          @"predecessorEdgeIDs", @"successorEdgeIDs", @"terminatorKind"],
        @[@"id", @"sourceBlockID", @"targetBlockID", @"targetAddress", @"kind", @"operationID"],
        @[@"id", @"varnodeID", @"kind", @"definingOperationID", @"definingPhiID"],
        @[@"operationID", @"inputSSAValueIDs", @"outputSSAValueID"],
        @[@"sourceBlockID", @"edgeID", @"ssaValueID"],
        @[@"id", @"blockID", @"varnodeID", @"outputSSAValueID", @"incoming"],
        @[@"id", @"partition", @"kind", @"definingOperationID", @"definingMemoryPhiID"],
        @[@"sourceBlockID", @"edgeID", @"memoryVersionID"],
        @[@"id", @"blockID", @"partition", @"outputMemoryVersionID", @"incoming"],
        @[@"id", @"operationID", @"kind", @"partition", @"inputMemoryVersionID", @"outputMemoryVersionID"],
        @[@"id", @"name", @"role", @"typeID", @"storageVarnodeIDs", @"liveRanges",
          @"confidence", @"provenance"],
        @[@"id", @"operationID", @"kind", @"targetAddress", @"targetSymbol",
          @"prototypeTypeID", @"argumentVariableIDs", @"resultVariableID", @"sourceRanges"],
        @[@"id", @"kind", @"parentRegionID", @"childRegionIDs", @"blockIDs",
          @"conditionOperationID", @"sourceRanges"],
        @[@"kind", @"id"],
        @[@"id", @"text", @"kind", @"line", @"column", @"sourceRanges", @"entityReferences"],
        @[@"text", @"language", @"isComplete", @"isTruncated"],
        @[@"code", @"severity", @"message", @"sourceRanges"],
        @[@"code", @"detail"],
        @[@"enums", @"optionals", @"tokenEntityKinds"],
        @[@"present", @"absent"],
    ];
    NSSet *actual = [NSSet setWithArray:dictionary.allKeys];
    NSArray<NSString *> *best = nil;
    NSUInteger bestMissing = NSUIntegerMax;
    for (NSArray<NSString *> *candidate in orders) {
        NSSet *candidateSet = [NSSet setWithArray:candidate];
        if (![actual isSubsetOfSet:candidateSet]) continue;
        const NSUInteger missing = candidate.count - actual.count;
        if (missing < bestMissing) {
            best = candidate;
            bestMissing = missing;
        }
    }
    if (best == nil) {
        return [dictionary.allKeys sortedArrayUsingSelector:@selector(compare:)];
    }
    NSMutableArray<NSString *> *present = [NSMutableArray arrayWithCapacity:actual.count];
    for (NSString *key in best) {
        if (dictionary[key] != nil) [present addObject:key];
    }
    return present;
}

id orderedReplyPropertyList(
    id value,
    NSMutableDictionary<NSString *, NSString *> *strings,
    NSMutableDictionary<NSNumber *, NSNumber *> *numbers,
    NSMutableDictionary<NSData *, NSData *> *dataValues
) {
    if ([value isKindOfClass:NSString.class]) {
        NSString *existing = strings[value];
        if (existing != nil) return existing;
        strings[value] = value;
        return value;
    }
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
            return [value boolValue] ? @YES : @NO;
        }
        NSNumber *existing = numbers[value];
        if (existing != nil) return existing;
        numbers[value] = value;
        return value;
    }
    if ([value isKindOfClass:NSData.class]) {
        NSData *existing = dataValues[value];
        if (existing != nil) return existing;
        dataValues[value] = value;
        return value;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *array = [NSMutableArray arrayWithCapacity:[value count]];
        for (id item in (NSArray *)value) {
            [array addObject:orderedReplyPropertyList(
                item, strings, numbers, dataValues
            )];
        }
        // Keep each encoded collection instance distinct. Copying an empty
        // NSMutableArray returns Foundation's shared empty-array singleton,
        // while Swift's frozen encoder emits a separate object at each field.
        return array;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        NSArray<NSString *> *keys = orderedKeysForReplyDictionary(dictionary);
        NSMutableDictionary *values = [NSMutableDictionary dictionaryWithCapacity:keys.count];
        for (NSString *key in keys) {
            values[key] = orderedReplyPropertyList(
                dictionary[key], strings, numbers, dataValues
            );
        }
        return [[MSOrderedPropertyListDictionary alloc]
            initWithValues:values orderedKeys:keys];
    }
    return value;
}

id orderedReplyPropertyList(id value) {
    return orderedReplyPropertyList(
        value,
        [NSMutableDictionary dictionary],
        [NSMutableDictionary dictionary],
        [NSMutableDictionary dictionary]
    );
}

std::uint64_t readBigEndian(
    const std::vector<std::uint8_t>& bytes,
    std::size_t offset,
    std::size_t count
) {
    if (count == 0U || count > 8U || offset > bytes.size() || count > bytes.size() - offset) {
        fail(WireFailureCode::nativeFailure, "reply binary property list is malformed");
    }
    std::uint64_t value = 0;
    for (std::size_t index = 0; index < count; ++index) {
        value = (value << 8U) | bytes[offset + index];
    }
    return value;
}

void appendBigEndian(
    std::vector<std::uint8_t>& output,
    std::uint64_t value,
    std::size_t count
) {
    for (std::size_t index = count; index > 0U; --index) {
        output.push_back(static_cast<std::uint8_t>(value >> ((index - 1U) * 8U)));
    }
}

std::size_t integerWidth(std::uint64_t value) {
    std::size_t width = 1U;
    while (width < 8U && value >= (std::uint64_t{1} << (width * 8U))) ++width;
    return width;
}

std::pair<std::size_t, std::size_t> collectionLayout(
    const std::vector<std::uint8_t>& object
) {
    if (object.empty()) fail(WireFailureCode::nativeFailure, "reply object is empty");
    const std::size_t inlineCount = object[0] & 0x0fU;
    if (inlineCount < 0x0fU) return {inlineCount, 1U};
    if (object.size() < 3U || object[1] >> 4U != 0x1U) {
        fail(WireFailureCode::nativeFailure, "reply collection count is malformed");
    }
    const std::size_t exponent = object[1] & 0x0fU;
    if (exponent > 3U) fail(WireFailureCode::nativeFailure, "reply collection count is too wide");
    const std::size_t byteCount = std::size_t{1} << exponent;
    const std::uint64_t count = readBigEndian(object, 2U, byteCount);
    if (count > std::numeric_limits<std::size_t>::max()) {
        fail(WireFailureCode::nativeFailure, "reply collection count overflows");
    }
    return {static_cast<std::size_t>(count), 2U + byteCount};
}

NSData *canonicalizeBinaryReplyObjects(NSData *data) {
    const auto *begin = static_cast<const std::uint8_t *>(data.bytes);
    std::vector<std::uint8_t> bytes(begin, begin + data.length);
    if (bytes.size() < 40U || std::memcmp(bytes.data(), "bplist00", 8U) != 0) {
        fail(WireFailureCode::nativeFailure, "reply is not a binary property list");
    }
    const std::size_t trailer = bytes.size() - 32U;
    const std::size_t oldOffsetSize = bytes[trailer + 6U];
    const std::size_t oldReferenceSize = bytes[trailer + 7U];
    const std::uint64_t objectCountValue = readBigEndian(bytes, trailer + 8U, 8U);
    const std::uint64_t topObjectValue = readBigEndian(bytes, trailer + 16U, 8U);
    const std::uint64_t offsetTableValue = readBigEndian(bytes, trailer + 24U, 8U);
    if (oldOffsetSize == 0U || oldOffsetSize > 8U ||
        oldReferenceSize == 0U || oldReferenceSize > 8U ||
        objectCountValue == 0U || objectCountValue > std::numeric_limits<std::size_t>::max() ||
        topObjectValue >= objectCountValue ||
        offsetTableValue > trailer || offsetTableValue > std::numeric_limits<std::size_t>::max()) {
        fail(WireFailureCode::nativeFailure, "reply binary property-list trailer is malformed");
    }
    const std::size_t objectCount = static_cast<std::size_t>(objectCountValue);
    const std::size_t offsetTable = static_cast<std::size_t>(offsetTableValue);
    if (objectCount > (trailer - offsetTable) / oldOffsetSize) {
        fail(WireFailureCode::nativeFailure, "reply offset table is malformed");
    }
    std::vector<std::size_t> offsets;
    offsets.reserve(objectCount + 1U);
    for (std::size_t index = 0; index < objectCount; ++index) {
        const std::uint64_t offset = readBigEndian(
            bytes, offsetTable + index * oldOffsetSize, oldOffsetSize
        );
        if (offset < 8U || offset >= offsetTable ||
            offset > std::numeric_limits<std::size_t>::max()) {
            fail(WireFailureCode::nativeFailure, "reply object offset is malformed");
        }
        offsets.push_back(static_cast<std::size_t>(offset));
    }
    offsets.push_back(offsetTable);
    for (std::size_t index = 1; index < offsets.size(); ++index) {
        if (offsets[index] <= offsets[index - 1U]) {
            fail(WireFailureCode::nativeFailure, "reply object table is not ordered");
        }
    }

    std::vector<std::vector<std::uint8_t>> objects;
    objects.reserve(objectCount);
    for (std::size_t index = 0; index < objectCount; ++index) {
        objects.emplace_back(
            bytes.begin() + static_cast<std::ptrdiff_t>(offsets[index]),
            bytes.begin() + static_cast<std::ptrdiff_t>(offsets[index + 1U])
        );
    }

    std::unordered_map<std::string, std::size_t> primitiveOwners;
    std::vector<std::size_t> representative(objectCount);
    std::vector<bool> keep(objectCount, true);
    for (std::size_t index = 0; index < objectCount; ++index) {
        const std::uint8_t kind = objects[index][0] >> 4U;
        if (kind != 0x0U && kind != 0x1U && kind != 0x5U && kind != 0x6U && kind != 0x7U) {
            representative[index] = index;
            continue;
        }
        std::string key;
        key.reserve(objects[index].size() + 1U);
        key.push_back(static_cast<char>(kind));
        key.append(
            reinterpret_cast<const char *>(objects[index].data()), objects[index].size()
        );
        const auto [iterator, inserted] = primitiveOwners.emplace(std::move(key), index);
        representative[index] = iterator->second;
        if (!inserted) keep[index] = false;
    }

    std::vector<std::size_t> newIndex(objectCount, std::numeric_limits<std::size_t>::max());
    std::size_t newObjectCount = 0U;
    for (std::size_t index = 0; index < objectCount; ++index) {
        if (keep[index]) newIndex[index] = newObjectCount++;
    }
    for (std::size_t index = 0; index < objectCount; ++index) {
        newIndex[index] = newIndex[representative[index]];
    }
    const std::size_t newReferenceSize = integerWidth(newObjectCount - 1U);

    std::vector<std::vector<std::uint8_t>> rewritten;
    rewritten.reserve(newObjectCount);
    for (std::size_t index = 0; index < objectCount; ++index) {
        if (!keep[index]) continue;
        const auto& object = objects[index];
        const std::uint8_t kind = object[0] >> 4U;
        if (kind != 0xAU && kind != 0xCU && kind != 0xDU) {
            rewritten.push_back(object);
            continue;
        }
        const auto [count, references] = collectionLayout(object);
        if (kind == 0xDU && count > std::numeric_limits<std::size_t>::max() / 2U) {
            fail(WireFailureCode::nativeFailure, "reply dictionary count overflows");
        }
        const std::size_t referenceCount = kind == 0xDU ? count * 2U : count;
        if (
            references > object.size() ||
            referenceCount > (object.size() - references) / oldReferenceSize) {
            fail(WireFailureCode::nativeFailure, "reply collection references are malformed");
        }
        std::vector<std::uint8_t> adjusted(object.begin(), object.begin() + references);
        adjusted.reserve(references + referenceCount * newReferenceSize);
        for (std::size_t ref = 0; ref < referenceCount; ++ref) {
            const std::uint64_t oldIndex = readBigEndian(
                object, references + ref * oldReferenceSize, oldReferenceSize
            );
            if (oldIndex >= objectCount) {
                fail(WireFailureCode::nativeFailure, "reply object reference is out of range");
            }
            appendBigEndian(adjusted, newIndex[static_cast<std::size_t>(oldIndex)], newReferenceSize);
        }
        rewritten.push_back(std::move(adjusted));
    }

    std::vector<std::uint8_t> output{'b', 'p', 'l', 'i', 's', 't', '0', '0'};
    std::vector<std::size_t> newOffsets;
    newOffsets.reserve(rewritten.size());
    for (const auto& object : rewritten) {
        newOffsets.push_back(output.size());
        output.insert(output.end(), object.begin(), object.end());
    }
    const std::size_t newOffsetTable = output.size();
    const std::size_t newOffsetSize = integerWidth(newOffsetTable);
    for (const std::size_t offset : newOffsets) appendBigEndian(output, offset, newOffsetSize);
    output.insert(output.end(), 6U, 0U);
    output.push_back(static_cast<std::uint8_t>(newOffsetSize));
    output.push_back(static_cast<std::uint8_t>(newReferenceSize));
    appendBigEndian(output, newObjectCount, 8U);
    appendBigEndian(output, newIndex[static_cast<std::size_t>(topObjectValue)], 8U);
    appendBigEndian(output, newOffsetTable, 8U);
    return [NSData dataWithBytes:output.data() length:output.size()];
}

NSData *serializeReply(NSDictionary *root) {
    NSError *error = nil;
    id ordered = orderedReplyPropertyList(root);
    NSData *canonical = [NSPropertyListSerialization dataWithPropertyList:ordered
                                                                   format:NSPropertyListBinaryFormat_v1_0
                                                                  options:0
                                                                    error:&error];
    if (canonical == nil || error != nil) fail(WireFailureCode::nativeFailure, "reply encoding failed");
    canonical = canonicalizeBinaryReplyObjects(canonical);
    if (canonical.length > kMaximumResponseBytes) {
        fail(WireFailureCode::responseTooLarge, "reply exceeds transport ceiling");
    }
    return canonical;
}

NSDictionary *encodeAvailability(const BackendAvailability& availability) {
    if (!availability.runtimeIdentity) {
        fail(WireFailureCode::nativeFailure, "prepared runtime identity is unavailable");
    }
    const auto& identity = *availability.runtimeIdentity;
    return @{
        @"available": @(availability.available),
        @"reasonCode": wireString(availability.reasonCode),
        @"runtimeIdentity": @{
            @"backendID": wireString(identity.backendId),
            @"engineVersion": wireString(identity.engineVersion),
            @"engineRevision": wireString(identity.engineRevision),
            @"wrapperVersion": wireString(identity.wrapperVersion),
            @"wrapperRevision": wireString(identity.wrapperRevision),
            @"packageManifestSHA256": wireString(identity.packageManifestSha256),
            @"packageTreeSHA256": wireString(identity.packageTreeSha256),
            @"languageID": wireString(identity.languageId),
            @"compilerSpecID": wireString(identity.compilerSpecId),
            @"targetProfileID": wireString(identity.targetProfileId),
            @"contextProfileSHA256": wireString(identity.contextProfileSha256),
        },
        @"capabilities": @{
            @"nativeDecompilerHeritage": @(availability.capabilities.nativeDecompilerHeritage),
            @"completeRegisterSSA": @(availability.capabilities.completeRegisterSsa),
            @"memorySSA": @(availability.capabilities.memorySsa),
            @"recoveredVariables": @(availability.capabilities.recoveredVariables),
            @"recoveredTypes": @(availability.capabilities.recoveredTypes),
            @"structuredControlFlow": @(availability.capabilities.structuredControlFlow),
            @"tokenizedPseudocode": @(availability.capabilities.tokenizedPseudocode),
            @"imageQualifiedSourceRanges": @(availability.capabilities.imageQualifiedSourceRanges),
        },
    };
}

NSDictionary *encodeResult(const StructuredResult& result) {
    NSArray *addressSpaces = mappedArray(result.addressSpaces, [](const AddressSpaceRecord& value) {
        return @{
            @"id": wireString(value.id), @"name": wireString(value.name),
            @"kind": mappedWireTag(value.kind, {
                {"constant", @"constant"}, {"processor", @"processor"},
                {"spacebase", @"spacebase"}, {"unique", @"unique"}, {"fspec", @"fspec"},
                {"iop", @"iop"}, {"join", @"join"},
            }), @"addressSizeBytes": @(value.addressSizeBytes),
            @"isProcessorSpace": @(value.isProcessorSpace),
        };
    });
    NSArray *types = mappedArray(result.types, [](const TypeRecord& value) {
        NSMutableDictionary *dictionary = [@{
            @"id": wireString(value.id), @"kind": mappedWireTag(value.kind, {
                {"array", @"array"}, {"boolean", @"boolean"}, {"enum", @"enumeration"},
                {"enumeration", @"enumeration"}, {"float", @"floating-point"},
                {"floatingPoint", @"floating-point"}, {"floating-point", @"floating-point"},
                {"function", @"function"}, {"integer", @"integer"}, {"pointer", @"pointer"},
                {"partial", @"unknown"}, {"spacebase", @"unknown"}, {"struct", @"structure"},
                {"structure", @"structure"}, {"union", @"union"}, {"unknown", @"unknown"},
                {"void", @"void"},
            }),
            @"name": wireString(value.name),
            @"fields": mappedArray(value.fields, [](const TypeFieldRecord& field) {
                return @{
                    @"name": wireString(field.name), @"typeID": wireString(field.typeId),
                    @"bitOffset": hexUInt64(field.bitOffset), @"bitSize": hexUInt64(field.bitSize),
                };
            }),
            @"confidence": mappedWireTag(value.confidence, {
                {"asserted", @"asserted"}, {"high", @"high"}, {"medium", @"medium"},
                {"low", @"low"}, {"unknown", @"unknown"},
            }),
            @"provenance": wireString(value.provenance),
            @"parameterTypeIDs": arrayOfStrings(value.parameterTypeIds),
        } mutableCopy];
        if (value.byteSize) dictionary[@"byteSize"] = hexUInt64(*value.byteSize);
        if (value.isSigned) dictionary[@"isSigned"] = @(*value.isSigned);
        addOptional(dictionary, @"pointeeTypeID", value.pointeeTypeId);
        addOptional(dictionary, @"returnTypeID", value.returnTypeId);
        return dictionary;
    });
    NSArray *instructions = mappedArray(result.instructions, [](const InstructionRecord& value) {
        NSData *bytes = [NSData dataWithBytes:value.bytes.data() length:value.bytes.size()];
        return @{
            @"id": wireString(value.id), @"address": hexUInt64(value.address), @"bytes": bytes,
            @"mnemonic": wireString(value.mnemonic), @"body": wireString(value.body),
            @"operationIDs": arrayOfStrings(value.operationIds), @"sourceRanges": encodeRanges(value.sourceRanges),
        };
    });
    NSArray *varnodes = mappedArray(result.varnodes, [](const VarnodeRecord& value) {
        NSMutableDictionary *dictionary = [@{
            @"id": wireString(value.id), @"addressSpaceID": wireString(value.addressSpaceId),
            @"offset": hexUInt64(value.offset), @"sizeBytes": @(value.sizeBytes),
            @"role": mappedWireTag(value.role, {
                {"address", @"address"}, {"constant", @"constant"}, {"internal", @"internal"},
                {"join", @"join"}, {"memory", @"memory"}, {"register", @"register"},
                {"stack", @"stack"}, {"unique", @"unique"},
            }),
        } mutableCopy];
        addOptional(dictionary, @"typeID", value.typeId);
        addOptional(dictionary, @"registerName", value.registerName);
        return dictionary;
    });
    NSArray *operations = mappedArray(result.operations, [](const OperationRecord& value) {
        NSMutableDictionary *dictionary = [@{
            @"id": wireString(value.id), @"blockID": wireString(value.blockId),
            @"sequence": hexUInt64(value.sequence), @"opcode": opcodeWireTag(value.opcode),
            @"inputVarnodeIDs": arrayOfStrings(value.inputVarnodeIds),
            @"sourceRanges": encodeRanges(value.sourceRanges),
        } mutableCopy];
        addOptional(dictionary, @"outputVarnodeID", value.outputVarnodeId);
        addOptionalHex(dictionary, @"directTargetAddress", value.directTargetAddress);
        addOptional(dictionary, @"userOperationName", value.userOperationName);
        NSString *effectKind = nil;
        switch (value.authenticationEffect.kind) {
        case AuthenticationEffectKind::none: effectKind = @"none"; break;
        case AuthenticationEffectKind::transformedOutput: effectKind = @"transformed-output"; break;
        case AuthenticationEffectKind::authenticatedMemoryAccessWithoutTransformedAddress:
            effectKind = @"authenticated-memory-access-without-transformed-address"; break;
        case AuthenticationEffectKind::authenticatedControlTransferWithoutTransformedTarget:
            effectKind = @"authenticated-control-transfer-without-transformed-target"; break;
        case AuthenticationEffectKind::standaloneAuthenticationWithoutTransformedOutput:
            effectKind = @"standalone-authentication-without-transformed-output"; break;
        default: throw ContractError("authentication effect kind is unsupported");
        }
        NSMutableDictionary *effect = [@{@"kind": effectKind} mutableCopy];
        addOptional(effect, @"outputSSAValueID", value.authenticationEffect.outputSsaValueId);
        dictionary[@"authenticationEffect"] = effect;
        return dictionary;
    });
    NSArray *blocks = mappedArray(result.blocks, [](const BlockRecord& value) {
        return @{
            @"id": wireString(value.id), @"startAddress": hexUInt64(value.startAddress),
            @"endAddressExclusive": hexUInt64(value.endAddressExclusive),
            @"operationIDs": arrayOfStrings(value.operationIds),
            @"predecessorEdgeIDs": arrayOfStrings(value.predecessorEdgeIds),
            @"successorEdgeIDs": arrayOfStrings(value.successorEdgeIds),
            @"terminatorKind": mappedWireTag(value.terminatorKind, {
                {"branch", @"branch"}, {"conditional", @"conditional"}, {"exit", @"exit"},
                {"fallthrough", @"fallthrough"}, {"return", @"return"}, {"switch", @"switch"},
                {"splice", @"splice"},
            }),
        };
    });
    NSArray *edges = mappedArray(result.edges, [](const EdgeRecord& value) {
        NSMutableDictionary *dictionary = [@{
            @"id": wireString(value.id), @"sourceBlockID": wireString(value.sourceBlockId),
            @"targetAddress": hexUInt64(value.targetAddress), @"kind": mappedWireTag(value.kind, {
                {"branch", @"branch"}, {"fallthrough", @"fallthrough"}, {"false", @"false"},
                {"switch-case", @"switch-case"}, {"switch-default", @"switch-default"},
                // GhidraProvider spells switch edges in camelCase (switchCase/switchDefault).
                {"switchCase", @"switch-case"}, {"switchDefault", @"switch-default"},
                {"true", @"true"}, {"splice", @"splice"},
            }),
        } mutableCopy];
        addOptional(dictionary, @"targetBlockID", value.targetBlockId);
        addOptional(dictionary, @"operationID", value.operationId);
        return dictionary;
    });
    NSArray *ssaValues = mappedArray(result.ssaValues, [](const SsaValueRecord& value) {
        NSMutableDictionary *dictionary = [@{
            @"id": wireString(value.id), @"varnodeID": wireString(value.varnodeId),
            @"kind": mappedWireTag(value.kind, {
                {"annotation", @"annotation"}, {"constant", @"constant"},
                {"functionEntry", @"function-entry"}, {"function-entry", @"function-entry"},
                {"operationResult", @"operation-result"}, {"operation-result", @"operation-result"},
                {"phiResult", @"phi-result"}, {"phi-result", @"phi-result"},
            }),
        } mutableCopy];
        addOptional(dictionary, @"definingOperationID", value.definingOperationId);
        addOptional(dictionary, @"definingPhiID", value.definingPhiId);
        return dictionary;
    });
    NSArray *ssaBindings = mappedArray(result.ssaBindings, [](const SsaBindingRecord& value) {
        NSMutableDictionary *dictionary = [@{
            @"operationID": wireString(value.operationId),
            @"inputSSAValueIDs": arrayOfStrings(value.inputSsaValueIds),
        } mutableCopy];
        addOptional(dictionary, @"outputSSAValueID", value.outputSsaValueId);
        return dictionary;
    });
    NSArray *phis = mappedArray(result.phis, [](const PhiRecord& value) {
        return @{
            @"id": wireString(value.id), @"blockID": wireString(value.blockId),
            @"varnodeID": wireString(value.varnodeId), @"outputSSAValueID": wireString(value.outputSsaValueId),
            @"incoming": mappedArray(value.incoming, [](const PhiIncomingRecord& incoming) {
                NSMutableDictionary *dictionary = [@{@"ssaValueID": wireString(incoming.ssaValueId)} mutableCopy];
                addOptional(dictionary, @"sourceBlockID", incoming.sourceBlockId);
                addOptional(dictionary, @"edgeID", incoming.edgeId);
                return dictionary;
            }),
        };
    });
    NSArray *memoryVersions = mappedArray(result.memoryVersions, [](const MemoryVersionRecord& value) {
        NSMutableDictionary *dictionary = [@{
            @"id": wireString(value.id), @"partition": wireString(value.partition),
            @"kind": mappedWireTag(value.kind, {
                {"functionEntry", @"function-entry"}, {"function-entry", @"function-entry"},
                {"operationResult", @"operation-result"}, {"operation-result", @"operation-result"},
                {"phiResult", @"phi-result"}, {"phi-result", @"phi-result"},
            }),
        } mutableCopy];
        addOptional(dictionary, @"definingOperationID", value.definingOperationId);
        addOptional(dictionary, @"definingMemoryPhiID", value.definingMemoryPhiId);
        return dictionary;
    });
    NSArray *memoryPhis = mappedArray(result.memoryPhis, [](const MemoryPhiRecord& value) {
        return @{
            @"id": wireString(value.id), @"blockID": wireString(value.blockId),
            @"partition": wireString(value.partition),
            @"outputMemoryVersionID": wireString(value.outputMemoryVersionId),
            @"incoming": mappedArray(value.incoming, [](const MemoryPhiIncomingRecord& incoming) {
                NSMutableDictionary *dictionary = [@{@"memoryVersionID": wireString(incoming.memoryVersionId)} mutableCopy];
                addOptional(dictionary, @"sourceBlockID", incoming.sourceBlockId);
                addOptional(dictionary, @"edgeID", incoming.edgeId);
                return dictionary;
            }),
        };
    });
    NSArray *memoryEffects = mappedArray(result.memoryEffects, [](const MemoryEffectRecord& value) {
        NSMutableDictionary *dictionary = [@{
            @"id": wireString(value.id), @"operationID": wireString(value.operationId),
            @"kind": mappedWireTag(value.kind, {
                {"read", @"read"}, {"write", @"write"}, {"readWrite", @"read-write"},
                {"read-write", @"read-write"},
            }), @"partition": wireString(value.partition),
        } mutableCopy];
        addOptional(dictionary, @"inputMemoryVersionID", value.inputMemoryVersionId);
        addOptional(dictionary, @"outputMemoryVersionID", value.outputMemoryVersionId);
        return dictionary;
    });
    NSArray *variables = mappedArray(result.variables, [](const VariableRecord& value) {
        NSMutableDictionary *dictionary = [@{
            @"id": wireString(value.id), @"name": wireString(value.name),
            @"role": mappedWireTag(value.role, {
                {"global", @"global"}, {"local", @"local"}, {"parameter", @"parameter"},
                {"result", @"result"}, {"temporary", @"temporary"},
            }),
            @"storageVarnodeIDs": arrayOfStrings(value.storageVarnodeIds),
            @"liveRanges": encodeRanges(value.liveRanges), @"confidence": mappedWireTag(value.confidence, {
                {"asserted", @"asserted"}, {"high", @"high"}, {"medium", @"medium"},
                {"low", @"low"}, {"unknown", @"unknown"},
            }),
            @"provenance": wireString(value.provenance),
        } mutableCopy];
        addOptional(dictionary, @"typeID", value.typeId);
        return dictionary;
    });
    NSArray *calls = mappedArray(result.calls, [](const CallRecord& value) {
        NSMutableDictionary *dictionary = [@{
            @"id": wireString(value.id), @"operationID": wireString(value.operationId),
            @"kind": mappedWireTag(value.kind, {{"direct", @"direct"}, {"indirect", @"indirect"}}),
            @"argumentVariableIDs": arrayOfStrings(value.argumentVariableIds),
            @"sourceRanges": encodeRanges(value.sourceRanges),
        } mutableCopy];
        addOptionalHex(dictionary, @"targetAddress", value.targetAddress);
        addOptional(dictionary, @"targetSymbol", value.targetSymbol);
        addOptional(dictionary, @"prototypeTypeID", value.prototypeTypeId);
        addOptional(dictionary, @"resultVariableID", value.resultVariableId);
        return dictionary;
    });
    NSArray *regions = mappedArray(result.regions, [](const RegionRecord& value) {
        NSMutableDictionary *dictionary = [@{
            @"id": wireString(value.id), @"kind": mappedWireTag(value.kind, {
                {"condition", @"condition"}, {"doWhile", @"do-while"}, {"do-while", @"do-while"},
                {"goto", @"goto"}, {"if", @"if"}, {"infiniteLoop", @"infinite-loop"},
                {"infinite-loop", @"infinite-loop"}, {"multiGoto", @"multi-goto"},
                {"multi-goto", @"multi-goto"}, {"root", @"root"}, {"sequence", @"sequence"},
                {"switch", @"switch"}, {"while", @"while"},
            }),
            @"childRegionIDs": arrayOfStrings(value.childRegionIds), @"blockIDs": arrayOfStrings(value.blockIds),
            @"sourceRanges": encodeRanges(value.sourceRanges),
        } mutableCopy];
        addOptional(dictionary, @"parentRegionID", value.parentRegionId);
        addOptional(dictionary, @"conditionOperationID", value.conditionOperationId);
        return dictionary;
    });
    NSArray *tokens = mappedArray(result.tokens, [](const PseudocodeTokenRecord& value) {
        return @{
            @"id": wireString(value.id), @"text": wireString(value.text),
            @"kind": mappedWireTag(value.kind, {
                {"comment", @"comment"}, {"identifier", @"identifier"}, {"keyword", @"keyword"},
                {"literal", @"literal"}, {"operation", @"operation"},
                {"punctuation", @"punctuation"}, {"type", @"type"}, {"whitespace", @"whitespace"},
            }),
            @"line": @(value.line), @"column": @(value.column), @"sourceRanges": encodeRanges(value.sourceRanges),
            @"entityReferences": mappedArray(value.entityReferences, [](const TokenEntityReference& reference) {
                return @{
                    @"kind": mappedWireTag(reference.kind, {
                        {"block", @"block"}, {"call", @"call"}, {"instruction", @"instruction"},
                        {"operation", @"operation"}, {"region", @"region"}, {"type", @"type"},
                        {"variable", @"variable"}, {"varnode", @"varnode"},
                    }),
                    @"id": wireString(reference.id),
                };
            }),
        };
    });
    NSArray *warnings = mappedArray(result.warnings, [](const DiagnosticRecord& value) {
        return @{
            @"code": wireString(value.code), @"severity": mappedWireTag(value.severity, {
                {"error", @"error"}, {"information", @"information"}, {"warning", @"warning"},
            }),
            @"message": wireString(value.message), @"sourceRanges": encodeRanges(value.sourceRanges),
        };
    });

    NSMutableDictionary *encoded = [@{
        @"requestID": wireString(result.requestId), @"requestSHA256": wireString(result.requestSha256),
        @"image": encodeImage(result.image), @"function": encodeFunction(result.function),
        @"addressSpaces": addressSpaces, @"types": types, @"instructions": instructions,
        @"varnodes": varnodes, @"operations": operations, @"blocks": blocks, @"edges": edges,
        @"ssaValues": ssaValues, @"ssaBindings": ssaBindings, @"phis": phis,
        @"memoryVersions": memoryVersions, @"memoryPhis": memoryPhis, @"memoryEffects": memoryEffects,
        @"variables": variables, @"calls": calls, @"regions": regions, @"tokens": tokens,
        @"warnings": warnings,
    } mutableCopy];
    if (result.pseudocodeDocument) {
        encoded[@"pseudocodeDocument"] = @{
            @"text": wireString(result.pseudocodeDocument->text),
            @"language": wireString(result.pseudocodeDocument->language),
            @"isComplete": @(result.pseudocodeDocument->isComplete),
            @"isTruncated": @(result.pseudocodeDocument->isTruncated),
        };
    }
    if (result.blockPartition) {
        const auto& partition = *result.blockPartition;
        encoded[@"blockPartition"] = @{
            @"version": @(partition.version),
            @"entryBlockID": wireString(partition.entryBlockId),
            @"blocks": mappedArray(partition.blocks, [](const BlockPartitionBlockRecord& block) {
                return @{
                    @"blockID": wireString(block.blockId), @"ordinal": @(block.ordinal),
                    @"entryAddress": hexUInt64(block.entryAddress),
                    @"sourceRanges": encodeRanges(block.sourceRanges),
                };
            }),
            @"instructions": mappedArray(partition.instructions, [](const InstructionOwnershipRecord& instruction) {
                return @{
                    @"instructionID": wireString(instruction.instructionId),
                    @"disposition": mappedWireTag(instruction.disposition, {
                        {"retained", @"retained"}, {"eliminated", @"eliminated"},
                    }),
                    @"spans": mappedArray(instruction.spans, [](const InstructionBlockSpanRecord& span) {
                        return @{
                            @"blockID": wireString(span.blockId),
                            @"firstOperationIndex": @(span.firstOperationIndex),
                            @"operationCount": @(span.operationCount),
                        };
                    }),
                };
            }),
            @"edges": mappedArray(partition.edges, [](const BlockPartitionEdgeRecord& edge) {
                return @{
                    @"edgeID": wireString(edge.edgeId), @"sourceSlot": @(edge.sourceSlot),
                    @"targetSlot": @(edge.targetSlot),
                    @"transferKind": mappedWireTag(edge.transferKind, {
                        {"direct", @"direct"}, {"rewritten-direct", @"rewritten-direct"},
                        {"intra-instruction", @"intra-instruction"},
                        {"rewritten-intra-instruction", @"rewritten-intra-instruction"},
                        {"fallthrough", @"fallthrough"}, {"indirect", @"indirect"},
                        {"splice", @"splice"},
                    }),
                };
            }),
        };
    }
    return encoded;
}

NSArray<NSString *> *uniqueValues(NSArray<NSDictionary *> *records, NSString *key) {
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *record in records) {
        NSString *value = record[key];
        if (value != nil && ![seen containsObject:value]) {
            [seen addObject:value];
            [values addObject:value];
        }
    }
    return values;
}

NSArray<NSDictionary *> *nestedRecords(NSArray<NSDictionary *> *records, NSString *key) {
    NSMutableArray<NSDictionary *> *values = [NSMutableArray array];
    for (NSDictionary *record in records) {
        NSArray<NSDictionary *> *nested = record[key];
        if (nested != nil) [values addObjectsFromArray:nested];
    }
    return values;
}

NSDictionary *optionalCoverage(NSArray<NSDictionary *> *records, NSString *key) {
    bool present = false;
    bool absent = false;
    for (NSDictionary *record in records) {
        if (record[key] == nil) {
            absent = true;
        } else {
            present = true;
        }
    }
    return @{@"present": @(present), @"absent": @(absent)};
}

StructuredResult mappingCoverageResult() {
    StructuredResult result;
    result.requestId = "00000000-0000-0000-0000-000000000099";
    result.requestSha256 = std::string(64, '9');
    result.image = {"image.coverage", "00000000-0000-0000-0000-000000000099", 0x1000};
    result.function = {"function.coverage", "coverage", 0x1000, 0x1004, {}};

    const std::vector<std::string> addressSpaceKinds{
        "constant", "processor", "spacebase", "unique", "fspec", "iop", "join",
    };
    for (std::size_t index = 0; index < addressSpaceKinds.size(); ++index) {
        result.addressSpaces.push_back({
            "space." + std::to_string(index), "space" + std::to_string(index),
            addressSpaceKinds[index], 8, index == 1,
        });
    }

    const std::vector<std::string> typeKinds{
        "array", "boolean", "enumeration", "floatingPoint", "function", "integer",
        "pointer", "structure", "union", "unknown", "void",
    };
    const std::vector<std::string> confidences{"asserted", "high", "medium", "low", "unknown"};
    for (std::size_t index = 0; index < typeKinds.size(); ++index) {
        result.types.push_back({
            .id = "type." + std::to_string(index),
            .kind = typeKinds[index],
            .name = "type" + std::to_string(index),
            .byteSize = index == 0 ? std::optional<std::uint64_t>(8) : std::nullopt,
            .isSigned = index == 0 ? std::optional<bool>(true) : std::nullopt,
            .pointeeTypeId = index == 0 ? std::optional<std::string>("type.1") : std::nullopt,
            .fields = {},
            .confidence = confidences[index % confidences.size()],
            .provenance = "mapping-coverage",
            .returnTypeId = index == 0 ? std::optional<std::string>("type.1") : std::nullopt,
            .parameterTypeIds = {},
        });
    }

    const std::vector<std::string> varnodeRoles{
        "address", "constant", "internal", "join", "memory", "register", "stack", "unique",
    };
    for (std::size_t index = 0; index < varnodeRoles.size(); ++index) {
        result.varnodes.push_back({
            "varnode." + std::to_string(index), "space.0", index, 8,
            varnodeRoles[index],
            index == 0 ? std::optional<std::string>("type.0") : std::nullopt,
            index == 0 ? std::optional<std::string>("x0") : std::nullopt,
        });
    }

    // Second consumer of the shared manifest. This coverage fixture previously held
    // its own transcription of the vocabulary, so the allowlist above and this list
    // could disagree while every existing test stayed green.
    const std::vector<std::string> opcodes{
#define MACSCOPE_PCODE_OPCODE(enumerator, canonical, wire) wire,
#include "MacScopeNativeDecompiler/PcodeOpcodeVocabulary.def"
#undef MACSCOPE_PCODE_OPCODE
    };
    for (std::size_t index = 0; index < opcodes.size(); ++index) {
        result.operations.push_back({
            "operation." + std::to_string(index), "block.0", index, opcodes[index],
            index == 0 ? std::optional<std::string>("varnode.0") : std::nullopt, {},
            index == 0 ? std::optional<Address>(0x2000) : std::nullopt, {},
            std::nullopt, {},
        });
    }

    const std::vector<std::string> terminators{
        "branch", "conditional", "exit", "fallthrough", "return", "switch",
    };
    for (std::size_t index = 0; index < terminators.size(); ++index) {
        result.blocks.push_back({
            "block." + std::to_string(index), 0x1000 + index, 0x1001 + index,
            {}, {}, {}, terminators[index],
        });
    }

    const std::vector<std::string> edgeKinds{
        // The provider's own spellings: the switch edges are camelCase natively.
        "branch", "fallthrough", "false", "switchCase", "switchDefault", "true",
    };
    for (std::size_t index = 0; index < edgeKinds.size(); ++index) {
        result.edges.push_back({
            "edge." + std::to_string(index), "block.0",
            index == 0 ? std::optional<std::string>("block.1") : std::nullopt,
            0x1001 + index, edgeKinds[index],
            index == 0 ? std::optional<std::string>("operation.0") : std::nullopt,
        });
    }

    const std::vector<std::string> ssaKinds{
        "annotation", "constant", "functionEntry", "operationResult", "phiResult",
    };
    for (std::size_t index = 0; index < ssaKinds.size(); ++index) {
        result.ssaValues.push_back({
            "ssa." + std::to_string(index), "varnode.0", ssaKinds[index],
            index == 0 ? std::optional<std::string>("operation.0") : std::nullopt,
            index == 1 ? std::optional<std::string>("phi.0") : std::nullopt,
        });
    }
    result.ssaBindings = {
        {"operation.0", {}, "ssa.0"},
        {"operation.1", {}, std::nullopt},
    };
    result.phis = {{
        "phi.0", "block.0", "varnode.0", "ssa.0",
        {{"block.0", "edge.0", "ssa.0"}, {std::nullopt, std::nullopt, "ssa.1"}},
    }};

    const std::vector<std::string> memoryVersionKinds{
        "functionEntry", "operationResult", "phiResult",
    };
    for (std::size_t index = 0; index < memoryVersionKinds.size(); ++index) {
        result.memoryVersions.push_back({
            "memory." + std::to_string(index), "unknown", memoryVersionKinds[index],
            index == 0 ? std::optional<std::string>("operation.0") : std::nullopt,
            index == 1 ? std::optional<std::string>("memoryPhi.0") : std::nullopt,
        });
    }
    result.memoryPhis = {{
        "memoryPhi.0", "block.0", "unknown", "memory.0",
        {{"block.0", "edge.0", "memory.0"}, {std::nullopt, std::nullopt, "memory.1"}},
    }};

    const std::vector<std::string> memoryEffectKinds{"read", "write", "readWrite"};
    for (std::size_t index = 0; index < memoryEffectKinds.size(); ++index) {
        result.memoryEffects.push_back({
            "effect." + std::to_string(index), "operation.0", memoryEffectKinds[index], "unknown",
            index == 0 ? std::optional<std::string>("memory.0") : std::nullopt,
            index == 0 ? std::optional<std::string>("memory.1") : std::nullopt,
        });
    }

    const std::vector<std::string> variableRoles{
        "global", "local", "parameter", "result", "temporary",
    };
    for (std::size_t index = 0; index < variableRoles.size(); ++index) {
        result.variables.push_back({
            "variable." + std::to_string(index), "variable" + std::to_string(index),
            variableRoles[index],
            index == 0 ? std::optional<std::string>("type.0") : std::nullopt,
            {}, {}, confidences[index], "mapping-coverage",
        });
    }

    result.calls = {
        {"call.0", "operation.0", "direct", 0x2000, "callee", "type.0", {}, "variable.0", {}},
        {"call.1", "operation.1", "indirect", std::nullopt, std::nullopt, std::nullopt,
         {}, std::nullopt, {}},
    };

    const std::vector<std::string> regionKinds{
        "condition", "doWhile", "goto", "if", "infiniteLoop", "multiGoto",
        "root", "sequence", "switch", "while",
    };
    for (std::size_t index = 0; index < regionKinds.size(); ++index) {
        result.regions.push_back({
            "region." + std::to_string(index), regionKinds[index],
            index == 0 ? std::optional<std::string>("region.1") : std::nullopt,
            {}, {}, index == 0 ? std::optional<std::string>("operation.0") : std::nullopt, {},
        });
    }

    const std::vector<std::string> tokenKinds{
        "comment", "identifier", "keyword", "literal", "operation", "punctuation",
        "type", "whitespace",
    };
    const std::vector<std::string> tokenEntityKinds{
        "block", "call", "instruction", "operation", "region", "type", "variable", "varnode",
    };
    for (std::size_t index = 0; index < tokenKinds.size(); ++index) {
        result.tokens.push_back({
            "token." + std::to_string(index), "token", tokenKinds[index],
            static_cast<std::uint32_t>(index + 1), 1, {},
            {{tokenEntityKinds[index], "entity." + std::to_string(index)}},
        });
    }
    result.pseudocodeDocument = PseudocodeDocumentRecord{
        "uint64_t fixture(uint64_t argument) {\n\treturn argument;\n}\n", "c", true, false,
    };

    const std::vector<std::string> severities{"error", "information", "warning"};
    for (std::size_t index = 0; index < severities.size(); ++index) {
        result.warnings.push_back({
            "diagnostic." + std::to_string(index), severities[index], "mapping coverage", {},
        });
    }
    return result;
}

} // namespace

WireError::WireError(WireFailureCode code, std::string message)
    : std::runtime_error(std::move(message)), code_(code) {}

WireFailureCode WireError::code() const noexcept { return code_; }

void validateBinaryPropertyListKeysForTesting(NSData *payload) {
    BinaryPlistKeyScanner(payload).validate();
}

DecodedRequest decodeRequest(NSData *payload, NSUUID *expectedRequestID) {
    if (payload.length > kMaximumRequestBytes) {
        fail(WireFailureCode::requestTooLarge, "request exceeds transport ceiling");
    }
    BinaryPlistKeyScanner(payload).validate();
    NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
    NSError *error = nil;
    id object = [NSPropertyListSerialization propertyListWithData:payload
                                                          options:NSPropertyListImmutable
                                                           format:&format
                                                            error:&error];
    if (object == nil || error != nil || format != NSPropertyListBinaryFormat_v1_0) {
        fail(WireFailureCode::malformedRequest, "request is not a binary property list");
    }
    NSDictionary *envelope = requireDictionary(object);
    requireExactKeys(envelope, @[@"schemaVersion", @"requestID", @"operation", @"body"]);
    const std::uint32_t schemaVersion = requireUInt32(envelope[@"schemaVersion"]);
    if (schemaVersion != 3U && schemaVersion != 4U) {
        fail(WireFailureCode::unsupportedSchemaVersion, "wire schema is unsupported");
    }
    NSUUID *envelopeID = requireCanonicalUUID(envelope[@"requestID"]);
    if (![envelopeID isEqual:expectedRequestID]) {
        fail(WireFailureCode::requestIDMismatch, "request ID does not match transport");
    }
    NSString *operation = requireString(envelope[@"operation"], 32);
    const bool documentOnly = [operation isEqualToString:@"decompile-document"];
    if (!documentOnly && ![operation isEqualToString:@"decompile"]) {
        fail(WireFailureCode::invalidRequest, "operation is unsupported");
    }

    NSDictionary *body = requireDictionary(envelope[@"body"]);
    requireExactKeys(body, @[
        @"requestID", @"requestSHA256", @"target", @"image", @"function",
        @"memoryRegions", @"symbols", @"authoredInputs", @"budgets",
    ]);
    NSUUID *bodyID = requireCanonicalUUID(body[@"requestID"]);
    if (![bodyID isEqual:expectedRequestID]) {
        fail(WireFailureCode::requestIDMismatch, "body request ID does not match transport");
    }
    NSString *sha = requireString(body[@"requestSHA256"], 64);
    if (!isLowerHex(sha, 64)) fail(WireFailureCode::invalidRequest, "request digest is not canonical");
    NSDictionary *targetObject = requireDictionary(body[@"target"]);
    requireExactKeys(targetObject, @[
        @"rawCPUType", @"rawCPUSubtype", @"normalizedVariant",
        @"recognizedCapabilityBits", @"selectedSliceSHA256", @"selectedSliceByteCount",
        @"profileID", @"languageID", @"compilerSpecID", @"contextProfileSHA256",
        @"context",
    ], @[@"pointerAuthABIVersion"]);
    const auto rawCPUType = requireHexUInt32(targetObject[@"rawCPUType"]);
    const auto rawCPUSubtype = requireHexUInt32(targetObject[@"rawCPUSubtype"]);
    NSString *selectedSliceSHA256 = requireString(targetObject[@"selectedSliceSHA256"], 64);
    if (!isLowerHex(selectedSliceSHA256, 64)) {
        fail(WireFailureCode::invalidRequest, "selected-slice digest is not canonical");
    }
    const auto selectedSliceByteCount = requireHexUInt64(targetObject[@"selectedSliceByteCount"]);
    TargetProfile target;
    try {
        target = normalizeAppleMachOTarget(
            rawCPUType,
            rawCPUSubtype,
            nativeString(selectedSliceSHA256),
            selectedSliceByteCount
        );
    } catch (const ContractError&) {
        fail(WireFailureCode::invalidRequest, "target profile is unsupported");
    }
    std::string_view variantName;
    switch (target.normalizedVariant) {
    case ArchitectureVariant::arm64: variantName = "arm64"; break;
    case ArchitectureVariant::arm64e: variantName = "arm64e"; break;
    case ArchitectureVariant::x86_64: variantName = "x86_64"; break;
    default: fail(WireFailureCode::invalidRequest, "unknown normalized architecture variant");
    }
    if (nativeString(requireString(targetObject[@"normalizedVariant"], 32)) != variantName ||
        nativeString(requireString(targetObject[@"recognizedCapabilityBits"], 8)) !=
            target.recognizedCapabilityBits ||
        nativeString(requireString(targetObject[@"profileID"], 256)) != target.profileId ||
        nativeString(requireString(targetObject[@"languageID"], 256)) != target.languageId ||
        nativeString(requireString(targetObject[@"compilerSpecID"], 256)) != target.compilerSpecId ||
        nativeString(requireString(targetObject[@"contextProfileSHA256"], 64)) !=
            target.contextProfileSha256) {
        fail(WireFailureCode::invalidRequest, "target profile does not match sealed authority");
    }
    id pointerAuthABI = targetObject[@"pointerAuthABIVersion"];
    if ((pointerAuthABI == nil) != !target.pointerAuthAbiVersion.has_value() ||
        (pointerAuthABI != nil && requireUInt32(pointerAuthABI) != *target.pointerAuthAbiVersion)) {
        fail(WireFailureCode::invalidRequest, "pointer-auth ABI does not match sealed authority");
    }
    NSArray *contextObjects = requireArray(targetObject[@"context"], 4U);
    if (contextObjects.count != target.context.size()) {
        fail(WireFailureCode::invalidRequest, "target context is incomplete");
    }
    for (NSUInteger index = 0; index < contextObjects.count; ++index) {
        NSDictionary *context = requireDictionary(contextObjects[index]);
        requireExactKeys(context, @[@"name", @"value"]);
        if (nativeString(requireString(context[@"name"], 64)) != target.context[index].name ||
            requireUInt32(context[@"value"]) != target.context[index].value) {
            fail(WireFailureCode::invalidRequest, "target context does not match sealed authority");
        }
    }

    ImageIdentity image = decodeImage(requireDictionary(body[@"image"]));
    FunctionIdentity function = decodeFunction(requireDictionary(body[@"function"]), schemaVersion);

    NSArray *regionObjects = requireArray(body[@"memoryRegions"], kMaximumRegions);
    if (regionObjects.count == 0) fail(WireFailureCode::invalidRequest, "memory map is empty");
    NSUInteger totalRegionBytes = 0;
    NSUInteger totalPatchIDs = 0;
    for (id object in regionObjects) {
        NSDictionary *dictionary = requireDictionary(object);
        requireExactKeys(dictionary, @[
            @"name", @"startAddress", @"permissions", @"rawBytes", @"effectiveBytes",
            @"appliedPatchIDs",
        ]);
        NSString *permissions = requireString(dictionary[@"permissions"], 3);
        requireTag(permissions, {@"---", @"r--", @"-w-", @"--x", @"rw-", @"r-x", @"-wx", @"rwx"});
        NSData *raw = requireData(dictionary[@"rawBytes"], kMaximumRequestBytes);
        NSData *effective = requireData(dictionary[@"effectiveBytes"], kMaximumRequestBytes);
        if (raw.length != effective.length) {
            fail(WireFailureCode::invalidRequest, "raw and effective bytes have different lengths");
        }
        NSArray<NSString *> *patches = stringArray(dictionary[@"appliedPatchIDs"], 100'000U, 11);
        if (raw.length > kMaximumTotalRegionBytes - totalRegionBytes ||
            patches.count > kMaximumAppliedPatchIDs - totalPatchIDs) {
            fail(WireFailureCode::invalidRequest, "expanded memory map exceeds native bounds");
        }
        totalRegionBytes += raw.length;
        totalPatchIDs += patches.count;
    }

    // Validate the complete logical expansion before copying any shared plist
    // data into request-owned C++ vectors. Binary plists may reference the same
    // NSData/NSArray object many times, so payload length alone is not a bound
    // on the decoded request's allocation cost.
    std::vector<MemoryRegion> regions;
    regions.reserve(regionObjects.count);
    for (id object in regionObjects) {
        NSDictionary *dictionary = requireDictionary(object);
        NSString *permissions = requireString(dictionary[@"permissions"], 3);
        NSData *raw = requireData(dictionary[@"rawBytes"], kMaximumRequestBytes);
        NSData *effective = requireData(dictionary[@"effectiveBytes"], kMaximumRequestBytes);
        NSArray<NSString *> *patches = stringArray(dictionary[@"appliedPatchIDs"], 100'000U, 11);
        regions.push_back({
            nativeString(requireString(dictionary[@"name"], 256)),
            requireHexUInt64(dictionary[@"startAddress"]),
            nativeString(permissions),
            bytesFromData(raw),
            bytesFromData(effective),
            nativeStrings(patches),
        });
    }

    NSArray *symbolObjects = requireArray(body[@"symbols"], kMaximumSymbols);
    std::vector<SymbolRecord> symbols;
    symbols.reserve(symbolObjects.count);
    for (id object in symbolObjects) {
        NSDictionary *dictionary = requireDictionary(object);
        requireExactKeys(dictionary, @[@"imageID", @"address", @"name", @"kind"]);
        NSString *kind = requireString(dictionary[@"kind"], 256);
        requireTag(kind, {@"alias", @"data", @"function", @"label", @"object", @"section", @"unknown"});
        symbols.push_back({
            nativeString(requireString(dictionary[@"imageID"], 256)),
            requireHexUInt64(dictionary[@"address"]),
            nativeString(requireString(dictionary[@"name"], 1'024)),
            nativeString(kind),
        });
    }

    AuthoredInputs authoredInputs = decodeAuthoredInputs(
        requireDictionary(body[@"authoredInputs"])
    );

    NSDictionary *budgetObject = requireDictionary(body[@"budgets"]);
    requireExactKeys(budgetObject, @[
        @"profileID",
        @"maxCodeBytes", @"maxInstructions", @"maxOperations", @"maxOutputBytes",
        @"maxWallTimeMilliseconds",
    ]);
    // v2 (8 MiB) and v3 (32 MiB, the product default) differ from the frozen v1
    // only in their output ceilings; each identity must carry its own exact limits.
    NSString *profileID = requireString(budgetObject[@"profileID"], 256);
    const bool isV2 = [profileID isEqualToString:@"native-product-budget-v2"];
    const bool isV3 = [profileID isEqualToString:@"native-product-budget-v3"];
    if ((!isV2 && !isV3 && ![profileID isEqualToString:@"native-product-budget-v1"]) ||
        requireUInt32(budgetObject[@"maxCodeBytes"]) != 1'048'576U ||
        requireUInt32(budgetObject[@"maxInstructions"]) != 65'536U ||
        requireUInt32(budgetObject[@"maxOperations"]) != 262'144U ||
        requireUInt32(budgetObject[@"maxOutputBytes"]) != (isV3 ? 33'554'432U : isV2 ? 8'388'608U : 1'048'576U) ||
        requireHexUInt64(budgetObject[@"maxWallTimeMilliseconds"]) != 5'000U) {
        fail(WireFailureCode::invalidRequest, "budget profile does not match sealed authority");
    }
    const ProfiledAnalysisBudgets profiledBudgets =
        isV3 ? productAnalysisBudgetsV3() : isV2 ? productAnalysisBudgetsV2() : productAnalysisBudgetsV1();
    AnalysisBudgets budgets = profiledBudgets.analysisLimits();
    if (budgets.maxOutputBytes > kMaximumResponseBytes) {
        fail(WireFailureCode::invalidRequest, "output budget exceeds transport ceiling");
    }

    try {
        ByteProvider bytes(std::move(regions));
        SymbolProvider symbolProvider(std::move(symbols));
        const std::string claimedSHA256 = nativeString(sha);
        const std::string canonicalSHA256 = canonicalRequestSha256V2({
            target, image, function, bytes, symbolProvider, authoredInputs, profiledBudgets,
            schemaVersion, documentOnly ? "decompile-document" : "decompile",
        });
        if (canonicalSHA256 != claimedSHA256) {
            fail(WireFailureCode::invalidRequest, "request digest does not bind canonical request");
        }
        DecodedRequest decoded{AnalysisRequestView(
            nativeString(bodyID.UUIDString), claimedSHA256, target.languageId,
            target.compilerSpecId, std::move(image), std::move(function),
            std::move(bytes), std::move(symbolProvider), TypeHintProvider({}),
            std::move(authoredInputs), budgets, schemaVersion
        )};
        decoded.request.documentOnly = documentOnly;
        return decoded;
    } catch (const ContractError&) {
        fail(WireFailureCode::invalidRequest, "request violates native contract");
    }
}

NSData *encodeSuccessReply(
    NSUUID *requestID,
    const AnalysisRequestView& request,
    const BackendAvailability& availability,
    const StructuredResult& result
) {
    if (!availability.available || request.requestId != nativeString(requestID.UUIDString)) {
        fail(WireFailureCode::nativeFailure, "validated result identity mismatch");
    }
    try {
        validateBackendAvailability(availability);
        if (!availability.runtimeIdentity ||
            availability.runtimeIdentity->languageId != request.languageId ||
            availability.runtimeIdentity->compilerSpecId != request.compilerSpecId) {
            fail(WireFailureCode::nativeFailure, "runtime profile differs from request authority");
        }
        validateStructuredResult(request, result);
        const std::size_t outputBound = structuredResultEncodedSizeUpperBound(result);
        if (outputBound > request.budgets.maxOutputBytes ||
            outputBound > kMaximumResponseBytes) {
            fail(WireFailureCode::responseTooLarge, "structured result exceeds output budget");
        }
    } catch (const WireError&) {
        throw;
    } catch (const ContractError&) {
        fail(WireFailureCode::nativeFailure, "native result violates publication contract");
    }
    NSData* encoded = serializeReply(@{
        @"schemaVersion": @(requiredWireReplySchemaVersion(result)),
        @"requestID": requestID.UUIDString,
        @"outcome": @"success",
        @"success": @{
            @"availability": encodeAvailability(availability),
            @"result": encodeResult(result),
        },
    });
    if (encoded.length > request.budgets.maxOutputBytes) {
        fail(WireFailureCode::responseTooLarge, "actual encoded reply exceeds output budget");
    }
    return encoded;
}

NSData *encodeFailureReply(NSUUID *requestID, WireFailureCode code, std::string detail) {
    NSMutableDictionary *failure = [@{@"code": failureTag(code)} mutableCopy];
    NSString *sanitized = sanitizeDetail(detail);
    if (sanitized.length > 0) failure[@"detail"] = sanitized;
    return serializeReply(@{
        @"schemaVersion": @3,
        @"requestID": requestID.UUIDString,
        @"outcome": @"failure",
        @"failure": failure,
    });
}

NSData *encodeMappingCoverageFixtureForTesting() {
    NSDictionary *result = encodeResult(mappingCoverageResult());
    NSArray<NSDictionary *> *phiIncoming = nestedRecords(result[@"phis"], @"incoming");
    NSArray<NSDictionary *> *memoryPhiIncoming = nestedRecords(result[@"memoryPhis"], @"incoming");
    NSArray<NSDictionary *> *tokenReferences = nestedRecords(result[@"tokens"], @"entityReferences");

    NSArray<NSString *> *failureCodes = @[
        failureTag(WireFailureCode::malformedRequest),
        failureTag(WireFailureCode::invalidRequest),
        failureTag(WireFailureCode::nativeFailure),
        failureTag(WireFailureCode::packageVerificationFailed),
        failureTag(WireFailureCode::busy),
        failureTag(WireFailureCode::cancelled),
        failureTag(WireFailureCode::timedOut),
        failureTag(WireFailureCode::unavailable),
        failureTag(WireFailureCode::unsupportedSchemaVersion),
        failureTag(WireFailureCode::requestIDMismatch),
        failureTag(WireFailureCode::unsupportedCompiler),
        failureTag(WireFailureCode::requestTooLarge),
        failureTag(WireFailureCode::responseTooLarge),
    ];

    NSDictionary *enums = @{
        @"addressSpaceKinds": uniqueValues(result[@"addressSpaces"], @"kind"),
        @"typeKinds": uniqueValues(result[@"types"], @"kind"),
        @"varnodeRoles": uniqueValues(result[@"varnodes"], @"role"),
        @"opcodes": uniqueValues(result[@"operations"], @"opcode"),
        @"blockTerminatorKinds": uniqueValues(result[@"blocks"], @"terminatorKind"),
        @"edgeKinds": uniqueValues(result[@"edges"], @"kind"),
        @"ssaValueKinds": uniqueValues(result[@"ssaValues"], @"kind"),
        @"memoryVersionKinds": uniqueValues(result[@"memoryVersions"], @"kind"),
        @"memoryEffectKinds": uniqueValues(result[@"memoryEffects"], @"kind"),
        @"variableRoles": uniqueValues(result[@"variables"], @"role"),
        @"callKinds": uniqueValues(result[@"calls"], @"kind"),
        @"regionKinds": uniqueValues(result[@"regions"], @"kind"),
        @"tokenKinds": uniqueValues(result[@"tokens"], @"kind"),
        @"diagnosticSeverities": uniqueValues(result[@"warnings"], @"severity"),
        @"confidences": uniqueValues(result[@"types"], @"confidence"),
        @"failureCodes": failureCodes,
    };
    NSDictionary *optionals = @{
        @"types.byteSize": optionalCoverage(result[@"types"], @"byteSize"),
        @"types.isSigned": optionalCoverage(result[@"types"], @"isSigned"),
        @"types.pointeeTypeID": optionalCoverage(result[@"types"], @"pointeeTypeID"),
        @"types.returnTypeID": optionalCoverage(result[@"types"], @"returnTypeID"),
        @"varnodes.typeID": optionalCoverage(result[@"varnodes"], @"typeID"),
        @"varnodes.registerName": optionalCoverage(result[@"varnodes"], @"registerName"),
        @"operations.outputVarnodeID": optionalCoverage(result[@"operations"], @"outputVarnodeID"),
        @"operations.directTargetAddress": optionalCoverage(result[@"operations"], @"directTargetAddress"),
        @"edges.targetBlockID": optionalCoverage(result[@"edges"], @"targetBlockID"),
        @"edges.operationID": optionalCoverage(result[@"edges"], @"operationID"),
        @"ssaValues.definingOperationID": optionalCoverage(result[@"ssaValues"], @"definingOperationID"),
        @"ssaValues.definingPhiID": optionalCoverage(result[@"ssaValues"], @"definingPhiID"),
        @"ssaBindings.outputSSAValueID": optionalCoverage(result[@"ssaBindings"], @"outputSSAValueID"),
        @"phis.incoming.sourceBlockID": optionalCoverage(phiIncoming, @"sourceBlockID"),
        @"phis.incoming.edgeID": optionalCoverage(phiIncoming, @"edgeID"),
        @"memoryVersions.definingOperationID": optionalCoverage(result[@"memoryVersions"], @"definingOperationID"),
        @"memoryVersions.definingMemoryPhiID": optionalCoverage(result[@"memoryVersions"], @"definingMemoryPhiID"),
        @"memoryPhis.incoming.sourceBlockID": optionalCoverage(memoryPhiIncoming, @"sourceBlockID"),
        @"memoryPhis.incoming.edgeID": optionalCoverage(memoryPhiIncoming, @"edgeID"),
        @"memoryEffects.inputMemoryVersionID": optionalCoverage(result[@"memoryEffects"], @"inputMemoryVersionID"),
        @"memoryEffects.outputMemoryVersionID": optionalCoverage(result[@"memoryEffects"], @"outputMemoryVersionID"),
        @"variables.typeID": optionalCoverage(result[@"variables"], @"typeID"),
        @"calls.targetAddress": optionalCoverage(result[@"calls"], @"targetAddress"),
        @"calls.targetSymbol": optionalCoverage(result[@"calls"], @"targetSymbol"),
        @"calls.prototypeTypeID": optionalCoverage(result[@"calls"], @"prototypeTypeID"),
        @"calls.resultVariableID": optionalCoverage(result[@"calls"], @"resultVariableID"),
        @"regions.parentRegionID": optionalCoverage(result[@"regions"], @"parentRegionID"),
        @"regions.conditionOperationID": optionalCoverage(result[@"regions"], @"conditionOperationID"),
    };
    return serializeReply(@{
        @"enums": enums,
        @"optionals": optionals,
        @"tokenEntityKinds": uniqueValues(tokenReferences, @"kind"),
    });
}

} // namespace macscope::native_decompiler::xpc_bridge

namespace {
struct CancellationState final { std::atomic_bool flag{false}; };
}

@interface MSNativeDecompilerCancellationHandle (BridgeInternal)
- (void *)nativeStateForBridge;
@end

@implementation MSNativeDecompilerCancellationHandle

- (instancetype)init {
    self = [super init];
    if (self != nil) _nativeState = new CancellationState();
    return self;
}

- (void)dealloc {
    delete static_cast<CancellationState *>(_nativeState);
}

- (void)cancel {
    static_cast<CancellationState *>(_nativeState)->flag.store(true, std::memory_order_relaxed);
}

- (void *)nativeStateForBridge {
    return _nativeState;
}

@end

namespace macscope::native_decompiler::xpc_bridge {

bool cancellationWasRequested(MSNativeDecompilerCancellationHandle *handle) noexcept {
    auto *state = static_cast<CancellationState *>([handle nativeStateForBridge]);
    return state != nullptr && state->flag.load(std::memory_order_relaxed);
}

CancellationToken cancellationToken(MSNativeDecompilerCancellationHandle *handle) noexcept {
    auto *state = static_cast<CancellationState *>([handle nativeStateForBridge]);
    return CancellationToken(state == nullptr ? nullptr : &state->flag);
}

} // namespace macscope::native_decompiler::xpc_bridge
