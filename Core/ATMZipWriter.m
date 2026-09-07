#import "ATMZipWriter.h"
#import <zlib.h>

static NSString *const ATMZipErrorDomain = @"com.aaz.tweakmanager.zip";

static void ATMAppendUInt16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[] = {(uint8_t)(value & 0xff), (uint8_t)((value >> 8) & 0xff)};
    [data appendBytes:bytes length:sizeof(bytes)];
}
static void ATMAppendUInt32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[] = {(uint8_t)(value & 0xff), (uint8_t)((value >> 8) & 0xff), (uint8_t)((value >> 16) & 0xff), (uint8_t)((value >> 24) & 0xff)};
    [data appendBytes:bytes length:sizeof(bytes)];
}
static uint16_t ATMReadUInt16(const uint8_t *bytes) { return (uint16_t)(bytes[0] | (bytes[1] << 8)); }
static uint32_t ATMReadUInt32(const uint8_t *bytes) { return (uint32_t)(bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)); }

@interface ATMZipEntry : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic, assign) uint32_t crc;
@property(nonatomic, assign) uint32_t size;
@property(nonatomic, assign) uint32_t offset;
@end
@implementation ATMZipEntry @end

@interface ATMZipWriter ()
@property(nonatomic, strong) NSFileHandle *handle;
@property(nonatomic, strong) NSMutableArray<ATMZipEntry *> *entries;
@property(nonatomic, assign) BOOL closed;
@end

@implementation ATMZipWriter
- (instancetype)initWithDestinationURL:(NSURL *)destinationURL error:(NSError **)error {
    if ((self = [super init])) {
        [NSFileManager.defaultManager removeItemAtURL:destinationURL error:nil];
        if (![NSFileManager.defaultManager createFileAtPath:destinationURL.path contents:nil attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}]) {
            if (error) *error = [NSError errorWithDomain:ATMZipErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"Unable to create backup archive."}];
            return nil;
        }
        _handle = [NSFileHandle fileHandleForWritingToURL:destinationURL error:error];
        _entries = [NSMutableArray array];
        if (!_handle) return nil;
    }
    return self;
}
- (BOOL)addData:(NSData *)data path:(NSString *)path error:(NSError **)error {
    if (self.closed || !data || !path.length || [path hasPrefix:@"/"] || [path containsString:@".."] || data.length > UINT32_MAX) {
        if (error) *error = [NSError errorWithDomain:ATMZipErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid backup entry."}];
        return NO;
    }
    NSData *nameData = [path dataUsingEncoding:NSUTF8StringEncoding];
    if (!nameData.length || nameData.length > UINT16_MAX) return NO;
    uint64_t offset64 = self.handle.offsetInFile;
    if (offset64 > UINT32_MAX) return NO;
    uLong crcValue = crc32(0L, Z_NULL, 0);
    crcValue = crc32(crcValue, data.bytes, (uInt)data.length);
    NSMutableData *header = [NSMutableData data];
    ATMAppendUInt32(header, 0x04034b50);
    ATMAppendUInt16(header, 20); ATMAppendUInt16(header, 0); ATMAppendUInt16(header, 0);
    ATMAppendUInt16(header, 0); ATMAppendUInt16(header, 0);
    ATMAppendUInt32(header, (uint32_t)crcValue);
    ATMAppendUInt32(header, (uint32_t)data.length); ATMAppendUInt32(header, (uint32_t)data.length);
    ATMAppendUInt16(header, (uint16_t)nameData.length); ATMAppendUInt16(header, 0);
    @try { [self.handle writeData:header]; [self.handle writeData:nameData]; [self.handle writeData:data]; }
    @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:ATMZipErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey: @"Unable to write backup entry."}];
        return NO;
    }
    ATMZipEntry *entry = [ATMZipEntry new];
    entry.path = path; entry.crc = (uint32_t)crcValue; entry.size = (uint32_t)data.length; entry.offset = (uint32_t)offset64;
    [self.entries addObject:entry];
    return YES;
}
- (BOOL)addFileURL:(NSURL *)fileURL path:(NSString *)path error:(NSError **)error {
    NSNumber *sizeNumber = nil;
    if (![fileURL getResourceValue:&sizeNumber forKey:NSURLFileSizeKey error:error] || sizeNumber.unsignedLongLongValue > UINT32_MAX || self.closed || !path.length || [path hasPrefix:@"/"] || [path containsString:@".."]) return NO;
    uint32_t size = sizeNumber.unsignedIntValue;
    NSData *nameData = [path dataUsingEncoding:NSUTF8StringEncoding];
    if (!nameData.length || nameData.length > UINT16_MAX || self.handle.offsetInFile > UINT32_MAX) return NO;
    uLong crcValue = crc32(0L, Z_NULL, 0);
    NSInputStream *checksumStream = [NSInputStream inputStreamWithURL:fileURL]; [checksumStream open];
    uint8_t buffer[64 * 1024]; NSInteger count = 0; uint64_t measured = 0;
    while ((count = [checksumStream read:buffer maxLength:sizeof(buffer)]) > 0) { crcValue = crc32(crcValue, buffer, (uInt)count); measured += (uint64_t)count; }
    NSError *streamError = checksumStream.streamError; [checksumStream close];
    if (count < 0 || streamError || measured != size) { if (error) *error = streamError ?: [NSError errorWithDomain:ATMZipErrorDomain code:7 userInfo:@{NSLocalizedDescriptionKey: @"Unable to verify package file."}]; return NO; }
    uint32_t offset = (uint32_t)self.handle.offsetInFile;
    NSMutableData *header = [NSMutableData data];
    ATMAppendUInt32(header, 0x04034b50); ATMAppendUInt16(header, 20); ATMAppendUInt16(header, 0); ATMAppendUInt16(header, 0);
    ATMAppendUInt16(header, 0); ATMAppendUInt16(header, 0); ATMAppendUInt32(header, (uint32_t)crcValue);
    ATMAppendUInt32(header, size); ATMAppendUInt32(header, size); ATMAppendUInt16(header, (uint16_t)nameData.length); ATMAppendUInt16(header, 0);
    @try { [self.handle writeData:header]; [self.handle writeData:nameData]; }
    @catch (__unused NSException *exception) { if (error) *error = [NSError errorWithDomain:ATMZipErrorDomain code:8 userInfo:@{NSLocalizedDescriptionKey: @"Unable to write package header."}]; return NO; }
    NSInputStream *copyStream = [NSInputStream inputStreamWithURL:fileURL]; [copyStream open]; measured = 0;
    while ((count = [copyStream read:buffer maxLength:sizeof(buffer)]) > 0) { @try { [self.handle writeData:[NSData dataWithBytesNoCopy:buffer length:(NSUInteger)count freeWhenDone:NO]]; } @catch (__unused NSException *exception) { count = -1; break; } measured += (uint64_t)count; }
    streamError = copyStream.streamError; [copyStream close];
    if (count < 0 || streamError || measured != size) { if (error) *error = streamError ?: [NSError errorWithDomain:ATMZipErrorDomain code:9 userInfo:@{NSLocalizedDescriptionKey: @"Unable to copy package file."}]; return NO; }
    ATMZipEntry *entry = [ATMZipEntry new]; entry.path = path; entry.crc = (uint32_t)crcValue; entry.size = size; entry.offset = offset; [self.entries addObject:entry];
    return YES;
}
- (BOOL)close:(NSError **)error {
    if (self.closed) return YES;
    uint64_t centralOffset64 = self.handle.offsetInFile;
    if (centralOffset64 > UINT32_MAX || self.entries.count > UINT16_MAX) return NO;
    @try {
        for (ATMZipEntry *entry in self.entries) {
            NSData *nameData = [entry.path dataUsingEncoding:NSUTF8StringEncoding];
            NSMutableData *header = [NSMutableData data];
            ATMAppendUInt32(header, 0x02014b50);
            ATMAppendUInt16(header, 20); ATMAppendUInt16(header, 20); ATMAppendUInt16(header, 0); ATMAppendUInt16(header, 0);
            ATMAppendUInt16(header, 0); ATMAppendUInt16(header, 0);
            ATMAppendUInt32(header, entry.crc); ATMAppendUInt32(header, entry.size); ATMAppendUInt32(header, entry.size);
            ATMAppendUInt16(header, (uint16_t)nameData.length); ATMAppendUInt16(header, 0); ATMAppendUInt16(header, 0);
            ATMAppendUInt16(header, 0); ATMAppendUInt16(header, 0); ATMAppendUInt32(header, 0); ATMAppendUInt32(header, entry.offset);
            [self.handle writeData:header]; [self.handle writeData:nameData];
        }
        uint64_t end64 = self.handle.offsetInFile;
        uint32_t centralSize = (uint32_t)(end64 - centralOffset64);
        NSMutableData *footer = [NSMutableData data];
        ATMAppendUInt32(footer, 0x06054b50); ATMAppendUInt16(footer, 0); ATMAppendUInt16(footer, 0);
        ATMAppendUInt16(footer, (uint16_t)self.entries.count); ATMAppendUInt16(footer, (uint16_t)self.entries.count);
        ATMAppendUInt32(footer, centralSize); ATMAppendUInt32(footer, (uint32_t)centralOffset64); ATMAppendUInt16(footer, 0);
        [self.handle writeData:footer]; [self.handle synchronizeFile]; [self.handle closeFile]; self.closed = YES;
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:ATMZipErrorDomain code:4 userInfo:@{NSLocalizedDescriptionKey: @"Unable to finalize backup archive."}];
        return NO;
    }
}
- (void)dealloc { if (!self.closed) { @try { [self.handle closeFile]; } @catch (__unused NSException *exception) {} } }
@end

NSData *ATMReadStoredZipEntry(NSURL *archiveURL, NSString *entryPath, NSError **error) {
    NSData *archive = [NSData dataWithContentsOfURL:archiveURL options:NSDataReadingMappedIfSafe error:error];
    if (!archive.length) return nil;
    const uint8_t *bytes = archive.bytes;
    NSUInteger offset = 0;
    while (offset + 30 <= archive.length && ATMReadUInt32(bytes + offset) == 0x04034b50) {
        uint16_t method = ATMReadUInt16(bytes + offset + 8);
        uint32_t size = ATMReadUInt32(bytes + offset + 18);
        uint16_t nameLength = ATMReadUInt16(bytes + offset + 26);
        uint16_t extraLength = ATMReadUInt16(bytes + offset + 28);
        NSUInteger dataOffset = offset + 30 + nameLength + extraLength;
        if (dataOffset > archive.length || size > archive.length - dataOffset) break;
        NSData *nameData = [archive subdataWithRange:NSMakeRange(offset + 30, nameLength)];
        NSString *name = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
        if ([name isEqualToString:entryPath]) {
            if (method != 0) {
                if (error) *error = [NSError errorWithDomain:ATMZipErrorDomain code:5 userInfo:@{NSLocalizedDescriptionKey: @"Compressed backup entries are not supported."}];
                return nil;
            }
            return [archive subdataWithRange:NSMakeRange(dataOffset, size)];
        }
        offset = dataOffset + size;
    }
    if (error) *error = [NSError errorWithDomain:ATMZipErrorDomain code:6 userInfo:@{NSLocalizedDescriptionKey: @"Backup manifest is missing."}];
    return nil;
}

NSArray<NSDictionary *> *ATMValidateStoredZipArchive(NSURL *archiveURL, NSError **error) {
    NSData *archive = [NSData dataWithContentsOfURL:archiveURL options:NSDataReadingMappedIfSafe error:error];
    if (archive.length < 22) return nil;
    const uint8_t *bytes = archive.bytes;
    NSUInteger offset = 0;
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    while (offset + 30 <= archive.length && ATMReadUInt32(bytes + offset) == 0x04034b50) {
        uint16_t flags = ATMReadUInt16(bytes + offset + 6);
        uint16_t method = ATMReadUInt16(bytes + offset + 8);
        uint32_t expectedCRC = ATMReadUInt32(bytes + offset + 14);
        uint32_t compressedSize = ATMReadUInt32(bytes + offset + 18);
        uint32_t size = ATMReadUInt32(bytes + offset + 22);
        uint16_t nameLength = ATMReadUInt16(bytes + offset + 26);
        uint16_t extraLength = ATMReadUInt16(bytes + offset + 28);
        NSUInteger nameOffset = offset + 30;
        NSUInteger dataOffset = nameOffset + nameLength + extraLength;
        if ((flags & 0x08) || method != 0 || compressedSize != size || dataOffset > archive.length || size > archive.length - dataOffset) break;
        NSData *nameData = [archive subdataWithRange:NSMakeRange(nameOffset, nameLength)];
        NSString *name = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
        if (!name.length || [name hasPrefix:@"/"] || [name containsString:@".."] || [paths containsObject:name]) break;
        uLong actualCRC = crc32(0L, Z_NULL, 0);
        actualCRC = crc32(actualCRC, bytes + dataOffset, (uInt)size);
        if ((uint32_t)actualCRC != expectedCRC) break;
        [paths addObject:name];
        [entries addObject:@{ @"path": name, @"size": @(size), @"crc32": @(expectedCRC), @"offset": @(offset) }];
        offset = dataOffset + size;
    }
    if (!entries.count || offset + 46 > archive.length || ATMReadUInt32(bytes + offset) != 0x02014b50) {
        if (error) *error = [NSError errorWithDomain:ATMZipErrorDomain code:10 userInfo:@{NSLocalizedDescriptionKey: @"The backup archive is incomplete or corrupted."}];
        return nil;
    }
    NSUInteger searchStart = archive.length > (UINT16_MAX + 22) ? archive.length - (UINT16_MAX + 22) : 0;
    NSUInteger eocd = NSNotFound;
    for (NSUInteger cursor = archive.length - 22; ; cursor--) {
        if (ATMReadUInt32(bytes + cursor) == 0x06054b50) { eocd = cursor; break; }
        if (cursor == searchStart) break;
    }
    if (eocd == NSNotFound || eocd + 22 > archive.length || ATMReadUInt16(bytes + eocd + 8) != entries.count || ATMReadUInt16(bytes + eocd + 10) != entries.count || ATMReadUInt32(bytes + eocd + 16) != offset || ATMReadUInt32(bytes + eocd + 12) != eocd - offset || eocd + 22 + ATMReadUInt16(bytes + eocd + 20) != archive.length) {
        if (error) *error = [NSError errorWithDomain:ATMZipErrorDomain code:11 userInfo:@{NSLocalizedDescriptionKey: @"The backup archive footer is invalid."}];
        return nil;
    }
    NSUInteger central = offset;
    for (NSDictionary *entry in entries) {
        if (central + 46 > eocd || ATMReadUInt32(bytes + central) != 0x02014b50 || ATMReadUInt16(bytes + central + 10) != 0 || ATMReadUInt32(bytes + central + 16) != [entry[@"crc32"] unsignedIntValue] || ATMReadUInt32(bytes + central + 20) != [entry[@"size"] unsignedIntValue] || ATMReadUInt32(bytes + central + 24) != [entry[@"size"] unsignedIntValue] || ATMReadUInt32(bytes + central + 42) != [entry[@"offset"] unsignedIntValue]) {
            if (error) *error = [NSError errorWithDomain:ATMZipErrorDomain code:12 userInfo:@{NSLocalizedDescriptionKey: @"The backup archive index does not match its contents."}];
            return nil;
        }
        uint16_t nameLength = ATMReadUInt16(bytes + central + 28), extraLength = ATMReadUInt16(bytes + central + 30), commentLength = ATMReadUInt16(bytes + central + 32);
        NSUInteger next = central + 46 + nameLength + extraLength + commentLength;
        if (next > eocd) return nil;
        NSString *name = [[NSString alloc] initWithData:[archive subdataWithRange:NSMakeRange(central + 46, nameLength)] encoding:NSUTF8StringEncoding];
        if (![name isEqualToString:entry[@"path"]]) { if (error) *error = [NSError errorWithDomain:ATMZipErrorDomain code:12 userInfo:@{NSLocalizedDescriptionKey: @"The backup archive index does not match its contents."}]; return nil; }
        central = next;
    }
    if (central != eocd) { if (error) *error = [NSError errorWithDomain:ATMZipErrorDomain code:12 userInfo:@{NSLocalizedDescriptionKey: @"The backup archive index is incomplete."}]; return nil; }
    return entries;
}
