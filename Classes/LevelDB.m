//
//  LevelDB.m
//
//  Copyright 2011-2016 Pave Labs. All rights reserved.
//
//  Modified by: Amr Aboelela <amraboelela@gmail.com>
//  Date: Aug 2016
//
//  See LICENCE for details.
//

#import "LevelDB.h"
//#import "LDBSnapshot.h"
//#import "LDBWriteBatch.h"

#import <leveldb/leveldb.h>
/*#import <leveldb/options.h>
#import <leveldb/cache.h>
#import <leveldb/filter_policy.h>
#import <leveldb/write_batch.h>
*/

#include "Common.h"

/*#define MaybeAddSnapshotToOptions(_from_, _to_, _snap_) \
leveldb::ReadOptions __to_;\
leveldb::ReadOptions * _to_ = &__to_;\
if (_snap_ != nil) { \
_to_->fill_cache = _from_.fill_cache; \
_to_->snapshot = [_snap_ getSnapshot]; \
} else \
_to_ = &_from_;
*/

#define AssertDBExists(_db_) \
NSAssert(_db_ != NULL, @"Database reference is not existent (it has probably been closed)");

#pragma mark - Public functions

NSString *getLibraryPath() {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    return [paths objectAtIndex:0];
}

static void seekToFirstOrKey(void *iter, NSString *key) {
    (key != nil) ? levelDBIteratorSeek(iter, [key UTF8String], key.length) : levelDBSeekToFirst(iter);
}

NSString * const kLevelDBChangeType         = @"changeType";
NSString * const kLevelDBChangeTypePut      = @"put";
NSString * const kLevelDBChangeTypeDelete   = @"del";
NSString * const kLevelDBChangeValue        = @"value";
NSString * const kLevelDBChangeKey          = @"key";

LevelDBOptions MakeLevelDBOptions() {
    return (LevelDBOptions) {true, true, false, false, true, 0, 0};
}

@interface LevelDB()

@end

@implementation LevelDB

@synthesize name=_name;
@synthesize path=_path;
@synthesize encoder=_encoder;
@synthesize decoder=_decoder;

+ (LevelDBOptions) makeOptions {
    return MakeLevelDBOptions();
}
- (id) initWithPath:(NSString *)path andName:(NSString *)name {
    LevelDBOptions opts = MakeLevelDBOptions();
    return [self initWithPath:path name:name andOptions:opts];
}
- (id) initWithPath:(NSString *)path name:(NSString *)name andOptions:(LevelDBOptions)opts {
    self = [super init];
    if (self) {
        self.name = name;
        self.path = path;
        
        if (opts.createIntermediateDirectories) {
            NSString *dirpath = [path stringByDeletingLastPathComponent];
            NSFileManager *fm = [NSFileManager defaultManager];
            NSError *crError;
            BOOL success = [fm createDirectoryAtPath:dirpath
                         withIntermediateDirectories:true
                                          attributes:nil
                                               error:&crError];
            if (!success) {
                NSLog(@"Problem creating parent directory: %@", crError);
                return nil;
            }
        }
        _db = levelDBOpen([_path UTF8String]);
        
        self.encoder = ^ NSData *(NSString *key, id object) {
#ifdef DEBUG
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                NSLog(@"No encoder block was set for this database [%@]", name);
                NSLog(@"Using a convenience encoder/decoder pair using NSKeyedArchiver.");
            });
#endif
            return [NSKeyedArchiver archivedDataWithRootObject:object];
        };
        self.decoder = ^ id (NSString *key, NSData *data) {
            return [NSKeyedUnarchiver unarchiveObjectWithData:data];
        };
    }
    
    return self;
}

+ (id)databaseInLibraryWithName:(NSString *)name {
    LevelDBOptions opts = MakeLevelDBOptions();
    return [self databaseInLibraryWithName:name andOptions:opts];
}
+ (id)databaseInLibraryWithName:(NSString *)name
                      andOptions:(LevelDBOptions)opts {
    NSString *path = [getLibraryPath() stringByAppendingPathComponent:name];
    LevelDB *ldb = [[[self alloc] initWithPath:path name:name andOptions:opts] autorelease];
    return ldb;
}

#pragma mark - Accessors

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@:%p path: %@>", [self className], self, _path];
}

#pragma mark - Setters

- (void)setObject:(id)value forKey:(NSString *)key {
    AssertDBExists(_db);
    NSParameterAssert(value != nil);
    //LevelDBKey lkey = KeyFromString(key);
    NSData *data = _encoder(key, value);
    //[self setObject:value forKey:key];
    
    int status = levelDBPut(_db, [key UTF8String], [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding], [data bytes], [data length]);
    if (status) {
        NSLog(@"Problem storing key/value pair in database");
    }
}

- (void) setObject:(id)value forKeyedSubscript:(NSString *)key {
    [self setObject:value forKey:key];
}

- (void) addEntriesFromDictionary:(NSDictionary *)dictionary {
    [dictionary enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [self setObject:obj forKey:key];
    }];
}

#pragma mark - Getters

- (id)objectForKey:(NSString *)key {
    AssertDBExists(_db);
    void *outData;
    int outDataLength;
    int status = levelDBGet(_db, [key UTF8String], [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding], &outData, &outDataLength);
    if (status) {
        NSLog(@"Problem retrieving value for key '%@' from database", key);
        return nil;
    }
    NSData *data = [NSData dataWithBytes:outData length:outDataLength];
    return _decoder(key, data);
}

- (id)objectsForKeys:(NSArray *)keys notFoundMarker:(id)marker {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:keys.count];
    [keys enumerateObjectsUsingBlock:^(id objId, NSUInteger idx, BOOL *stop) {
        id object = [self objectForKey:objId];
        if (object == nil) object = marker;
        //result[idx] = object;
        [result insertObject:object atIndex:idx];
    }];
    return [NSArray arrayWithArray:result];
}

- (BOOL)objectExistsForKey:(NSString *)key {
    return [self objectExistsForKey:key];
}

#pragma mark - Removers

- (void)removeObjectForKey:(NSString *)key {
    AssertDBExists(_db);

    int status = levelDBDeleteItem(_db, [key UTF8String], [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    if (status) {
        NSLog(@"Problem removing object with key: %@ in database", key);
    }
}

- (void) removeObjectsForKeys:(NSArray *)keyArray {
    [keyArray enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        [self removeObjectForKey:obj];
    }];
}

- (void)removeAllObjects {
    [self removeAllObjectsWithPrefix:nil];
}

- (void)removeAllObjectsWithPrefix:(NSString *)prefix {
    AssertDBExists(_db);
    void *iter = levelDBNewIterator(_db);
    
    const void *prefixPtr = [prefix UTF8String];
    size_t prefixLen = prefix.length;
    
    for (seekToFirstOrKey(iter, prefix); levelDBIteratorIsValid(iter); levelDBMoveCursor(iter, false)) {
        char *iKey;
        int iKeyLength;
        levelDBIteratorGetKey(iter, &iKey, &iKeyLength);
        
        if (prefix && memcmp(iKey, prefixPtr, MIN(prefixLen, iKeyLength)) != 0) {
            break;
        }
        levelDBDeleteItem(_db, iKey, iKeyLength);
    }
    levelDBDeleteIterator(iter);
}

#pragma mark - Selection

- (NSArray *)allKeys {
    NSMutableArray *keys = [[[NSMutableArray alloc] init] autorelease];
    [self enumerateKeysUsingBlock:^(NSString *key, BOOL *stop) {
        [keys addObject:key];
    }];
    return [NSArray arrayWithArray:keys];
}

- (NSArray *)keysByFilteringWithPredicate:(NSPredicate *)predicate {
    NSMutableArray *keys = [[[NSMutableArray alloc] init] autorelease];
    [self enumerateKeysAndObjectsBackward:NO lazily:NO
                            startingAtKey:nil
                      filteredByPredicate:predicate
                                andPrefix:nil
                               usingBlock:^(NSString *key, id obj, BOOL *stop) {
                                   [keys addObject:key];
                               }];
    return [NSArray arrayWithArray:keys];
}

- (NSDictionary *)dictionaryByFilteringWithPredicate:(NSPredicate *)predicate {
    NSMutableDictionary *results = [NSMutableDictionary dictionary];
    [self enumerateKeysAndObjectsBackward:NO lazily:NO
                            startingAtKey:nil
                      filteredByPredicate:predicate
                                andPrefix:nil
                               usingBlock:^(NSString *key, id obj, BOOL *stop) {
                                   [results setObject:obj forKey:key];
                               }];
    
    return [NSDictionary dictionaryWithDictionary:results];
}

#pragma mark - Enumeration

- (void)_startIterator:(void *)iter
             backward:(BOOL)backward
               prefix:(NSString *)prefix
                start:(NSString *)key {

    const void *prefixPtr;
    size_t prefixLen;
    NSString *startingKey;
    
    if (prefix) {
        startingKey = prefix;
        
        if (key) {
            NSRange range = [key rangeOfString:prefix];
            if (range.length > 0 &&  range.location == 0) {
                startingKey = key;
            }
        }
        unsigned int len = startingKey.length;
 
        // If a prefix is provided and the iteration is backwards
        // we need to start on the next key (maybe discarding the first iteration)
        if (backward) {
            
            signed long long i = len - 1; //startingKey.size() - 1;

            char startingKeyPtr[len];
            [startingKey getCharacters:startingKeyPtr range:NSMakeRange(0, len)];
            unsigned char *keyChar;
            while (1) {
                if (i < 0) {
                    levelDBSeekToLast(iter);
                    break;
                }
                keyChar = (unsigned char *)startingKeyPtr + i;
                if (*keyChar < 255) {
                    *keyChar = *keyChar + 1;
                    levelDBIteratorSeek(iter, startingKeyPtr, len);
                    if (!levelDBIteratorIsValid(iter)) {
                        levelDBSeekToLast(iter);
                    }
                    break;
                }
                i--;
            };
            if (!levelDBIteratorIsValid(iter)) {
                return;
            }
            char *iKey;
            int iKeyLength;
            levelDBIteratorGetKey(iter, &iKey, &iKeyLength);
            if (len > 0 && prefix != nil) {
                signed int cmp = memcmp(iKey, startingKeyPtr, len);
                if (cmp > 0) {
                    levelDBIteratorPrevious(iter);
                }
            }
        } else {
            // Otherwise, we start at the provided prefix
            levelDBIteratorSeek(iter, [startingKey UTF8String], len);
        }
    } else if (key) {
        levelDBIteratorSeek(iter, [key UTF8String], key.length);
    } else if (backward) {
        levelDBSeekToLast(iter);
    } else {
        levelDBSeekToFirst(iter);
    }
}

- (void)enumerateKeysUsingBlock:(LevelDBKeyBlock)block {
    [self enumerateKeysBackward:false
                  startingAtKey:nil
            filteredByPredicate:nil
                      andPrefix:nil
                     usingBlock:block];
}

- (void)enumerateKeysBackward:(BOOL)backward
                startingAtKey:(NSString *)key
          filteredByPredicate:(NSPredicate *)predicate
                    andPrefix:(NSString *)prefix
                   usingBlock:(LevelDBKeyBlock)block {
    AssertDBExists(_db);
    void *iter = levelDBNewIterator(_db);
    BOOL stop = false;
    LevelDBKeyValueBlock iterate = (predicate != nil)
    ? ^(NSString *key, id value, BOOL *stop) {
        if ([predicate evaluateWithObject:value]) {
            block(key, stop);
        }
    }
    : ^(NSString *key, id value, BOOL *stop) {
        block(key, stop);
    };
    
    for ([self _startIterator:iter backward:backward prefix:prefix start:key]; levelDBIteratorIsValid(iter); levelDBMoveCursor(iter, backward)) {
        char *iKey;
        int iKeyLength;
        levelDBIteratorGetKey(iter, &iKey, &iKeyLength);
        if (prefix && memcmp(iKey, [prefix UTF8String], MIN((size_t)prefix.length, iKeyLength)) != 0) {
            break;
        }
        NSString *iKeyString = [[NSString alloc] initWithBytes:iKey length:iKeyLength encoding:NSUTF8StringEncoding];
        void *iData;
        int iDataLength;
        levelDBIteratorGetValue(iter, &iData, &iDataLength);
        id v = (predicate == nil) ? nil : _decoder(iKeyString, [NSData dataWithBytes:iData length:iDataLength]);
        iterate(iKeyString, v, &stop);
        if (stop) break;
    }
    levelDBDeleteIterator(iter);
}

- (void)enumerateKeysAndObjectsUsingBlock:(LevelDBKeyValueBlock)block {
    [self enumerateKeysAndObjectsBackward:false
                                   lazily:false
                            startingAtKey:nil
                      filteredByPredicate:nil
                                andPrefix:nil
                               usingBlock:block];
}

- (void)enumerateKeysAndObjectsBackward:(BOOL)backward
                                 lazily:(BOOL)lazily
                          startingAtKey:(NSString *)key
                    filteredByPredicate:(NSPredicate *)predicate
                              andPrefix:(NSString *)prefix
                             usingBlock:(id)block {
    
    [self enumerateKeysAndObjectsBackward:backward
                                   lazily:lazily
                            startingAtKey:key
                      filteredByPredicate:predicate
                                andPrefix:prefix
                               usingBlock:block];
}

#pragma mark - Bookkeeping

- (void)deleteDatabaseFromDisk {
    [self close];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error;
    [fileManager removeItemAtPath:_path error:&error];
}

- (void)close {
    levelDBDelete(_db);
}

- (BOOL)closed {
    return _db == NULL;
}

- (void)dealloc {
    [self close];
    [_name release];
    [_path release];
    [super dealloc];
}

@end
