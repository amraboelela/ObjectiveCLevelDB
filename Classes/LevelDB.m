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

#import <leveldb/leveldb.h>

#include "Common.h"

#define AssertDBExists(_db_) \
NSAssert(_db_ != NULL, @"Database reference is not existent (it has probably been closed)");

#pragma mark - Static functions

static void _seekToFirstOrKey(void *iter, NSString *key) {
    (key != nil) ? levelDBIteratorSeek(iter, [key UTF8String], key.length) : levelDBIteratorMoveToFirst(iter);
}

static void _moveCursor(void *iter, bool backward) {
    backward ? levelDBIteratorMoveBackward(iter) : levelDBIteratorMoveForward(iter);
}

#pragma mark - Public functions

NSString *getLibraryPath() {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    return [paths objectAtIndex:0];
}

NSString * const kLevelDBChangeType         = @"changeType";
NSString * const kLevelDBChangeTypePut      = @"put";
NSString * const kLevelDBChangeTypeDelete   = @"del";
NSString * const kLevelDBChangeValue        = @"value";
NSString * const kLevelDBChangeKey          = @"key";

/*
LevelDBOptions MakeLevelDBOptions() {
    return (LevelDBOptions) {true, true, false, false, true, 0, 0};
}
 
@interface LevelDB()

@end
*/

@implementation LevelDB

@synthesize name=_name;
@synthesize path=_path;
@synthesize encoder=_encoder;
@synthesize decoder=_decoder;

- (id)initWithPath:(NSString *)path name:(NSString *)name {
    self = [super init];
    if (self) {
        self.name = name;
        self.path = path;
        
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
    NSString *path = [getLibraryPath() stringByAppendingPathComponent:name];
    LevelDB *ldb = [[[self alloc] initWithPath:path name:name] autorelease];
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
    NSData *data = _encoder(key, value);
    
    int status = levelDBItemPut(_db, [key UTF8String], [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding], [data bytes], [data length]);
    if (status) {
        NSLog(@"Problem storing key/value pair in database");
    }
}

- (void)setObject:(id)value forKeyedSubscript:(NSString *)key {
    [self setObject:value forKey:key];
}

- (void)addEntriesFromDictionary:(NSDictionary *)dictionary {
    [dictionary enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [self setObject:obj forKey:key];
    }];
}

#pragma mark - Getters

- (id)objectForKey:(NSString *)key {
    AssertDBExists(_db);
    void *outData;
    int outDataLength;
    int status = levelDBItemGet(_db, [key UTF8String], [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding], &outData, &outDataLength);
    if (status != 0) {
        return nil;
    }
    NSData *data = [NSData dataWithBytes:outData length:outDataLength];
    return _decoder(key, data);
}

- (id)objectForKeyedSubscript:(id)key {
    return [self objectForKey:key];
}

- (id)objectsForKeys:(NSArray *)keys notFoundMarker:(id)marker {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:keys.count];
    [keys enumerateObjectsUsingBlock:^(id objId, NSUInteger idx, BOOL *stop) {
        id object = [self objectForKey:objId];
        if (object == nil) object = marker;
        [result insertObject:object atIndex:idx];
    }];
    return [NSArray arrayWithArray:result];
}

- (BOOL)objectExistsForKey:(NSString *)key {
    AssertDBExists(_db);
    
    void *outData;
    int outDataLength;
    int status = levelDBItemGet(_db, [key UTF8String], [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding], &outData, &outDataLength);
    if (status != 0) {
        return false;
    } else {
        return true;
    }
}

#pragma mark - Removers

- (void)removeObjectForKey:(NSString *)key {
    AssertDBExists(_db);

    int status = levelDBItemDelete(_db, [key UTF8String], [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
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
    void *iter = levelDBIteratorNew(_db);
    
    const void *prefixPtr = [prefix UTF8String];
    size_t prefixLen = prefix.length;
    
    for (_seekToFirstOrKey(iter, prefix); levelDBIteratorIsValid(iter); levelDBIteratorMoveForward(iter)) {
        char *iKey;
        int iKeyLength;
        levelDBIteratorGetKey(iter, &iKey, &iKeyLength);
        
        if (prefix && memcmp(iKey, prefixPtr, MIN(prefixLen, iKeyLength)) != 0) {
            break;
        }
        levelDBItemDelete(_db, iKey, iKeyLength);
    }
    levelDBIteratorDelete(iter);
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
    [self enumerateKeysAndObjectsBackward:NO
                                   lazily:NO
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
    [self enumerateKeysAndObjectsBackward:NO
                                   lazily:NO
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
            signed long long i = len - 1;

            char *startingKeyPtr = malloc(len);
            memcpy(startingKeyPtr, [startingKey UTF8String], len);
            unsigned char *keyChar;
            while (1) {
                if (i < 0) {
                    levelDBIteratorMoveToLast(iter);
                    break;
                }
                keyChar = (unsigned char *)startingKeyPtr + i;
                if (*keyChar < 255) {
                    *keyChar = *keyChar + 1;
                    levelDBIteratorSeek(iter, startingKeyPtr, len);
                    if (!levelDBIteratorIsValid(iter)) {
                        levelDBIteratorMoveToLast(iter);
                    }
                    break;
                }
                i--;
            };
            free(startingKeyPtr);
            if (!levelDBIteratorIsValid(iter)) {
                return;
            }
            char *iKey;
            int iKeyLength;
            levelDBIteratorGetKey(iter, &iKey, &iKeyLength);
            if (len > 0 && prefix != nil) {
                signed int cmp = memcmp(iKey, [startingKey UTF8String], len);
                if (cmp > 0) {
                    levelDBIteratorMoveBackward(iter);
                }
            }
        } else {
            // Otherwise, we start at the provided prefix
            levelDBIteratorSeek(iter, [startingKey UTF8String], len);
        }
    } else if (key) {
        levelDBIteratorSeek(iter, [key UTF8String], key.length);
    } else if (backward) {
        levelDBIteratorMoveToLast(iter);
    } else {
        levelDBIteratorMoveToFirst(iter);
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
    void *iter = levelDBIteratorNew(_db);
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
    
    for ([self _startIterator:iter backward:backward prefix:prefix start:key]; levelDBIteratorIsValid(iter); _moveCursor(iter, backward)) {
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
        if (stop) {
            break;
        }
    }
    levelDBIteratorDelete(iter);
}

- (void)enumerateKeysAndObjectsBackward:(BOOL)backward
                                 lazily:(BOOL)lazily
                          startingAtKey:(NSString *)key
                    filteredByPredicate:(NSPredicate *)predicate
                              andPrefix:(NSString *)prefix
                             usingBlock:(id)block {
    
    AssertDBExists(_db);
    void *iter = levelDBIteratorNew(_db);
    BOOL stop = false;
    
    LevelDBLazyKeyValueBlock iterate = (predicate != nil)
    
    // If there is a predicate:
    ? ^ (NSString *key, LevelDBValueGetterBlock valueGetter, BOOL *stop) {
        // We need to get the value, whether the `lazily` flag was set or not
        id value = valueGetter();
        
        // If the predicate yields positive, we call the block
        if ([predicate evaluateWithObject:value]) {
            if (lazily) {
                ((LevelDBLazyKeyValueBlock)block)(key, valueGetter, stop);
            } else {
                ((LevelDBKeyValueBlock)block)(key, value, stop);
            }
        }
    }
    
    // Otherwise, we call the block
    : ^ (NSString *key, LevelDBValueGetterBlock valueGetter, BOOL *stop) {
        if (lazily) {
            ((LevelDBLazyKeyValueBlock)block)(key, valueGetter, stop);
        } else {
            ((LevelDBKeyValueBlock)block)(key, valueGetter(), stop);
        }
    };
    LevelDBValueGetterBlock getter;
        
    for ([self _startIterator:iter backward:backward prefix:prefix start:key]; levelDBIteratorIsValid(iter); _moveCursor(iter, backward)) {
        
        char *iKey;
        int iKeyLength;
        levelDBIteratorGetKey(iter, &iKey, &iKeyLength);
        if (prefix && memcmp(iKey, [prefix UTF8String], MIN((size_t)prefix.length, iKeyLength)) != 0) {
            break;
        }
        NSString *iKeyString = [[NSString alloc] initWithBytes:iKey length:iKeyLength encoding:NSUTF8StringEncoding];
        
        getter = ^ id {
            void *iData;
            int iDataLength;
            levelDBIteratorGetValue(iter, &iData, &iDataLength);
            id v = _decoder(iKeyString, [NSData dataWithBytes:iData length:iDataLength]);
            return v;
        };
        iterate(iKeyString, getter, &stop);
        if (stop) {
            break;
        }
    }
    levelDBIteratorDelete(iter);
}

- (void)enumerateKeysAndObjectsUsingBlock:(LevelDBKeyValueBlock)block {
    [self enumerateKeysAndObjectsBackward:false
                                   lazily:false
                            startingAtKey:nil
                      filteredByPredicate:nil
                                andPrefix:nil
                               usingBlock:block];
}

/*
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
}*/

#pragma mark - Bookkeeping

- (void)deleteDatabaseFromDisk {
    [self close];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error;
    [fileManager removeItemAtPath:_path error:&error];
}

- (void)close {
    if (_db) {
        levelDBDelete(_db);
        _db = NULL;
    }
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
