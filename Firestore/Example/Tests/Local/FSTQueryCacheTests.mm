/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Firestore/Example/Tests/Local/FSTQueryCacheTests.h"

#include <set>

#import "Firestore/Source/Core/FSTQuery.h"
#import "Firestore/Source/Core/FSTSnapshotVersion.h"
#import "Firestore/Source/Local/FSTEagerGarbageCollector.h"
#import "Firestore/Source/Local/FSTPersistence.h"
#import "Firestore/Source/Local/FSTQueryData.h"
#import "Firestore/Source/Local/FSTRemoteDocumentCache.h"

#import "Firestore/Example/Tests/Util/FSTHelpers.h"
#import "Firestore/third_party/Immutable/Tests/FSTImmutableSortedSet+Testing.h"

#include "Firestore/core/src/firebase/firestore/model/document_key.h"
#include "Firestore/core/test/firebase/firestore/testutil/testutil.h"

namespace testutil = firebase::firestore::testutil;
using firebase::firestore::model::DocumentKey;

NS_ASSUME_NONNULL_BEGIN

@implementation FSTQueryCacheTests {
  FSTQuery *_queryRooms;
  FSTListenSequenceNumber _previousSequenceNumber;
  FSTTargetID _previousTargetID;
  FSTTestSnapshotVersion _previousSnapshotVersion;
}

- (void)setUp {
  [super setUp];

  _queryRooms = FSTTestQuery("rooms");
  _previousSequenceNumber = 1000;
  _previousTargetID = 500;
  _previousSnapshotVersion = 100;
}

- (void)tearDown {
  [self.persistence shutdown];
}

/**
 * Xcode will run tests from any class that extends XCTestCase, but this doesn't work for
 * FSTSpecTests since it is incomplete without the implementations supplied by its subclasses.
 */
- (BOOL)isTestBaseClass {
  return [self class] == [FSTQueryCacheTests class];
}

- (void)testReadQueryNotInCache {
  if ([self isTestBaseClass]) return;

  self.persistence.run("testReadQueryNotInCache",
                       [&]() { XCTAssertNil([self.queryCache queryDataForQuery:_queryRooms]); });
}

- (void)testSetAndReadAQuery {
  if ([self isTestBaseClass]) return;

  self.persistence.run("testSetAndReadAQuery", [&]() {
    FSTQueryData *queryData = [self queryDataWithQuery:_queryRooms];
    [self.queryCache addQueryData:queryData];

    FSTQueryData *result = [self.queryCache queryDataForQuery:_queryRooms];
    XCTAssertEqualObjects(result.query, queryData.query);
    XCTAssertEqual(result.targetID, queryData.targetID);
    XCTAssertEqualObjects(result.resumeToken, queryData.resumeToken);
  });
}

- (void)testCanonicalIDCollision {
  if ([self isTestBaseClass]) return;

  self.persistence.run("testCanonicalIDCollision", [&]() {
    // Type information is currently lost in our canonicalID implementations so this currently an
    // easy way to force colliding canonicalIDs
    FSTQuery *q1 = [FSTTestQuery("a") queryByAddingFilter:FSTTestFilter("foo", @"==", @(1))];
    FSTQuery *q2 = [FSTTestQuery("a") queryByAddingFilter:FSTTestFilter("foo", @"==", @"1")];
    XCTAssertEqualObjects(q1.canonicalID, q2.canonicalID);

    FSTQueryData *data1 = [self queryDataWithQuery:q1];
    [self.queryCache addQueryData:data1];

    // Using the other query should not return the query cache entry despite equal canonicalIDs.
    XCTAssertNil([self.queryCache queryDataForQuery:q2]);
    XCTAssertEqualObjects([self.queryCache queryDataForQuery:q1], data1);

    FSTQueryData *data2 = [self queryDataWithQuery:q2];
    [self.queryCache addQueryData:data2];
    XCTAssertEqual([self.queryCache count], 2);

    XCTAssertEqualObjects([self.queryCache queryDataForQuery:q1], data1);
    XCTAssertEqualObjects([self.queryCache queryDataForQuery:q2], data2);

    [self.queryCache removeQueryData:data1];
    XCTAssertNil([self.queryCache queryDataForQuery:q1]);
    XCTAssertEqualObjects([self.queryCache queryDataForQuery:q2], data2);
    XCTAssertEqual([self.queryCache count], 1);

    [self.queryCache removeQueryData:data2];
    XCTAssertNil([self.queryCache queryDataForQuery:q1]);
    XCTAssertNil([self.queryCache queryDataForQuery:q2]);
    XCTAssertEqual([self.queryCache count], 0);
  });
}

- (void)testSetQueryToNewValue {
  if ([self isTestBaseClass]) return;

  self.persistence.run("testSetQueryToNewValue", [&]() {
    FSTQueryData *queryData1 =
        [self queryDataWithQuery:_queryRooms targetID:1 listenSequenceNumber:10 version:1];
    [self.queryCache addQueryData:queryData1];

    FSTQueryData *queryData2 =
        [self queryDataWithQuery:_queryRooms targetID:1 listenSequenceNumber:10 version:2];
    [self.queryCache addQueryData:queryData2];

    FSTQueryData *result = [self.queryCache queryDataForQuery:_queryRooms];
    XCTAssertNotEqualObjects(queryData2.resumeToken, queryData1.resumeToken);
    XCTAssertNotEqualObjects(queryData2.snapshotVersion, queryData1.snapshotVersion);
    XCTAssertEqualObjects(result.resumeToken, queryData2.resumeToken);
    XCTAssertEqualObjects(result.snapshotVersion, queryData2.snapshotVersion);
  });
}

- (void)testRemoveQuery {
  if ([self isTestBaseClass]) return;

  self.persistence.run("testRemoveQuery", [&]() {
    FSTQueryData *queryData1 = [self queryDataWithQuery:_queryRooms];
    [self.queryCache addQueryData:queryData1];

    [self.queryCache removeQueryData:queryData1];

    FSTQueryData *result = [self.queryCache queryDataForQuery:_queryRooms];
    XCTAssertNil(result);
  });
}

- (void)testRemoveNonExistentQuery {
  if ([self isTestBaseClass]) return;

  self.persistence.run("testRemoveNonExistentQuery", [&]() {
    FSTQueryData *queryData = [self queryDataWithQuery:_queryRooms];

    // no-op, but make sure it doesn't throw.
    XCTAssertNoThrow([self.queryCache removeQueryData:queryData]);
  });
}

- (void)testRemoveQueryRemovesMatchingKeysToo {
  if ([self isTestBaseClass]) return;

  self.persistence.run("testRemoveQueryRemovesMatchingKeysToo", [&]() {
    FSTQueryData *rooms = [self queryDataWithQuery:_queryRooms];
    [self.queryCache addQueryData:rooms];

    DocumentKey key1 = testutil::Key("rooms/foo");
    DocumentKey key2 = testutil::Key("rooms/bar");
    [self addMatchingKey:key1 forTargetID:rooms.targetID atSequenceNumber:1];
    [self addMatchingKey:key2 forTargetID:rooms.targetID atSequenceNumber:1];

    XCTAssertTrue([self.queryCache containsKey:key1]);
    XCTAssertTrue([self.queryCache containsKey:key2]);

    [self.queryCache removeQueryData:rooms];
    XCTAssertFalse([self.queryCache containsKey:key1]);
    XCTAssertFalse([self.queryCache containsKey:key2]);
  });
}

- (void)testAddOrRemoveMatchingKeys {
  if ([self isTestBaseClass]) return;

  self.persistence.run("testAddOrRemoveMatchingKeys", [&]() {
    DocumentKey key = testutil::Key("foo/bar");

    XCTAssertFalse([self.queryCache containsKey:key]);

    [self addMatchingKey:key forTargetID:1 atSequenceNumber:10];
    XCTAssertTrue([self.queryCache containsKey:key]);

    [self addMatchingKey:key forTargetID:2 atSequenceNumber:11];
    XCTAssertTrue([self.queryCache containsKey:key]);

    [self removeMatchingKey:key forTargetID:1];
    XCTAssertTrue([self.queryCache containsKey:key]);

    [self removeMatchingKey:key forTargetID:2];
    XCTAssertFalse([self.queryCache containsKey:key]);
  });
}

- (void)testRemoveMatchingKeysForTargetID {
  if ([self isTestBaseClass]) return;

  self.persistence.run("testRemoveMatchingKeysForTargetID", [&]() {
    DocumentKey key1 = testutil::Key("foo/bar");
    DocumentKey key2 = testutil::Key("foo/baz");
    DocumentKey key3 = testutil::Key("foo/blah");

    [self addMatchingKey:key1 forTargetID:1 atSequenceNumber:10];
    [self addMatchingKey:key2 forTargetID:1 atSequenceNumber:10];
    [self addMatchingKey:key3 forTargetID:2 atSequenceNumber:11];
    XCTAssertTrue([self.queryCache containsKey:key1]);
    XCTAssertTrue([self.queryCache containsKey:key2]);
    XCTAssertTrue([self.queryCache containsKey:key3]);

    [self.queryCache removeMatchingKeysForTargetID:1];
    XCTAssertFalse([self.queryCache containsKey:key1]);
    XCTAssertFalse([self.queryCache containsKey:key2]);
    XCTAssertTrue([self.queryCache containsKey:key3]);

    [self.queryCache removeMatchingKeysForTargetID:2];
    XCTAssertFalse([self.queryCache containsKey:key1]);
    XCTAssertFalse([self.queryCache containsKey:key2]);
    XCTAssertFalse([self.queryCache containsKey:key3]);
  });
}

- (void)testRemoveEmitsGarbageEvents {
  if ([self isTestBaseClass]) return;

  DocumentKey room1 = testutil::Key("rooms/bar");
  DocumentKey room2 = testutil::Key("rooms/foo");
  FSTQueryData *rooms = [self queryDataWithQuery:FSTTestQuery("rooms")];

  DocumentKey hall1 = testutil::Key("halls/bar");
  DocumentKey hall2 = testutil::Key("halls/foo");
  FSTQueryData *halls = [self queryDataWithQuery:FSTTestQuery("halls")];

  self.persistence.run("testRemoveEmitsGarbageEvents", [&]() {
    //FSTEagerGarbageCollector *garbageCollector = [[FSTEagerGarbageCollector alloc] init];
    //[garbageCollector addGarbageSource:self.queryCache];
    //XCTAssertEqual([garbageCollector collectGarbage], std::set<DocumentKey>({}));

    [self.queryCache addQueryData:rooms];
    [self addMatchingKey:room1 forTargetID:rooms.targetID atSequenceNumber:rooms.sequenceNumber];
    [self addMatchingKey:room2 forTargetID:rooms.targetID atSequenceNumber:rooms.sequenceNumber];

    [self.queryCache addQueryData:halls];
    [self addMatchingKey:hall1 forTargetID:halls.targetID atSequenceNumber:halls.sequenceNumber];
    [self addMatchingKey:hall2 forTargetID:halls.targetID atSequenceNumber:halls.sequenceNumber];
  });

  self.persistence.run("garbage check 1", [&]() {
    // Nothing should have been removed yet.
    XCTAssertTrue([self.queryCache containsKey:room1]);
    XCTAssertTrue([self.queryCache containsKey:room2]);
    XCTAssertTrue([self.queryCache containsKey:hall1]);
    XCTAssertTrue([self.queryCache containsKey:hall2]);

    // trigger removal of room1
    [self removeMatchingKey:room1 forTargetID:rooms.targetID];
  });

  self.persistence.run("garbage check 2", [&]() {
    // Just room1 should be removed
    XCTAssertFalse([self.queryCache containsKey:room1]);
    XCTAssertTrue([self.queryCache containsKey:room2]);
    XCTAssertTrue([self.queryCache containsKey:hall1]);
    XCTAssertTrue([self.queryCache containsKey:hall2]);

    // trigger removal of everything associated with rooms
    [self.queryCache removeQueryData:rooms];
  });

  self.persistence.run("garbage check 3", [&]() {
    // All of the rooms should have been removed.
    XCTAssertFalse([self.queryCache containsKey:room1]);
    XCTAssertFalse([self.queryCache containsKey:room2]);
    XCTAssertTrue([self.queryCache containsKey:hall1]);
    XCTAssertTrue([self.queryCache containsKey:hall2]);

    // trigger removal of everything associated with halls
    [self.queryCache removeMatchingKeysForTargetID:halls.targetID];
  });

  self.persistence.run("garbage check 4", [&]() {
    // Everything should have been removed.
    XCTAssertFalse([self.queryCache containsKey:room1]);
    XCTAssertFalse([self.queryCache containsKey:room2]);
    XCTAssertFalse([self.queryCache containsKey:hall1]);
    XCTAssertFalse([self.queryCache containsKey:hall2]);

  });
}

- (void)testMatchingKeysForTargetID {
  if ([self isTestBaseClass]) return;

  self.persistence.run("testMatchingKeysForTargetID", [&]() {
    DocumentKey key1 = testutil::Key("foo/bar");
    DocumentKey key2 = testutil::Key("foo/baz");
    DocumentKey key3 = testutil::Key("foo/blah");

    [self addMatchingKey:key1 forTargetID:1 atSequenceNumber:10];
    [self addMatchingKey:key2 forTargetID:1 atSequenceNumber:10];
    [self addMatchingKey:key3 forTargetID:2 atSequenceNumber:11];

    FSTAssertEqualSets([self.queryCache matchingKeysForTargetID:1], (@[ key1, key2 ]));
    FSTAssertEqualSets([self.queryCache matchingKeysForTargetID:2], @[ key3 ]);

    [self addMatchingKey:key1 forTargetID:2 atSequenceNumber:12];
    FSTAssertEqualSets([self.queryCache matchingKeysForTargetID:1], (@[ key1, key2 ]));
    FSTAssertEqualSets([self.queryCache matchingKeysForTargetID:2], (@[ key1, key3 ]));
  });
}

- (void)testHighestListenSequenceNumber {
  if ([self isTestBaseClass]) return;

  self.persistence.run("testHighestListenSequenceNumber", [&]() {
    FSTQueryData *query1 = [[FSTQueryData alloc] initWithQuery:FSTTestQuery("rooms")
                                                      targetID:1
                                          listenSequenceNumber:10
                                                       purpose:FSTQueryPurposeListen];
    [self.queryCache addQueryData:query1];
    FSTQueryData *query2 = [[FSTQueryData alloc] initWithQuery:FSTTestQuery("halls")
                                                      targetID:2
                                          listenSequenceNumber:20
                                                       purpose:FSTQueryPurposeListen];
    [self.queryCache addQueryData:query2];
    XCTAssertEqual([self.queryCache highestListenSequenceNumber], 20);

    // TargetIDs never come down.
    [self.queryCache removeQueryData:query2];
    XCTAssertEqual([self.queryCache highestListenSequenceNumber], 20);

    // A query with an empty result set still counts.
    FSTQueryData *query3 = [[FSTQueryData alloc] initWithQuery:FSTTestQuery("garages")
                                                      targetID:42
                                          listenSequenceNumber:100
                                                       purpose:FSTQueryPurposeListen];
    [self.queryCache addQueryData:query3];
    XCTAssertEqual([self.queryCache highestListenSequenceNumber], 100);

    [self.queryCache removeQueryData:query1];
    XCTAssertEqual([self.queryCache highestListenSequenceNumber], 100);

    [self.queryCache removeQueryData:query3];
    XCTAssertEqual([self.queryCache highestListenSequenceNumber], 100);
  });

  // Verify that the highestTargetID even survives restarts.
  self.persistence.run("testHighestListenSequenceNumber restart", [&]() {
    self.queryCache = [self.persistence queryCache];
    [self.queryCache start];
    XCTAssertEqual([self.queryCache highestListenSequenceNumber], 100);
  });
}

- (void)testHighestTargetID {
  if ([self isTestBaseClass]) return;

  self.persistence.run("testHighestTargetID", [&]() {
    XCTAssertEqual([self.queryCache highestTargetID], 0);

    FSTQueryData *query1 = [[FSTQueryData alloc] initWithQuery:FSTTestQuery("rooms")
                                                      targetID:1
                                          listenSequenceNumber:10
                                                       purpose:FSTQueryPurposeListen];
    DocumentKey key1 = testutil::Key("rooms/bar");
    DocumentKey key2 = testutil::Key("rooms/foo");
    [self.queryCache addQueryData:query1];
    [self addMatchingKey:key1 forTargetID:1 atSequenceNumber:10];
    [self addMatchingKey:key2 forTargetID:1 atSequenceNumber:10];

    FSTQueryData *query2 = [[FSTQueryData alloc] initWithQuery:FSTTestQuery("halls")
                                                      targetID:2
                                          listenSequenceNumber:20
                                                       purpose:FSTQueryPurposeListen];
    DocumentKey key3 = testutil::Key("halls/foo");
    [self.queryCache addQueryData:query2];
    [self addMatchingKey:key3 forTargetID:2 atSequenceNumber:11];
    XCTAssertEqual([self.queryCache highestTargetID], 2);

    // TargetIDs never come down.
    [self.queryCache removeQueryData:query2];
    XCTAssertEqual([self.queryCache highestTargetID], 2);

    // A query with an empty result set still counts.
    FSTQueryData *query3 = [[FSTQueryData alloc] initWithQuery:FSTTestQuery("garages")
                                                      targetID:42
                                          listenSequenceNumber:100
                                                       purpose:FSTQueryPurposeListen];
    [self.queryCache addQueryData:query3];
    XCTAssertEqual([self.queryCache highestTargetID], 42);

    [self.queryCache removeQueryData:query1];
    XCTAssertEqual([self.queryCache highestTargetID], 42);

    [self.queryCache removeQueryData:query3];
    XCTAssertEqual([self.queryCache highestTargetID], 42);
  });

  // Verify that the highestTargetID even survives restarts.
  self.persistence.run("testHighestTargetID restart", [&]() {
    self.queryCache = [self.persistence queryCache];
    [self.queryCache start];
    XCTAssertEqual([self.queryCache highestTargetID], 42);
  });
}

- (void)testLastRemoteSnapshotVersion {
  if ([self isTestBaseClass]) return;

  self.persistence.run("testLastRemoteSnapshotVersion", [&]() {
    XCTAssertEqualObjects([self.queryCache lastRemoteSnapshotVersion],
                          [FSTSnapshotVersion noVersion]);

    // Can set the snapshot version.
    [self.queryCache setLastRemoteSnapshotVersion:FSTTestVersion(42)];
    XCTAssertEqualObjects([self.queryCache lastRemoteSnapshotVersion], FSTTestVersion(42));
  });

  // Snapshot version persists restarts.
  self.queryCache = [self.persistence queryCache];
  self.persistence.run("testLastRemoteSnapshotVersion restart", [&]() {
    [self.queryCache start];
    XCTAssertEqualObjects([self.queryCache lastRemoteSnapshotVersion], FSTTestVersion(42));
  });
}

#pragma mark - Helpers

/**
 * Creates a new FSTQueryData object from the given parameters, synthesizing a resume token from
 * the snapshot version.
 */
- (FSTQueryData *)queryDataWithQuery:(FSTQuery *)query {
  return [self queryDataWithQuery:query
                         targetID:++_previousTargetID
             listenSequenceNumber:++_previousSequenceNumber
                          version:++_previousSnapshotVersion];
}

- (FSTQueryData *)queryDataWithQuery:(FSTQuery *)query
                            targetID:(FSTTargetID)targetID
                listenSequenceNumber:(FSTListenSequenceNumber)sequenceNumber
                             version:(FSTTestSnapshotVersion)version {
  NSData *resumeToken = FSTTestResumeTokenFromSnapshotVersion(version);
  return [[FSTQueryData alloc] initWithQuery:query
                                    targetID:targetID
                        listenSequenceNumber:sequenceNumber
                                     purpose:FSTQueryPurposeListen
                             snapshotVersion:FSTTestVersion(version)
                                 resumeToken:resumeToken];
}

- (void)addMatchingKey:(FSTDocumentKey *)key
           forTargetID:(FSTTargetID)targetID
      atSequenceNumber:(FSTListenSequenceNumber)sequenceNumber {
  FSTDocumentKeySet *keys = [FSTDocumentKeySet keySet];
  keys = [keys setByAddingObject:key];

  [self.queryCache addMatchingKeys:keys forTargetID:targetID atSequenceNumber:sequenceNumber];
}

- (void)removeMatchingKey:(const DocumentKey &)key forTargetID:(FSTTargetID)targetID {
  FSTDocumentKeySet *keys = [FSTDocumentKeySet keySet];
  keys = [keys setByAddingObject:key];
  [self.queryCache removeMatchingKeys:keys forTargetID:targetID atSequenceNumber:0];
}

@end

NS_ASSUME_NONNULL_END
